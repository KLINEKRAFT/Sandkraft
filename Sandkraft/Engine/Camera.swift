//
//  Camera.swift
//  Sandkraft
//
//  An orbit camera with one unusual property: the point it orbits is the last
//  place you touched the sand.
//
//  That single decision removes the pan gesture from the phone entirely. Pan is
//  the hardest of the three camera verbs to make discoverable on a touchscreen —
//  orbit and zoom have obvious gestures, pan does not — and the reason you want
//  it is almost always "I am working over here now". So: work over here, and the
//  camera comes with you. Pan still exists on the Mac, where there is a whole
//  keyboard and a trackpad to hang it off.
//
//  Everything the camera exposes is a spring. Letting go of a pinch should feel
//  like setting something down, not like dropping it.
//

import Foundation
import simd

struct CameraLimits {
    var minDistance: Float = 4.5
    /// Far enough out to hold the whole of the widened square in frame at the
    /// default field of view, and no further: past this the beach is a postage
    /// stamp in the middle of an ocean.
    var maxDistance: Float = 78
    /// Below about eight degrees the camera is inside the beach; above
    /// eighty-five it gimbal-locks and the horizon spins.
    var minElevation: Float = degreesToRadians(7)
    var maxElevation: Float = degreesToRadians(84)
    /// How far the focus point may wander from the middle of the working ground.
    /// Tracks `sk_buildPad`'s outer radius, so the pivot can reach every part of
    /// the beach that is worth building on and no part that is not.
    var targetRadius: Float = 32
}

final class Camera {

    // MARK: Desired state

    var targetPoint = SIMD3<Float>(0, 0, -4)
    var desiredDistance: Float = 27
    var desiredAzimuth: Float = degreesToRadians(-90)      // looking out to sea
    var desiredElevation: Float = degreesToRadians(26)

    // MARK: Smoothed state

    private var distance = Spring(27, response: 0.32)
    private var azimuth = Spring(degreesToRadians(-90), response: 0.24)
    private var elevation = Spring(degreesToRadians(26), response: 0.24)
    private var smoothedTarget = SIMD3<Float>(0, 0, -4)

    var limits = CameraLimits()

    var fieldOfView: Float = degreesToRadians(46)
    var nearPlane: Float = 0.12
    var farPlane: Float = 900

    /// Set while a gesture is in flight. Springs run stiffer during direct
    /// manipulation so the camera tracks the finger, and softer afterwards so it
    /// settles rather than stops.
    var isInteracting = false {
        didSet {
            let response: Float = isInteracting ? 0.10 : 0.30
            distance.response = response
            azimuth.response = response
            elevation.response = response
        }
    }

    // MARK: Derived

    private(set) var position = SIMD3<Float>(0, 8, 18)

    var forward: SIMD3<Float> { normalize(smoothedTarget - position) }

    /// Horizontal basis, for translating a screen-space drag into world motion.
    var screenRight: SIMD3<Float> {
        SIMD3(cos(azimuth.value + .pi / 2), 0, sin(azimuth.value + .pi / 2))
    }
    var screenForward: SIMD3<Float> {
        SIMD3(cos(azimuth.value), 0, sin(azimuth.value))
    }

    // MARK: - Update

    func update(dt: Float, groundHeight: (SIMD2<Float>) -> Float) {
        desiredDistance = clampf(desiredDistance, limits.minDistance, limits.maxDistance)
        desiredElevation = clampf(desiredElevation, limits.minElevation, limits.maxElevation)

        // Keep the focus point over the working ground. Wandering off toward the
        // headlands is never what anyone meant to do.
        let flat = SIMD2<Float>(targetPoint.x, targetPoint.z) - SIMD2<Float>(0, -7)
        let r = length(flat)
        if r > limits.targetRadius {
            let clamped = flat * (limits.targetRadius / r) + SIMD2<Float>(0, -7)
            targetPoint.x = clamped.x
            targetPoint.z = clamped.y
        }
        targetPoint.y = groundHeight(SIMD2(targetPoint.x, targetPoint.z))

        distance.step(toward: desiredDistance, dt: dt)
        azimuth.step(toward: desiredAzimuth, dt: dt)
        elevation.step(toward: desiredElevation, dt: dt)
        // The focus point moves on a slower curve than the orbit. Snapping the
        // pivot the instant a finger lands somewhere new is disorienting; taking
        // half a second to slide there reads as the camera following you.
        smoothedTarget = approach(smoothedTarget, targetPoint, halfLife: 0.22, dt: dt)

        let ce = cos(elevation.value), se = sin(elevation.value)
        let offset = SIMD3<Float>(ce * cos(azimuth.value), se, ce * sin(azimuth.value)) * distance.value
        var eye = smoothedTarget + offset

        // Never let the eye drop below the ground it is looking at. A camera
        // inside a dune is the fastest way to make a beautiful game look broken.
        let floorY = groundHeight(SIMD2(eye.x, eye.z)) + 0.45
        if eye.y < floorY {
            eye.y = floorY
        }
        position = eye
    }

    /// Place the camera without any spring settling. Used when a tide starts and
    /// when a save is loaded, where a two-second glide from the old view would
    /// read as a bug.
    func snap(target: SIMD3<Float>, distance d: Float, azimuth a: Float, elevation e: Float) {
        targetPoint = target
        smoothedTarget = target
        desiredDistance = d
        desiredAzimuth = a
        desiredElevation = e
        distance = Spring(d, response: distance.response)
        azimuth = Spring(a, response: azimuth.response)
        elevation = Spring(e, response: elevation.response)
    }

    // MARK: - Gestures

    func orbit(deltaAzimuth: Float, deltaElevation: Float) {
        desiredAzimuth += deltaAzimuth
        desiredElevation = clampf(desiredElevation + deltaElevation,
                                  limits.minElevation, limits.maxElevation)
    }

    /// Multiplicative, so a pinch feels the same whether you are close in or
    /// pulled right back.
    func dolly(scale: Float) {
        desiredDistance = clampf(desiredDistance / max(scale, 0.01),
                                 limits.minDistance, limits.maxDistance)
    }

    /// Screen-space pan, in points, translated into metres at the focus plane.
    func pan(dx: Float, dy: Float, viewportHeight: Float) {
        let metresPerPoint = 2 * distance.value * tan(fieldOfView * 0.5) / max(viewportHeight, 1)
        let move = screenRight * (-dx * metresPerPoint) + screenForward * (dy * metresPerPoint)
        targetPoint.x += move.x
        targetPoint.z += move.z
    }

    /// Move the pivot to a point on the sand without changing the view direction.
    /// This is what the touch handler calls on every stroke.
    func focus(on point: SIMD3<Float>) {
        targetPoint.x = point.x
        targetPoint.z = point.z
    }

    // MARK: - Matrices

    func viewMatrix() -> float4x4 {
        Mat4.lookAt(eye: position, target: smoothedTarget, up: SIMD3<Float>(0, 1, 0))
    }

    func projectionMatrix(aspect: Float) -> float4x4 {
        Mat4.perspective(fovY: fieldOfView, aspect: aspect, near: nearPlane, far: farPlane)
    }

    /// The world-space ray through a point in the viewport. `point` is in pixels
    /// with the origin at the top left, which is what both AppKit and UIKit hand
    /// us after the appropriate flip.
    func ray(atViewportPoint point: SIMD2<Float>, viewportSize: SIMD2<Float>) -> (origin: SIMD3<Float>, direction: SIMD3<Float>) {
        let aspect = viewportSize.x / max(viewportSize.y, 1)
        let vp = projectionMatrix(aspect: aspect) * viewMatrix()
        let inverse = vp.inverse

        let ndc = SIMD2<Float>((point.x / max(viewportSize.x, 1)) * 2 - 1,
                               1 - (point.y / max(viewportSize.y, 1)) * 2)

        // Depth 1 is the far plane in Metal's 0…1 clip space.
        var far = inverse * SIMD4<Float>(ndc.x, ndc.y, 1, 1)
        far /= far.w
        let direction = normalize(SIMD3(far.x, far.y, far.z) - position)
        return (position, direction)
    }

    // MARK: - Shadow fitting

    /// Fit an orthographic light frustum around the working ground.
    ///
    /// Fitting it to the *view* frustum instead would be textbook and would be
    /// wrong here: the shadow map would then resize and re-orient every time the
    /// camera moved, and the texel grid crawling across a static sandcastle is far
    /// more distracting than the resolution you gain. The playable area is 48 m
    /// square and never moves, so the light matrix depends only on the sun.
    static func lightMatrix(sunDirection: SIMD3<Float>,
                            domain: SIMD4<Float>,
                            maxHeight: Float = 7) -> float4x4 {
        let centre = SIMD3<Float>(domain.x + domain.z * 0.5, 0.6, domain.y + domain.w * 0.5)
        let radius = length(SIMD2<Float>(domain.z, domain.w)) * 0.5 + 2

        var dir = sunDirection
        // A sun exactly at the horizon produces an infinitely long frustum, and
        // one below it produces a shadow map of the underside of the world.
        if dir.y < 0.08 {
            dir = normalize(SIMD3(dir.x, max(dir.y, 0.08), dir.z))
        }

        let eye = centre + dir * (radius + maxHeight * 2)
        let view = Mat4.lookAt(eye: eye, target: centre, up: SIMD3<Float>(0, 1, 0))
        let projection = Mat4.orthographic(left: -radius, right: radius,
                                           bottom: -radius, top: radius,
                                           near: 0.1, far: radius * 2 + maxHeight * 4)
        return projection * view
    }
}
