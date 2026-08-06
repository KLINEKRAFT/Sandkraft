//
//  Post.metal
//  Sandkraft — the last thing that happens to a pixel
//
//  Bright pass → separable blur → composite. Three small passes rather than one
//  large one, because the blur runs at half resolution and the composite is the
//  only pass that touches every full-resolution pixel.
//
//  The half-resolution blur earns its keep twice: once as bloom, and once as the
//  out-of-focus source for depth of field. A separate DOF chain would be the
//  textbook answer and would cost another two passes to produce something the
//  eye cannot distinguish at this aperture.
//

#include "Render.h"

// MARK: - Full-screen triangle
//
// One triangle, not two. Two would put a diagonal seam through the middle of
// every derivative-based effect in the composite.

struct PostVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex PostVertexOut post_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    PostVertexOut out;
    out.uv = p;
    out.position = float4(p * float2(2.0f, -2.0f) + float2(-1.0f, 1.0f), 0.0f, 1.0f);
    return out;
}

// MARK: - Bright pass

fragment float4 post_brightpass(PostVertexOut in [[stage_in]],
                                constant SKPostUniforms &u [[buffer(0)]],
                                texture2d<float> source    [[texture(0)]]) {
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);

    // A four-tap box at the half-resolution texel centres, which is a free
    // downsample — the hardware bilinear does most of the averaging.
    float2 texel = u.viewport.zw;
    float3 c = source.sample(s, in.uv + float2(-texel.x,  texel.y)).rgb
             + source.sample(s, in.uv + float2( texel.x,  texel.y)).rgb
             + source.sample(s, in.uv + float2(-texel.x, -texel.y)).rgb
             + source.sample(s, in.uv + float2( texel.x, -texel.y)).rgb;
    c *= 0.25f;

    // Soft knee. A hard threshold makes bloom pop on and off as a highlight
    // crosses it, which reads as flicker on moving water — and moving water is
    // most of what bloom is for here.
    const float threshold = 1.0f;
    const float knee = 0.55f;
    float lum = sk_luma(c);
    float soft = clamp(lum - threshold + knee, 0.0f, 2.0f * knee);
    soft = soft * soft / (4.0f * knee + 1e-5f);
    float contribution = max(soft, lum - threshold) / max(lum, 1e-5f);

    return float4(c * contribution, 1.0f);
}

// MARK: - Separable blur

/// Nine-tap Gaussian using linear-sampling pairs, so it costs five fetches.
/// `direction` is (1,0) or (0,1) in texels.
fragment float4 post_blur(PostVertexOut in [[stage_in]],
                          constant SKPostUniforms &u  [[buffer(0)]],
                          constant float2 &direction  [[buffer(1)]],
                          texture2d<float> source     [[texture(0)]]) {
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);

    const float offsets[3] = { 0.0f, 1.3846153846f, 3.2307692308f };
    const float weights[3] = { 0.2270270270f, 0.3162162162f, 0.0702702703f };

    float2 step = direction * u.viewport.zw;
    float3 c = source.sample(s, in.uv).rgb * weights[0];
    for (int i = 1; i < 3; ++i) {
        c += source.sample(s, in.uv + step * offsets[i]).rgb * weights[i];
        c += source.sample(s, in.uv - step * offsets[i]).rgb * weights[i];
    }
    return float4(c, 1.0f);
}

// MARK: - Composite

inline float sk_linearDepth(float d, float near, float far) {
    // Metal clip space: depth runs 0…1, and the projection used here is the
    // standard reversed-nothing right-handed one, so this is the plain inverse.
    return (near * far) / max(far - d * (far - near), 1e-5f);
}

/// Sobel over linear depth and luminance. Depth catches silhouettes, luminance
/// catches the internal lines — a crease where a rampart meets the beach has no
/// depth discontinuity at all and would otherwise go unmarked.
inline float sk_inkEdge(texture2d<float> color, depth2d<float> depthTex,
                        float2 uv, float2 texel, float near, float far) {
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    constexpr sampler sd(coord::normalized, filter::nearest, address::clamp_to_edge);

    float d[9];
    float l[9];
    int k = 0;
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            float2 o = uv + float2(float(x), float(y)) * texel;
            d[k] = sk_linearDepth(depthTex.sample(sd, o), near, far);
            l[k] = sk_luma(color.sample(s, o).rgb);
            ++k;
        }
    }

    float gxD = (d[0] + 2.0f * d[3] + d[6]) - (d[2] + 2.0f * d[5] + d[8]);
    float gyD = (d[0] + 2.0f * d[1] + d[2]) - (d[6] + 2.0f * d[7] + d[8]);
    // Normalised by depth, or the outline thickens toward the horizon until the
    // headlands are solid ink.
    float depthEdge = sqrt(gxD * gxD + gyD * gyD) / max(d[4], 0.5f);

    float gxL = (l[0] + 2.0f * l[3] + l[6]) - (l[2] + 2.0f * l[5] + l[8]);
    float gyL = (l[0] + 2.0f * l[1] + l[2]) - (l[6] + 2.0f * l[7] + l[8]);
    float lumEdge = sqrt(gxL * gxL + gyL * gyL);

    return clamp(smoothstep(0.10f, 0.55f, depthEdge) + smoothstep(0.55f, 1.30f, lumEdge),
                 0.0f, 1.0f);
}

fragment float4 post_composite(PostVertexOut in [[stage_in]],
                               constant SKPostUniforms &u   [[buffer(0)]],
                               constant SKLookUniforms &look[[buffer(1)]],
                               texture2d<float> scene       [[texture(0)]],
                               texture2d<float> bloom       [[texture(1)]],
                               depth2d<float>   depthTex    [[texture(2)]]) {
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    constexpr sampler sd(coord::normalized, filter::nearest, address::clamp_to_edge);

    float2 uv = in.uv;
    float2 texel = u.viewport.zw;

    // Lateral chromatic aberration, radial from the centre. Small values sell
    // "printed"; anything visible sells "broken".
    float3 c;
    if (u.chromatic > 1e-5f) {
        float2 dir = (uv - 0.5f);
        float2 off = dir * u.chromatic;
        c.r = scene.sample(s, clamp(uv + off, 0.0f, 1.0f)).r;
        c.g = scene.sample(s, uv).g;
        c.b = scene.sample(s, clamp(uv - off, 0.0f, 1.0f)).b;
    } else {
        c = scene.sample(s, uv).rgb;
    }

    // Supersample resolve: a rotated-grid tent over the larger source buffer.
    // Four extra taps, and only when the buffer is actually bigger than the
    // drawable.
    if (u.resolveStrength > 1e-4f) {
        float2 o = u.resolveTexel;
        float3 t = scene.sample(s, uv + float2( o.x,  o.y)).rgb
                 + scene.sample(s, uv + float2(-o.x,  o.y)).rgb
                 + scene.sample(s, uv + float2( o.x, -o.y)).rgb
                 + scene.sample(s, uv + float2(-o.x, -o.y)).rgb;
        c = mix(c, (c + t) * 0.2f, u.resolveStrength);
    }

    float3 blurred = bloom.sample(s, uv).rgb;

    // Depth of field. The circle of confusion is a simple distance ratio — this
    // is a miniature effect, not a lens simulation, and the moment it starts
    // behaving like a real lens it stops looking like a diorama.
    if (u.aperture > 1e-4f) {
        float depth = sk_linearDepth(depthTex.sample(sd, uv), u.nearPlane, u.farPlane);
        float coc = clamp(abs(depth - u.focusDistance) / max(u.focusDistance, 0.5f) * u.aperture,
                          0.0f, 1.0f);
        // The bloom buffer is a bright-passed blur, not a plain one, so mixing it
        // straight in would only blur the highlights. Blend toward a
        // luminance-matched version of it instead.
        float3 soft = mix(c, blurred + c * 0.35f, 0.72f);
        c = mix(c, soft, coc * coc);
    }

    c += blurred * u.bloomStrength;

    // Ink outline, before tonemapping, so the line sits in scene-referred space
    // and does not change weight with exposure.
    if (u.inkOutline > 1e-4f) {
        float edge = sk_inkEdge(scene, depthTex, uv, texel, u.nearPlane, u.farPlane);
        float3 ink = mix(float3(0.055f, 0.048f, 0.052f), float3(0.78f, 0.84f, 0.92f), u.night);
        c = mix(c, ink, clamp(edge * u.inkOutline, 0.0f, 0.92f));
    }

    c *= u.exposure;

    // Printed looks are already display-referred: they were assembled out of ink
    // colours, not out of radiance. Running them through a film curve crushes
    // exactly the flat ink steps that are the entire point of them.
    bool printed = (look.treatment == 2) || (look.treatment == 3);
    if (!printed) {
        c = sk_tonemapACES(c);
    } else {
        c = clamp(c, 0.0f, 1.0f);
    }

    c = pow(max(c, 0.0f), float3(1.0f / max(u.contrast, 0.05f)));
    c = sk_saturate3(c, u.saturation);

    // Vignette. Cosine-fourth-ish rather than a radial gradient, which is what
    // real glass does and what stops it reading as a filter.
    float2 vd = (uv - 0.5f) * float2(u.viewport.x / max(u.viewport.y, 1.0f), 1.0f);
    float vig = 1.0f - u.vignette * clamp(dot(vd, vd) * 1.15f, 0.0f, 1.0f);
    c *= vig;

    // Grain. Animated, and scaled by (1 − luminance) so it lives in the shadows
    // where film grain lives rather than sitting evenly over a bright sky.
    if (u.grain > 1e-5f) {
        float n = sk_hash12(in.position.xy + float2(u.time * 61.7f, u.time * 37.1f)) - 0.5f;
        c += n * u.grain * (1.0f - sk_luma(c) * 0.65f);
    }

    return float4(max(c, 0.0f), 1.0f);
}
