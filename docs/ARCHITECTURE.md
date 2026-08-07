# Architecture

How a frame is built, and why it is built that way.

## The shape of it

```
SwiftUI  ─────────────────────────────────────────────────────────┐
  RootView → PlayView → MetalSceneView (UI/NSViewRepresentable)    │
                              │                                    │
                              ▼                                    │
                     SandkraftRenderView (MTKView)                 │
                       gestures ──────────────┐                    │
                              │               │                    │
                              ▼               ▼                    │
                      SceneCoordinator ◄── GameModel  ◄────────────┘
                       (MTKViewDelegate)     (@Observable)
                              │
                              ▼
                          Renderer ──► SandSimulation
                                   ├─► ParticleSystem
                                   └─► PropRenderer
```

`GameModel` owns all game state and knows nothing about Metal. `Renderer` owns
all GPU state and knows nothing about tides. `SceneCoordinator` is the only place
the two meet, once per frame, and it is deliberately the only file that has to
understand both vocabularies.

That boundary is not tidiness. It means the tide state machine, the scoring, the
pail arithmetic and the objective evaluation can all be reasoned about — and
tested — without a GPU.

## One frame

1. **Advance the model.** `GameModel.update(dt:)` moves the wave clock, the day
   clock and the tide phase, and leans the adornments.
2. **Assemble `FrameInput`.** A plain struct with no back-reference to the model,
   so the render loop cannot read game state halfway through encoding and get a
   value that is being mutated.
3. **Setup command buffer.** Brush uniforms, the mould stamp, undo capture, and
   any pending beach reset. This is a *separate* command buffer committed before
   the frame, so the solver step inside `Renderer.draw` sees them.
4. **Bake the sky** — only if the sun has moved more than 0.0035 radians or the
   cloud cover changed. At "Held" day speed this happens once per session.
5. **Step the solver.** `tier.substeps` iterations of `sim_step`, ping-ponging
   two RGBA32Float textures. Particle deposits are folded in on the first
   substep only.
6. **Ambient occlusion**, every fourth frame, at half resolution.
7. **Metrics.** A two-stage threadgroup reduction into a shared `MTLBuffer`, read
   on the completion handler.
8. **Pick.** A single-thread raymarch, if the input layer queued one.
9. **Shadow pass** — depth only, terrain and props. The skirt is not drawn.
10. **Opaque pass** — sky (depth writes off), terrain skirt (depth-biased), the
    inner terrain grid, then props.
11. **Copy** the colour buffer, so the water can sample what is behind it.
12. **Water pass** — composites by hand against the copy and writes opaque.
13. **Particles** — alpha blended, depth-tested, no depth write.
14. **Bloom** — bright pass then two separable blurs at half resolution.
15. **Composite** to the drawable: supersample resolve, depth of field, bloom,
    ink outline, tonemap, grade, vignette, grain.

## Decisions worth knowing

**Compute for the sand, raster for the picture.** The reference implementation
this project learned from ran the whole simulation through fragment shaders,
because WebGL2 has no compute. Metal does, and a compute kernel reading a texture
with `access::read` is both clearer and faster than a full-screen triangle
pretending to be one.

**No vertex buffers anywhere in the terrain.** `sk_gridUV` decodes `vertex_id`
into a cell and a corner. The mesh is displaced by a vertex texture fetch of the
live simulation field, so the geometry cannot lag the sand by a frame, and there
is nothing to upload.

**The vertex height and the fragment normal deliberately disagree.** The vertex
takes a *point* sample of the field; the fragment rebuilds the normal from a
*smoothed* resample. The geometry is faceted at sim-texel scale while the shading
is continuous, and that combination is what makes a heightfield read as sand
rather than as a mesh.

**Bilinear is done in the shader, not the sampler.** RGBA32Float is not linearly
filterable everywhere, and doing it by hand means the sampler never has to change
between the solver and the renderer — which removes a whole category of "why is
the water one texel off the sand" bug. The weights are smoothstepped, which gives
C¹ continuity and stops the reconstructed normal showing the texel grid.

**The hardpack is baked, not derived.** `sk_bedrock` is nine value-noise
evaluations and two sines describing ground that never moves, and almost
everything asked for it several times over: the terrain fragment differenced it
four times to rebuild the macro normal, the water fragment five, and the solver
nine times per texel per substep. It is now baked once into a 1024² RG32Float
table — hardpack in `.r`, the loose bed in `.g` — covering ±40 m, which is the
48 m simulated square plus every headland with room to spare.

Three things about that table are load-bearing:

- **The extent is a compile-time constant, not a uniform.** `SK_BEDROCK_EXTENT`
  lives in Common.h and never crosses into Swift. Nothing about the table varies
  per frame, so carrying it in `SKFrameUniforms` would widen a struct that has to
  keep its layout identical on both sides of the bridge in order to ship a
  number that cannot change. Swift supplies a square texture and nothing else.
- **The grid is vertex-centred.** Texel 0 sits exactly on −40 m and texel N−1
  exactly on +40 m, so a lookup on the border lands on a stored texel with a zero
  interpolation weight. Past ±40 m the shaders fall back to the analytic pair,
  and because both sides are the same function of the same position the join is
  under a micron — the float32 round trip of a value a few metres tall. Space the
  table the obvious way, texel centres at (i+0.5)/N, and the border falls halfway
  between two samples where the interpolation error is worst, turning a seam
  nobody can measure into a millimetre step you can watch the sun catch.
- **The weights are smoothstepped**, exactly as `sk_sandSmooth` smoothsteps its
  own, and for exactly the same reason: the terrain fragment rebuilds its macro
  normal by differencing this function, and plain bilinear — whose gradient is
  piecewise constant — would print the table's own texel grid onto the beach.

The solver's first invariant survives because the lookup is still a pure function
of world position: when a neighbouring cell runs its own step and looks back, it
rebuilds the identical world position and reads the identical bits, so the pair
transfer stays exactly antisymmetric. The initial state and the pristine profile
are baked from the table too, rather than from the analytic pair, so the beach is
never a hair out of step with the ground it stands on.

**Water composites by hand.** The fragment samples the already-rendered opaque
scene and returns the mix, rather than relying on a blend state. That costs one
full-resolution copy and buys refraction, correct depth absorption, and a swash
edge that is a soft coverage ramp instead of a hard discard.

**The shadow frustum is fitted to the beach, not the view.** Fitting to the view
frustum is textbook and would be wrong here: the map would resize and re-orient
every time the camera moved, and a texel grid crawling across a static sandcastle
is far more distracting than the resolution it buys. The playable area is 48 m
square and never moves, so the light matrix depends only on the sun.

**Fixed-point atomics for particle deposit.** Atomic float add is not available
on every GPU this ships to. A `2⁻²⁰ m³` quantum in a `device atomic_uint` buffer
is deterministic, portable, and resolved into the deposit texture by one kernel
per frame.

**Looks are data.** `SKLookUniforms` carries tints, band counts, screen angles,
grading and outline weight. The shaders branch exactly once, on `treatment`,
where the work genuinely differs — shaded, banded, ink-separated, or contoured.
Nine copies of the terrain shader would be nine places to fix every bug.

## The two invariants

Every change to `Sim.metal` has to preserve both:

1. **Every pair transfer is exactly antisymmetric.** Sand is conserved to the
   last grain. This is what makes the pail meter honest and what makes an
   undermined wall fall over without anybody scripting it.
2. **No cell gives away more than 1/9 of what it owns per substep.** Eight
   neighbours pull on the same cell in the same pass. Let each take an eighth and
   a cell under a breaking wave is asked for more sand than exists, goes
   negative, gets clamped at zero — and that clamp quietly *mints* sand. Left
   alone it grows dunes out of nothing during a storm.

## Quality tiers

| | Battery | Balanced | Detail | Maximum |
|---|---|---|---|---|
| Simulation | 256² | 384² | 512² | 640² |
| Terrain grid | 256 | 320 | 448 | 576 |
| Shadow map | 1024² | 1536² | 2048² | 2048² |
| Substeps | 2 | 3 | 4 | 5 |
| Particles | 8k | 20k | 48k | 96k |
| Render scale | 0.90× | 1.00× | 1.15× | 1.30× |
| Undo depth | 6 | 8 | 12 | 16 |

Chosen automatically from `MTLDevice.supportsFamily`, overridable in Settings.
Changing tier rebuilds the simulation, which lays down a fresh beach — the
settings screen says so rather than silently discarding the player's castle.

## Known gaps

Written down rather than left to be discovered:

- **Saving the beach is plumbed but not wired to the interface.**
  `SandSimulation.snapshotForSaving` and `.restore` both work, but there is no
  document type and no save UI. Note that `PlacedProp` is *not* `Codable` — an
  earlier version of this list said it was, and it is not; conforming it is part
  of the work, not a thing already done.
- **Props read one ground height per frame**, sampled near the cursor, so an
  adornment far from where you are working leans late. A per-prop height query
  needs either a batched pick kernel or a small CPU mirror of the field.
- **Rising mode has no end condition** beyond the water eventually covering
  everything.
- **The bedrock table stops at ±40 m.** Beyond it the skirt and the open sea go
  back to evaluating `sk_bedrock` per pixel. That is most of the distant beach,
  and widening the table to cover the full ±340 m skirt would cost far more
  memory than the picture out there is worth — but it does mean the far field is
  still the most expensive part of the frame.
