//
//  MetalSceneView.swift
//  Sandkraft
//
//  The bridge between SwiftUI and Metal, and the whole of the input model.
//
//  The input design is the part worth reading.
//
//  On iPhone: **one finger draws, two fingers move the camera.** There is no pan
//  gesture, because the camera orbits the last place you touched — work
//  somewhere new and the pivot comes with you. That removes the hardest of the
//  three camera verbs to teach on a touchscreen, and removes the mode switch
//  that games usually reach for instead.
//
//  On Mac: left button draws, right button (or ⌥-drag) orbits, scroll pans,
//  pinch and ⌘-scroll dolly. Every one of those is what the same gesture does in
//  every other 3D app on the platform, because a Mac app that invents its own
//  camera controls is a Mac app nobody can use.
//

import SwiftUI
import MetalKit
import simd

// MARK: - Render loop

extension SceneCoordinator: MTKViewDelegate {

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        MainActor.assumeIsolated {
            renderer.resize(drawableSize: size)
            // The gesture layer works in points and the renderer works in pixels,
            // so the ray-casting viewport has to be the point size. Taking it from
            // the view's own bounds rather than dividing by a scale factor means
            // it stays right on a mixed-DPI Mac setup, where the backing scale
            // changes the moment the window crosses to the other display.
            let bounds = view.bounds.size
            if bounds.width > 1, bounds.height > 1 {
                viewportChanged(to: SIMD2(Float(bounds.width), Float(bounds.height)))
            }
        }
    }

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated {
            let dt = renderer.smoothedFrameDuration
            advance(dt: dt)
            emitToolEffects(dt: dt)

            // Brush state, undo capture and any pending beach reset go on their
            // own command buffer *before* the frame, so the solver step inside
            // Renderer.draw sees them.
            if let setup = renderer.context.commandQueue.makeCommandBuffer() {
                setup.label = "frame.setup"
                if prepareForEncoding(commandBuffer: setup) {
                    setup.commit()
                } else {
                    setup.commit()
                }
            }

            renderer.draw(in: view)
            afterEncoding()
        }
    }
}

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - iOS

#if os(iOS)

final class SandkraftRenderView: MTKView {
    weak var coordinator: SceneCoordinator?

    private var pinchBaseline: CGFloat = 1

    func installGestures() {
        isMultipleTouchEnabled = true

        let draw = UIPanGestureRecognizer(target: self, action: #selector(handleDraw(_:)))
        draw.minimumNumberOfTouches = 1
        draw.maximumNumberOfTouches = 1
        // A tool stroke must start the instant a finger lands, or the first
        // centimetre of every line is missing.
        draw.delaysTouchesBegan = false
        addGestureRecognizer(draw)

        let orbit = UIPanGestureRecognizer(target: self, action: #selector(handleOrbit(_:)))
        orbit.minimumNumberOfTouches = 2
        orbit.maximumNumberOfTouches = 2
        addGestureRecognizer(orbit)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)

        let rotate = UIRotationGestureRecognizer(target: self, action: #selector(handleRotate(_:)))
        addGestureRecognizer(rotate)

        // Pinch, two-finger drag and twist all belong to the same physical
        // gesture and must run together.
        orbit.delegate = self
        pinch.delegate = self
        rotate.delegate = self
    }

    private func point(_ recognizer: UIGestureRecognizer) -> SIMD2<Float> {
        let p = recognizer.location(in: self)
        return SIMD2(Float(p.x), Float(p.y))
    }

    @objc private func handleDraw(_ g: UIPanGestureRecognizer) {
        guard let coordinator else { return }
        switch g.state {
        case .began:     coordinator.pointerDown(at: point(g))
        case .changed:   coordinator.pointerMoved(to: point(g))
        case .ended:     coordinator.pointerUp()
        case .cancelled, .failed: coordinator.pointerCancelled()
        default: break
        }
    }

    @objc private func handleOrbit(_ g: UIPanGestureRecognizer) {
        guard let coordinator else { return }
        switch g.state {
        case .began:
            // A two-finger gesture that starts mid-stroke cancels the stroke
            // rather than leaving a smear where the fingers landed.
            coordinator.pointerCancelled()
            g.setTranslation(.zero, in: self)
        case .changed:
            let t = g.translation(in: self)
            coordinator.orbit(dx: Float(t.x), dy: Float(t.y))
            g.setTranslation(.zero, in: self)
        case .ended, .cancelled, .failed:
            coordinator.endCameraGesture()
        default: break
        }
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        guard let coordinator else { return }
        switch g.state {
        case .began:
            coordinator.pointerCancelled()
            g.scale = 1
        case .changed:
            coordinator.dolly(scale: Float(g.scale))
            g.scale = 1
        case .ended, .cancelled, .failed:
            coordinator.endCameraGesture()
        default: break
        }
    }

    @objc private func handleRotate(_ g: UIRotationGestureRecognizer) {
        guard let coordinator else { return }
        // Twisting two fingers rotates the *mould*, not the camera. Camera yaw is
        // already on the two-finger drag, and a mould you cannot aim is a mould
        // you cannot use.
        switch g.state {
        case .changed:
            coordinator.rotateMould(by: Float(g.rotation))
            g.rotation = 0
        default: break
        }
    }
}

extension SandkraftRenderView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Everything two-fingered composes; the one-finger draw never does.
        !(g is UIPanGestureRecognizer && (g as? UIPanGestureRecognizer)?.maximumNumberOfTouches == 1)
    }
}

struct MetalSceneView: UIViewRepresentable {
    let coordinator: SceneCoordinator

    func makeUIView(context: Context) -> SandkraftRenderView {
        let view = SandkraftRenderView(frame: .zero, device: coordinator.renderer.context.device)
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .invalid       // the renderer owns its own depth
        view.framebufferOnly = false
        view.preferredFramesPerSecond = 120           // ProMotion where it exists
        view.isOpaque = true
        view.coordinator = coordinator
        view.delegate = coordinator
        view.installGestures()
        return view
    }

    func updateUIView(_ view: SandkraftRenderView, context: Context) {
        view.isPaused = false
    }
}

#endif

// MARK: - macOS

#if os(macOS)

final class SandkraftRenderView: MTKView {
    weak var coordinator: SceneCoordinator?

    override var acceptsFirstResponder: Bool { true }

    private var trackingArea: NSTrackingArea?
    private var orbiting = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    /// AppKit's origin is bottom-left; everything else in this project is
    /// top-left. Flipping once, here, is cheaper than remembering to flip
    /// everywhere else.
    private func point(_ event: NSEvent) -> SIMD2<Float> {
        let p = convert(event.locationInWindow, from: nil)
        return SIMD2(Float(p.x), Float(bounds.height - p.y))
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            orbiting = true
        } else {
            coordinator?.pointerDown(at: point(event))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if orbiting {
            coordinator?.orbit(dx: Float(event.deltaX), dy: Float(event.deltaY))
        } else {
            coordinator?.pointerMoved(to: point(event))
        }
    }

    override func mouseUp(with event: NSEvent) {
        if orbiting {
            orbiting = false
            coordinator?.endCameraGesture()
        } else {
            coordinator?.pointerUp()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        coordinator?.pointerMoved(to: point(event))
    }

    override func rightMouseDragged(with event: NSEvent) {
        coordinator?.orbit(dx: Float(event.deltaX), dy: Float(event.deltaY))
    }

    override func rightMouseUp(with event: NSEvent) {
        coordinator?.endCameraGesture()
    }

    override func scrollWheel(with event: NSEvent) {
        guard let coordinator else { return }
        if event.modifierFlags.contains(.command) {
            coordinator.dolly(scale: 1 + Float(event.scrollingDeltaY) * 0.01)
        } else if event.modifierFlags.contains(.shift) {
            coordinator.orbit(dx: Float(event.scrollingDeltaX), dy: Float(event.scrollingDeltaY))
        } else {
            coordinator.pan(dx: Float(event.scrollingDeltaX), dy: Float(event.scrollingDeltaY))
        }
        if event.phase == .ended || event.momentumPhase == .ended {
            coordinator.endCameraGesture()
        }
    }

    override func magnify(with event: NSEvent) {
        coordinator?.dolly(scale: 1 + Float(event.magnification))
        if event.phase == .ended { coordinator?.endCameraGesture() }
    }

    override func rotate(with event: NSEvent) {
        coordinator?.rotateMould(by: Float(event.rotation) * .pi / 180)
    }
}

struct MetalSceneView: NSViewRepresentable {
    let coordinator: SceneCoordinator

    func makeNSView(context: Context) -> SandkraftRenderView {
        let view = SandkraftRenderView(frame: .zero, device: coordinator.renderer.context.device)
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .invalid
        view.framebufferOnly = false
        view.preferredFramesPerSecond = 120
        view.coordinator = coordinator
        view.delegate = coordinator
        return view
    }

    func updateNSView(_ view: SandkraftRenderView, context: Context) {
        view.isPaused = false
    }
}

#endif
