//
//  Props.metal
//  Sandkraft — the things you put on top
//
//  Adornments are ordinary instanced meshes, built procedurally on the CPU at
//  launch (see PropMeshLibrary.swift) rather than synthesised in the vertex
//  shader.
//
//  That is a deliberate choice against the clever option. A procedural vertex
//  shader for twelve different objects would be one enormous switch that cannot
//  be inspected in the GPU debugger, cannot be unit-tested, and re-derives the
//  same geometry sixty times a second. A few thousand triangles built once at
//  launch costs about 200 KB and is legible.
//
//  What the shader *does* own is the lean: every prop tilts with the sand under
//  it and goes over when the water reaches it, and that is per-instance state
//  that changes every frame.
//

#include "Render.h"

struct PropVertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    float4 color    [[attribute(2)]];   // baked material colour, a = roughness
};

struct PropVertexOut {
    float4 position [[position]];
    float3 worldPosition;
    float3 normal;
    float4 color;
    float health;
};

/// Build the instance transform: yaw, then a lean about a horizontal axis, then
/// translate. The lean axis and angle come from how the sand under the prop has
/// moved, which the CPU works out from the pick and metric readbacks.
inline float4x4 sk_propTransform(SKProp prop) {
    float s = max(prop.position.w, 0.001f);
    float3 axis = float3(prop.orientation.x, 0.0f, prop.orientation.y) + float3(1e-4f, 0.0f, 0.0f);

    float4x4 scale = float4x4(float4(s, 0.0f, 0.0f, 0.0f),
                              float4(0.0f, s, 0.0f, 0.0f),
                              float4(0.0f, 0.0f, s, 0.0f),
                              float4(0.0f, 0.0f, 0.0f, 1.0f));

    // Lean about a horizontal axis, then yaw, then scale — read right to left.
    // The product's fourth column is (0,0,0,1), so the translation can simply be
    // written into it afterwards. MSL matrices subscript to columns.
    float4x4 m = sk_rotationAxis(axis, prop.orientation.z) * sk_rotationY(prop.orientation.w) * scale;
    m[3] = float4(prop.position.xyz, 1.0f);
    return m;
}

vertex PropVertexOut prop_vertex(PropVertexIn in                    [[stage_in]],
                                 uint iid                           [[instance_id]],
                                 device const SKProp *props         [[buffer(1)]],
                                 constant SKFrameUniforms &frame    [[buffer(2)]]) {
    SKProp prop = props[iid];
    float4x4 model = sk_propTransform(prop);

    float4 world = model * float4(in.position, 1.0f);
    float3 normal = normalize((model * float4(in.normal, 0.0f)).xyz);

    PropVertexOut out;
    out.worldPosition = world.xyz;
    out.normal = normal;
    out.color = in.color;
    out.health = prop.state.r;
    out.position = frame.viewProjection * world;
    return out;
}

vertex float4 prop_shadow_vertex(PropVertexIn in                 [[stage_in]],
                                 uint iid                        [[instance_id]],
                                 device const SKProp *props      [[buffer(1)]],
                                 constant SKFrameUniforms &frame [[buffer(2)]]) {
    SKProp prop = props[iid];
    float4 world = sk_propTransform(prop) * float4(in.position, 1.0f);
    return frame.lightViewProjection * world;
}

fragment float4 prop_fragment(PropVertexOut in [[stage_in]],
                              constant SKFrameUniforms &frame [[buffer(0)]],
                              constant SKLookUniforms &look   [[buffer(1)]],
                              texture2d<float> skyLUT         [[texture(0)]],
                              depth2d<float>   shadowMap      [[texture(1)]]) {
    float3 N = normalize(in.normal);
    float3 V = normalize(frame.cameraPosition.xyz - in.worldPosition);
    float3 L = frame.sunDirection.xyz;

    // Two-sided. Flags, sails and kelp are single-sided sheets and would
    // otherwise go black the moment the wind turned them over.
    if (dot(N, V) < 0.0f) { N = -N; }

    float NoL = max(dot(N, L), 0.0f);
    float shadow = sk_shadowAt(shadowMap, frame.lightViewProjection,
                               in.worldPosition + N * 0.008f, NoL,
                               frame.shadowTexel, frame.shadowEnabled);

    // Sun-bleached, salt-stained, and darker where the water has already been.
    float3 albedo = in.color.rgb * mix(0.45f, 1.0f, in.health);
    float rough = clamp(in.color.a, 0.08f, 1.0f);

    float3 direct = frame.sunColor.rgb * shadow * albedo * (1.0f / SK_PI)
                  * sk_orenNayar(N, V, L, rough);

    float3 amb = sk_ambientFrom(skyLUT, N) * albedo * 1.15f;
    // The same beach bounce the sand gets. A parasol lit only from above reads
    // as a cardboard cut-out.
    amb += sk_ambientFrom(skyLUT, float3(0.0f, 1.0f, 0.0f)) * albedo * albedo * 0.35f
         * smoothstep(0.5f, -0.2f, N.y);

    float3 H = normalize(V + L);
    float alpha = max(rough * rough, 0.002f);
    float3 spec = sk_F_Schlick(float3(0.04f), max(dot(V, H), 0.0f))
                * sk_D_GGX(max(dot(N, H), 0.0f), alpha)
                * sk_V_Smith(max(dot(N, V), 1e-4f), NoL, alpha) * NoL;

    float3 col = direct + amb + frame.sunColor.rgb * shadow * spec;
    col += albedo * frame.moonColor.rgb * max(dot(N, frame.moonDirection.xyz), 0.0f) * 0.9f;

    // Follow the look, so a paper boat on a screen-printed beach is printed too.
    if (look.treatment == 1) {
        float key = sk_softBands(NoL * mix(0.55f, 1.0f, shadow), max(look.bandCount, 2.0f), look.bandSoftness);
        float3 skyc = sk_ambientFrom(skyLUT, float3(0.0f, 1.0f, 0.0f));
        col = mix(albedo * skyc * 0.75f, albedo * (frame.sunColor.rgb * 0.6f + skyc), key);
    } else if (look.treatment == 2) {
        float lum = clamp(NoL * mix(0.5f, 1.0f, shadow) + sk_luma(albedo) * 0.6f - 0.15f, 0.0f, 1.0f);
        float3 inks[5];
        sk_sandInks(look.index, frame.night, inks);
        float3 printed = sk_screenPrint(lum, in.position.xy, look.screenAngle, look.screenScale,
                                        inks[0], inks[1], inks[2], inks[3], inks[4]);
        // Keep a trace of the prop's own colour, or every adornment prints as
        // sand and the whole beach turns monochrome.
        col = mix(printed, printed * albedo * 1.8f, 0.45f);
    } else if (look.treatment == 3) {
        float nite = frame.night;
        float3 ink = mix(float3(0.255f, 0.235f, 0.215f), float3(0.80f, 0.87f, 0.93f), nite);
        float3 paper = mix(float3(0.945f, 0.918f, 0.850f), float3(0.075f, 0.130f, 0.235f), nite);
        col = mix(paper, ink, 0.35f + 0.45f * (1.0f - NoL));
    }

    float dist = length(frame.cameraPosition.xyz - in.worldPosition);
    col = sk_applyFog(skyLUT, col, dist, -V, frame.fogK,
                      frame.sunDirection.xyz, frame.sunColor.rgb);

    return float4(col, 1.0f);
}
