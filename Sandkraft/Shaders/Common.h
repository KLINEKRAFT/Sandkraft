//
//  Common.h
//  Sandkraft — shared shader library
//
//  Every shader in the game includes this file, which means the beach profile,
//  the wave field and the mould silhouettes are *literally the same functions*
//  on the simulation side and on the render side. That is not a tidiness
//  argument: it is the only reason the water that erodes your wall is in the
//  same place as the water you can see eroding it, and the only reason the
//  ghost outline under your cursor is exactly what turns out of the mould.
//
//  Everything here is `inline`. Metal compiles each .metal file as its own
//  translation unit and links them into one library, so a non-inline definition
//  in a shared header is a duplicate-symbol error waiting to happen.
//

#ifndef SandkraftCommon_h
#define SandkraftCommon_h

#include <metal_stdlib>
#include "ShaderTypes.h"

using namespace metal;

// MARK: - Constants

constant float SK_PI  = 3.14159265359f;
constant float SK_TAU = 6.28318530718f;

/// The simulated square, in metres. The sea lies toward +Z, the dunes stand at
/// −Z, and the camera is happiest somewhere in between.
constant float4 SK_DOMAIN = float4(-24.0f, -24.0f, 48.0f, 48.0f);

/// Half-width of the baked hardpack table, in metres — it covers ±40 m on both
/// axes, comfortably past the 48 m simulated square and past every headland.
///
/// Deliberately a compile-time constant rather than a uniform. The table is a
/// property of the terrain, not of the frame: nothing about it varies at
/// runtime, so putting it in `SKFrameUniforms` would widen a struct that
/// crosses the Swift ⇄ Metal boundary in order to carry a number that can never
/// change. The Swift side never learns the extent at all — it supplies a
/// texture and `bedrock_bake` fills it from here.
constant float SK_BEDROCK_EXTENT = 40.0f;

// MARK: - Hashes
//
// Hoskins-style integer-free hashes. Cheap, well-distributed, and — importantly
// for a simulation that must reproduce the same beach every launch —
// deterministic across every GPU we ship on, because they touch nothing but
// fract() and multiply.

inline float sk_hash12(float2 p) {
    float3 p3 = fract(float3(p.x, p.y, p.x) * 0.1031f);
    p3 += dot(p3, p3.yzx + 33.33f);
    return fract((p3.x + p3.y) * p3.z);
}

inline float2 sk_hash22(float2 p) {
    float3 p3 = fract(float3(p.x, p.y, p.x) * float3(0.1031f, 0.1030f, 0.0973f));
    p3 += dot(p3, p3.yzx + 33.33f);
    return fract((p3.xx + p3.yz) * p3.zy);
}

inline float3 sk_hash32(float2 p) {
    float3 p3 = fract(float3(p.x, p.y, p.x) * float3(0.1031f, 0.1030f, 0.0973f));
    p3 += dot(p3, p3.yxz + 33.33f);
    return fract((p3.xxy + p3.yzz) * p3.zyx);
}

// MARK: - Noise

inline float sk_vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0f - 2.0f * f);
    float a = sk_hash12(i);
    float b = sk_hash12(i + float2(1.0f, 0.0f));
    float c = sk_hash12(i + float2(0.0f, 1.0f));
    float d = sk_hash12(i + float2(1.0f, 1.0f));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

inline float sk_gnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * f * (f * (f * 6.0f - 15.0f) + 10.0f);
    float a = dot(sk_hash22(i)                         * 2.0f - 1.0f, f);
    float b = dot(sk_hash22(i + float2(1.0f, 0.0f))    * 2.0f - 1.0f, f - float2(1.0f, 0.0f));
    float c = dot(sk_hash22(i + float2(0.0f, 1.0f))    * 2.0f - 1.0f, f - float2(0.0f, 1.0f));
    float d = dot(sk_hash22(i + float2(1.0f, 1.0f))    * 2.0f - 1.0f, f - float2(1.0f, 1.0f));
    return (mix(mix(a, b, u.x), mix(c, d, u.x), u.y)) * 0.72f + 0.5f;
}

inline float sk_fbm(float2 p, int octaves) {
    float s = 0.0f, a = 0.5f, n = 0.0f;
    for (int i = 0; i < 6; ++i) {
        if (i >= octaves) { break; }
        s += a * sk_vnoise(p);
        n += a;
        p = p * 2.03f + 17.1f;
        a *= 0.5f;
    }
    return s / max(n, 1e-4f);
}

inline float sk_fbmG(float2 p, int octaves) {
    float s = 0.0f, a = 0.5f, n = 0.0f;
    for (int i = 0; i < 6; ++i) {
        if (i >= octaves) { break; }
        s += a * sk_gnoise(p);
        n += a;
        p = p * 2.07f + 11.7f;
        a *= 0.5f;
    }
    return s / max(n, 1e-4f);
}

inline float sk_smax(float a, float b, float k) {
    float h = clamp(0.5f + 0.5f * (a - b) / k, 0.0f, 1.0f);
    return mix(b, a, h) + k * h * (1.0f - h);
}

// MARK: - The shore
//
// The bedrock is what would be left if every loose grain were carried away. It
// never changes. The loose sand on top of it is the simulation's business.

/// Additive, and exactly zero outside its own footprint. A max() against this
/// would drag the entire sea floor up to zero, which is a very quiet way to
/// delete an ocean.
inline float sk_rockDome(float2 p, float2 c, float r, float h) {
    float2 q = (p - c) / float2(r, r * 0.78f);
    float k = 1.0f - dot(q, q);
    if (k <= 0.0f) { return 0.0f; }
    return h * pow(k, 0.62f) * (0.80f + 0.36f * sk_vnoise(p * 1.7f));
}

/// The working ground: where the shore is flat, where the loose sand is deep,
/// and where anything you build is worth counting. One function, so those three
/// can never drift apart from one another.
inline float sk_buildPad(float2 p) {
    return smoothstep(23.0f, 15.0f, length((p - float2(0.0f, -7.0f)) * float2(1.0f, 0.92f)));
}

inline float sk_bedrock(float2 p) {
    float z = p.y;
    float y = 1.55f - 0.0705f * (z + 24.0f);

    // Landward dune ridge, pushed out past the working ground so the camera can
    // pull back over the whole of it without burying itself in a hill.
    y += 3.35f * smoothstep(-21.5f, -31.0f, z) * (0.85f + 0.4f * sk_vnoise(p * 0.11f));

    float pad = sk_buildPad(p);

    // The hardpack dips away beneath the pad. The surface stays where it was;
    // what changes is how far down you can dig before you hit the bottom.
    y -= 0.98f * pad;

    // Longshore undulation.
    y += (0.42f * sk_vnoise(p * 0.062f) - 0.21f)  * (1.0f - 0.88f * pad);
    y += (0.13f * sk_vnoise(p * 0.21f)  - 0.065f) * (1.0f - 0.72f * pad);

    // Ripple corduroy left by every tide that came before this one.
    float rip = sin(z * 2.15f + 5.2f * sk_vnoise(p * 0.17f) + 0.9f * sin(p.x * 0.31f)) * 0.021f;
    y += rip * smoothstep(-8.0f, 4.0f, z) * (1.0f - 0.55f * pad);

    // Headlands, for framing.
    y += sk_rockDome(p, float2(-22.6f,   7.5f), 5.4f, 3.10f);
    y += sk_rockDome(p, float2( 23.8f,  -1.5f), 4.8f, 2.70f);
    y += sk_rockDome(p, float2(-19.6f, -19.5f), 6.2f, 1.55f);
    y += sk_rockDome(p, float2( 18.2f, -21.0f), 5.2f, 1.95f);
    y += sk_rockDome(p, float2( 26.0f,  11.0f), 3.2f, 2.10f);

    return y;
}

/// How bare the rock is here. Loose sand does not cling to the headlands, and
/// finite-differencing bedrock() four times per pixel to discover that costs
/// more than the rest of the frame put together.
inline float sk_domeMask(float2 p, float2 c, float r) {
    float2 q = (p - c) / float2(r, r * 0.78f);
    return clamp(1.55f - dot(q, q) * 1.55f, 0.0f, 1.0f);
}

inline float sk_rockiness(float2 p) {
    float m = sk_domeMask(p, float2(-22.6f,   7.5f), 5.4f);
    m = max(m, sk_domeMask(p, float2( 23.8f,  -1.5f), 4.8f));
    m = max(m, sk_domeMask(p, float2(-19.6f, -19.5f), 6.2f));
    m = max(m, sk_domeMask(p, float2( 18.2f, -21.0f), 5.2f));
    m = max(m, sk_domeMask(p, float2( 26.0f,  11.0f), 3.2f));
    return m;
}

/// The loose sand last night's tide left behind. Shared by the simulation's
/// initial state and by the coarse skirt that carries the beach out past the
/// simulated square, so the two meet without a visible step.
inline float sk_sandBed(float2 p) {
    float pad = sk_buildPad(p);
    // Deep. The hardpack dropped 0.98 m under the same pad, so the surface lands
    // where it always did — but there is now the better part of two metres of
    // sand over it, which is enough to cut a moat you could lose a spade in.
    float d = 0.30f + 1.30f * pad + 0.18f * sk_vnoise(p * 0.33f) + 0.08f * sk_vnoise(p * 1.1f);
    return max(d * (1.0f - sk_rockiness(p)), 0.0f);
}

// MARK: - The shore, baked
//
// `sk_bedrock` is nine value-noise evaluations and two sines, and it describes
// ground that never moves. Every fragment of terrain differenced it four times
// to rebuild the macro normal, the water paid it five times, and the solver paid
// it nine times per texel per substep — for an answer that was the same on the
// first frame as on the last. It is now baked into an RG32Float table once, at
// startup, and read back with two texture fetches.
//
// The table is the *only* consumer of `sk_bedrock` and `sk_sandBed` in the
// steady state. Both stay in this header because `bedrock_bake` needs them, and
// because the world does not stop at ±40 m: the beach skirt and the sea carry on
// out to ±340 m, and out there the analytic pair is still what answers.

/// One tap of the baked hardpack: `.x` is `sk_bedrock`, `.y` is `sk_sandBed`.
///
/// **The table is vertex-centred, not texel-centred.** Texel 0 holds the value
/// at −SK_BEDROCK_EXTENT and texel N−1 the value at +SK_BEDROCK_EXTENT, so a
/// lookup landing exactly on the border falls on a stored texel with a zero
/// interpolation weight and returns the baked number itself. That is what keeps
/// the join with the analytic fallback below a micron wide: at the border the
/// two sides are the same function of the same position, differing only by the
/// float32 round trip of a value a few metres tall. Space the table the obvious
/// way instead — texel centres at (i+0.5)/N — and the border lands halfway
/// between two samples, where the interpolation error is at its worst and the
/// seam becomes a millimetre step you can see the sun catch.
///
/// The weights are smoothstepped for the same reason `sk_sandSmooth`
/// smoothsteps its own: plain bilinear has a piecewise-constant gradient, and
/// the terrain fragment rebuilds its macro normal by *differencing this
/// function*. Straight bilinear would print the table's own texel grid onto the
/// beach as a quilt of diamonds.
inline float2 sk_bedrockPair(texture2d<float> lut, float2 p) {
    // Past the table, answer the long way. This is the skirt and the open sea,
    // where the ground is a plane with some noise on it and nobody is building.
    if (any(abs(p) > float2(SK_BEDROCK_EXTENT))) {
        return float2(sk_bedrock(p), sk_sandBed(p));
    }

    constexpr sampler np(coord::normalized, filter::nearest, address::clamp_to_edge);

    float N = float(lut.get_width());

    // Normalise first, scale second. Folding the two into one reciprocal
    // constant would round it, and then a lookup at exactly ±SK_BEDROCK_EXTENT
    // would land a hair either side of the last texel instead of on it — which
    // is the whole property the seam rests on. This way the division is exact at
    // both borders and `f` comes out at precisely zero.
    float2 g = (p + SK_BEDROCK_EXTENT) / (2.0f * SK_BEDROCK_EXTENT);
    float2 t = g * (N - 1.0f);
    float2 i = floor(t), f = fract(t);
    f = f * f * (3.0f - 2.0f * f);

    float2 texel = float2(1.0f / N);
    float2 b = (i + 0.5f) * texel;
    // Explicit LOD, not because there is a mip chain — there is not — but because
    // this is called from vertex functions too, and an implicit-LOD sample in a
    // vertex function does not compile. At the far border the +1 taps run off the
    // edge; clamp_to_edge catches them, and their weight is zero anyway.
    float2 s00 = lut.sample(np, b, level(0)).rg;
    float2 s10 = lut.sample(np, b + float2(texel.x, 0.0f), level(0)).rg;
    float2 s01 = lut.sample(np, b + float2(0.0f, texel.y), level(0)).rg;
    float2 s11 = lut.sample(np, b + texel, level(0)).rg;
    return mix(mix(s00, s10, f.x), mix(s01, s11, f.x), f.y);
}

/// The hardpack alone. Prefer `sk_bedrockPair` where the loose bed is wanted as
/// well — it is the same tap.
inline float sk_bedrockAt(texture2d<float> lut, float2 p) {
    return sk_bedrockPair(lut, p).x;
}

// MARK: - The angle of repose
//
// The whole design rests on this one function.
//
//     bone dry        →  about 33°, a slope and never a wall
//     damp and packed →  past vertical
//     saturated       →  it runs like soup
//
// Everything you build here is an argument with this number. Water is one
// argument, the flat of your hand is another, and the sea is the rebuttal.

inline float sk_repose(float moisture, float packing) {
    float wet  = smoothstep(0.035f, 0.55f, moisture);
    float over = smoothstep(0.90f, 1.0f, moisture);

    float s = mix(0.655f, 3.9f, wet);
    s *= (1.0f + 2.35f * packing);

    // Packed sand keeps its shape after it dries. The water is what let you
    // build the face; the packing is what holds it up, and packing does not
    // evaporate. Without this floor, a tower moulded at noon slumps into a heap
    // by mid-afternoon — which is not what a beach does.
    s = max(s, 0.655f + 14.0f * packing * packing);

    // Soaking still ruins it. A floor for dry sand, not for soup.
    s *= (1.0f - 0.86f * over);

    return max(s, 0.38f);
}

// MARK: - The moulds
//
// The plastic shapes in the bottom of every beach bag. Each one is a height
// profile over a unit disc:
//     .x  coverage — 0 outside, 1 inside, soft at the rim
//     .y  height as a fraction of the mould's depth
// The simulation stamps with these; the sand shader draws the ghost outline
// under your cursor from the same call.

inline float sk_boxD(float2 p, float2 c, float2 hs) {
    float2 d = abs(p - c) - hs;
    return min(max(d.x, d.y), 0.0f) + length(max(d, 0.0f));
}

inline float2 sk_mouldShape(float2 q, int id, float p) {
    float r = length(q);
    float a = atan2(q.y, q.x);
    float cov = 0.0f, hh = 1.0f;

    if (id == 0) {                                  // round turret
        cov = 1.0f - smoothstep(0.90f, 1.00f, r);
        hh  = 1.0f - 0.07f * r;
        float n = max(p, 3.0f);
        float k = fract(a / SK_TAU * n + 0.5f);
        float notch = smoothstep(0.26f, 0.40f, k) * (1.0f - smoothstep(0.60f, 0.74f, k));
        hh -= notch * 0.15f * smoothstep(0.52f, 0.84f, r);
    } else if (id == 1) {                           // square keep
        float2 d = abs(q);
        float m = max(d.x, d.y);
        cov = 1.0f - smoothstep(0.88f, 0.98f, m);
        hh  = 1.0f;
        float cn = length(d - float2(0.74f, 0.74f));
        hh += (1.0f - smoothstep(0.14f, 0.26f, cn)) * 0.20f;
        float t2 = (d.x > d.y) ? q.y : q.x;
        float k = fract(t2 * 2.4f + 0.5f);
        float notch = smoothstep(0.28f, 0.42f, k) * (1.0f - smoothstep(0.58f, 0.72f, k));
        hh -= notch * 0.13f * smoothstep(0.60f, 0.88f, m) * (1.0f - smoothstep(0.14f, 0.26f, cn));
    } else if (id == 2) {                           // gatehouse
        float dL = sk_boxD(q, float2(-0.62f, 0.0f), float2(0.34f, 0.36f));
        float dR = sk_boxD(q, float2( 0.62f, 0.0f), float2(0.34f, 0.36f));
        float dW = sk_boxD(q, float2( 0.00f, 0.0f), float2(0.64f, 0.24f));
        float dd = min(min(dL, dR), dW);
        cov = 1.0f - smoothstep(-0.03f, 0.04f, dd);
        float tw = 1.0f - smoothstep(-0.02f, 0.06f, min(dL, dR));
        hh = mix(0.58f, 1.0f, tw);
        float arch = 1.0f - smoothstep(0.10f, 0.24f, abs(q.x));
        hh -= arch * (1.0f - tw) * 0.26f;
    } else if (id == 3) {                           // star fort
        float R = 0.54f + 0.46f * pow(abs(cos(2.5f * a)), 0.55f);
        cov = 1.0f - smoothstep(R - 0.07f, R + 0.01f, r);
        hh  = 1.0f - 0.13f * r;
        float k = fract(a / SK_TAU * 10.0f + 0.5f);
        hh -= smoothstep(0.30f, 0.44f, k) * (1.0f - smoothstep(0.56f, 0.70f, k))
            * 0.10f * smoothstep(0.4f, 0.8f, r);
    } else if (id == 4) {                           // stepped ziggurat
        float m = max(abs(q.x), abs(q.y));
        cov = 1.0f - smoothstep(0.92f, 1.00f, m);
        float t = clamp(1.0f - m, 0.0f, 1.0f);
        hh = (floor(t * 3.0f) + 1.0f) / 3.0f;
    } else if (id == 5) {                           // spire
        cov = 1.0f - smoothstep(0.86f, 0.98f, r);
        hh  = pow(max(1.0f - r * 0.98f, 0.0f), 0.62f);
        hh *= 1.0f + 0.05f * sin(a * 7.0f + r * 9.0f);
    } else if (id == 6) {                           // scallop shell
        float ribs = 0.5f + 0.5f * cos(a * 9.0f);
        float R = 0.90f + 0.09f * ribs;
        cov = 1.0f - smoothstep(R - 0.05f, R + 0.01f, r);
        // A mould turns out flat-topped with near-vertical sides. Dome it and
        // the outline stops reading — you get a lump, not a scallop.
        hh = 0.66f + 0.20f * ribs + 0.16f * sqrt(max(1.0f - r * r, 0.0f));
    } else if (id == 7) {                           // fish
        float e  = length(q * float2(1.05f, 1.85f));
        float dB = e - 0.80f;
        float2 t = q - float2(-0.72f, 0.0f);
        float dT = max(abs(t.y) * 1.05f + t.x * 0.62f, -t.x - 0.42f);
        float dd = min(dB, dT);
        cov = 1.0f - smoothstep(-0.02f, 0.05f, dd);
        float en = min(e / 0.80f, 1.0f);
        hh  = 0.74f + 0.26f * sqrt(max(1.0f - en * en, 0.0f));
        hh *= 1.0f - smoothstep(0.62f, 1.10f, -q.x) * 0.42f;   // the tail sits lower
        float eye = 1.0f - smoothstep(0.06f, 0.13f, length(q - float2(0.34f, 0.16f)));
        hh -= eye * 0.22f;
    } else if (id == 8) {                           // crab
        float e   = length(q * float2(1.20f, 1.45f));
        float dB  = e - 0.66f;
        float dC1 = length(q - float2(-0.70f, 0.52f)) - 0.25f;
        float dC2 = length(q - float2( 0.70f, 0.52f)) - 0.25f;
        float dl  = 1e3f;
        for (int i = 0; i < 3; ++i) {
            float y = 0.10f - float(i) * 0.30f;
            dl = min(dl, sk_boxD(q, float2(-0.70f, y), float2(0.30f, 0.085f)));
            dl = min(dl, sk_boxD(q, float2( 0.70f, y), float2(0.30f, 0.085f)));
        }
        float dd = min(min(dB, min(dC1, dC2)), dl);
        cov = 1.0f - smoothstep(-0.02f, 0.05f, dd);
        float body = 1.0f - smoothstep(-0.05f, 0.12f, dB);
        float en = min(e / 0.66f, 1.0f);
        hh = mix(0.52f, 0.74f + 0.26f * sqrt(max(1.0f - en * en, 0.0f)), body);
        float ey = 1.0f - smoothstep(0.05f, 0.12f,
                                     min(length(q - float2(-0.22f, 0.30f)),
                                         length(q - float2( 0.22f, 0.30f))));
        hh += ey * 0.16f;
    } else {                                        // starfish
        float R = 0.40f + 0.60f * pow(abs(cos(2.5f * a)), 0.85f);
        cov = 1.0f - smoothstep(R - 0.06f, R + 0.01f, r);
        hh  = 0.80f + 0.20f * (1.0f - smoothstep(0.0f, 0.55f, r));
    }

    return float2(clamp(cov, 0.0f, 1.0f), max(hh, 0.0f));
}

// MARK: - The water

// direction.xy · wavelength in metres · amplitude weight
//
// The amplitude falls as roughly L^1.5, not L^1, and that exponent is the whole
// difference between a swell and a chop.
//
// What the eye reads as choppiness is *slope*, and the slope a component
// contributes is A·k — amplitude times wavenumber. The previous table fell as
// L^1, which holds A·k very nearly constant: every one of the five octaves
// carried the same slope as the 19-metre swell, so none of them was the sea and
// all of them were texture. A real wind sea is peak-dominated; the short waves
// ride on the long one rather than competing with it.
//
//   before          after
//   L      A·k      L      A·k
//   19.0   0.066    23.0   0.062
//   12.2   0.064    13.1   0.046
//    6.9   0.060     8.3   0.037
//    3.9   0.050     4.4   0.027
//    2.35  0.046     2.5   0.020
//
// Total slope drops by a third while total height drops by under a tenth. Same
// sea, and it stops crawling.
//
// The wavelengths are also respread. The old set ran 19 : 12.2 : 6.9 : 3.9 with
// ratios of 1.77 twice over, and a near-geometric progression beats against
// itself on a fixed period — which is what "wonky" looks like from a distance.
// The new ratios are deliberately irregular.
//
// Directional spread widens with decreasing wavelength, which is both correct
// and what stops the crests reading as one long extruded ridge. The widest is
// pulled in from 28° to 24°, because past that the short waves start to look
// like a cross-sea rather than like wind on a swell.
constant float4 SK_WAVE0 = float4( 0.05f, -1.000f, 23.00f, 0.2250f);
constant float4 SK_WAVE1 = float4(-0.22f, -0.975f, 13.10f, 0.0967f);
constant float4 SK_WAVE2 = float4( 0.29f, -0.957f,  8.30f, 0.0488f);
constant float4 SK_WAVE3 = float4(-0.34f, -0.940f,  4.40f, 0.0188f);
constant float4 SK_WAVE4 = float4( 0.41f, -0.912f,  2.50f, 0.0081f);

inline float4 sk_waveParam(int i) {
    if (i == 0) { return SK_WAVE0; }
    if (i == 1) { return SK_WAVE1; }
    if (i == 2) { return SK_WAVE2; }
    if (i == 3) { return SK_WAVE3; }
    return SK_WAVE4;
}

/// The slow breathing of the sets. This is what runs the swash up the beach and
/// then takes it back, and it is the thing you learn to time your work against.
inline float sk_seaLevelAt(float base, float t) {
    return base
         + 0.118f * sin(t * 0.5100f)
         + 0.067f * sin(t * 0.2410f + 1.73f)
         + 0.028f * sin(t * 1.0700f + 0.41f);
}

/// Gerstner sum with shoaling, refraction and depth-limited breaking.
///   d   still-water depth in metres, clamped ≥ 0
///   amp global swell scale for this tide
/// Returns xyz = displacement, w = breaking intensity 0…1.
inline float4 sk_gerstner(float2 p, float t, float d, float amp, int waveCount) {
    float3 disp = float3(0.0f);
    float brk = 0.0f, wsum = 0.0f;

    // First: how steep does this sum *want* to be? A Gerstner surface stays
    // single-valued only while its total steepness stays under one. Budget the
    // whole sum rather than each component — five waves each allowed 0.92 add
    // up to 4.6, and on the late tides, where the swell is biggest and
    // refraction has turned every component to face the beach so they add
    // rather than cancel, it really does go over. That is what folded,
    // flickering, overlapping crests on a rising tide actually are.
    float stSum = 0.0f;
    for (int i = 0; i < 5; ++i) {
        if (i >= waveCount) { break; }
        float4 Wq = sk_waveParam(i);
        float kq  = SK_TAU / Wq.z;
        float thq = tanh(clamp(kq * max(d, 0.015f), 0.02f, 10.0f));
        float Aq  = min(Wq.w * amp / sqrt(max(thq, 0.055f)), 0.46f * max(d, 0.02f));
        stSum += min(0.92f, Aq * kq * 2.6f);
    }
    float budget = min(1.0f, 0.80f / max(stSum, 1e-4f));

    for (int i = 0; i < 5; ++i) {
        if (i >= waveCount) { break; }
        float4 W = sk_waveParam(i);
        float L = W.z;
        float k = SK_TAU / L;
        float2 dir = normalize(W.xy);

        // Refraction: as the bottom comes up, every component turns to face the
        // beach. This is why the swash arrives parallel to the shore no matter
        // which way the swell came from.
        float sh = 1.0f - smoothstep(0.0f, 6.0f, d);
        dir = normalize(mix(dir, float2(0.0f, -1.0f), sh * 0.88f));

        float kd = clamp(k * max(d, 0.015f), 0.02f, 10.0f);
        float th = tanh(kd);
        float c  = sqrt(9.81f / k * th);
        float A  = W.w * amp / sqrt(max(th, 0.055f));
        float Ab = 0.46f * max(d, 0.02f);              // depth-limited breaking height
        float over = max(A - Ab, 0.0f);
        brk  += (over / max(A, 1e-4f)) * W.w;
        wsum += W.w;
        A = min(A, Ab);

        float ph = dot(dir * k, p) - c * k * t;

        // Horizontal orbital motion. The depth under a point is measured
        // *before* this term moves it, so a crest shoved half a metre up a
        // sloping beach would carry the wrong depth with it and end up buried in
        // one place and standing proud of the sand in the next — a picket fence
        // instead of a waterline. Orbital motion belongs to deep water anyway:
        // it collapses as the bottom comes up. Hold it off until there is real
        // water under the wave, and never let it exceed the depth it moves in.
        float Q = min(0.92f, A * k * 2.6f) * budget;
        float horiz = min(min(Q / k, A * 2.2f), d * 0.45f) * smoothstep(0.06f, 1.10f, d);
        disp.xz -= dir * horiz * sin(ph);
        disp.y  += A * cos(ph);
    }

    return float4(disp, clamp(brk / max(wsum, 1e-4f) * 1.35f, 0.0f, 1.0f));
}

/// Cheap vertical-only query for the simulation. Three components is plenty
/// when all you want to know is whether this cell is under a breaker.
inline float sk_waveY(float2 p, float t, float d, float amp, thread float &brk) {
    float4 g = sk_gerstner(p, t, d, amp, 3);
    brk = g.w;
    return g.y;
}

// MARK: - Sky sampling
//
// Lat-long lookup with a horizon-biased vertical axis, so the ten degrees of sky
// that anyone actually looks at get most of the texels.

inline float2 sk_dirToSkyUV(float3 d) {
    float az = atan2(d.z, d.x) / SK_TAU + 0.5f;
    float e  = asin(clamp(d.y, -1.0f, 1.0f)) / SK_PI;      // −0.5 … 0.5
    float v  = 0.5f + sign(e) * sqrt(abs(e) * 2.0f) * 0.5f;
    return float2(az, clamp(v, 0.001f, 0.999f));
}

inline float3 sk_skyUVToDir(float2 uv) {
    float az = (uv.x - 0.5f) * SK_TAU;
    float s  = (uv.y - 0.5f) * 2.0f;
    float el = sign(s) * s * s * 0.5f * SK_PI;
    float cy = cos(el);
    return float3(cy * cos(az), sin(el), cy * sin(az));
}

// MARK: - Colour

constant float3x3 SK_ACES_IN = float3x3(
    float3(0.59719f, 0.07600f, 0.02840f),
    float3(0.35458f, 0.90834f, 0.13383f),
    float3(0.04823f, 0.01566f, 0.83777f));

constant float3x3 SK_ACES_OUT = float3x3(
    float3( 1.60475f, -0.10208f, -0.00327f),
    float3(-0.53108f,  1.10813f, -0.07276f),
    float3(-0.07367f, -0.00605f,  1.07602f));

inline float3 sk_rrtOdt(float3 v) {
    float3 a = v * (v + 0.0245786f) - 0.000090537f;
    float3 b = v * (0.983729f * v + 0.4329510f) + 0.238081f;
    return a / b;
}

inline float3 sk_tonemapACES(float3 c) {
    c = SK_ACES_IN * c;
    c = sk_rrtOdt(c);
    c = SK_ACES_OUT * c;
    return clamp(c, 0.0f, 1.0f);
}

inline float sk_luma(float3 c) {
    return dot(c, float3(0.2126f, 0.7152f, 0.0722f));
}

inline float3 sk_saturate3(float3 c, float k) {
    return mix(float3(sk_luma(c)), c, k);
}

/// Hard quantisation, for looks that want a stepped ramp.
inline float sk_bands(float x, float n) {
    return floor(clamp(x, 0.0f, 0.999f) * n + 0.5f) / n;
}

/// Soft-edged steps. A hard floor() crawls visibly as the sun moves.
inline float sk_softBands(float x, float n, float w) {
    float s = clamp(x, 0.0f, 1.0f) * n;
    float f = floor(s), r = s - f;
    return (f + smoothstep(0.5f - w, 0.5f + w, r)) / n;
}

/// A rotated dot screen, exactly the way a print shop would do it.
inline float sk_halftone(float2 fc, float v, float ang, float scale) {
    float c = cos(ang), s = sin(ang);
    float2 p = float2(fc.x * c - fc.y * s, fc.x * s + fc.y * c) / scale;
    float2 g = fract(p) - 0.5f;
    float r = sqrt(clamp(v, 0.0f, 1.0f)) * 0.74f;
    return smoothstep(r + 0.075f, r - 0.075f, length(g));
}

/// Five inks, dot-screened between each adjacent pair. Light is not shaded
/// here, it is *separated*.
inline float3 sk_screenPrint(float L, float2 fc, float ang, float scale,
                             float3 i0, float3 i1, float3 i2, float3 i3, float3 i4) {
    float t = clamp(L, 0.0f, 0.9999f) * 4.0f;
    float f = floor(t);
    float d = sk_halftone(fc, t - f, ang, scale);
    float3 a, b;
    if (f < 0.5f)      { a = i0; b = i1; }
    else if (f < 1.5f) { a = i1; b = i2; }
    else if (f < 2.5f) { a = i2; b = i3; }
    else               { a = i3; b = i4; }
    return mix(a, b, d);
}

/// How far past sundown we are, read straight off the sun's transmitted colour.
inline float sk_nightOf(float3 sunColor) {
    return clamp(1.0f - sk_luma(sunColor) * 2.2f, 0.0f, 1.0f);
}

// MARK: - BRDF pieces

inline float sk_D_GGX(float NoH, float a) {
    float a2 = a * a;
    float d = NoH * NoH * (a2 - 1.0f) + 1.0f;
    return a2 / (SK_PI * d * d + 1e-7f);
}

inline float sk_V_Smith(float NoV, float NoL, float a) {
    float a2 = a * a;
    float gv = NoL * sqrt(NoV * NoV * (1.0f - a2) + a2);
    float gl = NoV * sqrt(NoL * NoL * (1.0f - a2) + a2);
    return 0.5f / max(gv + gl, 1e-5f);
}

inline float3 sk_F_Schlick(float3 f0, float u) {
    float f = pow(1.0f - u, 5.0f);
    return f0 + (1.0f - f0) * f;
}

/// Oren–Nayar. This is the reason a lit sand slope reads as flat and chalky
/// rather than as a shiny sphere — sand is about as rough as diffuse gets.
inline float sk_orenNayar(float3 N, float3 V, float3 L, float rough) {
    float NoL = max(dot(N, L), 0.0f);
    float NoV = max(dot(N, V), 0.0f);
    float s = rough * rough;
    float A = 1.0f - 0.5f * s / (s + 0.33f);
    float B = 0.45f * s / (s + 0.09f);
    float cosPhi = dot(normalize(V - N * NoV + 1e-6f), normalize(L - N * NoL + 1e-6f));
    float av = acos(clamp(NoV, 0.03f, 1.0f));
    float al = acos(clamp(NoL, 0.03f, 1.0f));
    float a = max(av, al), b = min(av, al);
    return NoL * (A + B * max(cosPhi, 0.0f) * sin(a) * min(tan(b), 3.0f));
}

// MARK: - Sand field sampling
//
// The simulation texture is RGBA32Float and therefore not linearly filterable on
// every GPU we support, so we always do the bilinear ourselves. It also means
// the sampler never has to change between the sim and the renderer, which
// removes a whole category of "why is the water a texel off the sand" bug.

inline float2 sk_uvToWorld(float2 uv, float4 domain) {
    return domain.xy + uv * domain.zw;
}

inline float2 sk_worldToUV(float2 p, float4 domain) {
    return (p - domain.xy) / domain.zw;
}

inline float4 sk_sandBilinear(texture2d<float, access::sample> sandTex,
                              float2 uv, float res, float2 texel) {
    constexpr sampler nearestClamp(coord::normalized, filter::nearest, address::clamp_to_edge);
    float2 t = uv * res - 0.5f;
    float2 i = floor(t), f = fract(t);
    float2 b = (i + 0.5f) * texel;
    float4 s00 = sandTex.sample(nearestClamp, b);
    float4 s10 = sandTex.sample(nearestClamp, b + float2(texel.x, 0.0f));
    float4 s01 = sandTex.sample(nearestClamp, b + float2(0.0f, texel.y));
    float4 s11 = sandTex.sample(nearestClamp, b + texel);
    return mix(mix(s00, s10, f.x), mix(s01, s11, f.x), f.y);
}

/// Total ground height at a world position: hardpack plus whatever loose sand is
/// standing on it. Outside the simulated square this falls back to the analytic
/// bed, which is what makes the skirt meet the domain without a seam.
inline float sk_groundY(texture2d<float, access::sample> sandTex,
                        texture2d<float> bedrockLUT,
                        float2 p, float4 domain, float res, float2 texel) {
    float2 uv = sk_worldToUV(p, domain);
    float2 bed = sk_bedrockPair(bedrockLUT, p);
    if (uv.x < 0.0f || uv.x > 1.0f || uv.y < 0.0f || uv.y > 1.0f) {
        return bed.x + bed.y;
    }
    return bed.x + sk_sandBilinear(sandTex, uv, res, texel).r;
}

#endif /* SandkraftCommon_h */
