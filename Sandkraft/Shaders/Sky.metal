//
//  Sky.metal
//  Sandkraft — the air
//
//  Two things live here, and keeping them separate is the whole design:
//
//    1. A small lat-long LUT of the *atmosphere only*, baked on demand whenever
//       the sun has moved enough to matter. Everything that needs to ask "what
//       colour is the sky in this direction" — ambient light, wet-sand
//       reflections, aerial perspective — reads this, cheaply, at whatever mip
//       suits its roughness.
//
//    2. A full-resolution direct pass that draws what you actually look at: the
//       LUT, plus the sun disc, the moon, the stars and the clouds. These are
//       high-frequency and would be destroyed by the LUT's resolution, so they
//       never go in it.
//
//  The alternative — baking clouds into the LUT — means either re-baking every
//  frame as they drift or watching the reflections lag the sky. Neither is
//  worth it.
//

#include "Render.h"

// MARK: - Atmosphere
//
// Single-scattering Rayleigh + Mie against a spherical shell. Two nested ray
// marches: along the view ray, and from each sample toward the sun. Coarse, but
// this is a 256×128 texture that a mip chain is about to blur anyway, and the
// thing it must get right is the *hue* progression from midday through sunset
// into night. It does.

constant float SK_PLANET_R      = 6360000.0f;
constant float SK_ATMOS_R       = 6420000.0f;
constant float3 SK_BETA_RAYLEIGH = float3(5.802e-6f, 13.558e-6f, 33.100e-6f);
constant float SK_BETA_MIE       = 3.996e-6f;
constant float SK_ABSORB_MIE     = 4.400e-6f;
constant float SK_H_RAYLEIGH     = 8000.0f;
constant float SK_H_MIE          = 1200.0f;

/// Distance from `origin` along `dir` to the outer shell. Negative when the ray
/// never reaches it, which cannot happen from inside but is cheap to guard.
inline float sk_atmosphereDistance(float3 origin, float3 dir, float radius) {
    float b = dot(origin, dir);
    float c = dot(origin, origin) - radius * radius;
    float d = b * b - c;
    if (d < 0.0f) { return -1.0f; }
    return -b + sqrt(d);
}

inline bool sk_hitsPlanet(float3 origin, float3 dir) {
    float b = dot(origin, dir);
    float c = dot(origin, origin) - SK_PLANET_R * SK_PLANET_R;
    float d = b * b - c;
    return d >= 0.0f && (-b - sqrt(d)) > 0.0f;
}

inline float sk_rayleighPhase(float mu) {
    return 3.0f / (16.0f * SK_PI) * (1.0f + mu * mu);
}

inline float sk_miePhase(float mu, float g) {
    float g2 = g * g;
    float denom = 1.0f + g2 - 2.0f * g * mu;
    return 3.0f / (8.0f * SK_PI) * ((1.0f - g2) * (1.0f + mu * mu))
         / ((2.0f + g2) * pow(max(denom, 1e-4f), 1.5f));
}

/// Scattered radiance arriving from `dir`, for an observer standing on the beach.
inline float3 sk_scatter(float3 dir, float3 sunDir, float turbidity, float rayleighScale, float mieScale) {
    const int VIEW_STEPS = 14;
    const int LIGHT_STEPS = 6;

    float3 origin = float3(0.0f, SK_PLANET_R + 12.0f, 0.0f);
    float far = sk_atmosphereDistance(origin, dir, SK_ATMOS_R);
    if (far <= 0.0f) { return float3(0.0f); }

    // Looking below the horizon, stop at the ground rather than marching through
    // the planet and coming out the far side glowing.
    if (sk_hitsPlanet(origin, dir)) {
        float b = dot(origin, dir);
        float c = dot(origin, origin) - SK_PLANET_R * SK_PLANET_R;
        far = min(far, -b - sqrt(max(b * b - c, 0.0f)));
    }

    float mu = dot(dir, sunDir);
    float pR = sk_rayleighPhase(mu);
    float pM = sk_miePhase(mu, 0.76f);

    float3 betaR = SK_BETA_RAYLEIGH * rayleighScale;
    float betaM = SK_BETA_MIE * mieScale * turbidity;
    float betaMExt = (SK_BETA_MIE * mieScale + SK_ABSORB_MIE) * turbidity;

    float ds = far / float(VIEW_STEPS);
    float3 accumR = float3(0.0f);
    float3 accumM = float3(0.0f);
    float odR = 0.0f, odM = 0.0f;

    for (int i = 0; i < VIEW_STEPS; ++i) {
        float3 p = origin + dir * (ds * (float(i) + 0.5f));
        float h = max(length(p) - SK_PLANET_R, 0.0f);
        float hr = exp(-h / SK_H_RAYLEIGH) * ds;
        float hm = exp(-h / SK_H_MIE) * ds;
        odR += hr;
        odM += hm;

        // Transmittance from this sample toward the sun.
        float lightFar = sk_atmosphereDistance(p, sunDir, SK_ATMOS_R);
        float odRL = 0.0f, odML = 0.0f;
        bool shadowed = sk_hitsPlanet(p, sunDir);
        if (!shadowed && lightFar > 0.0f) {
            float dls = lightFar / float(LIGHT_STEPS);
            for (int j = 0; j < LIGHT_STEPS; ++j) {
                float3 q = p + sunDir * (dls * (float(j) + 0.5f));
                float hq = max(length(q) - SK_PLANET_R, 0.0f);
                odRL += exp(-hq / SK_H_RAYLEIGH) * dls;
                odML += exp(-hq / SK_H_MIE) * dls;
            }
        } else {
            // Deep in the planet's shadow. Leave a floor rather than a hard zero
            // so twilight fades instead of switching off.
            odRL = 1e6f;
            odML = 1e6f;
        }

        float3 tau = betaR * (odR + odRL) + float3(betaMExt * (odM + odML));
        float3 attenuation = exp(-tau);
        accumR += hr * attenuation;
        accumM += hm * attenuation;
    }

    float3 col = (accumR * betaR * pR + accumM * betaM * pM) * 22.0f;

    // Night floor: airglow and integrated starlight, so a moonless sky is very
    // dark blue rather than pure black — pure black reads as a rendering bug.
    float night = smoothstep(0.08f, -0.16f, sunDir.y);
    col += float3(0.0016f, 0.0021f, 0.0042f) * night;

    return max(col, 0.0f);
}

// MARK: - Bake

kernel void sky_bake(texture2d<float, access::write> lut [[texture(0)]],
                     constant SKSkyUniforms &u           [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]]) {
    const uint W = lut.get_width(), H = lut.get_height();
    if (gid.x >= W || gid.y >= H) { return; }

    float2 uv = (float2(gid) + 0.5f) / float2(W, H);
    float3 dir = sk_skyUVToDir(uv);

    float3 col = sk_scatter(dir, u.sunDirection.xyz, u.turbidity, u.rayleighScale, u.mieScale);

    // The moon lights the sky too, weakly and with a cool cast. Cheap and worth
    // it: without it the ninth tide is genuinely too dark to play.
    float moonMu = max(dot(dir, u.moonDirection.xyz), 0.0f);
    col += float3(0.010f, 0.013f, 0.022f) * pow(moonMu, 3.0f)
         * u.moonDirection.w * smoothstep(-0.06f, 0.12f, u.moonDirection.y);

    // Below the horizon the LUT holds the ground half — used only by ambient
    // lookups, and only ever reached by normals that are pointing downward.
    float below = smoothstep(0.02f, -0.10f, dir.y);
    float3 groundBounce = u.groundAlbedo.rgb
        * sk_scatter(float3(dir.x, abs(dir.y) + 0.05f, dir.z), u.sunDirection.xyz,
                     u.turbidity, u.rayleighScale, u.mieScale) * 0.35f;
    col = mix(col, groundBounce, below);

    // A flat overcast cover, folded into the LUT rather than the direct pass:
    // ambient really does go grey and uniform under cloud, and reflections
    // should follow.
    if (u.cloudCover > 0.01f) {
        float3 grey = float3(sk_luma(col));
        col = mix(col, mix(grey, col, 0.35f) * mix(1.0f, 0.62f, u.cloudCover),
                  u.cloudCover * 0.55f);
    }

    lut.write(float4(col, 1.0f), gid);
}

// MARK: - Direct pass
//
// A full-screen triangle. The camera ray comes back out of the inverse
// view-projection, which is exact and needs no per-frame frustum-corner upload.

struct SkyVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex SkyVertexOut sky_vertex(uint vid [[vertex_id]]) {
    // One triangle covering the viewport. Two would introduce a diagonal seam in
    // any derivative-based effect that crosses it.
    float2 p = float2((vid << 1) & 2, vid & 2);
    SkyVertexOut out;
    out.uv = p;
    out.position = float4(p * float2(2.0f, -2.0f) + float2(-1.0f, 1.0f), 0.0f, 1.0f);
    return out;
}

/// Layered fbm clouds on a plane far overhead, with a little self-shadowing.
/// Not volumetric, and it does not need to be: at this scale a good silhouette
/// and a warm underside are the entire read.
inline float sk_cloudField(float2 p, float t, float cover) {
    float2 q = p * 0.18f + float2(t * 0.006f, t * 0.0025f);
    float base = sk_fbmG(q, 4);
    // Domain warp, which is what turns fbm porridge into something with edges.
    float2 warp = float2(sk_fbmG(q * 1.9f + 5.2f, 2), sk_fbmG(q * 1.9f - 3.7f, 2)) - 0.5f;
    float shape = sk_fbmG(q * 2.4f + warp * 1.6f, 4);
    float d = mix(base, shape, 0.65f);
    float threshold = mix(0.78f, 0.30f, clamp(cover, 0.0f, 1.0f));
    return smoothstep(threshold, threshold + 0.24f, d);
}

fragment float4 sky_fragment(SkyVertexOut in [[stage_in]],
                             constant SKFrameUniforms &frame [[buffer(0)]],
                             constant SKSkyUniforms &sky     [[buffer(1)]],
                             texture2d<float> lut            [[texture(0)]]) {
    // Reconstruct the world-space ray. Depth 1 is the far plane in Metal's 0…1
    // clip space.
    float2 ndc = in.uv * float2(2.0f, -2.0f) + float2(-1.0f, 1.0f);
    float4 far = frame.inverseViewProjection * float4(ndc, 1.0f, 1.0f);
    float3 dir = normalize(far.xyz / far.w - frame.cameraPosition.xyz);

    float3 col = sk_skySample(lut, dir, 0.0f);

    float3 sunDir = frame.sunDirection.xyz;
    float3 moonDir = frame.moonDirection.xyz;

    // Stars. Hashed cell grid over the sphere, faded out by daylight and by the
    // moon's own glow. Twinkle is a slow sine per star — a fast one reads as
    // dying pixels.
    float night = frame.night;
    if (night > 0.01f) {
        float2 su = sk_dirToSkyUV(dir) * float2(620.0f, 310.0f);
        float2 cell = floor(su);
        float2 f = fract(su);
        float3 h = sk_hash32(cell);
        if (h.z > 0.982f) {
            float2 centre = float2(0.3f + 0.4f * h.x, 0.3f + 0.4f * h.y);
            float d = length(f - centre);
            float mag = (h.z - 0.982f) / 0.018f;
            float twinkle = 0.72f + 0.28f * sin(frame.time * (0.7f + h.x * 1.6f) + h.y * 31.0f);
            float star = smoothstep(0.085f, 0.0f, d) * mag * twinkle;
            float3 tint = mix(float3(0.80f, 0.86f, 1.00f), float3(1.00f, 0.92f, 0.78f), h.x);
            col += tint * star * 0.55f * night * smoothstep(-0.02f, 0.10f, dir.y);
        }
    }

    // The moon: a disc with a soft limb and a phase terminator, plus a halo.
    float moonMu = dot(dir, moonDir);
    if (moonMu > 0.9985f) {
        float d = acos(clamp(moonMu, -1.0f, 1.0f));
        float r = 0.0045f;
        float disc = smoothstep(r, r * 0.72f, d);
        // Phase: how much of the visible face the sun lights. Approximated from
        // the angle between the sun and moon directions, which is exactly what
        // sets it.
        float phase = clamp(0.5f - 0.5f * dot(sunDir, moonDir), 0.0f, 1.0f);
        col += float3(0.92f, 0.93f, 0.88f) * disc * (0.25f + 1.35f * phase) * frame.moonColor.w;
    }
    col += float3(0.10f, 0.12f, 0.16f) * pow(max(moonMu, 0.0f), 220.0f) * frame.moonColor.w * 0.6f;

    // The sun: a disc with limb darkening, and a bloom skirt that the post pass
    // will pick up and spread.
    float sunMu = dot(dir, sunDir);
    float sunAngle = acos(clamp(sunMu, -1.0f, 1.0f));
    float sunR = 0.0047f;
    if (sunAngle < sunR * 3.0f) {
        float t = clamp(sunAngle / sunR, 0.0f, 1.0f);
        float limb = sqrt(max(1.0f - t * t, 0.0f));
        float disc = smoothstep(1.0f, 0.86f, t) * (0.35f + 0.65f * limb);
        col += frame.sunColor.rgb * disc * 55.0f;
    }
    col += frame.sunColor.rgb * pow(max(sunMu, 0.0f), 640.0f) * 6.0f;
    col += frame.sunColor.rgb * pow(max(sunMu, 0.0f), 22.0f) * 0.10f;

    // Clouds, on a plane 2 km up. Skipped entirely when looking down.
    if (dir.y > 0.008f && sky.cloudCover > 0.005f) {
        float2 planeP = dir.xz / dir.y * 2000.0f + float2(sky.cloudDrift, sky.cloudDrift * 0.4f);
        float cover = sk_cloudField(planeP * 0.001f, sky.time, sky.cloudCover);

        // Self-shadow by sampling the field again a step toward the sun.
        float2 toSun = normalize(sunDir.xz + float2(1e-4f, 0.0f)) * 60.0f;
        float lit = sk_cloudField((planeP + toSun) * 0.001f, sky.time, sky.cloudCover);
        float shade = clamp(1.0f - (lit - cover) * 1.4f, 0.35f, 1.0f);

        float3 cloudLit = frame.sunColor.rgb * 1.35f + float3(0.30f, 0.36f, 0.46f);
        float3 cloudDark = mix(float3(0.30f, 0.33f, 0.40f), frame.sunColor.rgb * 0.55f, 0.35f);
        float3 cloudCol = mix(cloudDark, cloudLit, shade);

        // Silver lining: the sun burning through a thin edge.
        float rim = smoothstep(0.35f, 0.05f, abs(cover - 0.5f)) * pow(max(sunMu, 0.0f), 6.0f);
        cloudCol += frame.sunColor.rgb * rim * 1.6f;

        // Fade the whole layer toward the horizon, where the plane approximation
        // stretches to infinity and stops being convincing.
        float horizonFade = smoothstep(0.008f, 0.10f, dir.y);
        col = mix(col, cloudCol, cover * horizonFade * 0.94f);
    }

    return float4(col, 1.0f);
}
