# Sandkraft — minimal web edition

A cartoon-styled sandcastle sandbox that runs in a phone browser. Dig, pour,
pack, wet, and watch the tide take it back.

This is not a port of the app in `Sandkraft/`. It is a much smaller thing that
shares the app's physics: the angle-of-repose curve, the eight-neighbour
avalanche relaxation and the beach profile are carried across from
`Sandkraft/Shaders/Common.h` with their constants intact, because those numbers
are the difference between sand that behaves and sand that does not.

## Running it

Any static server. There is no build step and no dependencies — the browser
loads ES modules directly.

```
cd web
python3 -m http.server 8000
# then open http://localhost:8000
```

## Deploying to Vercel

The whole thing is static, so there is nothing to configure beyond the
`vercel.json` already here.

```
cd web
npx vercel deploy --prod
```

Set the project root to `web/` if you deploy from the repository root instead.

Adding it to an iPhone Home Screen gives you a full-screen launcher with no
Safari chrome, which is most of the way to feeling like an app without being
one. It is still a web page: no App Store listing, no push, no haptics.

## Controls

**One finger works the sand, two fingers move the camera.** A sandbox where the
first thing a finger does is spin the world is a sandbox nobody digs in. On a
mouse: left-drag to work, right-drag or Shift-drag to orbit, wheel to zoom.

## How a frame is built

1. **Bake the hardpack** — once, at startup, into an RG float table over ±40 m.
   `bedrock()` is several noise evaluations describing ground that never moves,
   and the solver would otherwise ask for it nine times per texel per step.
2. **Step the solver** — three or four substeps of fragment-shader ping-pong
   between two float textures. WebGL2 has no compute shaders, so this is the
   original architecture rather than the app's Metal kernels.
3. **Draw sky, beach, sea** into an offscreen colour + depth target.
4. **Ink and composite** — silhouettes found in screen space from depth.

There are no vertex buffers anywhere. Positions are decoded from `gl_VertexID`
and the height comes from a vertex texture fetch of the live simulation, so the
geometry cannot lag the sand by a frame.

## What "cartoon" means here

Four decisions, not a filter over a realistic renderer:

- light is quantised into three bands rather than smoothly integrated;
- shadow is a **hue shift** toward violet rather than the same colour multiplied
  down — that single change is most of what separates a cartoon from an
  underexposed photograph;
- every silhouette on the playable square gets an ink line;
- the sea is two tones and a band of foam, with no specular at all.

## The two invariants

Inherited from the app, and every edit to `shaders/sim.js` has to preserve both:

1. **Every pair transfer is exactly antisymmetric.** Sand is conserved to the
   last grain. This is what makes an undermined wall fall over without anybody
   scripting it.
2. **No cell gives away more than 1/9 of what it owns per step.** Eight
   neighbours pull on the same cell in the same pass. Let each take an eighth
   and a cell under a breaking wave is asked for more sand than exists, goes
   negative, gets clamped at zero — and that clamp quietly *mints* sand.

## Requirements, honestly

- **WebGL2** and one of `EXT_color_buffer_float` or
  `EXT_color_buffer_half_float`. In practice: iOS 15+, and any current desktop
  browser. Without a float render target the solver cannot run, and the page
  says so rather than showing a black canvas.
- Full float is asked for first. Sand depth is a length in metres and half float
  runs out of mantissa around a millimetre, which shows up as drift in a tall
  wall.

## Known limits

Written down rather than left to be discovered:

- **Picking marches the *pristine* shore, not the live field.** The ray
  converges against the baked table — hardpack plus the bed the tide left — so a
  tower you built yourself is not in the height it iterates against, and the
  cursor drifts a little when you work on top of your own castle. Fixing it
  properly needs a GPU pick or a per-frame readback of the sand field.
- **Past ±40 m the beach falls back to evaluating the profile per pixel.** That
  is most of the distant frame, and it is the largest remaining cost.
- **No save, no score, no props, no particles.** The app has all four. This
  does not.
- The sea fills any depression below sea level whether or not it is connected to
  the water. On a real beach that is groundwater and looks right; in a deep
  moat cut inland it is a coincidence that happens to look right.
