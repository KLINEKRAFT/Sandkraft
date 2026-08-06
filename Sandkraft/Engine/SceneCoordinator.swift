//
//  SceneCoordinator.swift
//  Sandkraft
//
//  The one place the game model and the renderer meet.
//
//  The model says what happened. The renderer knows how to draw. This turns the
//  first into the second, once per frame, and owns the small amount of state
//  that genuinely belongs to neither: where the cursor is in the world, whether a
//  gesture is in flight, and the one-frame lag between asking the GPU what is
//  under the finger and being told.
//

import Foundation
import Metal
import MetalKit
import simd

@MainActor
final class SceneCoordinator: NSObject, ObservableObject {

    let renderer: Renderer
    let model: GameModel
    let haptics = Haptics()
    let audio: AudioDirector

    /// Where the last GPU pick landed. Updated a frame after it is requested,
    /// which is imperceptible while drawing and worth the alternative — reading
    /// four megabytes of heightfield back to the CPU every frame.
    private(set) var cursorWorld = SIMD3<Float>(0, 0, 0)
    private(set) var cursorValid = false

    private var viewportSize = SIMD2<Float>(1, 1)
    private var lastPointer = SIMD2<Float>.zero
    private var pointerActive = false
    private var strokeCaptured = false
    private var needsBeachReset = true
    private var needsParticleClear = true
    private var mouldRotation: Float = 0

    /// Queued for the next encoded frame, because a stamp must land on exactly
    /// one substep.
    private var pendingStamp: MouldStamp?

    /// Rate-limits the emission of dig and pour particles. Emitting every frame
    /// at 120 Hz is twice as many grains as at 60 Hz for the same stroke, which
    /// would make the effect frame-rate dependent.
    private var effectAccumulator: Double = 0

    init(renderer: Renderer, model: GameModel) {
        self.renderer = renderer
        self.model = model
        self.audio = AudioDirector()
        super.init()
    }

    // MARK: - Frame

    func advance(dt: Double) {
        model.update(dt: dt)

        // Push everything the renderer needs for this frame.
        var input = FrameInput()
        input.environment = model.environment()
        input.atmosphere = model.atmosphere
        input.look = model.look
        input.dayFraction = model.dayFraction
        input.cloudCover = model.cloudCover
        input.highWater = model.highWaterLine
        input.paused = model.isPaused
        input.reducedMotion = model.reducedMotion

        input.cursorWorld = SIMD2(cursorWorld.x, cursorWorld.z)
        input.cursorRadius = Float(model.tool.radius * model.brushScale)
        input.cursorVisible = cursorValid && model.phase != .briefing && model.phase != .reckoning

        if model.selectedToolID == .mould, cursorValid {
            input.ghostVisible = input.cursorVisible
            input.ghostOrigin = SIMD2(cursorWorld.x, cursorWorld.z)
            input.ghostRadius = Float(model.mould.radius * model.brushScale)
            input.ghostRotation = mouldRotation
            input.ghostShape = model.mould.shapeIndex
            input.ghostDetail = Float(model.mould.detail)
        }

        input.props = model.gpuProps()
        input.lanterns = model.gpuLanterns()
        renderer.input = input

        // The camera follows your work — but only *between* strokes.
        //
        // Moving the pivot during a drag is a feedback loop: the pivot slides
        // toward the cursor, which shifts the view, which moves where the ray
        // through the cursor lands, which the pivot then chases. You end up
        // digging at a target that is running away from you. The pivot is
        // updated once, when the stroke ends.
        renderer.camera.update(dt: Float(dt)) { [weak self] p in
            self?.approximateGroundHeight(at: p) ?? 0
        }

        model.ingest(frameDuration: renderer.smoothedFrameDuration)
        drainEffects(dt: dt)
        audio.update(model: model, dt: dt)
    }

    /// A cheap CPU stand-in for the heightfield, used only to keep the camera out
    /// of the sand. Accurate enough for that and nothing else: it is the analytic
    /// bed with no built sand in it, which is exactly the surface the camera
    /// should not be allowed under.
    private func approximateGroundHeight(at p: SIMD2<Float>) -> Float {
        // Mirrors sk_bedrock's dune and pad terms without the headlands, which the
        // camera is clamped away from anyway.
        let z = p.y
        var y: Float = 1.55 - 0.0705 * (z + 24)
        y += 3.35 * smoothstepf(-21.5, -31.0, z) * 0.95
        let pad = smoothstepf(23, 15, length((p - SIMD2(0, -7)) * SIMD2(1, 0.92)))
        y -= 0.98 * pad
        return y + 0.9 * pad          // roughly the loose bed sitting on top
    }

    private func drainEffects(dt: Double) {
        for effect in model.drainEffects() {
            switch effect {
            case .mouldTurnedOut(let world, let moisture):
                pendingStamp = model.mouldStamp(at: world, moisture: moisture, rotation: mouldRotation)
                haptics.impact(.heavy)
                audio.play(.mouldTurnedOut)
            case .propPlaced:
                haptics.selection()
                audio.play(.propPlaced)
            case .propToppled(let prop):
                haptics.impact(.light)
                audio.play(.propToppled)
                renderer.particles.emitCollapseDust(at: prop.position, strength: 0.6)
            case .toolChanged:
                haptics.selection()
            case .phaseChanged(let phase):
                haptics.impact(phase == .flooding ? .heavy : .medium)
                audio.play(phase == .flooding ? .floodBegins : .phaseChange)
            case .objectiveMet:
                haptics.success()
                audio.play(.objectiveMet)
            case .undoPerformed:
                haptics.impact(.light)
            case .digSpray(let at, let moisture, let volume, let toward):
                renderer.particles.emitDigSpray(at: at, moisture: moisture, volume: volume, toward: toward)
            case .pour(let at, let moisture, let volume):
                renderer.particles.emitPour(at: at, moisture: moisture, volume: volume)
            case .collapse(let at, let strength):
                renderer.particles.emitCollapseDust(at: at, strength: strength)
            }
        }
        _ = dt
    }

    // MARK: - Input

    func viewportChanged(to size: SIMD2<Float>) {
        viewportSize = size
    }

    /// Convert a point in the view into a world position, using the last GPU pick
    /// as the reference height. The GPU refines it on the next frame; this makes
    /// the first sample of a stroke land somewhere sensible instead of at the
    /// origin.
    private func approximateWorld(at point: SIMD2<Float>) -> SIMD3<Float>? {
        let ray = renderer.camera.ray(atViewportPoint: point, viewportSize: viewportSize)
        let planeY = cursorValid ? cursorWorld.y : 0.3
        guard ray.direction.y < -0.001 else { return nil }
        let t = (planeY - ray.origin.y) / ray.direction.y
        guard t > 0 else { return nil }
        return ray.origin + ray.direction * t
    }

    private func requestPick(at point: SIMD2<Float>) {
        let ray = renderer.camera.ray(atViewportPoint: point, viewportSize: viewportSize)
        renderer.pendingPickRay = ray
    }

    func pointerDown(at point: SIMD2<Float>) {
        lastPointer = point
        pointerActive = true
        requestPick(at: point)

        guard let world = approximateWorld(at: point) else { return }
        let sample = StrokeSample(world: world,
                                  moisture: Float(model.hoverMoisture),
                                  packing: Float(model.hoverPacking),
                                  sandDepth: 0, bedrock: 0)
        model.beginStroke(sample)
        strokeCaptured = false
        haptics.impact(.light)
        audio.beginTool(model.selectedToolID)
    }

    func pointerMoved(to point: SIMD2<Float>) {
        guard pointerActive else {
            // Hover on the Mac. Still worth a pick: the moisture readout under an
            // idle cursor is how people learn where the damp sand is.
            requestPick(at: point)
            lastPointer = point
            return
        }
        lastPointer = point
        requestPick(at: point)

        guard let world = approximateWorld(at: point) else { return }
        let sample = StrokeSample(world: cursorValid ? cursorWorld : world,
                                  moisture: Float(model.hoverMoisture),
                                  packing: Float(model.hoverPacking),
                                  sandDepth: 0, bedrock: 0)
        model.continueStroke(sample)
    }

    func pointerUp() {
        guard pointerActive else { return }
        pointerActive = false
        model.endStroke()
        audio.endTool()
        // Now that nothing is being dragged, bring the pivot to where the work
        // just happened. This is the whole "no pan gesture needed" idea, and it
        // only works if it happens between strokes rather than during them.
        if cursorValid { renderer.camera.focus(on: cursorWorld) }
    }

    func pointerCancelled() {
        pointerActive = false
        model.cancelStroke()
        audio.endTool()
    }

    func orbit(dx: Float, dy: Float) {
        renderer.camera.isInteracting = true
        // Radians per point. Tuned so a full swipe across an iPhone is a little
        // under half a turn — enough to get behind a castle in one gesture.
        renderer.camera.orbit(deltaAzimuth: -dx * 0.0062, deltaElevation: dy * 0.0050)
    }

    func dolly(scale: Float) {
        renderer.camera.isInteracting = true
        renderer.camera.dolly(scale: scale)
    }

    func pan(dx: Float, dy: Float) {
        renderer.camera.isInteracting = true
        renderer.camera.pan(dx: dx, dy: dy, viewportHeight: viewportSize.y)
    }

    func endCameraGesture() {
        renderer.camera.isInteracting = false
    }

    func rotateMould(by radians: Float) {
        mouldRotation += radians
    }

    // MARK: - Commands

    func undo() {
        guard let commandBuffer = renderer.context.commandQueue.makeCommandBuffer() else { return }
        if renderer.simulation.undo(in: commandBuffer) {
            haptics.impact(.light)
            audio.play(.undo)
        }
        commandBuffer.commit()
        publishUndoState()
    }

    func redo() {
        guard let commandBuffer = renderer.context.commandQueue.makeCommandBuffer() else { return }
        if renderer.simulation.redo(in: commandBuffer) {
            haptics.impact(.light)
        }
        commandBuffer.commit()
        publishUndoState()
    }

    private func publishUndoState() {
        model.ingest(canUndo: renderer.simulation.canUndo, canRedo: renderer.simulation.canRedo)
    }

    func resetBeach() {
        needsBeachReset = true
    }

    // MARK: - Encoding hooks
    //
    // Called by the MTKView delegate immediately before the renderer encodes, so
    // brush and stamp state land on the same command buffer as the solver step
    // they are meant to affect.

    func prepareForEncoding(commandBuffer: MTLCommandBuffer) -> Bool {
        var didWork = false

        if needsBeachReset {
            renderer.simulation.reset(seaBase: model.currentSeaLevel, in: commandBuffer)
            needsBeachReset = false
            didWork = true
        }
        if needsParticleClear {
            renderer.particles.clear(in: commandBuffer)
            needsParticleClear = false
            didWork = true
        }

        // Undo capture: one snapshot per gesture, taken at the moment the first
        // brush of the stroke is about to be applied.
        if model.isStroking, !strokeCaptured {
            renderer.simulation.captureUndoState(in: commandBuffer)
            strokeCaptured = true
        }
        if !model.isStroking, strokeCaptured {
            renderer.simulation.commitUndoState(in: commandBuffer)
            strokeCaptured = false
            publishUndoState()
        }

        renderer.simulation.stroke = model.currentBrush() ?? BrushStroke()
        if let stamp = pendingStamp {
            renderer.simulation.armStamp(stamp)
            pendingStamp = nil
        }
        return didWork
    }

    func afterEncoding() {
        // Consume the GPU's answers from last frame.
        let pick = renderer.simulation.pick
        cursorValid = pick.point.w > 0.5
        if cursorValid {
            cursorWorld = SIMD3(pick.point.x, pick.point.y, pick.point.z)
        }
        model.ingest(pick: pick)
        model.ingest(metrics: renderer.simulation.metrics,
                     baselineVolume: renderer.simulation.baselineVolume)

        // Adornments follow the sand under them.
        for prop in model.props where !prop.toppled {
            // Only the props near the cursor get refreshed each frame; a full
            // sweep would need a pick per prop per frame, and the sand does not
            // move fast enough to notice the difference.
            let d = distance(SIMD2(prop.position.x, prop.position.z),
                             SIMD2(cursorWorld.x, cursorWorld.z))
            if d < 3.5, cursorValid {
                model.updatePropGround(id: prop.id, groundY: cursorWorld.y)
            }
        }
    }

    /// Emit the particles for whatever the brush is doing, at a fixed rate.
    func emitToolEffects(dt: Double) {
        guard model.isStroking, cursorValid else { effectAccumulator = 0; return }
        effectAccumulator += dt
        let interval = 1.0 / 30.0
        guard effectAccumulator >= interval else { return }
        effectAccumulator -= interval

        let tool = model.tool
        let moisture = Float(model.hoverMoisture)
        switch tool.id {
        case .dig:
            let toward = SIMD2<Float>(renderer.camera.screenRight.x, renderer.camera.screenRight.z) * 0.4
            renderer.particles.emitDigSpray(at: cursorWorld, moisture: moisture,
                                            volume: 0.010, toward: toward)
        case .pour, .drip:
            if !model.pailIsEmpty || model.mode == .shore {
                renderer.particles.emitPour(at: cursorWorld,
                                            moisture: Float(model.pailMoisture),
                                            volume: 0.008)
            }
        default:
            break
        }
    }
}
