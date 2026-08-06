//
//  MathUtil.swift
//  Sandkraft
//
//  Matrix builders and the two easing primitives the whole app animates with.
//
//  Every projection here targets Metal's clip space, where depth runs 0…1 rather
//  than −1…1. Getting that wrong produces a picture that looks almost right and
//  a depth buffer that is silently useless, so the near/far mapping is spelled
//  out in each function rather than left to memory.
//

import Foundation
import simd

// MARK: - Projections

enum Mat4 {

    /// Right-handed perspective with reversed nothing and depth in 0…1.
    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> float4x4 {
        let ys = 1 / tan(fovY * 0.5)
        let xs = ys / max(aspect, 0.0001)
        let zs = far / (near - far)
        return float4x4(columns: (
            SIMD4<Float>(xs, 0,  0,           0),
            SIMD4<Float>(0,  ys, 0,           0),
            SIMD4<Float>(0,  0,  zs,         -1),
            SIMD4<Float>(0,  0,  zs * near,   0)
        ))
    }

    /// Right-handed orthographic with depth in 0…1. Used for the sun's shadow
    /// pass, where the light is effectively infinitely far away.
    static func orthographic(left: Float, right: Float,
                             bottom: Float, top: Float,
                             near: Float, far: Float) -> float4x4 {
        let rl = max(right - left, 1e-5)
        let tb = max(top - bottom, 1e-5)
        let nf = near - far
        return float4x4(columns: (
            SIMD4<Float>(2 / rl, 0,      0,       0),
            SIMD4<Float>(0,      2 / tb, 0,       0),
            SIMD4<Float>(0,      0,      1 / nf,  0),
            SIMD4<Float>(-(right + left) / rl, -(top + bottom) / tb, near / nf, 1)
        ))
    }

    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> float4x4 {
        let f = normalize(eye - target)                  // +Z points back toward the eye
        var upv = up
        // Degenerate when looking straight down, which the camera can do. Pick a
        // different up rather than producing a NaN matrix.
        if abs(dot(normalize(upv), f)) > 0.999 { upv = SIMD3<Float>(0, 0, 1) }
        let r = normalize(cross(upv, f))
        let u = cross(f, r)
        return float4x4(columns: (
            SIMD4<Float>(r.x, u.x, f.x, 0),
            SIMD4<Float>(r.y, u.y, f.y, 0),
            SIMD4<Float>(r.z, u.z, f.z, 0),
            SIMD4<Float>(-dot(r, eye), -dot(u, eye), -dot(f, eye), 1)
        ))
    }

    static func translation(_ t: SIMD3<Float>) -> float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
        return m
    }

    static func scale(_ s: SIMD3<Float>) -> float4x4 {
        float4x4(diagonal: SIMD4<Float>(s.x, s.y, s.z, 1))
    }

    static func rotationY(_ a: Float) -> float4x4 {
        let c = cos(a), s = sin(a)
        return float4x4(columns: (
            SIMD4<Float>( c, 0, -s, 0),
            SIMD4<Float>( 0, 1,  0, 0),
            SIMD4<Float>( s, 0,  c, 0),
            SIMD4<Float>( 0, 0,  0, 1)
        ))
    }

    /// Rotation about an arbitrary axis. Used by the props, which lean.
    static func rotation(axis: SIMD3<Float>, angle: Float) -> float4x4 {
        let a = normalize(axis)
        let c = cos(angle), s = sin(angle), t = 1 - c
        let (x, y, z) = (a.x, a.y, a.z)
        return float4x4(columns: (
            SIMD4<Float>(t * x * x + c,     t * x * y + s * z, t * x * z - s * y, 0),
            SIMD4<Float>(t * x * y - s * z, t * y * y + c,     t * y * z + s * x, 0),
            SIMD4<Float>(t * x * z + s * y, t * y * z - s * x, t * z * z + c,     0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }
}

// MARK: - Easing
//
// Two primitives, used everywhere, and deliberately no more than two. A codebase
// with nine different smoothing functions has nine different feels, and the
// player notices even if they could not tell you why.

/// Frame-rate independent exponential approach. `halfLife` is the time in
/// seconds for the remaining distance to halve — a unit that survives a change
/// of frame rate, unlike the naïve `mix(a, b, 0.1)` that every real-time
/// codebase is full of and that runs twice as fast at 120 Hz.
@inline(__always)
func approach(_ current: Float, _ target: Float, halfLife: Float, dt: Float) -> Float {
    guard halfLife > 0 else { return target }
    let k = 1 - exp2(-dt / halfLife)
    return current + (target - current) * k
}

@inline(__always)
func approach(_ current: SIMD3<Float>, _ target: SIMD3<Float>, halfLife: Float, dt: Float) -> SIMD3<Float> {
    guard halfLife > 0 else { return target }
    let k = 1 - exp2(-dt / halfLife)
    return current + (target - current) * k
}

/// A critically damped spring. Overshoots never, settles fast, and is what the
/// camera uses so that letting go of a pinch feels like setting something down
/// rather than dropping it.
struct Spring {
    var value: Float
    var velocity: Float = 0
    /// Time to settle, roughly. Lower is snappier.
    var response: Float = 0.28

    init(_ value: Float, response: Float = 0.28) {
        self.value = value
        self.response = response
    }

    mutating func step(toward target: Float, dt: Float) {
        guard response > 0 else { value = target; velocity = 0; return }
        // Clamp dt so a stalled frame cannot make the spring explode.
        let h = min(dt, 1.0 / 30.0)
        let omega = 2 * Float.pi / response
        let f = 1 + 2 * h * omega
        let oo = omega * omega
        let hoo = h * oo
        let hhoo = h * hoo
        let denominator = f + hhoo
        let detachedValue = (f * value + h * velocity + hhoo * target) / denominator
        velocity = (velocity + hoo * (target - value)) / denominator
        value = detachedValue
    }
}

// MARK: - Small helpers

@inline(__always)
func clampf(_ v: Float, _ lo: Float, _ hi: Float) -> Float { min(max(v, lo), hi) }

@inline(__always)
func smoothstepf(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
    let t = clampf((x - edge0) / (edge1 - edge0), 0, 1)
    return t * t * (3 - 2 * t)
}

@inline(__always)
func degreesToRadians(_ d: Float) -> Float { d * .pi / 180 }

@inline(__always)
func radiansToDegrees(_ r: Float) -> Float { r * 180 / .pi }
