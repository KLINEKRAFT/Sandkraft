//
//  Render.h
//  Sandkraft — shared rendering library
//
//  Common.h holds the maths the *simulation* and the renderer must agree on.
//  This header holds the pieces only the renderer needs: field resampling with
//  shading-quality filtering, sky lookups, shadows, fog, ink palettes and the
//  buffer-less grid decoder.
//
//  It exists because Metal compiles every .metal file as its own translation
//  unit. A helper defined in Terrain.metal simply does not exist in
//  Water.metal, and the two passes have to agree about the shadow bias, the
//  fog curve and the colour of the sea or the picture comes apart at the
//  waterline.
//
//  Everything here is `inline`, for the same reason as Common.h.
//

#ifndef SandkraftRender_h
#define SandkraftRender_h

#include "Common.h"

// MARK: - Buffer-less grid
//
// `vertex_id` decodes to a cell and a corner; two counter-clockwise triangles
// per cell. The divisor is (edge − 1) so the grid corners land exactly on the
// domain corners rather than on texel centres. No vertex buffer, no index
// buffer, nothing to upload.

inline float2 sk_gridUV(uint vid, uint edge) {
    uint quad = vid / 6u;
    uint k    = vid - quad * 6u;
    uint W    = max(edge, 2u) - 1u;
    uint cx   = quad % W;
    uint cy   = quad / W;

    uint2 o;
    switch (k) {
        case 0:  o = uint2(0, 0); break;
        case 1:  o = uint2(1, 0); break;
        case 2:  o = uint2(0, 1); break;
        case 3:  o = uint2(1, 0); break;
        case 4:  o = uint2(1, 1); break;
        default: o = uint2(0, 1); break;
    }
    return float2(uint2(cx, cy) + o) / float(W);
}

/// The power-warped sheet that carries the world out to ±340 m. Shared by the
/// beach skirt and the sea so the two can never disagree about where the world
/// ends. The exponent concentrates triangle density near the player.
inline float2 sk_skirtPosition(float2 uv) {
    float2 s = uv * 2.0f - 1.0f;
    return float2(0.0f, -4.0f) + sign(s) * pow(abs(s), float2(2.6f)) * 340.0f;
}

// MARK: - Small matrices
//
// Only the props need these, but they need them in two shaders (the lit pass and
// the shadow pass) and the two must build the identical transform or an
// adornment casts a shadow from somewhere it is not.

inline float4x4 sk_rotationY(float a) {
    float c = cos(a), s = sin(a);
    return float4x4(float4( c, 0.0f, -s, 0.0f),
                    float4(0.0f, 1.0f, 0.0f, 0.0f),
                    float4( s, 0.0f,  c, 0.0f),
                    float4(0.0f, 0.0f, 0.0f, 1.0f));
}

inline float4x4 sk_rotationAxis(float3 axis, float angle) {
    float3 a = normalize(axis);
    float c = cos(angle), s = sin(angle), t = 1.0f - c;
    return float4x4(
        float4(t * a.x * a.x + c,        t * a.x * a.y + s * a.z, t * a.x * a.z - s * a.y, 0.0f),
        float4(t * a.x * a.y - s * a.z,  t * a.y * a.y + c,       t * a.y * a.z + s * a.x, 0.0f),
        float4(t * a.x * a.z + s * a.y,  t * a.y * a.z - s * a.x, t * a.z * a.z + c,       0.0f),
        float4(0.0f, 0.0f, 0.0f, 1.0f));
}

// MARK: - Field resampling

/// Bilinear with smoothstepped weights. The C¹ continuity — zero gradient at
/// every texel centre — is what stops the reconstructed normal showing the texel
/// grid as a quilt of diamonds. It costs a slight flatness exactly at texel
/// centres, which nobody has ever noticed, and everybody notices the grid.
inline float4 sk_sandSmooth(texture2d<float> sandTex, float2 uv, float res, float2 texel) {
    constexpr sampler np(coord::normalized, filter::nearest, address::clamp_to_edge);
    float2 t = uv * res - 0.5f;
    float2 i = floor(t), f = fract(t);
    f = f * f * (3.0f - 2.0f * f);
    float2 b = (i + 0.5f) * texel;
    // Explicit LOD, not because there is a mip chain — there is not — but because
    // this is called from the water *vertex* shader too, and an implicit-LOD
    // sample in a vertex function does not compile.
    float4 s00 = sandTex.sample(np, b, level(0));
    float4 s10 = sandTex.sample(np, b + float2(texel.x, 0.0f), level(0));
    float4 s01 = sandTex.sample(np, b + float2(0.0f, texel.y), level(0));
    float4 s11 = sandTex.sample(np, b + texel, level(0));
    return mix(mix(s00, s10, f.x), mix(s01, s11, f.x), f.y);
}

/// Ground height using the shading-quality resample. Outside the simulated
/// square this falls back to the analytic bed, which is what makes the skirt
/// meet the domain without a seam.
inline float sk_groundYSmooth(texture2d<float> sandTex, texture2d<float> bedrockLUT,
                              float2 p, float4 domain, float res, float2 texel) {
    float2 uv = (p - domain.xy) / domain.zw;
    float2 bed = sk_bedrockPair(bedrockLUT, p);
    float s = (uv.x >= 0.0f && uv.x <= 1.0f && uv.y >= 0.0f && uv.y <= 1.0f)
            ? sk_sandSmooth(sandTex, uv, res, texel).r
            : bed.y;
    return bed.x + s;
}

/// Still-water depth: how far below the mean surface the ground is here, before
/// any wave displacement. Negative on dry land.
inline float sk_stillDepth(texture2d<float> sandTex, texture2d<float> bedrockLUT,
                           float2 p, float seaLevel,
                           float4 domain, float res, float2 texel) {
    return seaLevel - sk_groundYSmooth(sandTex, bedrockLUT, p, domain, res, texel);
}

// MARK: - Sky

inline float3 sk_skySample(texture2d<float> skyLUT, float3 d, float lod) {
    constexpr sampler s(coord::normalized, filter::linear, mip_filter::linear,
                        s_address::repeat, t_address::clamp_to_edge);
    return skyLUT.sample(s, sk_dirToSkyUV(normalize(d)), level(lod)).rgb;
}

/// Sky ambient for a normal. The +0.25 Y bias tilts every lookup skyward, so a
/// vertical wall never samples the ground half of the lat-long LUT and come out
/// the colour of the beach it is standing on.
inline float3 sk_ambientFrom(texture2d<float> skyLUT, float3 N) {
    float3 up = sk_skySample(skyLUT, float3(0.0f, 1.0f, 0.0f), 5.0f);
    float3 a  = sk_skySample(skyLUT, normalize(N + float3(0.0f, 0.25f, 0.0f)), 4.0f);
    return mix(a, up, 0.35f);
}

/// Aerial perspective. Thin, but it is what puts the headlands *away*, and it is
/// applied identically to all nine looks — a screen print of a distant headland
/// is still a screen print of something far away.
inline float3 sk_applyFog(texture2d<float> skyLUT, float3 col, float dist, float3 rd,
                          float fogK, float3 sunDir, float3 sunColor) {
    float f = 1.0f - exp(-dist * fogK);
    float3 sky = sk_skySample(skyLUT, rd, 2.0f);
    float sunAmt = pow(max(dot(rd, sunDir), 0.0f), 8.0f);
    sky += sunColor * sunAmt * 0.35f;
    return mix(col, sky, clamp(f, 0.0f, 1.0f));
}

// MARK: - Shadows

constant float2 SK_POISSON[9] = {
    float2( 0.000f,  0.000f), float2( 0.940f,  0.170f), float2( 0.290f,  0.940f),
    float2(-0.680f,  0.640f), float2(-0.960f, -0.230f), float2(-0.310f, -0.910f),
    float2( 0.660f, -0.720f), float2( 0.470f,  0.520f), float2(-0.520f, -0.400f)
};

/// Nine rotated Poisson taps against a hardware comparison sampler. Every tap is
/// a binary in-or-out; all of the softness comes from the kernel and the
/// per-fragment rotation, which turns what would be nine visible bands into
/// noise the eye reads as a penumbra.
inline float sk_shadowAt(depth2d<float> shadowMap, float4x4 lightVP, float3 wp,
                         float NoL, float texel, float enabled) {
    if (enabled < 0.5f) { return 1.0f; }
    constexpr sampler sc(coord::normalized, filter::linear,
                         address::clamp_to_edge, compare_func::less_equal);

    float4 lp = lightVP * float4(wp, 1.0f);
    if (lp.w <= 0.0f) { return 1.0f; }
    float3 pc = lp.xyz / lp.w;
    pc.xy = pc.xy * float2(0.5f, -0.5f) + 0.5f;      // clip space → texture space
    if (pc.x < 0.002f || pc.x > 0.998f || pc.y < 0.002f || pc.y > 0.998f || pc.z > 0.999f) {
        return 1.0f;
    }

    // Slope-scaled bias. Too little and a shallowly-lit dune self-shadows into
    // stripes; too much and a tower stops casting onto its own base.
    float bias = clamp(0.0016f * tan(acos(clamp(NoL, 0.02f, 1.0f))), 0.0004f, 0.006f);
    float ref = pc.z - bias;

    float ang = sk_hash12(floor(wp.xz * 140.0f)) * SK_TAU;
    float ca = cos(ang), sa = sin(ang);
    float2x2 rot = float2x2(float2(ca, sa), float2(-sa, ca));

    float sum = 0.0f;
    for (int i = 0; i < 9; ++i) {
        float2 o = rot * SK_POISSON[i] * texel * 1.35f;
        sum += shadowMap.sample_compare(sc, pc.xy + o, ref);
    }
    return sum / 9.0f;
}

// MARK: - Procedural detail
//
// These use fwidth() and must only be called from fragment functions.

/// Ridged, drifting noise folded to thin filaments. This is the light dancing on
/// the bottom of two inches of water.
inline float sk_caustic(float2 p, float t) {
    float a = 0.0f;
    float2 q = p * 2.3f;
    for (int i = 0; i < 3; ++i) {
        float2 o = float2(sin(t * 0.70f + float(i) * 2.1f),
                          cos(t * 0.53f + float(i) * 1.7f)) * 0.35f;
        a += abs(sk_gnoise(q + o + float(i) * 13.0f) * 2.0f - 1.0f);
        q *= 1.9f;
    }
    a = 1.0f - a / 3.0f;
    return pow(clamp(a, 0.0f, 1.0f), 5.0f);
}

/// A contour line one pixel wide at any camera distance, whatever the slope.
/// `fwidth` does all of the work; `weight` only sets the minimum width on a
/// perfectly flat patch, where the derivative goes to zero and the line would
/// otherwise vanish entirely.
inline float sk_contour(float h, float interval, float weight) {
    float c = fract(h / max(interval, 1e-4f));
    float w = fwidth(h / max(interval, 1e-4f)) * 1.1f + weight;
    return 1.0f - smoothstep(0.0f, w, min(c, 1.0f - c));
}

/// Grain, wind ripple and corduroy, differenced into a tangent-space normal.
///
/// `wetness`, `packing` and `detail` are all clamped to 0…1. The reference this
/// was ported from fed an unclamped style index into the wetness slot, which
/// inverted and amplified the micro-normal for six of its nine looks. The
/// results were interesting, but they were not chosen — and a value that can
/// only ever be 0…1 should be typed that way.
inline float3 sk_detailNormal(float2 p, float wetness, float packing, float fade, float detail) {
    const float e = 0.028f;
    float amp = mix(1.0f, 0.30f, clamp(wetness, 0.0f, 1.0f))
              * mix(1.0f, 0.45f, clamp(packing, 0.0f, 1.0f))
              * max(detail, 0.0f);

    // Forward differences: three evaluations rather than five. A central
    // difference would double the cost for a difference nobody can see at this
    // amplitude.
    float h0 = ((sk_fbmG(p * 7.4f, 3) - 0.5f) * 0.055f
              + (sk_fbmG(p * 23.0f, 2) - 0.5f) * 0.024f
              + (sk_gnoise(p * 74.0f) - 0.5f) * 0.010f * fade) * amp;

    float2 px = p + float2(e, 0.0f);
    float hx = ((sk_fbmG(px * 7.4f, 3) - 0.5f) * 0.055f
              + (sk_fbmG(px * 23.0f, 2) - 0.5f) * 0.024f
              + (sk_gnoise(px * 74.0f) - 0.5f) * 0.010f * fade) * amp;

    float2 pz = p + float2(0.0f, e);
    float hz = ((sk_fbmG(pz * 7.4f, 3) - 0.5f) * 0.055f
              + (sk_fbmG(pz * 23.0f, 2) - 0.5f) * 0.024f
              + (sk_gnoise(pz * 74.0f) - 0.5f) * 0.010f * fade) * amp;

    return normalize(float3(-(hx - h0) / e, 1.0f, -(hz - h0) / e));
}

/// Advected, folded noise for sea foam. Two octaves drifting at different speeds
/// is enough — foam is read as a shape, not as a texture.
inline float sk_foamField(float2 p, float t) {
    float a = sk_fbmG(p * 0.85f + float2(0.0f, -t * 0.16f), 3);
    float b = sk_fbmG(p * 2.10f + float2(t * 0.07f, -t * 0.31f), 2);
    return clamp(a * 0.65f + b * 0.55f, 0.0f, 1.0f);
}

// MARK: - Ink runs
//
// Five inks each for sand and water, plus a night set. A printed look has to
// change plates for a night edition, or midnight comes out identical to noon.

constant float3 SK_SP_SAND[5] = {
    float3(0.118f, 0.094f, 0.098f), float3(0.376f, 0.204f, 0.180f),
    float3(0.741f, 0.443f, 0.278f), float3(0.925f, 0.757f, 0.514f),
    float3(0.976f, 0.933f, 0.847f)
};
constant float3 SK_SP_WATER[5] = {
    float3(0.047f, 0.121f, 0.165f), float3(0.063f, 0.278f, 0.325f),
    float3(0.141f, 0.494f, 0.502f), float3(0.424f, 0.737f, 0.686f),
    float3(0.957f, 0.929f, 0.859f)
};
constant float3 SK_WB_SAND[5] = {
    float3(0.086f, 0.078f, 0.070f), float3(0.301f, 0.247f, 0.204f),
    float3(0.588f, 0.494f, 0.388f), float3(0.831f, 0.760f, 0.643f),
    float3(0.949f, 0.929f, 0.886f)
};
constant float3 SK_WB_WATER[5] = {
    float3(0.055f, 0.078f, 0.118f), float3(0.129f, 0.192f, 0.286f),
    float3(0.267f, 0.376f, 0.478f), float3(0.545f, 0.639f, 0.694f),
    float3(0.902f, 0.906f, 0.886f)
};
constant float3 SK_NIGHT_SAND[5] = {
    float3(0.038f, 0.046f, 0.078f), float3(0.098f, 0.124f, 0.196f),
    float3(0.205f, 0.256f, 0.360f), float3(0.390f, 0.455f, 0.560f),
    float3(0.690f, 0.735f, 0.800f)
};
constant float3 SK_NIGHT_WATER[5] = {
    float3(0.022f, 0.036f, 0.070f), float3(0.048f, 0.084f, 0.150f),
    float3(0.098f, 0.160f, 0.250f), float3(0.215f, 0.300f, 0.400f),
    float3(0.640f, 0.690f, 0.760f)
};

/// Pick the sand ink run for a look, already blended toward its night edition.
inline void sk_sandInks(int lookIndex, float night, thread float3 *out) {
    for (int i = 0; i < 5; ++i) {
        float3 day = (lookIndex == 7) ? SK_WB_SAND[i] : SK_SP_SAND[i];
        out[i] = mix(day, SK_NIGHT_SAND[i], night);
    }
}

inline void sk_waterInks(int lookIndex, float night, thread float3 *out) {
    for (int i = 0; i < 5; ++i) {
        float3 day = (lookIndex == 7) ? SK_WB_WATER[i] : SK_SP_WATER[i];
        out[i] = mix(day, SK_NIGHT_WATER[i], night);
    }
}

#endif /* SandkraftRender_h */
