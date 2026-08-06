//
//  SandSimulation.swift
//  Sandkraft
//
//  The Swift side of Sim.metal: owns the sand textures, drives the substeps,
//  runs the metric reduction and the pick ray, and keeps the undo stack.
//
//  Everything here runs on the render thread. The two values the interface cares
//  about — metrics and the pick result — arrive on a completion handler on some
//  other thread, so they live behind a lock and are copied out once per frame.
//

import Foundation
import Metal
import simd

// MARK: - Environment

/// The state of the world for one simulation step. Assembled fresh each frame by
/// the game model, so the simulation never has to know what a tide is.
struct SimulationEnvironment {
    var time: Double = 0
    var seaBase: Double = -0.3
    var waveAmplitude: Double = 0.8
    /// 0 switches off every wave term in the solver, and with it most of the
    /// cost. Sandbox play at low tide really is nearly free.
    var erosion: Double = 1.0
    var sunDrying: Double = 1.0
}

// MARK: - Brush

struct BrushStroke {
    var start: SIMD2<Float> = .zero
    var end: SIMD2<Float> = .zero
    var radius: Float = 1
    var strength: Float = 0
    var mode: ToolMode = .none
    /// Meaning depends on the mode: the reference height for Carve/Level/Wall,
    /// the pail gate for Pour/Drip.
    var parameter: Float = 1
    /// Round or square footprint. Rides on `stamp3.w`, which was spare.
    var shape: BrushShape = .round
}

struct MouldStamp {
    var position: SIMD2<Float> = .zero
    var radius: Float = 1
    var height: Float = 1
    var detail: Float = 8
    var baseY: Float = 0
    var rotation: Float = 0
    var moisture: Float = 0.8
    var shapeIndex: Int32 = 0
}

// MARK: - Simulation

final class SandSimulation {

    // MARK: Geometry

    /// The simulated square, in metres. Matches `SK_DOMAIN` in Common.h.
    static let domain = SIMD4<Float>(-24, -24, 48, 48)

    let resolution: Int
    var cellSize: Float { Self.domain.z / Float(resolution) }
    var cellArea: Float { cellSize * cellSize }

    // MARK: Resources

    private let context: MetalContext

    private(set) var sand: MTLTexture        // the live field, read by the renderer
    private var sandBack: MTLTexture
    private(set) var pristine: MTLTexture
    private(set) var ambientOcclusion: MTLTexture
    private var deposit: MTLTexture
    private var depositAccumulator: MTLBuffer

    private var metricPartials: MTLBuffer
    private var metricsBuffer: MTLBuffer
    private var pickBuffer: MTLBuffer

    // MARK: Pipelines

    private let pInit: MTLComputePipelineState
    private let pPristine: MTLComputePipelineState
    private let pStep: MTLComputePipelineState
    private let pAO: MTLComputePipelineState
    private let pMetricPartial: MTLComputePipelineState
    private let pMetricFinal: MTLComputePipelineState
    private let pPick: MTLComputePipelineState
    private let pDepositResolve: MTLComputePipelineState
    private let pDepositClear: MTLComputePipelineState

    // MARK: Reduction geometry
    //
    // metrics_partial declares a 256-entry threadgroup array and reduces across
    // exactly 256 threads, so the threadgroup size is not negotiable and we
    // dispatch it explicitly rather than letting the generic helper choose.

    private static let metricThreadgroup = MTLSize(width: 16, height: 16, depth: 1)
    private static let metricSlots = 8
    private let partialCount: Int

    // MARK: Readback

    private let readbackLock = NSLock()
    private var _metrics = SKMetrics()
    private var _pick = SKPickResult()
    private var pendingMetricReads = 0

    /// Discard the next few readbacks after a reset. One may already be in flight
    /// describing the *old* shore, and if we believe it the pail meter starts
    /// life lying.
    private var discardReads = 0

    /// The volume of loose sand in the domain when this beach was laid down.
    /// Everything the pail meter says is relative to this.
    private(set) var baselineVolume: Double = -1

    var metrics: SKMetrics {
        readbackLock.lock(); defer { readbackLock.unlock() }
        return _metrics
    }

    var pick: SKPickResult {
        readbackLock.lock(); defer { readbackLock.unlock() }
        return _pick
    }

    // MARK: Brush state

    var stroke = BrushStroke()
    private var stamp: MouldStamp?
    /// The mould stamp must land on exactly one substep. Two would turn out two
    /// towers a millimetre apart, which reads as one very strange tower.
    private var stampArmed = false

    // MARK: Undo

    private var undoPool: [MTLTexture] = []
    private var undoStack: [MTLTexture] = []
    private var undoCursor = 0
    let undoDepth: Int

    var canUndo: Bool { undoCursor > 0 }
    var canRedo: Bool { undoCursor + 1 < undoStack.count }

    // MARK: - Init

    init(context: MetalContext, tier: QualityTier) throws {
        // Bound to a local before anything else. `makeField` below is a nested
        // function, and a nested function that touches `self.resolution` counts as
        // capturing self — which Swift will not allow before every stored property
        // has a value. Reading the local instead keeps it capture-free.
        let res = tier.simResolution

        self.context = context
        self.resolution = res
        self.undoDepth = tier.undoDepth

        let field: MTLTextureUsage = [.shaderRead, .shaderWrite]

        func makeField(_ label: String) throws -> MTLTexture {
            guard let t = context.makeTexture(width: res, height: res,
                                              format: .rgba32Float, usage: field, label: label) else {
                throw MetalSetupError.noDevice
            }
            return t
        }

        sand      = try makeField("sand.front")
        sandBack  = try makeField("sand.back")
        pristine  = try makeField("sand.pristine")

        guard let ao = context.makeTexture(width: max(res / 2, 128),
                                           height: max(res / 2, 128),
                                           format: .r8Unorm, usage: field, label: "sand.ao"),
              let dep = context.makeTexture(width: res, height: res,
                                            format: .rg32Float, usage: field, label: "sand.deposit"),
              let acc = context.makeBuffer(length: res * res * 2 * MemoryLayout<UInt32>.stride,
                                           storage: .storageModePrivate, label: "sand.depositAccumulator")
        else { throw MetalSetupError.noDevice }

        ambientOcclusion = ao
        deposit = dep
        depositAccumulator = acc

        let tgWide = (res + Self.metricThreadgroup.width - 1) / Self.metricThreadgroup.width
        let tgHigh = (res + Self.metricThreadgroup.height - 1) / Self.metricThreadgroup.height
        partialCount = tgWide * tgHigh

        guard let partials = context.makeBuffer(length: partialCount * Self.metricSlots * MemoryLayout<Float>.stride,
                                                storage: .storageModePrivate, label: "metrics.partials"),
              let metricsBuf = context.makeBuffer(length: MemoryLayout<SKMetrics>.stride, label: "metrics.result"),
              let pickBuf = context.makeBuffer(length: MemoryLayout<SKPickResult>.stride, label: "pick.result")
        else { throw MetalSetupError.noDevice }

        metricPartials = partials
        metricsBuffer = metricsBuf
        pickBuffer = pickBuf

        pInit           = try context.computePipeline("sim_init")
        pPristine       = try context.computePipeline("sim_pristine")
        pStep           = try context.computePipeline("sim_step")
        pAO             = try context.computePipeline("sim_ao")
        pMetricPartial  = try context.computePipeline("metrics_partial")
        pMetricFinal    = try context.computePipeline("metrics_final")
        pPick           = try context.computePipeline("sim_pick")
        pDepositResolve = try context.computePipeline("deposit_resolve")
        pDepositClear   = try context.computePipeline("deposit_clear")

        for i in 0..<undoDepth {
            guard let t = context.makeTexture(width: res, height: res,
                                              format: .rgba32Float,
                                              usage: [.shaderRead, .shaderWrite],
                                              label: "sand.undo.\(i)") else {
                throw MetalSetupError.noDevice
            }
            undoPool.append(t)
        }
    }

    // MARK: - Uniforms

    private func uniforms(_ env: SimulationEnvironment, dt: Float, depositScale: Float) -> SKSimUniforms {
        var u = SKSimUniforms()
        u.domain = Self.domain
        u.texel = SIMD2<Float>(1 / Float(resolution), 1 / Float(resolution))
        u.simResolution = Float(resolution)
        u.dt = dt
        u.time = Float(env.time)
        u.seaBase = Float(env.seaBase)
        u.waveAmplitude = Float(env.waveAmplitude)
        u.erosion = Float(env.erosion)
        u.sunDrying = Float(env.sunDrying)
        u.depositScale = depositScale

        u.brushA = SIMD4<Float>(stroke.start.x, stroke.start.y, stroke.radius, stroke.strength)
        u.brushB = SIMD4<Float>(stroke.end.x, stroke.end.y, Float(stroke.mode.rawValue), stroke.parameter)

        if let s = stamp, stampArmed {
            u.stamp  = SIMD4<Float>(s.position.x, s.position.y, s.radius, s.height)
            u.stamp2 = SIMD4<Float>(s.detail, s.baseY, 1, 1)
            u.stamp3 = SIMD4<Float>(Float(s.shapeIndex), s.rotation, s.moisture, 0)
        } else {
            u.stamp  = .zero
            // .z carries the Wall tool's gate as well as the stamp gate, so it
            // stays at 1 when no mould is pending.
            u.stamp2 = SIMD4<Float>(8, 0, 1, 0)
            u.stamp3 = SIMD4<Float>(0, 0, 0.8, 0)
        }

        // Set last and in one place: the brush footprint is a property of the
        // stroke, not of the mould, and both branches above would otherwise have
        // to remember to carry it.
        u.stamp3.w = stroke.shape.rawFlag

        return u
    }

    // MARK: - Lifecycle

    /// Lay down a fresh beach. `seaBase` sets how far up the shore last night's
    /// tide reached, which is what decides how much of it starts damp.
    func reset(seaBase: Double, in commandBuffer: MTLCommandBuffer) {
        var env = SimulationEnvironment()
        env.seaBase = seaBase
        var u = uniforms(env, dt: 0, depositScale: 0)

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = "sim.reset"

        encoder.setComputePipelineState(pInit)
        encoder.setTexture(sand, index: 0)
        encoder.setBytes(&u, length: MemoryLayout<SKSimUniforms>.stride, index: 0)
        context.dispatch(encoder, pipeline: pInit, width: resolution, height: resolution)

        encoder.setComputePipelineState(pPristine)
        encoder.setTexture(pristine, index: 0)
        encoder.setBytes(&u, length: MemoryLayout<SKSimUniforms>.stride, index: 0)
        context.dispatch(encoder, pipeline: pPristine, width: resolution, height: resolution)

        encoder.setComputePipelineState(pDepositClear)
        encoder.setTexture(deposit, index: 0)
        context.dispatch(encoder, pipeline: pDepositClear, width: resolution, height: resolution)

        encoder.endEncoding()

        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.label = "sim.reset.clearAccumulator"
            blit.fill(buffer: depositAccumulator, range: 0..<depositAccumulator.length, value: 0)
            blit.endEncoding()
        }

        undoStack.removeAll()
        undoCursor = 0
        baselineVolume = -1
        discardReads = 2
        stamp = nil
        stampArmed = false
        stroke = BrushStroke()
    }

    // MARK: - Step

    /// Advance the solver. `dt` is the whole frame's worth of time; it is divided
    /// across `substeps` internally, and the deposit texture is applied on the
    /// first substep only.
    func step(environment: SimulationEnvironment,
              dt: Double,
              substeps: Int,
              in commandBuffer: MTLCommandBuffer) {
        guard substeps > 0 else { return }

        // Cap the frame's simulated time. A stall — a phone call, a window drag,
        // the app coming back from the background — must not be allowed to
        // deliver half a second of avalanche in one frame and knock the castle
        // over while nobody was looking.
        let clamped = min(dt, 1.0 / 20.0)
        let sub = Float(clamped / Double(substeps))

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = "sim.step"

        // Fold the frame's particle deposits into a texture the solver can read.
        encoder.setComputePipelineState(pDepositResolve)
        encoder.setBuffer(depositAccumulator, offset: 0, index: 0)
        var fixedScale = Float(Self.depositFixedPointScale)
        encoder.setBytes(&fixedScale, length: MemoryLayout<Float>.stride, index: 1)
        encoder.setTexture(deposit, index: 0)
        context.dispatch(encoder, pipeline: pDepositResolve, width: resolution, height: resolution)

        var env = environment
        for i in 0..<substeps {
            // Deposits describe a whole frame's worth of landed sand, so they are
            // applied once, at full strength, on the first substep. Applying them
            // every substep would deliver the same handful three times.
            let depositScale: Float = (i == 0) ? 1 : 0
            env.time = environment.time + Double(sub) * Double(i)
            var u = uniforms(env, dt: sub, depositScale: depositScale)

            encoder.setComputePipelineState(pStep)
            encoder.setTexture(sand, index: 0)
            encoder.setTexture(sandBack, index: 1)
            encoder.setTexture(deposit, index: 2)
            encoder.setBytes(&u, length: MemoryLayout<SKSimUniforms>.stride, index: 0)
            context.dispatch(encoder, pipeline: pStep, width: resolution, height: resolution)

            swap(&sand, &sandBack)

            if stampArmed { stampArmed = false; stamp = nil }
        }

        encoder.endEncoding()
    }

    /// Horizon-scan ambient occlusion. Half resolution, and it does not need to
    /// run every frame — the sand moves slowly compared to the eye.
    func updateAmbientOcclusion(environment: SimulationEnvironment, in commandBuffer: MTLCommandBuffer) {
        var u = uniforms(environment, dt: 0, depositScale: 0)
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = "sim.ao"
        encoder.setComputePipelineState(pAO)
        encoder.setTexture(sand, index: 0)
        encoder.setTexture(ambientOcclusion, index: 1)
        encoder.setBytes(&u, length: MemoryLayout<SKSimUniforms>.stride, index: 0)
        context.dispatch(encoder, pipeline: pAO, width: ambientOcclusion.width, height: ambientOcclusion.height)
        encoder.endEncoding()
    }

    // MARK: - Metrics

    func measure(environment: SimulationEnvironment,
                 highWater: Double,
                 in commandBuffer: MTLCommandBuffer) {
        var u = uniforms(environment, dt: 0, depositScale: 0)
        var high = Float(highWater)
        var count = UInt32(partialCount)
        var area = cellArea
        var texels = Float(resolution * resolution)

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = "sim.metrics"

        encoder.setComputePipelineState(pMetricPartial)
        encoder.setTexture(sand, index: 0)
        encoder.setTexture(pristine, index: 1)
        encoder.setBuffer(metricPartials, offset: 0, index: 0)
        encoder.setBytes(&u, length: MemoryLayout<SKSimUniforms>.stride, index: 1)
        encoder.setBytes(&high, length: MemoryLayout<Float>.stride, index: 2)
        let wide = (resolution + Self.metricThreadgroup.width - 1) / Self.metricThreadgroup.width
        let high2 = (resolution + Self.metricThreadgroup.height - 1) / Self.metricThreadgroup.height
        encoder.dispatchThreadgroups(MTLSize(width: wide, height: high2, depth: 1),
                                     threadsPerThreadgroup: Self.metricThreadgroup)

        encoder.setComputePipelineState(pMetricFinal)
        encoder.setBuffer(metricPartials, offset: 0, index: 0)
        encoder.setBuffer(metricsBuffer, offset: 0, index: 1)
        encoder.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 2)
        encoder.setBytes(&area, length: MemoryLayout<Float>.stride, index: 3)
        encoder.setBytes(&texels, length: MemoryLayout<Float>.stride, index: 4)
        encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))

        encoder.endEncoding()

        pendingMetricReads += 1
        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            let value = self.metricsBuffer.contents()
                .bindMemory(to: SKMetrics.self, capacity: 1).pointee
            self.readbackLock.lock()
            self.pendingMetricReads -= 1
            if self.discardReads > 0 {
                self.discardReads -= 1
            } else {
                self._metrics = value
                if self.baselineVolume < 0 {
                    self.baselineVolume = Double(value.totalVolume)
                }
            }
            self.readbackLock.unlock()
        }
    }

    // MARK: - Picking

    func raycast(origin: SIMD3<Float>,
                 direction: SIMD3<Float>,
                 environment: SimulationEnvironment,
                 in commandBuffer: MTLCommandBuffer) {
        var u = uniforms(environment, dt: 0, depositScale: 0)
        var o = SIMD4<Float>(origin, 0)
        var d = SIMD4<Float>(direction, 0)

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = "sim.pick"
        encoder.setComputePipelineState(pPick)
        encoder.setTexture(sand, index: 0)
        encoder.setBuffer(pickBuffer, offset: 0, index: 0)
        encoder.setBytes(&u, length: MemoryLayout<SKSimUniforms>.stride, index: 1)
        encoder.setBytes(&o, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
        encoder.setBytes(&d, length: MemoryLayout<SIMD4<Float>>.stride, index: 3)
        encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()

        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            let value = self.pickBuffer.contents()
                .bindMemory(to: SKPickResult.self, capacity: 1).pointee
            self.readbackLock.lock()
            self._pick = value
            self.readbackLock.unlock()
        }
    }

    // MARK: - Moulds

    /// Arm a mould to be turned out on the next substep.
    func armStamp(_ s: MouldStamp) {
        stamp = s
        stampArmed = true
    }

    // MARK: - Undo

    /// Capture the current field. Called once at the start of each gesture, not
    /// per frame — a stroke is one undoable act, however long you hold it.
    func captureUndoState(in commandBuffer: MTLCommandBuffer) {
        // Anything ahead of the cursor is a future that is no longer going to
        // happen. Recycle it.
        while undoStack.count > undoCursor + 1 {
            undoPool.append(undoStack.removeLast())
        }
        // The first capture of a session records the state *before* the first
        // stroke, so the stack always has something to go back to.
        if undoStack.isEmpty {
            guard let slot = takeUndoSlot() else { return }
            blit(from: sand, to: slot, in: commandBuffer)
            undoStack.append(slot)
            undoCursor = 0
        }
    }

    /// Commit the result of a gesture as a new undo point.
    func commitUndoState(in commandBuffer: MTLCommandBuffer) {
        while undoStack.count > undoCursor + 1 {
            undoPool.append(undoStack.removeLast())
        }
        guard let slot = takeUndoSlot() else { return }
        blit(from: sand, to: slot, in: commandBuffer)
        undoStack.append(slot)
        undoCursor = undoStack.count - 1
    }

    @discardableResult
    func undo(in commandBuffer: MTLCommandBuffer) -> Bool {
        guard canUndo else { return false }
        undoCursor -= 1
        blit(from: undoStack[undoCursor], to: sand, in: commandBuffer)
        discardReads = 1
        return true
    }

    @discardableResult
    func redo(in commandBuffer: MTLCommandBuffer) -> Bool {
        guard canRedo else { return false }
        undoCursor += 1
        blit(from: undoStack[undoCursor], to: sand, in: commandBuffer)
        discardReads = 1
        return true
    }

    private func takeUndoSlot() -> MTLTexture? {
        if let slot = undoPool.popLast() { return slot }
        // The stack is full. Drop the oldest state — losing the deepest undo is
        // a far better outcome than refusing to record the newest one.
        guard !undoStack.isEmpty else { return nil }
        let oldest = undoStack.removeFirst()
        undoCursor = max(undoCursor - 1, 0)
        return oldest
    }

    private func blit(from src: MTLTexture, to dst: MTLTexture, in commandBuffer: MTLCommandBuffer) {
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.label = "sand.copy"
        blit.copy(from: src, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: resolution, height: resolution, depth: 1),
                  to: dst, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
    }

    // MARK: - Particle feedback

    var depositBuffer: MTLBuffer { depositAccumulator }
    static let depositFixedPointScale: Double = 1_048_576   // 2^20, ~1 µm³ of resolution

    // MARK: - Persistence

    /// Read the whole field back. Synchronous and slow by design — this is only
    /// ever called when saving, which is off the hot path.
    func snapshotForSaving(in commandBuffer: MTLCommandBuffer) -> MTLBuffer? {
        let bytesPerRow = resolution * 16
        guard let staging = context.makeBuffer(length: bytesPerRow * resolution, label: "sand.save") else {
            return nil
        }
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.label = "sand.download"
        blit.copy(from: sand, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: resolution, height: resolution, depth: 1),
                  to: staging, destinationOffset: 0,
                  destinationBytesPerRow: bytesPerRow,
                  destinationBytesPerImage: bytesPerRow * resolution)
        blit.endEncoding()
        return staging
    }

    /// Restore a saved field. Returns false when the save was made at a different
    /// simulation resolution, which the caller reports rather than papering over
    /// with a resample nobody asked for.
    func restore(from data: Data, in commandBuffer: MTLCommandBuffer) -> Bool {
        let expected = resolution * resolution * 16
        guard data.count == expected else { return false }
        guard let staging = context.makeBuffer(length: expected, label: "sand.restore") else { return false }
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                staging.contents().copyMemory(from: base, byteCount: expected)
            }
        }
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return false }
        blit.label = "sand.upload"
        blit.copy(from: staging, sourceOffset: 0,
                  sourceBytesPerRow: resolution * 16,
                  sourceBytesPerImage: expected,
                  sourceSize: MTLSize(width: resolution, height: resolution, depth: 1),
                  to: sand, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        discardReads = 2
        baselineVolume = -1
        return true
    }
}
