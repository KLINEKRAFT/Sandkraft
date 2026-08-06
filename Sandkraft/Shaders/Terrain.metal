//
//  Terrain.metal
//  Sandkraft — the sand, drawn
//
//  The beach is a real triangle mesh, not a raymarch, and it has no vertex
//  buffer: positions are synthesised from `vertex_id` alone and displaced by a
//  vertex texture fetch of the simulation field. That removes every per-frame
//  buffer upload, and it means the geometry can never be a frame behind the
//  simulation.
//
//  Two deliberate disagreements are worth knowing about before changing
//  anything here:
//
//    · The vertex height is a *point* sample of the sim texture. The fragment
//      normal is rebuilt from a *smoothed* resample of the same field. The
//      geometry is therefore faceted at sim-texel scale while the shading is
//      continuous, and that combination is what makes a heightfield read as
//      sand rather than as a mesh.
//
//    · The nine looks are not nine shaders. Everything up to the surface
//      treatment is shared, and the treatment branches exactly once — on
//      `treatment`, where the work really is different — with the rest of each
//      look expressed as parameters in SKLookUniforms.
//

#include "Render.h"

// MARK: - Vertex

struct TerrainVertexOut {
    float4 position [[position]];
    float3 worldPosition;
    float2 domainUV;
    float4 sand;
};

vertex TerrainVertexOut terrain_vertex(uint vid [[vertex_id]],
                                       constant SKFrameUniforms &frame [[buffer(0)]],
                                       constant SKTerrainUniforms &terrain [[buffer(1)]],
                                       texture2d<float> sandTex [[texture(0)]]) {
    constexpr sampler np(coord::normalized, filter::nearest, address::clamp_to_edge);

    float2 uv = sk_gridUV(vid, uint(terrain.gridEdge));
    float2 wp;
    float4 S = float4(0.0f);
    float drop = 0.0f;

    if (terrain.outer > 0.5f) {
        // The skirt. Inside the domain it samples the *same* field as the inner
        // grid, so the two can never diverge; and it is sunk 0.85 m below the
        // real surface over the last couple of metres of the border, so its
        // coarse triangles cannot saw up through the fine ones when the sea
        // scours the shoreline.
        wp = sk_skirtPosition(uv);
        float2 duv = (wp - frame.domain.xy) / frame.domain.zw;
        bool ins = duv.x > 0.0f && duv.x < 1.0f && duv.y > 0.0f && duv.y < 1.0f;
        S.r = ins ? sandTex.sample(np, clamp(duv, 0.0f, 1.0f), level(0)).r : sk_sandBed(wp);
        float2 dd = min(duv, 1.0f - duv);
        drop = 0.85f * smoothstep(0.0f, 0.045f, max(0.0f, min(dd.x, dd.y)));
        uv = clamp(duv, 0.0f, 1.0f);
    } else {
        wp = frame.domain.xy + uv * frame.domain.zw;
        S = sandTex.sample(np, uv, level(0));
    }

    float y = sk_bedrock(wp) + S.r - drop;

    TerrainVertexOut out;
    out.worldPosition = float3(wp.x, y, wp.y);
    out.domainUV = uv;
    out.sand = S;
    out.position = frame.viewProjection * float4(out.worldPosition, 1.0f);
    return out;
}

/// Depth-only pass for the sun. The skirt is deliberately not drawn into it —
/// nothing 340 m away casts a shadow anyone will see, and leaving it out
/// effectively doubles the shadow map's resolution over the part that matters.
vertex float4 terrain_shadow_vertex(uint vid [[vertex_id]],
                                    constant SKFrameUniforms &frame [[buffer(0)]],
                                    constant SKTerrainUniforms &terrain [[buffer(1)]],
                                    texture2d<float> sandTex [[texture(0)]]) {
    constexpr sampler np(coord::normalized, filter::nearest, address::clamp_to_edge);
    float2 uv = sk_gridUV(vid, uint(terrain.gridEdge));
    float2 wp = frame.domain.xy + uv * frame.domain.zw;
    float y = sk_bedrock(wp) + sandTex.sample(np, uv, level(0)).r;
    return frame.lightViewProjection * float4(wp.x, y, wp.y, 1.0f);
}

// MARK: - Surface treatments

struct SurfaceInputs {
    float3 albedo;
    float3 N;
    float3 V;
    float3 L;
    float3 worldPosition;
    float NoL;
    float shadow;
    float ao;
    float vertical;
    float wet;
    float sheen;
    float packing;
    float night;
    float2 screenPosition;
};

/// Quantised light. Three to five soft steps, with the shade tone taken off the
/// *lit* colour rather than off pure ambient — a pure-ambient shade goes slate
/// at golden hour, which is exactly when you least want it to.
inline float3 sk_treatBanded(SurfaceInputs s, constant SKLookUniforms &look,
                             float3 keyColor, float3 skyColor, float3 sunDir) {
    float key = sk_softBands(s.NoL * mix(0.55f, 1.0f, s.shadow) * s.ao,
                             max(look.bandCount, 2.0f), look.bandSoftness);

    float3 kc = keyColor * 0.145f + skyColor * 0.9f;
    kc = mix(float3(sk_luma(kc)), kc, 0.60f);        // held back toward neutral, so a
                                                     // low sun does not stain everything
    float3 lit = s.albedo * kc;
    float hi = smoothstep(0.06f, 0.40f, sunDir.y);
    float3 shadeTint = mix(float3(0.66f, 0.58f, 0.55f), float3(0.50f, 0.55f, 0.68f), hi);
    float3 shade = lit * shadeTint + s.albedo * skyColor * 0.42f;

    float3 col = mix(shade, lit, key);

    float rim = pow(1.0f - max(dot(s.N, s.V), 0.0f), 3.2f) * max(s.NoL, 0.18f);
    col += (keyColor * 0.05f + skyColor * 0.6f) * rim * 0.55f * s.albedo;

    float back = pow(max(dot(s.V, -s.L), 0.0f), 2.0f)
               * pow(1.0f - max(dot(s.N, s.V), 0.0f), 1.8f);
    col += keyColor * s.shadow * back * s.albedo * 0.14f;
    return col;
}

/// Five inks and a rotated dot screen. Light is not shaded here, it is
/// *separated* — which is why this look survives a change of sun angle that
/// would wreck a banded one.
inline float3 sk_treatSeparated(SurfaceInputs s, constant SKLookUniforms &look) {
    float L = clamp(s.NoL * mix(0.45f, 1.0f, s.shadow) * s.ao * 1.15f
                    + sk_luma(s.albedo) * 0.55f - 0.18f, 0.0f, 1.0f);

    float3 inks[5];
    sk_sandInks(look.index, s.night, inks);

    float3 col = sk_screenPrint(L, s.screenPosition, look.screenAngle, look.screenScale,
                                inks[0], inks[1], inks[2], inks[3], inks[4]);

    // Wet sand takes the water run instead of the sand run. This is the only
    // place the printed looks acknowledge moisture at all, and it is enough.
    float3 wetInks[5];
    sk_waterInks(look.index, s.night, wetInks);
    col = mix(col, mix(col, wetInks[1], 0.55f), clamp(s.wet * 0.9f + s.sheen, 0.0f, 1.0f));
    return col;
}

/// The only look that reads the heightfield *as* a heightfield. After dark the
/// survey sheet inverts into a blueprint, which costs three mixes and is the
/// single most-remarked-upon thing in the whole style set.
inline float3 sk_treatContoured(SurfaceInputs s, constant SKLookUniforms &look) {
    float nite = s.night;
    float3 paper = mix(float3(0.945f, 0.918f, 0.850f), float3(0.075f, 0.130f, 0.235f), nite);
    float3 ink   = mix(float3(0.255f, 0.235f, 0.215f), float3(0.800f, 0.870f, 0.930f), nite);
    float3 fill  = mix(float3(0.905f, 0.848f, 0.700f), float3(0.105f, 0.180f, 0.300f), nite);

    float interval = max(look.contourInterval, 0.02f);
    float line = sk_contour(s.worldPosition.y, interval, 0.014f);
    float idx  = sk_contour(s.worldPosition.y, interval * 5.0f, 0.011f);

    float steep = smoothstep(0.80f, 0.32f, s.N.y);
    float hatch = step(0.55f, fract((s.worldPosition.x + s.worldPosition.z) * 5.5f
                                    + s.worldPosition.y * 2.0f));

    float3 col = mix(paper, fill, 0.62f + 0.20f * (1.0f - s.ao));
    col = mix(col, ink, clamp(line * 0.42f + idx * 0.55f, 0.0f, 1.0f));
    col = mix(col, ink, steep * hatch * 0.42f);       // hachures down the fall line
    col *= 0.93f + 0.13f * mix(0.4f, 1.0f, s.NoL * s.shadow);
    return col;
}

// MARK: - Fragment

fragment float4 terrain_fragment(TerrainVertexOut in [[stage_in]],
                                 constant SKFrameUniforms &frame     [[buffer(0)]],
                                 constant SKTerrainUniforms &terrain [[buffer(1)]],
                                 constant SKLookUniforms &look       [[buffer(2)]],
                                 constant SKPointLight *lights       [[buffer(3)]],
                                 texture2d<float> sandTex            [[texture(0)]],
                                 texture2d<float> aoTex              [[texture(1)]],
                                 texture2d<float> skyLUT             [[texture(2)]],
                                 depth2d<float>   shadowMap          [[texture(3)]]) {
    constexpr sampler linearClamp(coord::normalized, filter::linear, address::clamp_to_edge);

    float2 wp = in.worldPosition.xz;
    float2 duv = (wp - frame.domain.xy) / frame.domain.zw;
    bool inside = duv.x > 0.0f && duv.x < 1.0f && duv.y > 0.0f && duv.y < 1.0f;

    // 1 · Material field. Outside the simulated square there is no sand depth,
    //     no packing and no film — only a moisture that rises as the ground
    //     approaches the waterline, so the skirt wets and dries with the tide.
    float4 S = inside
        ? sk_sandSmooth(sandTex, duv, frame.simResolution, frame.texel)
        : float4(0.0f, smoothstep(0.45f, -0.30f, in.worldPosition.y - frame.seaBase), 0.0f, 0.0f);

    float moisture = S.g, packing = S.b, film = S.a;
    float wet = clamp(moisture * 1.05f, 0.0f, 1.0f);
    float sheen = clamp(film * 4.5f, 0.0f, 1.0f);

    // 2 · Macro normal, rebuilt by central-differencing the smoothed field. No
    //     vertex normals exist anywhere in this renderer. This is the most
    //     expensive thing in the shader and the reason the surface reads as a
    //     continuum rather than as a mesh.
    float e = max(terrain.cell, 1e-3f);
    float hl = sk_groundYSmooth(sandTex, wp - float2(e, 0.0f), frame.domain, frame.simResolution, frame.texel);
    float hr = sk_groundYSmooth(sandTex, wp + float2(e, 0.0f), frame.domain, frame.simResolution, frame.texel);
    float hd = sk_groundYSmooth(sandTex, wp - float2(0.0f, e), frame.domain, frame.simResolution, frame.texel);
    float hu = sk_groundYSmooth(sandTex, wp + float2(0.0f, e), frame.domain, frame.simResolution, frame.texel);
    float3 Nmac = normalize(float3(hl - hr, 2.0f * e, hd - hu));

    // 3 · Wall projection. All the procedural texture is authored top-down, which
    //     smears the instant a moulded tower presents a vertical face. Shear the
    //     shading coordinate toward an along-the-wall / height frame rather than
    //     paying for a full triplanar blend.
    float vertical = smoothstep(0.72f, 0.18f, Nmac.y);
    float2 hz = normalize(float2(-Nmac.z, Nmac.x) + float2(1e-4f, 0.0f));
    float2 wallP = float2(dot(wp, hz), in.worldPosition.y * 1.15f + 13.7f);
    float2 sp = mix(wp, wallP, vertical);

    float3 V = normalize(frame.cameraPosition.xyz - in.worldPosition);
    float dist = length(frame.cameraPosition.xyz - in.worldPosition);

    // 4 · Distance fade. Procedural noise has no mip chain, so the highest octave
    //     is simply faded out before it can alias.
    float fw = fwidth(wp.x) + fwidth(wp.y) + 0.0001f;
    float dfade = exp(-fw * 34.0f);

    // 5 · Micro relief.
    float3 Ndet = sk_detailNormal(sp, max(wet, sheen), packing, dfade, look.waterTint.w);
    float3 Tt = normalize(cross(float3(0.0f, 0.0f, 1.0f), Nmac));
    float3 Bt = cross(Nmac, Tt);
    float3 N = normalize(Tt * Ndet.x + Nmac * Ndet.y + Bt * Ndet.z);
    N = normalize(mix(N, Nmac, sheen * 0.75f));       // standing water flattens grain

    // 6 · Albedo.
    float grain  = sk_fbm(sp * 3.1f, 3);
    float grain2 = sk_vnoise(sp * 17.0f);

    float3 dry = mix(float3(0.600f, 0.517f, 0.386f), float3(0.702f, 0.622f, 0.470f), grain);
    dry = mix(dry, float3(0.745f, 0.700f, 0.586f), smoothstep(0.62f, 0.95f, grain2) * 0.45f);

    // Heavy minerals: dark ribbons stretched across the beach and confined to the
    // swash band. Deliberately keyed off the interpolated vertex height rather
    // than the smoothed one, which gives the ribbons the slightly ragged edge a
    // clean sample does not have.
    float heavy = smoothstep(0.68f, 0.93f, sk_fbm(sp * float2(0.9f, 4.2f) + 31.0f, 3));
    float swash = smoothstep(0.9f, 0.05f, abs(in.worldPosition.y - frame.seaBase - 0.05f));
    dry = mix(dry, float3(0.235f, 0.205f, 0.198f), heavy * swash * 0.62f);

    dry = mix(dry, dry * float3(0.90f, 0.90f, 0.94f), packing * 0.30f);
    dry *= look.sandTint.rgb;

    float3 albedo = mix(dry, dry * float3(0.50f, 0.470f, 0.452f) * look.wetTint.rgb, wet * 0.92f);
    albedo = mix(albedo, albedo * 0.76f, sheen * 0.6f);

    // 7 · Occlusion.
    float ao = inside ? aoTex.sample(linearClamp, duv).r : 1.0f;
    ao = mix(1.0f, ao, 0.92f);
    float micAO = 0.86f + 0.14f * grain;

    // 8 · Direct light.
    float3 L = frame.sunDirection.xyz;
    float NoL = max(dot(N, L), 0.0f);
    float shadow = sk_shadowAt(shadowMap, frame.lightViewProjection,
                               in.worldPosition + N * 0.012f, NoL,
                               frame.shadowTexel, frame.shadowEnabled);

    // Roughness is the whole wet-sand tell. Dry sand at 0.96 is about as rough as
    // a diffuse surface gets; a standing film takes it to near-mirror.
    float rough = mix(look.sandTint.w, 0.40f, wet);
    rough = mix(rough, 0.13f, sheen);
    rough = mix(rough, rough * 0.82f, packing * 0.5f);

    float3 diff = albedo * (1.0f / SK_PI);
    float on = sk_orenNayar(N, V, L, rough);
    float3 direct = frame.sunColor.rgb * shadow * (diff * on);

    // Forward scatter — sand glows when you look toward the sun.
    float fwd = pow(max(dot(V, -L), 0.0f), 3.0f) * (1.0f - NoL * 0.6f);
    direct += frame.sunColor.rgb * shadow * albedo * fwd * 0.055f;

    float3 skyZenith = sk_ambientFrom(skyLUT, float3(0.0f, 1.0f, 0.0f));
    float3 amb = sk_ambientFrom(skyLUT, N) * albedo * ao * micAO * 1.38f;
    // The beach bounce: light coming back *up* off the flat sand into vertical
    // faces. Double-bounce colour, gated to walls only. This is most of what
    // lights the shaded side of a real sandcastle.
    amb += (frame.sunColor.rgb * 0.055f + skyZenith * 0.55f)
         * albedo * albedo * 0.62f * ao * vertical;

    // 9 · Specular. F0 is driven entirely by the water state, which is what makes
    //     wet sand read as wet rather than merely as darker sand.
    float NoV = max(dot(N, V), 1e-4f);
    float3 H = normalize(V + L);
    float NoH = max(dot(N, H), 0.0f);
    float VoH = max(dot(V, H), 0.0f);
    float3 f0 = mix(float3(0.020f), float3(0.043f), wet);
    f0 = mix(f0, float3(0.055f), sheen);
    float alpha = max(rough * rough, 0.0015f);
    float3 spec = sk_F_Schlick(f0, VoH) * sk_D_GGX(NoH, alpha)
                * sk_V_Smith(NoV, NoL, alpha) * NoL * look.wetTint.w;

    float3 col = direct + amb + frame.sunColor.rgb * shadow * spec;

    // Moonlight: pure Lambert, no shadow, no specular. The moon is not bright
    // enough to earn any of that, and the extra passes show up on a thermal graph.
    float NoLm = max(dot(N, frame.moonDirection.xyz), 0.0f);
    col += albedo * frame.moonColor.rgb * NoLm * 0.95f;

    // Environment reflection, only where a film is actually standing.
    if (sheen > 0.01f) {
        float3 R = reflect(-V, N);
        float3 env = sk_skySample(skyLUT, R, mix(3.0f, 0.4f, sheen));
        float fres = pow(1.0f - NoV, 5.0f);
        col += env * sheen * (0.030f + 0.30f * fres) * look.wetTint.w;
    }

    // 10 · Surface treatment. One branch, and the only one in the shader.
    SurfaceInputs si;
    si.albedo = albedo;
    si.N = N; si.V = V; si.L = L;
    si.worldPosition = in.worldPosition;
    si.NoL = NoL;
    si.shadow = shadow;
    si.ao = ao;
    si.vertical = vertical;
    si.wet = wet;
    si.sheen = sheen;
    si.packing = packing;
    si.night = frame.night;
    si.screenPosition = in.position.xy;

    float3 keyColor = frame.sunColor.rgb + frame.moonColor.rgb * 3.0f;

    switch (look.treatment) {
        case 1: col = sk_treatBanded(si, look, keyColor, skyZenith, frame.sunDirection.xyz); break;
        case 2: col = sk_treatSeparated(si, look); break;
        case 3: col = sk_treatContoured(si, look); break;
        default: break;                                  // continuous: keep the PBR result
    }

    // 11 · Mica. Only the continuous look earns this — a printed beach has no
    //      business glittering. Faded with distance because it is pure aliasing
    //      bait at any real screen density.
    if (look.treatment == 0) {
        float3 Rv = reflect(-V, Nmac);
        float glint = sk_vnoise(sp * 260.0f) * sk_vnoise(sp * 91.0f + 4.3f);
        glint = pow(clamp(glint, 0.0f, 1.0f), 7.0f);
        float align = pow(max(dot(Rv, L), 0.0f), 60.0f);
        col += frame.sunColor.rgb * glint * align * dfade * shadow * 3.2f * (1.0f - wet * 0.7f);
    }

    // 12 · Lanterns. Additive, every look — a lit lantern has to read as lit
    //      whether the beach is being shaded or printed.
    int lanternCount = int(terrain.lanternCount + 0.5f);
    for (int i = 0; i < lanternCount && i < 16; ++i) {
        float3 d = lights[i].position.xyz - in.worldPosition;
        float dd = dot(d, d);
        float radius = max(lights[i].position.w, 0.01f);
        if (dd > radius * radius) { continue; }
        float atten = 1.0f - sqrt(dd) / radius;
        atten *= atten;
        float lambert = max(dot(N, normalize(d)), 0.0f);
        col += albedo * lights[i].color.rgb * lights[i].color.w * atten * (0.25f + 0.75f * lambert);
    }

    // 13 · Standing water: caustics, and the cool cast of looking through it.
    float sl = sk_seaLevelAt(frame.seaBase, frame.time);
    float wdep = sl - in.worldPosition.y;
    if (wdep > 0.0f) {
        float cs = sk_caustic(wp * 1.35f + float2(0.0f, frame.time * 0.12f), frame.time);
        float atten = exp(-max(wdep, 0.0f) * 0.55f);
        col += frame.sunColor.rgb * shadow * cs * atten * 0.55f * (0.4f + 0.6f * NoL);
        col *= mix(float3(1.0f), float3(0.55f, 0.82f, 0.86f) * look.waterTint.rgb,
                   clamp(wdep * 0.9f, 0.0f, 0.75f));
    }

    // 14 · The cursor, projected onto the surface rather than drawn as an
    //      overlay, so it wraps over the shape of whatever you are about to
    //      change instead of floating above it.
    if (terrain.cursor.w > 0.5f) {
        float r = max(terrain.cursor.z, 0.02f);
        // Measured in the same metric the solver is about to use — L² draws a
        // circle, L∞ draws a square — so the ring is never a promise the brush
        // does not keep. Both metrics have unit gradient across an edge, so the
        // line width below needs no special case.
        float2 rel = wp - terrain.cursor.xy;
        float d = terrain.cursor.w > 1.5f ? max(abs(rel.x), abs(rel.y)) : length(rel);
        float ew = max(fw * 1.6f, r * 0.012f);
        float ring = 1.0f - smoothstep(ew, ew * 2.4f, abs(d - r));
        ring *= 1.0f - vertical * 0.75f;
        float inner = (1.0f - smoothstep(0.0f, r, d)) * 0.05f;
        col += float3(1.0f, 0.97f, 0.90f) * (ring * 0.55f + inner);
    }

    // 15 · The mould ghost, drawn from `sk_mouldShape` — the same call the solver
    //      stamps with, so what you line up is exactly what turns out.
    if (terrain.ghost.w > 0.5f) {
        float R = max(terrain.ghost.x, 0.02f);
        float2 rel = wp - terrain.ghostOrigin.xy;
        if (dot(rel, rel) < R * R * 4.0f) {
            float ro = terrain.ghost.y;
            float ca = cos(-ro), sa = sin(-ro);
            float2 q = float2(rel.x * ca - rel.y * sa, rel.x * sa + rel.y * ca) / R;
            float2 ms = sk_mouldShape(q, int(terrain.ghost.z + 0.5f), terrain.ghost2.x);
            float edge = ms.x * (1.0f - ms.x) * 4.0f;    // peaks on the coverage boundary
            col += float3(0.62f, 0.86f, 1.00f) * smoothstep(0.35f, 1.0f, edge) * 0.30f;
            col += float3(0.30f, 0.50f, 0.70f) * ms.x * 0.05f;
        }
    }

    // 16 · Aerial perspective.
    col = sk_applyFog(skyLUT, col, dist, -V, frame.fogK,
                      frame.sunDirection.xyz, frame.sunColor.rgb);

    // Alpha is a geometry mask for the post pass's ink edge detector.
    return float4(col, 1.0f);
}
