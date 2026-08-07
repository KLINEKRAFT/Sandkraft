// The solver.
//
// WebGL2 has no compute shaders, so this is fragment-shader ping-pong between
// two float textures — which is how the physics ran originally, before the
// native build moved it to Metal compute. The numerics did not change.
//
// Two invariants. Every edit to this file has to preserve both:
//
//   1. Every pair transfer is exactly antisymmetric. Sand is conserved to the
//      last grain. This is what makes an undermined wall fall over without
//      anybody scripting it.
//   2. No cell gives away more than 1/9 of what it owns per step. Eight
//      neighbours pull on the same cell in the same pass. Let each take an
//      eighth and a cell under a breaking wave is asked for more sand than
//      exists, goes negative, gets clamped at zero — and that clamp quietly
//      *mints* sand. Left alone it grows dunes out of nothing during a storm.

import { COMMON } from './common.js';

export const FULLSCREEN_VS = /* glsl */ `#version 300 es
precision highp float;
out vec2 vUV;
void main() {
    // Buffer-less fullscreen triangle. No vertex data, nothing to upload.
    vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
    vUV = p;
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}`;

/// Fill the hardpack table. Run once, at startup.
///
/// The bake takes its resolution as a uniform because it has nothing to sample —
/// and it is vertex-centred to match `bedrockPair`: floor(gl_FragCoord) / (N-1)
/// puts the first and last samples exactly on the borders rather than half a
/// texel inside them, which is the property the analytic fallback meets.
export const BEDROCK_BAKE_FS = /* glsl */ `#version 300 es
precision highp float;
${COMMON}
uniform float uResolution;
out vec4 outColor;
void main() {
    vec2 g = floor(gl_FragCoord.xy) / (uResolution - 1.0);
    vec2 p = mix(vec2(-BEDROCK_EXTENT), vec2(BEDROCK_EXTENT), g);
    outColor = vec4(bedrock(p), sandBed(p), 0.0, 1.0);
}`;

/// The shore as the tide left it.
export const SIM_INIT_FS = /* glsl */ `#version 300 es
precision highp float;
${COMMON}
uniform sampler2D uBedrock;
uniform float uResolution;
uniform float uSeaBase;
out vec4 outColor;
void main() {
    vec2 uv = gl_FragCoord.xy / uResolution;
    vec2 wp = uvToWorld(uv);

    vec2 bed = bedrockPair(uBedrock, wp);
    float depth = bed.y;

    // Wetness follows the *surface*, not the hardpack — the top of a deep bed
    // dries in the sun exactly like a shallow one does.
    float wet = smoothstep(0.55, -0.35, bed.x + depth - uSeaBase);
    float m = clamp(wet * 0.92 + 0.06 + 0.05 * vnoise(wp * 0.6), 0.0, 1.0);

    outColor = vec4(depth, m, 0.0, 0.0);
}`;

/// One step of the solver, with the brush folded in.
export const SIM_STEP_FS = /* glsl */ `#version 300 es
precision highp float;
${COMMON}

uniform sampler2D uField;
uniform sampler2D uBedrock;
uniform float uResolution;
uniform float uDt;
uniform float uTime;
uniform float uSeaBase;
uniform float uWaveAmp;
uniform float uErosion;

// Brush: xy = world position, z = radius, w = strength (0 when not drawing).
uniform vec4  uBrush;
uniform int   uTool;          // 0 none, 1 dig, 2 pour, 3 pack, 4 wet

out vec4 outColor;

/// How hard the sea is working this cell, right now.
float waveWork(vec2 wp, float groundHeight) {
    if (uErosion <= 0.0) { return 0.0; }

    float sl = seaLevelAt(uSeaBase, uTime);
    float still = sl - groundHeight;

    // The wave is depth-limited, so anything above still water is untouched —
    // and skipping it here is what keeps the whole solver cheap.
    if (still <= 0.0) { return 0.0; }

    float brk = 0.0;
    float wy = sl + waveHeight(wp, uTime, still, uWaveAmp, brk);
    float depth = wy - groundHeight;
    if (depth <= 0.0) { return 0.0; }

    float thin = exp(-max(depth, 0.0) * 1.25) * smoothstep(0.0, 0.045, depth);
    return clamp((0.30 + 1.85 * brk) * thin * uErosion, 0.0, 2.2);
}

const ivec2 OFF[8] = ivec2[8](
    ivec2( 1,  0), ivec2(-1,  0), ivec2( 0,  1), ivec2( 0, -1),
    ivec2( 1,  1), ivec2(-1,  1), ivec2( 1, -1), ivec2(-1, -1)
);

void main() {
    ivec2 gid = ivec2(gl_FragCoord.xy);
    int R = int(uResolution);

    vec2 uv = (vec2(gid) + 0.5) / uResolution;
    vec2 wp = uvToWorld(uv);

    vec4 S = texelFetch(uField, gid, 0);
    float h = S.r, m = S.g, c = S.b;

    float b0 = bedrockAt(uBedrock, wp);
    float H0 = b0 + h;
    float cellSize = DOMAIN.z / uResolution;

    float wa   = waveWork(wp, H0);
    float rep0 = repose(m, c);

    // Wet, packed sand resists being fluidised. Loose dry sand does not.
    float resist = 1.0 / (1.0 + 3.4 * c + 1.1 * m);
    rep0 *= (1.0 - 0.93 * clamp(wa * resist, 0.0, 1.0));

    float rate = 0.115 + 0.42 * clamp(wa, 0.0, 1.0);

    float dSand = 0.0, mAcc = 0.0, cAcc = 0.0, wAcc = 0.0;
    float mDiff = 0.0;

    for (int i = 0; i < 8; ++i) {
        ivec2 n = gid + OFF[i];
        if (n.x < 0 || n.y < 0 || n.x >= R || n.y >= R) { continue; }

        vec4 Sn = texelFetch(uField, n, 0);
        vec2 nwp = uvToWorld((vec2(n) + 0.5) / uResolution);

        float bn = bedrockAt(uBedrock, nwp);
        float Hn = bn + Sn.r;
        mDiff += (Sn.g - m);

        float dist = length(vec2(OFF[i])) * cellSize;

        float wan  = waveWork(nwp, Hn);
        float repn = repose(Sn.g, Sn.b);
        repn *= (1.0 - 0.93 * clamp(wan / (1.0 + 3.4 * Sn.b + 1.1 * Sn.g), 0.0, 1.0));
        float rep = 0.5 * (rep0 + repn);

        // Relaxation rate for this pair, with a hard ceiling. Under a breaking
        // wave this term reaches four times the stable limit without the clamp,
        // and the shoreline comes out as a row of alternating one-cell spikes —
        // a picket fence that is the solver oscillating, not the sea eroding.
        float rt = min(0.5 * (rate + 0.115 + 0.42 * clamp(wan, 0.0, 1.0)), 0.118);

        float dH  = H0 - Hn;
        float thr = rep * dist;
        float t = 0.0;
        if (dH > thr)       { t = -(dH - thr); }
        else if (dH < -thr) { t =  (-dH - thr); }
        t *= rt;

        // Symmetric clamp — the identical expression evaluated from either
        // side, so the pair transfer stays exactly antisymmetric. Invariant 1,
        // and the 0.111 is invariant 2.
        if (t < 0.0) { t = -min(-t, h * 0.111); }
        else         { t =  min( t, Sn.r * 0.111); }

        dSand += t;
        if (t > 0.0) { mAcc += Sn.g * t; cAcc += Sn.b * t; wAcc += t; }
    }

    float nh = max(h + dSand, 0.0);

    // Arriving sand brings its own moisture and packing with it.
    if (wAcc > 1e-6 && nh > 1e-6) {
        float f = clamp(wAcc / nh, 0.0, 1.0);
        m = mix(m, mAcc / wAcc, f);
        c = mix(c, cAcc / wAcc, f);
    }
    h = nh;

    // Moisture diffuses, the sun dries it, and the sea soaks it.
    m += mDiff * 0.045 * uDt * 12.0;
    m -= 0.020 * uDt * (1.0 - clamp(wa, 0.0, 1.0));
    m += wa * uDt * 1.6;

    // Being knocked about loosens packed sand.
    c -= wa * uDt * 0.55;

    // ------------------------------------------------------------- the brush
    if (uTool != 0 && uBrush.w > 0.0) {
        float d = length(wp - uBrush.xy);
        float w = 1.0 - smoothstep(uBrush.z * 0.35, uBrush.z, d);
        w *= uBrush.w;

        if (w > 0.0) {
            if (uTool == 1) {
                // Dig. Cannot take what is not there — the hardpack is the floor.
                h = max(h - w * 2.2 * uDt * 12.0, 0.0);
            } else if (uTool == 2) {
                // Pour, at the moisture of the pail.
                float add = w * 1.8 * uDt * 12.0;
                float total = h + add;
                if (total > 1e-6) { m = mix(m, 0.62, add / total); }
                h = total;
            } else if (uTool == 3) {
                // Pack, with the flat of a hand. This is what buys a vertical face.
                c = min(c + w * 2.4 * uDt * 12.0, 1.0);
            } else if (uTool == 4) {
                m = min(m + w * 1.9 * uDt * 12.0, 1.0);
            }
        }
    }

    outColor = vec4(h, clamp(m, 0.0, 1.0), clamp(c, 0.0, 1.0), 0.0);
}`;
