//
//  Sim.metal
//  Sandkraft — the sand
//
//  A continuous heightfield solved on the GPU: eight-neighbour avalanche
//  relaxation against a *variable* angle of repose, capillary moisture, a
//  shallow-flow water film, and wave fluidisation.
//
//  Two invariants hold this whole thing together, and every change to this file
//  has to keep both:
//
//    1. Every transfer between two cells is exactly antisymmetric. Sand is
//       conserved to the last grain. That is what makes the pail meter honest,
//       and what makes an undermined wall fall over without anybody scripting
//       it — the sand goes somewhere, and the tower notices.
//
//    2. No cell may give away more than 1/9 of what it owns per substep. Eight
//       neighbours all pull on the same cell in the same pass; let each of them
//       take an eighth and a cell under a breaking wave gets asked for more sand
//       than exists, goes negative, gets clamped at zero — and that clamp
//       quietly *mints* sand. Left alone it grows dunes out of nothing during a
//       storm.
//
//  Ported from the reference WebGL2 implementation with the numerics preserved
//  exactly; see docs/ATTRIBUTION.md.
//

#include "Common.h"

// MARK: - The hardpack, baked
//
// Run once, when the simulation is built. Everything downstream — the solver,
// the renderer, the particles, the pick ray — reads the table this fills rather
// than re-deriving ground that has not moved since the world was made.

/// Fill the bedrock lookup. `.r` is `sk_bedrock`, `.g` is `sk_sandBed`.
///
/// The grid is vertex-centred and must stay that way: texel 0 sits exactly on
/// −SK_BEDROCK_EXTENT and texel N−1 exactly on +SK_BEDROCK_EXTENT, which is the
/// arithmetic `sk_bedrockPair` inverts to find its taps. The two mappings are
/// each other's inverse, and if one is changed the other has to move with it or
/// the whole beach shifts half a texel sideways.
kernel void bedrock_bake(texture2d<float, access::write> outLUT [[texture(0)]],
                         uint2 gid                              [[thread_position_in_grid]]) {
    const uint N = outLUT.get_width();
    if (gid.x >= N || gid.y >= outLUT.get_height()) { return; }

    // Written as a mix rather than as base-plus-stride so the two ends are
    // exact: at gid 0 the interpolant is 0 and at gid N−1 it is 1, which puts
    // the first and last samples on ±SK_BEDROCK_EXTENT to the bit. A stride of
    // 2E/(N−1) accumulated instead would drift a few microns off the far edge,
    // and the far edge is precisely where the analytic fallback has to meet it.
    float2 p = mix(float2(-SK_BEDROCK_EXTENT), float2(SK_BEDROCK_EXTENT),
                   float2(gid) / float(N - 1u));

    outLUT.write(float4(sk_bedrock(p), sk_sandBed(p), 0.0f, 1.0f), gid);
}

// MARK: - Initial state

kernel void sim_init(texture2d<float, access::write>  outSand    [[texture(0)]],
                     texture2d<float>                 bedrockLUT [[texture(1)]],
                     constant SKSimUniforms &u                   [[buffer(0)]],
                     uint2 gid                                   [[thread_position_in_grid]]) {
    if (gid.x >= outSand.get_width() || gid.y >= outSand.get_height()) { return; }

    float2 uv = (float2(gid) + 0.5f) * u.texel;
    float2 wp = sk_uvToWorld(uv, u.domain);

    // Read from the table rather than the analytic pair, even though this runs
    // once: the pristine profile, the solver and the renderer all read the
    // table, and an initial state built from a different arithmetic would start
    // the beach a hair out of step with the ground it is standing on.
    float2 bed  = sk_bedrockPair(bedrockLUT, wp);
    float b     = bed.x;
    float depth = bed.y;

    // Wetness follows the *surface*, not the hardpack — the top of a deep bed
    // dries in the sun exactly like a shallow one does.
    float wet = smoothstep(0.55f, -0.35f, b + depth - u.seaBase);
    float m = clamp(wet * 0.92f + 0.06f + 0.05f * sk_vnoise(wp * 0.6f), 0.0f, 1.0f);

    outSand.write(float4(depth, m, 0.0f, 0.0f), gid);
}

/// The shore as the tide left it, baked once. It never changes, and deriving it
/// per texel per frame cost more than the entire rest of the frame.
kernel void sim_pristine(texture2d<float, access::write> outPristine [[texture(0)]],
                         texture2d<float>                bedrockLUT  [[texture(1)]],
                         constant SKSimUniforms &u                   [[buffer(0)]],
                         uint2 gid                                   [[thread_position_in_grid]]) {
    if (gid.x >= outPristine.get_width() || gid.y >= outPristine.get_height()) { return; }
    float2 uv = (float2(gid) + 0.5f) * u.texel;
    float2 wp = sk_uvToWorld(uv, u.domain);
    float2 bed = sk_bedrockPair(bedrockLUT, wp);
    outPristine.write(float4(bed.x, bed.y, 0.0f, 1.0f), gid);
}

// MARK: - Helpers

inline float sk_segDist(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float t = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6f), 0.0f, 1.0f);
    return length(pa - ba * t);
}

/// The same swept stroke, measured in L∞ instead of L².
///
/// The isolines of max(|x|, |y|) are concentric squares, so this one metric
/// switch turns a round spade into a square one without a single tool having to
/// know about it — every mode below is written against the falloff `w`, not
/// against the distance. The square is world-axis aligned, so a wall swept along
/// X comes out with straight ends rather than rounded ones.
inline float sk_segDistSquare(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float t = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6f), 0.0f, 1.0f);
    float2 q = abs(pa - ba * t);
    return max(q.x, q.y);
}

/// How hard the sea is working this cell, right now.
inline float sk_waveWork(float2 wp, float groundY, constant SKSimUniforms &u) {
    if (u.erosion <= 0.0f) { return 0.0f; }

    float sl = sk_seaLevelAt(u.seaBase, u.time);
    float still = sl - groundY;

    // The wave is depth-limited, so anything above still water is untouched —
    // and skipping it here is what keeps the whole solver cheap.
    if (still <= 0.0f) { return 0.0f; }

    float brk = 0.0f;
    float wy = sl + sk_waveY(wp, u.time, still, u.waveAmplitude, brk);
    float depth = wy - groundY;
    if (depth <= 0.0f) { return 0.0f; }

    float thin = exp(-max(depth, 0.0f) * 1.25f) * smoothstep(0.0f, 0.045f, depth);
    return clamp((0.30f + 1.85f * brk) * thin * u.erosion, 0.0f, 2.2f);
}

constant int2 SK_OFF[8] = {
    int2( 1,  0), int2(-1,  0), int2( 0,  1), int2( 0, -1),
    int2( 1,  1), int2(-1,  1), int2( 1, -1), int2(-1, -1)
};

// MARK: - The step

kernel void sim_step(texture2d<float, access::read>  inSand     [[texture(0)]],
                     texture2d<float, access::write> outSand    [[texture(1)]],
                     texture2d<float, access::read>  inDeposit  [[texture(2)]],
                     texture2d<float>                bedrockLUT [[texture(3)]],
                     constant SKSimUniforms &u                  [[buffer(0)]],
                     uint2 gid                                  [[thread_position_in_grid]]) {
    const uint W = inSand.get_width();
    const uint H = inSand.get_height();
    if (gid.x >= W || gid.y >= H) { return; }

    float2 uv = (float2(gid) + 0.5f) * u.texel;
    float2 wp = sk_uvToWorld(uv, u.domain);

    float4 S = inSand.read(gid);
    float h = S.r, m = S.g, c = S.b, f = S.a;

    // Nine of these per texel per substep — the single largest consumer of
    // `sk_bedrock` in the whole project, and the reason the table exists.
    //
    // Invariant 1 survives the change because the lookup is still a pure
    // function of world position: when the neighbour runs its own step and looks
    // back at this cell, it rebuilds the identical `wp` from the identical
    // arithmetic and gets the identical bits out of the table. The pair transfer
    // stays exactly antisymmetric.
    float b0 = sk_bedrockAt(bedrockLUT, wp);
    float H0 = b0 + h;
    float cellSize = u.domain.z / u.simResolution;

    float wa   = sk_waveWork(wp, H0, u);
    float rep0 = sk_repose(m, c);

    // Wet, packed sand resists being fluidised. Loose dry sand does not.
    float resist = 1.0f / (1.0f + 3.4f * c + 1.1f * m);
    rep0 *= (1.0f - 0.93f * clamp(wa * resist, 0.0f, 1.0f));

    float rate = 0.115f + 0.42f * clamp(wa, 0.0f, 1.0f);

    float dSand = 0.0f, mAcc = 0.0f, cAcc = 0.0f, wAcc = 0.0f;
    float mDiff = 0.0f, sumH = 0.0f, nH = 0.0f;
    float dFilm = 0.0f;
    float surf = H0 + f;

    for (int i = 0; i < 8; ++i) {
        int2 n = int2(gid) + SK_OFF[i];
        if (n.x < 0 || n.y < 0 || n.x >= int(W) || n.y >= int(H)) { continue; }

        float4 Sn = inSand.read(uint2(n));
        float2 nuv = (float2(n) + 0.5f) * u.texel;
        float2 nwp = sk_uvToWorld(nuv, u.domain);

        float bn = sk_bedrockAt(bedrockLUT, nwp);
        float Hn = bn + Sn.r;
        sumH += Hn;
        nH   += 1.0f;
        mDiff += (Sn.g - m);

        float dist = length(float2(SK_OFF[i])) * cellSize;

        float wan  = sk_waveWork(nwp, Hn, u);
        float repn = sk_repose(Sn.g, Sn.b);
        repn *= (1.0f - 0.93f * clamp(wan / (1.0f + 3.4f * Sn.b + 1.1f * Sn.g), 0.0f, 1.0f));
        float rep = 0.5f * (rep0 + repn);

        // Relaxation rate for this pair, with a hard ceiling. Under a breaking
        // wave this term used to reach 0.535 — four times over the stable limit
        // — and the shoreline came out as a row of alternating one-cell spikes:
        // a picket fence that was the solver oscillating, not the sea eroding.
        // The sea still bites just as hard. It does it by dropping the angle of
        // repose, which is the physical lever, rather than by moving sand faster
        // than the scheme can stay stable.
        float rt = min(0.5f * (rate + 0.115f + 0.42f * clamp(wan, 0.0f, 1.0f)), 0.118f);

        float dH  = H0 - Hn;
        float thr = rep * dist;
        float t = 0.0f;
        if (dH > thr)       { t = -(dH - thr); }
        else if (dH < -thr) { t =  (-dH - thr); }
        t *= rt;

        // Symmetric clamp — the identical expression evaluated from either side,
        // so the pair transfer stays exactly antisymmetric. See invariant 2.
        if (t < 0.0f) { t = -min(-t, h * 0.111f); }
        else          { t =  min( t, Sn.r * 0.111f); }

        dSand += t;
        if (t > 0.0f) { mAcc += Sn.g * t; cAcc += Sn.b * t; wAcc += t; }

        // Water film — shallow flow over the surface. Four-neighbour only; the
        // diagonals add cost and change nothing you can see.
        if (i < 4) {
            float sn = Hn + Sn.a;
            float fl = (surf - sn) * 0.26f;
            fl = clamp(fl, -Sn.a * 0.24f, f * 0.24f);
            dFilm -= fl;
        }
    }

    float hOld = h;
    h = max(h + dSand, 0.0f);

    // Material that moved carries its own wetness, and arrives unpacked.
    if (wAcc > 1e-6f) {
        float denom = max(hOld + wAcc, 1e-4f);
        m = clamp((m * max(hOld, 0.0f) + mAcc)        / denom, 0.0f, 1.0f);
        c = clamp((c * max(hOld, 0.0f) + cAcc * 0.35f) / denom, 0.0f, 1.0f);
    }

    // Sand that moves arrives unpacked — but only in proportion to how much of
    // the column actually moved. Wiping a cell's packing the instant a single
    // grain shifts makes slumping self-feeding: it loosens, so it slumps more,
    // so it loosens more, and a tower that should have settled a centimetre runs
    // all the way down to a heap.
    c *= 1.0f - clamp(abs(dSand) / max(h, 0.08f), 0.0f, 1.0f) * 0.55f;

    // Capillary spread. Small, or a wet tower drains into the dry beach around
    // it in a couple of seconds.
    m = clamp(m + mDiff * 0.0022f, 0.0f, 1.0f);

    f = max(f + dFilm, 0.0f);

    // MARK: The sea's chemistry

    float sl = sk_seaLevelAt(u.seaBase, u.time);
    float table = smoothstep(0.40f, -0.30f, H0 - sl);
    m = max(m, table * 0.98f);

    if (wa > 0.0f) {
        m = max(m, clamp(wa * 1.4f, 0.0f, 1.0f));
        f = max(f, min(wa * 0.16f, 0.22f));
        c = max(c - u.dt * wa * 0.85f, 0.0f);
    }

    float infil = min(f, u.dt * 0.62f);
    f -= infil;
    m = clamp(m + infil * 2.4f / max(h, 0.06f), 0.0f, 1.0f);

    // Evaporation. Slow enough that a wall you wet at the start of a tide is
    // still standing at the end of it; fast enough that you have to keep the
    // bucket moving. Roughly a hundred seconds of full sun takes sand from
    // soaked to useless.
    float mWet = m;
    m -= u.dt * u.sunDrying * (0.0019f + 0.0044f * (1.0f - table));
    m = clamp(m, 0.0f, 1.0f);
    f = max(0.0f, f - u.dt * 0.085f);

    // Sand that dries *out of a wet state* sets. The bridges between the grains
    // go with the water, but the grains have already locked where you pressed
    // them and the surface crusts over — so a castle stiffens as it dries
    // instead of collapsing. Only sand that was genuinely wet earns this; dry
    // beach sand blown into a heap sets to nothing.
    c = clamp(c + max(mWet - m, 0.0f) * 1.6f * smoothstep(0.12f, 0.42f, mWet), 0.0f, 1.0f);

    // Packing barely fades on its own. It is undone by the sea, by digging and
    // by slumping, all of which take it away far faster than time does.
    c = max(0.0f, c - u.dt * (0.0004f + 0.042f * smoothstep(0.91f, 1.0f, m)));

    // MARK: Sand that has just landed
    //
    // Applied on the first substep only — depositScale is 0 for the rest, or the
    // same handful gets delivered two or three times a frame.

    if (u.depositScale > 0.0f) {
        float2 dp = inDeposit.read(gid).rg * u.depositScale;
        if (dp.r > 0.00002f) {
            h += dp.r;
            float arrM = dp.g / max(dp.r, 1e-6f);
            // A column carries one moisture, so blending arrivals against its
            // whole depth would dilute a bucket of wet sand into whatever dry
            // metre it happened to land on. Only the top of a pile behaves wet —
            // mix against a shallow active layer instead.
            float skin = min(h - dp.r, 0.35f);
            m = clamp((m * skin + arrM * dp.r) / max(skin + dp.r, 1e-4f), 0.0f, 1.0f);
            c *= 1.0f - min(dp.r * 8.0f, 0.88f);      // it arrives loose, every time
        }
    }

    // MARK: The tool

    int mode = int(u.brushB.z + 0.5f);
    if (mode > 0) {
        float r = u.brushA.z;
        float d = u.stamp3.w > 0.5f ? sk_segDistSquare(wp, u.brushA.xy, u.brushB.xy)
                                    : sk_segDist(wp, u.brushA.xy, u.brushB.xy);
        float w = 1.0f - smoothstep(r * 0.24f, r, d);
        if (w > 0.0015f) {
            float s = u.brushA.w * u.dt;
            float avgH = nH > 0.0f ? sumH / nH : H0;

            if (mode == 1) {                          // DIG
                float take = min(h, s * 1.35f * w);
                h -= take;
                c *= 1.0f - w * 0.55f;
            } else if (mode == 2) {                   // POUR
                h += s * 1.15f * w * u.brushB.w;
                c *= 1.0f - w * 0.72f;
                m = mix(m, m * 0.86f, w * 0.4f);
            } else if (mode == 3) {                   // PACK
                c = clamp(mix(c, 1.0f, clamp(w * s * 3.1f, 0.0f, 1.0f)), 0.0f, 1.0f);
                float settle = clamp(w * s * 2.2f, 0.0f, 0.9f);
                h = mix(h, max(avgH - b0, 0.0f), settle * 0.55f);
                h -= s * w * 0.035f * h;
            } else if (mode == 4) {                   // WET
                // The bucket takes you to damp, not to soup. You have to work at
                // ruining it, which is exactly how it goes on a real beach.
                m = clamp(mix(m, 0.86f, clamp(w * s * 2.4f, 0.0f, 1.0f)), 0.0f, 1.0f);
                f += s * w * 0.42f;
            } else if (mode == 5) {                   // CARVE
                // A blade, not a scoop. Everything you drag over comes down to
                // the level you first pressed on — press beside a wall, drag
                // through it, and you have a gateway rather than a dent. The cut
                // edge is packed hard, because a soft one just slumps back in
                // behind the spade.
                float wc = 1.0f - smoothstep(r * 0.74f, r, d);
                float floorY = clamp(u.brushB.w - b0, 0.0f, 6.0f);
                h -= clamp(h - floorY, 0.0f, s * 2.6f) * wc;
                // Only sand still standing above the cut gets pressed. Otherwise
                // a stroke run along flat ground at its own level packs the whole
                // beach, and Carve quietly becomes Pack with a narrower brush.
                float proud = smoothstep(0.02f, 0.16f, h - floorY);
                c = clamp(max(c, wc * proud * 0.92f), 0.0f, 1.0f);
            } else if (mode == 6) {                   // RAMPART
                float want = clamp(u.brushB.w - b0, 0.0f, 5.0f);
                float rise = clamp(want - h, 0.0f, s * 2.6f) * w * u.stamp2.z;
                h += rise;
                c = clamp(mix(c, 0.62f, w * 0.30f), 0.0f, 1.0f);
            } else if (mode == 7) {                   // DRIP
                float n  = sk_vnoise(wp * 11.0f + float2(u.time * 1.7f, u.time * -1.1f));
                float n2 = sk_vnoise(wp * 31.0f - u.time * 2.3f);
                float blob = w * w * (0.35f + 1.25f * n * n) * (0.6f + 0.8f * n2);
                h += s * 0.34f * blob * u.brushB.w;
                m = clamp(mix(m, 0.93f, w * 0.55f), 0.0f, 1.0f);
                c = clamp(mix(c, 0.50f, w * 0.30f), 0.0f, 1.0f);
            } else if (mode == 8) {                   // LEVEL
                float want = clamp(u.brushB.w - b0, 0.0f, 5.0f);
                h += clamp(want - h, -s * 2.0f, s * 2.0f) * w;
            } else if (mode == 9) {                   // SMOOTH
                h = mix(h, max(avgH - b0, 0.0f), clamp(w * s * 3.4f, 0.0f, 0.92f));
            } else if (mode == 11) {                  // SCOOP — filling the mould
                float take = min(h, s * 1.6f * w * w);
                h -= take;
                c *= 1.0f - w * 0.40f;
            }
        }
    }

    // MARK: Turning out the mould

    if (u.stamp.z > 0.0f && u.stamp2.w > 0.5f) {
        float2 rel = wp - u.stamp.xy;
        float R = u.stamp.z;
        if (dot(rel, rel) < R * R * 4.0f) {
            float ro = u.stamp3.y;
            float ca = cos(-ro), sa = sin(-ro);
            float2 q = float2(rel.x * ca - rel.y * sa, rel.x * sa + rel.y * ca) / R;
            int mid = int(u.stamp3.x + 0.5f);

            float2 ms = sk_mouldShape(q, mid, u.stamp2.x);
            // The same silhouette, dilated: sampling nearer the centre pushes the
            // coverage boundary outward. This is the sand that squeezes out under
            // the rim, and it follows the shape. A radial skirt instead would
            // leave a raised disc around everything, which reads as a plinth
            // rather than as sand.
            float2 msO = sk_mouldShape(q * 0.84f, mid, u.stamp2.x);

            float baseY = u.stamp2.y;
            float topY  = baseY + u.stamp.w * ms.y;
            // Outside the shape, measure from the ground that is actually here —
            // never from the height of the spot you happened to click.
            float collar = (b0 + h) + msO.x * 0.065f;
            float want   = mix(collar, topY, ms.x) - b0;

            if (want > h) {
                float k = clamp(ms.x * 1.6f, 0.0f, 1.0f);
                h = want;
                // What comes out is the sand that went in, pressed hard against
                // the inside of the mould on its way.
                m = mix(m, u.stamp3.z, k);
                c = max(c, 0.80f * k);
            }
        }
    }

    h = clamp(h, 0.0f, 6.0f);
    outSand.write(float4(h, m, c, min(f, 0.6f)), gid);
}

// MARK: - Ambient occlusion
//
// Horizon-scan AO over the heightfield. Eight directions, nine exponentially
// spaced samples each, with a per-texel rotation so the banding turns into
// noise that the half-resolution blur eats.

kernel void sim_ao(texture2d<float, access::sample> sandTex    [[texture(0)]],
                   texture2d<float, access::write>  outAO      [[texture(1)]],
                   texture2d<float>                 bedrockLUT [[texture(2)]],
                   constant SKSimUniforms &u                  [[buffer(0)]],
                   uint2 gid                                  [[thread_position_in_grid]]) {
    const uint W = outAO.get_width();
    const uint H = outAO.get_height();
    if (gid.x >= W || gid.y >= H) { return; }

    float2 uv = (float2(gid) + 0.5f) / float2(W, H);
    float2 wp = sk_uvToWorld(uv, u.domain);
    float h0 = sk_groundY(sandTex, bedrockLUT, wp, u.domain, u.simResolution, u.texel);

    float vis = 0.0f;
    float jitter = sk_hash12(float2(gid)) * SK_TAU;

    for (int d = 0; d < 8; ++d) {
        float a = (float(d) + 0.5f) / 8.0f * SK_TAU + jitter;
        float2 dir = float2(cos(a), sin(a));
        float maxS = 0.0f;
        float dist = 0.055f;
        for (int s = 0; s < 9; ++s) {
            float hq = sk_groundY(sandTex, bedrockLUT, wp + dir * dist,
                                  u.domain, u.simResolution, u.texel);
            maxS = max(maxS, (hq - h0) / dist);
            dist *= 1.52f;
        }
        vis += 1.0f - maxS / sqrt(1.0f + maxS * maxS);
    }
    vis /= 8.0f;

    outAO.write(float4(clamp(vis, 0.0f, 1.0f), 0.0f, 0.0f, 1.0f), gid);
}

// MARK: - Metrics
//
// A two-stage reduction into a shared buffer. The reference implementation used
// a mip pyramid and a pixel readback; on unified memory a threadgroup reduction
// straight into an MTLBuffer is both simpler and a frame quicker.
//
// Slot layout (8 floats per partial), sum except where noted:
//   0 total volume · 1 standing worth · 2 packed volume · 3 peak height (MAX)
//   4 wetted area  · 5 moat volume    · 6 Σ moisture    · 7 Σ packing

constexpr constant uint SK_METRIC_SLOTS = 8;
constexpr constant uint SK_METRIC_TG = 256;   // 16 × 16, and not negotiable:
                                              // the reduction below assumes it

kernel void metrics_partial(texture2d<float, access::read> sandTex     [[texture(0)]],
                            texture2d<float, access::read> pristineTex [[texture(1)]],
                            device float *partials                     [[buffer(0)]],
                            constant SKSimUniforms &u                  [[buffer(1)]],
                            constant float &highY                      [[buffer(2)]],
                            uint2 gid  [[thread_position_in_grid]],
                            uint  lid  [[thread_index_in_threadgroup]],
                            uint2 tgid [[threadgroup_position_in_grid]],
                            uint2 tgs  [[threadgroups_per_grid]]) {
    threadgroup float scratch[SK_METRIC_TG * SK_METRIC_SLOTS];

    float v[SK_METRIC_SLOTS];
    for (uint i = 0; i < SK_METRIC_SLOTS; ++i) { v[i] = 0.0f; }

    const uint W = sandTex.get_width();
    const uint H = sandTex.get_height();

    if (gid.x < W && gid.y < H) {
        float2 uv = (float2(gid) + 0.5f) * u.texel;
        float2 wp = sk_uvToWorld(uv, u.domain);

        float4 S  = sandTex.read(gid);
        float2 pr = pristineTex.read(gid).rg;

        float b   = pr.r;
        float gy  = b + S.r;
        float pad = sk_buildPad(wp);

        // Measure against the shore as the tide left it, not against sea level —
        // otherwise the dune behind you scores several thousand for existing.
        float pristine = b + pr.g;
        float built = step(pristine + 0.12f, gy);
        float above = max(gy - max(pristine, highY), 0.0f);

        v[0] = S.r;
        v[1] = above * (0.22f + 1.60f * S.b) * pad;
        v[2] = S.b * max(gy - pristine, 0.0f) * pad;
        v[3] = (gy - highY) * built * pad;
        v[4] = (S.a > 0.004f || S.g > 0.88f) ? 1.0f : 0.0f;
        v[5] = max(pristine - gy, 0.0f) * pad;
        v[6] = S.g;
        v[7] = S.b;
    }

    for (uint i = 0; i < SK_METRIC_SLOTS; ++i) {
        scratch[lid * SK_METRIC_SLOTS + i] = v[i];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint stride = SK_METRIC_TG / 2; stride > 0; stride >>= 1) {
        if (lid < stride) {
            uint a = lid * SK_METRIC_SLOTS;
            uint b = (lid + stride) * SK_METRIC_SLOTS;
            scratch[a + 0] += scratch[b + 0];
            scratch[a + 1] += scratch[b + 1];
            scratch[a + 2] += scratch[b + 2];
            scratch[a + 3]  = max(scratch[a + 3], scratch[b + 3]);
            scratch[a + 4] += scratch[b + 4];
            scratch[a + 5] += scratch[b + 5];
            scratch[a + 6] += scratch[b + 6];
            scratch[a + 7] += scratch[b + 7];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    if (lid == 0) {
        uint tg = tgid.y * tgs.x + tgid.x;
        for (uint i = 0; i < SK_METRIC_SLOTS; ++i) {
            partials[tg * SK_METRIC_SLOTS + i] = scratch[i];
        }
    }
}

kernel void metrics_final(device const float *partials [[buffer(0)]],
                          device SKMetrics *out        [[buffer(1)]],
                          constant uint &partialCount  [[buffer(2)]],
                          constant float &cellArea     [[buffer(3)]],
                          constant float &texelCount   [[buffer(4)]],
                          uint lid [[thread_index_in_threadgroup]]) {
    threadgroup float scratch[SK_METRIC_TG * SK_METRIC_SLOTS];

    float v[SK_METRIC_SLOTS];
    for (uint i = 0; i < SK_METRIC_SLOTS; ++i) { v[i] = 0.0f; }

    for (uint p = lid; p < partialCount; p += SK_METRIC_TG) {
        uint base = p * SK_METRIC_SLOTS;
        v[0] += partials[base + 0];
        v[1] += partials[base + 1];
        v[2] += partials[base + 2];
        v[3]  = max(v[3], partials[base + 3]);
        v[4] += partials[base + 4];
        v[5] += partials[base + 5];
        v[6] += partials[base + 6];
        v[7] += partials[base + 7];
    }

    for (uint i = 0; i < SK_METRIC_SLOTS; ++i) {
        scratch[lid * SK_METRIC_SLOTS + i] = v[i];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint stride = SK_METRIC_TG / 2; stride > 0; stride >>= 1) {
        if (lid < stride) {
            uint a = lid * SK_METRIC_SLOTS;
            uint b = (lid + stride) * SK_METRIC_SLOTS;
            scratch[a + 0] += scratch[b + 0];
            scratch[a + 1] += scratch[b + 1];
            scratch[a + 2] += scratch[b + 2];
            scratch[a + 3]  = max(scratch[a + 3], scratch[b + 3]);
            scratch[a + 4] += scratch[b + 4];
            scratch[a + 5] += scratch[b + 5];
            scratch[a + 6] += scratch[b + 6];
            scratch[a + 7] += scratch[b + 7];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    if (lid == 0) {
        SKMetrics mres;
        mres.totalVolume   = scratch[0] * cellArea;
        mres.standingWorth = scratch[1] * cellArea;
        mres.packedVolume  = scratch[2] * cellArea;
        mres.peakHeight    = scratch[3];
        mres.wettedArea    = scratch[4] * cellArea;
        mres.moatVolume    = scratch[5] * cellArea;
        mres.meanMoisture  = scratch[6] / max(texelCount, 1.0f);
        mres.meanPacking   = scratch[7] / max(texelCount, 1.0f);
        out[0] = mres;
    }
}

// MARK: - Ray pick
//
// One thread. Marches the ray against the heightfield, then bisects for a clean
// surface point. Runs on the GPU rather than the CPU because the heightfield
// lives on the GPU and reading 4 MB back per frame to answer "what is under the
// finger" would be an absurd trade.

kernel void sim_pick(texture2d<float, access::sample> sandTex    [[texture(0)]],
                     texture2d<float>                 bedrockLUT [[texture(1)]],
                     device SKPickResult *out                    [[buffer(0)]],
                     constant SKSimUniforms &u                  [[buffer(1)]],
                     constant float4 &rayOrigin                 [[buffer(2)]],
                     constant float4 &rayDirection              [[buffer(3)]],
                     uint tid [[thread_position_in_grid]]) {
    if (tid != 0) { return; }

    float3 ro = rayOrigin.xyz;
    float3 rd = normalize(rayDirection.xyz);

    float t = 0.02f, hitT = -1.0f, prevT = t;

    for (int i = 0; i < 190; ++i) {
        float3 p = ro + rd * t;
        float d = p.y - sk_groundY(sandTex, bedrockLUT, p.xz, u.domain, u.simResolution, u.texel);
        if (d <= 0.0f) { hitT = t; break; }
        prevT = t;
        t += max(0.045f, d * 0.62f);
        if (t > 260.0f) { break; }
    }

    SKPickResult r;
    if (hitT < 0.0f) {
        r.point = float4(0.0f);
        r.sand  = float4(0.0f);
        out[0] = r;
        return;
    }

    float lo = prevT, hi = hitT;
    for (int i = 0; i < 14; ++i) {
        float mid = 0.5f * (lo + hi);
        float3 p = ro + rd * mid;
        if (p.y - sk_groundY(sandTex, bedrockLUT, p.xz, u.domain, u.simResolution, u.texel) > 0.0f) {
            lo = mid;
        } else {
            hi = mid;
        }
    }

    float3 hp = ro + rd * (0.5f * (lo + hi));
    float2 uv = sk_worldToUV(hp.xz, u.domain);
    float4 s = float4(0.0f);
    if (uv.x >= 0.0f && uv.x <= 1.0f && uv.y >= 0.0f && uv.y <= 1.0f) {
        s = sk_sandBilinear(sandTex, uv, u.simResolution, u.texel);
    }

    r.point = float4(hp, 1.0f);
    r.sand  = float4(s.g, s.b, s.r, sk_bedrockAt(bedrockLUT, hp.xz));
    out[0] = r;
}

// MARK: - Deposit accumulator
//
// Particles land back in the heightfield through a fixed-point atomic buffer
// rather than an atomic-float texture, because atomic float is not universally
// available and correctness beats one kernel's worth of elegance. This pass
// unpacks the accumulator into the RG texture the solver reads, and clears it.

kernel void deposit_resolve(device atomic_uint *accumulator      [[buffer(0)]],
                            texture2d<float, access::write> out  [[texture(0)]],
                            constant float &scale                [[buffer(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
    const uint W = out.get_width();
    if (gid.x >= W || gid.y >= out.get_height()) { return; }

    uint index = (gid.y * W + gid.x) * 2;
    uint volumeFixed   = atomic_exchange_explicit(&accumulator[index],     0u, memory_order_relaxed);
    uint moistureFixed = atomic_exchange_explicit(&accumulator[index + 1], 0u, memory_order_relaxed);

    out.write(float4(float(volumeFixed) / scale, float(moistureFixed) / scale, 0.0f, 0.0f), gid);
}

kernel void deposit_clear(texture2d<float, access::write> out [[texture(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) { return; }
    out.write(float4(0.0f), gid);
}
