//
//  Particles.metal
//  Sandkraft — the sand that is in the air
//
//  A fixed-capacity GPU particle pool. Spawning writes into a ring; updating
//  integrates, collides against the heightfield, and — this is the part that
//  matters — puts the sand *back*. A grain that lands atomically adds its volume
//  to the deposit accumulator, which the solver folds into the heightfield on the
//  next frame's first substep.
//
//  Without that feedback the particles are confetti: pretty, and a lie, because
//  the sand you threw would never arrive. With it, a shovelful genuinely leaves
//  one place and genuinely lands in another, and the conservation invariant the
//  whole simulation rests on survives contact with the effects layer.
//
//  The accumulator is fixed-point integers rather than atomic floats. Atomic
//  float add is not available everywhere we ship, and a deterministic 2⁻²⁰ m³
//  quantum is worth more here than the elegance of the float version.
//

#include "Render.h"

// MARK: - Spawn

/// Particle kinds, matching `ParticleKind` in Swift.
///   0 grain — carries sand, deposits on landing
///   1 spray — thrown by a breaker, evaporates
///   2 foam  — sits on the surface briefly
///   3 dust  — dry sand blown off a ridge, deposits almost nothing

kernel void particle_spawn(device SKParticle *particles      [[buffer(0)]],
                           device atomic_uint *cursor        [[buffer(1)]],
                           constant SKParticleUniforms &u    [[buffer(2)]],
                           constant float4 &kindPayload      [[buffer(3)]],
                           uint tid [[thread_position_in_grid]]) {
    uint requested = uint(max(u.spawnA.w, 0.0f));
    if (tid >= requested) { return; }

    // Ring allocation. Overwriting the oldest particle is exactly the right
    // failure mode for an effect: the pool never grows, and what you lose is
    // something that was already most of the way through its life.
    uint slot = atomic_fetch_add_explicit(cursor, 1u, memory_order_relaxed) % max(u.capacity, 1u);

    float3 h = sk_hash32(float2(float(tid) + float(u.seed) * 0.618f,
                                float(u.seed) * 0.317f + 1.7f));
    float3 h2 = sk_hash32(float2(float(u.seed) * 0.113f, float(tid) * 0.771f + 3.1f));

    float spread = u.spawnB.w;
    float3 jitter = (h * 2.0f - 1.0f) * spread;

    SKParticle p;
    p.position = float4(u.spawnA.xyz + jitter * float3(1.0f, 0.35f, 1.0f), 0.0f);
    p.velocity = float4(u.spawnB.xyz + (h2 * 2.0f - 1.0f) * float3(1.5f, 1.1f, 1.5f),
                        kindPayload.z * (0.6f + 0.8f * h.z));
    p.payload = float4(kindPayload.x * (0.5f + h2.x),   // volume carried, m³
                       kindPayload.y,                    // moisture
                       0.012f + 0.020f * h.y,            // radius, metres
                       kindPayload.w);                   // kind
    particles[slot] = p;
}

// MARK: - Update

kernel void particle_update(device SKParticle *particles       [[buffer(0)]],
                            device atomic_uint *deposit        [[buffer(1)]],
                            constant SKParticleUniforms &u     [[buffer(2)]],
                            texture2d<float> sandTex           [[texture(0)]],
                            texture2d<float> bedrockLUT        [[texture(1)]],
                            uint tid [[thread_position_in_grid]]) {
    if (tid >= u.capacity) { return; }

    SKParticle p = particles[tid];
    float life = p.velocity.w;
    if (life <= 0.0f) { return; }

    float age = p.position.w;
    if (age >= life) {
        particles[tid].velocity.w = 0.0f;
        return;
    }

    int kind = int(p.payload.w + 0.5f);
    float3 pos = p.position.xyz;
    float3 vel = p.velocity.xyz;

    // Integrate. Drag is per-kind: a grain of sand is ballistic, spray is not.
    float drag = (kind == 0) ? 0.06f : ((kind == 3) ? 1.35f : 0.85f);
    vel.y -= u.gravity * u.dt;
    vel -= vel * drag * u.dt;

    // A light onshore breeze, so dust and spray drift the way the flags do
    // rather than falling in a plumb line.
    if (kind >= 2) {
        float2 breeze = float2(0.35f, -0.18f) * (0.6f + 0.4f * sk_vnoise(pos.xz * 0.2f + u.time * 0.3f));
        vel.xz += breeze * u.dt * 1.4f;
    }

    pos += vel * u.dt;

    float ground = sk_groundYSmooth(sandTex, bedrockLUT, pos.xz, u.domain, u.simResolution, u.texel);
    float seaLevel = sk_seaLevelAt(u.seaBase, u.time);

    bool landed = pos.y <= ground;
    bool drowned = (kind != 2) && (pos.y <= seaLevel) && (seaLevel > ground);

    if (landed || drowned) {
        // Put the sand back. Only grains and dust carry any; spray and foam are
        // water and have nothing to deposit.
        if ((kind == 0 || kind == 3) && p.payload.x > 0.0f) {
            float2 uv = (pos.xz - u.domain.xy) / u.domain.zw;
            if (uv.x >= 0.0f && uv.x <= 1.0f && uv.y >= 0.0f && uv.y <= 1.0f) {
                uint2 texel = uint2(clamp(uv * u.simResolution, 0.0f, u.simResolution - 1.0f));
                uint index = (texel.y * uint(u.simResolution) + texel.x) * 2u;

                // Volume is stored as a depth increment for one cell, which is
                // what the solver wants: metres, not cubic metres.
                float cellArea = (u.domain.z / u.simResolution) * (u.domain.w / u.simResolution);
                float depth = p.payload.x / max(cellArea, 1e-6f);

                uint dFixed = uint(clamp(depth * u.depositFixedPointScale, 0.0f, 4.0e9f));
                uint mFixed = uint(clamp(depth * p.payload.y * u.depositFixedPointScale, 0.0f, 4.0e9f));
                atomic_fetch_add_explicit(&deposit[index],      dFixed, memory_order_relaxed);
                atomic_fetch_add_explicit(&deposit[index + 1u], mFixed, memory_order_relaxed);
            }
        }
        particles[tid].velocity.w = 0.0f;      // retire
        return;
    }

    p.position = float4(pos, age + u.dt);
    p.velocity = float4(vel, life);
    particles[tid] = p;
}

// MARK: - Draw

struct ParticleVertexOut {
    float4 position [[position]];
    float2 local;                 // −1…1 across the sprite
    float4 tint;
    float fade;
};

vertex ParticleVertexOut particle_vertex(uint vid                  [[vertex_id]],
                                         uint iid                  [[instance_id]],
                                         device const SKParticle *particles [[buffer(0)]],
                                         constant SKFrameUniforms &frame    [[buffer(1)]]) {
    SKParticle p = particles[iid];

    ParticleVertexOut out;
    if (p.velocity.w <= 0.0f) {
        // Retired. Collapse to a degenerate triangle off-screen rather than
        // paying for a compacted draw list every frame.
        out.position = float4(0.0f, 0.0f, -10.0f, 1.0f);
        out.local = float2(0.0f);
        out.tint = float4(0.0f);
        out.fade = 0.0f;
        return out;
    }

    const float2 corners[6] = {
        float2(-1.0f, -1.0f), float2( 1.0f, -1.0f), float2(-1.0f,  1.0f),
        float2( 1.0f, -1.0f), float2( 1.0f,  1.0f), float2(-1.0f,  1.0f)
    };
    float2 corner = corners[vid];

    // Camera basis straight out of the view matrix's rows. Cheaper and more
    // stable than reconstructing it from the camera position and a world up.
    // MSL matrices subscript to columns, so the world-space right vector is the
    // first *row* — element .x of each of the first three columns.
    float3 right = normalize(float3(frame.view[0].x, frame.view[1].x, frame.view[2].x));
    float3 up    = normalize(float3(frame.view[0].y, frame.view[1].y, frame.view[2].y));

    float t = clamp(p.position.w / max(p.velocity.w, 1e-3f), 0.0f, 1.0f);
    int kind = int(p.payload.w + 0.5f);

    // Spray and foam grow as they dissipate; grains do not.
    float grow = (kind == 0) ? 1.0f : (1.0f + t * 1.8f);
    float size = p.payload.z * grow;

    float3 world = p.position.xyz + (right * corner.x + up * corner.y) * size;

    float4 tint;
    switch (kind) {
        case 0:  tint = float4(0.68f, 0.60f, 0.46f, 1.00f); break;   // grain
        case 1:  tint = float4(0.92f, 0.96f, 0.98f, 0.85f); break;   // spray
        case 2:  tint = float4(0.98f, 0.99f, 0.99f, 0.70f); break;   // foam
        default: tint = float4(0.80f, 0.74f, 0.62f, 0.45f); break;   // dust
    }
    // Wet grains are darker, exactly as they are on the ground.
    tint.rgb *= mix(1.0f, 0.62f, (kind == 0) ? p.payload.y : 0.0f);

    out.position = frame.viewProjection * float4(world, 1.0f);
    out.local = corner;
    out.tint = tint;
    out.fade = (1.0f - t) * (kind == 0 ? 1.0f : smoothstep(1.0f, 0.55f, t));
    return out;
}

fragment float4 particle_fragment(ParticleVertexOut in [[stage_in]],
                                  constant SKFrameUniforms &frame [[buffer(0)]]) {
    float d = length(in.local);
    if (d > 1.0f) { discard_fragment(); }

    // Soft round sprite. No texture: a disc with a smooth edge is what a grain
    // of sand at this size actually resolves to, and an alpha texture would be
    // one more asset to ship for no visible gain.
    float alpha = (1.0f - smoothstep(0.55f, 1.0f, d)) * in.tint.a * in.fade;

    float3 lit = in.tint.rgb * (frame.sunColor.rgb * 0.85f + frame.moonColor.rgb * 0.6f + 0.28f);
    return float4(lit * alpha, alpha);
}
