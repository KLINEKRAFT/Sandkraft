//
//  Water.metal
//  Sandkraft — the sea
//
//  The water surface is the same Gerstner sum the solver erodes with. Not a
//  similar one, not a visually matched one — literally `sk_gerstner` out of
//  Common.h, evaluated with the same depth and the same amplitude. If the two
//  ever diverge, waves start biting sand they are not touching and the whole
//  game quietly stops making sense.
//
//  Compositing is done by hand rather than with a blend state: the fragment
//  samples the already-rendered opaque scene and returns the mixed result. That
//  costs one full-resolution copy and buys refraction, correct depth
//  absorption, and a swash edge that can be a soft coverage ramp instead of a
//  hard discard — which matters, because a hard discard gives a stair-stepped
//  shoreline that no amount of multisampling will fix.
//

#include "Render.h"

struct WaterVertexOut {
    float4 position [[position]];
    float3 worldPosition;
    float2 flatPosition;      // the undisplaced XZ — the wave field is a function of this
    float stillDepth;
    float breaking;
};

// MARK: - Vertex

vertex WaterVertexOut water_vertex(uint vid [[vertex_id]],
                                   constant SKFrameUniforms &frame     [[buffer(0)]],
                                   constant SKTerrainUniforms &terrain [[buffer(1)]],
                                   texture2d<float> sandTex            [[texture(0)]]) {
    float2 uv = sk_gridUV(vid, uint(terrain.gridEdge));
    float2 p = sk_skirtPosition(uv);

    float seaLevel = sk_seaLevelAt(frame.seaBase, frame.time);
    float depth = max(sk_stillDepth(sandTex, p, seaLevel, frame.domain,
                                    frame.simResolution, frame.texel), 0.0f);

    float4 g = sk_gerstner(p, frame.time, depth, frame.waveAmplitude, 5);

    WaterVertexOut out;
    out.flatPosition = p;
    out.worldPosition = float3(p.x + g.x, seaLevel + g.y, p.y + g.z);
    out.stillDepth = depth;
    out.breaking = g.w;
    out.position = frame.viewProjection * float4(out.worldPosition, 1.0f);
    return out;
}

// MARK: - Fragment

fragment float4 water_fragment(WaterVertexOut in [[stage_in]],
                               constant SKFrameUniforms &frame     [[buffer(0)]],
                               constant SKTerrainUniforms &terrain [[buffer(1)]],
                               constant SKLookUniforms &look       [[buffer(2)]],
                               texture2d<float> sandTex            [[texture(0)]],
                               texture2d<float> skyLUT             [[texture(1)]],
                               texture2d<float> sceneColor         [[texture(2)]],
                               depth2d<float>   shadowMap          [[texture(3)]]) {
    constexpr sampler linearClamp(coord::normalized, filter::linear, address::clamp_to_edge);

    float seaLevel = sk_seaLevelAt(frame.seaBase, frame.time);
    float2 p = in.flatPosition;

    // Where the ground is, and therefore how much water is actually standing over
    // it. `coverage` is the soft waterline.
    float stillGround = seaLevel - in.stillDepth;
    float wedge = in.worldPosition.y - stillGround;
    float coverage = smoothstep(0.0f, 0.035f, wedge);

    float2 screenUV = in.position.xy * frame.viewport.zw;
    float3 straight = sceneColor.sample(linearClamp, screenUV).rgb;
    if (coverage <= 0.002f) { return float4(straight, 1.0f); }

    // Surface normal from the analytic wave field, central-differenced in the
    // *undisplaced* frame. Far more stable than differencing the displaced vertex
    // positions, which fold over each other near a breaker.
    const float e = 0.22f;
    float dl = max(sk_stillDepth(sandTex, p - float2(e, 0.0f), seaLevel, frame.domain, frame.simResolution, frame.texel), 0.0f);
    float dr = max(sk_stillDepth(sandTex, p + float2(e, 0.0f), seaLevel, frame.domain, frame.simResolution, frame.texel), 0.0f);
    float dd = max(sk_stillDepth(sandTex, p - float2(0.0f, e), seaLevel, frame.domain, frame.simResolution, frame.texel), 0.0f);
    float du = max(sk_stillDepth(sandTex, p + float2(0.0f, e), seaLevel, frame.domain, frame.simResolution, frame.texel), 0.0f);

    float hl = sk_gerstner(p - float2(e, 0.0f), frame.time, dl, frame.waveAmplitude, 5).y;
    float hr = sk_gerstner(p + float2(e, 0.0f), frame.time, dr, frame.waveAmplitude, 5).y;
    float hd = sk_gerstner(p - float2(0.0f, e), frame.time, dd, frame.waveAmplitude, 5).y;
    float hu = sk_gerstner(p + float2(0.0f, e), frame.time, du, frame.waveAmplitude, 5).y;
    float3 N = normalize(float3(hl - hr, 2.0f * e, hd - hu));

    // Fine chop. Without it a calm sea is a sheet of glass, which is not what
    // calm looks like.
    float chopFade = exp(-(fwidth(p.x) + fwidth(p.y)) * 20.0f);
    float2 cp = p * 3.4f + float2(frame.time * 0.11f, -frame.time * 0.27f);
    const float ce = 0.09f;
    float c0 = sk_fbmG(cp, 3);
    float cx = sk_fbmG(cp + float2(ce, 0.0f), 3);
    float cz = sk_fbmG(cp + float2(0.0f, ce), 3);
    float chopAmp = 0.055f * chopFade * smoothstep(0.05f, 0.60f, in.stillDepth);
    N = normalize(N + float3(-(cx - c0) / ce, 0.0f, -(cz - c0) / ce) * chopAmp);

    float3 V = normalize(frame.cameraPosition.xyz - in.worldPosition);
    float NoV = max(dot(N, V), 1e-3f);
    float3 L = frame.sunDirection.xyz;
    float NoL = max(dot(N, L), 0.0f);

    // Screen-space refraction. The offset scales with depth, so shallow water
    // barely bends and deep water bends a lot — correct, and conveniently
    // self-limiting near the shore where the artefacts would show.
    float bend = clamp(in.stillDepth * 0.05f, 0.0f, 0.035f);
    float2 refractUV = clamp(screenUV + N.xz * bend, float2(0.002f), float2(0.998f));
    float3 behind = sceneColor.sample(linearClamp, refractUV).rgb;
    // Fall back toward the unrefracted tap at the edges, where a refracted one can
    // reach past the shoreline and pull in sky.
    behind = mix(straight, behind, coverage);

    // Absorption. Water is not blue because it reflects the sky; it is blue
    // because it eats red. Path length is roughly twice the depth for a
    // near-vertical view, which the 1.6 stands in for.
    float path = max(wedge, 0.0f) * 1.6f;
    float3 extinction = float3(0.46f, 0.10f, 0.055f) / max(look.waterTint.rgb, float3(0.05f));
    float3 transmittance = exp(-extinction * path);
    float3 deepTint = float3(0.016f, 0.115f, 0.150f) * look.waterTint.rgb;
    float3 refracted = behind * transmittance + deepTint * (1.0f - transmittance);

    // Reflection. Mirror the ray back up rather than ever sampling the ground
    // half of the LUT — at a grazing angle over chop, R.y goes negative
    // constantly and the sea fills with flecks of beach.
    float3 R = reflect(-V, N);
    R.y = abs(R.y);
    float3 reflected = sk_skySample(skyLUT, R,
                                    mix(2.4f, 0.0f, smoothstep(0.0f, 0.35f, in.stillDepth)));

    // Fresnel, with the grazing response softened so a low camera does not turn
    // the whole bay into a mirror and lose the sand under it.
    float fresnel = 0.02f + 0.98f * pow(1.0f - NoV, 5.0f);
    fresnel = mix(fresnel, min(fresnel, 0.72f), 0.55f);

    float3 col = mix(refracted, reflected, fresnel);

    // Sun glitter.
    float3 H = normalize(V + L);
    float NoH = max(dot(N, H), 0.0f);
    const float alpha = 0.045f;
    float3 spec = sk_F_Schlick(float3(0.02f), max(dot(V, H), 0.0f))
                * sk_D_GGX(NoH, alpha) * sk_V_Smith(NoV, NoL, alpha) * NoL;
    float shadow = sk_shadowAt(shadowMap, frame.lightViewProjection, in.worldPosition,
                               NoL, frame.shadowTexel, frame.shadowEnabled);
    col += frame.sunColor.rgb * spec * shadow * 2.4f;

    // MARK: Foam
    //
    // Three sources, and they read as three different things on a real beach:
    //   · breaking crests, straight out of the Gerstner steepness budget
    //   · the shallow wedge where a wave is running out of water underneath it
    //   · the swash line itself, the thin lace at the very top of the run

    float foamNoise = sk_foamField(in.flatPosition * 0.75f, frame.time);
    float crest   = smoothstep(0.28f, 0.85f, in.breaking);
    float shallow = smoothstep(0.65f, 0.06f, in.stillDepth);
    float lace    = smoothstep(0.16f, 0.0f, wedge) * smoothstep(0.0f, 0.02f, wedge);

    float foam = clamp(crest * 1.15f + shallow * crest * 0.9f + lace * 1.4f, 0.0f, 1.6f);
    foam *= smoothstep(0.28f, 0.72f, foamNoise + crest * 0.25f);
    foam = clamp(foam, 0.0f, 1.0f);

    float3 foamColor = look.foamTint.rgb
        * (frame.sunColor.rgb * (0.55f + 0.45f * NoL) * shadow
           + sk_ambientFrom(skyLUT, float3(0.0f, 1.0f, 0.0f)) * 0.85f);
    col = mix(col, foamColor, foam * 0.92f);

    // Subsurface glow through the back of a wave standing between you and the
    // sun. This is the green in the lip of a breaker, and it is worth two lines.
    float through = pow(max(dot(V, -L), 0.0f), 2.5f)
                  * smoothstep(0.0f, 0.5f, in.breaking)
                  * smoothstep(1.6f, 0.15f, in.stillDepth);
    col += float3(0.22f, 0.62f, 0.48f) * frame.sunColor.rgb * through * 0.85f;

    // The treatments that replace light rather than shade it need the sea to
    // follow, or the water stays photographic while the beach is a woodcut.
    if (look.treatment == 2) {
        float lum = clamp(sk_luma(col) * 1.6f, 0.0f, 1.0f);
        float3 inks[5];
        sk_waterInks(look.index, frame.night, inks);
        float3 printed = sk_screenPrint(lum, in.position.xy, look.screenAngle, look.screenScale,
                                        inks[0], inks[1], inks[2], inks[3], inks[4]);
        col = mix(printed, mix(printed, look.foamTint.rgb, 0.75f), foam);
    } else if (look.treatment == 1) {
        float lum = sk_softBands(clamp(sk_luma(col) * 1.35f, 0.0f, 1.0f),
                                 max(look.bandCount, 2.0f), look.bandSoftness);
        float3 shallowInk = float3(0.42f, 0.76f, 0.78f) * look.waterTint.rgb;
        float3 deepInk    = float3(0.08f, 0.28f, 0.42f) * look.waterTint.rgb;
        col = mix(deepInk, shallowInk, lum);
        col = mix(col, look.foamTint.rgb, foam * 0.85f);
    } else if (look.treatment == 3) {
        // On the survey sheet the sea is a tint block with ruled depth contours,
        // the way a chart draws water.
        float nite = frame.night;
        float3 tint = mix(float3(0.72f, 0.82f, 0.88f), float3(0.09f, 0.16f, 0.30f), nite);
        float3 ink  = mix(float3(0.255f, 0.235f, 0.215f), float3(0.80f, 0.87f, 0.93f), nite);
        float rule = sk_contour(in.stillDepth, 0.5f, 0.02f);
        col = mix(tint, ink, rule * 0.35f);
        col = mix(col, ink, foam * 0.25f);
    }

    float dist = length(frame.cameraPosition.xyz - in.worldPosition);
    col = sk_applyFog(skyLUT, col, dist, -V, frame.fogK,
                      frame.sunDirection.xyz, frame.sunColor.rgb);

    // Composited by hand, so this pass writes opaque and the blend state stays
    // out of it entirely.
    return float4(mix(straight, col, coverage), 1.0f);
}
