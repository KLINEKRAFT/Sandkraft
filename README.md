# Sandkraft

A sandcastle simulator for iPhone and Mac. One Swift codebase, one Metal
renderer, two native apps.

The whole of the sand is a GPU simulation: a continuous heightfield with
moisture, packing and a water film, relaxed against a *variable* angle of repose
eight neighbours at a time. Nothing about a collapse is scripted. The sea takes a
handful of sand from the bottom of your wall, the wall is then standing on a
slope steeper than sand can be, and it falls down — because that is what the
solver says has to happen.

**Dry sand cannot stand.** Everything else in the game follows from that one
sentence.

---

## What is here

```
Sandkraft.xcodeproj          one multiplatform target → iPhone, iPad and Mac
Sandkraft/
├── App/                     entry point, root routing, macOS menu bar
├── Engine/                  Metal context, simulation, renderer, camera, audio
├── Game/                    tools, moulds, tides, scoring, the game model
├── Input/                   the SwiftUI ⇄ Metal bridge and all gesture handling
├── Shaders/                 the GPU: 6 shader files and 3 shared headers
├── UI/                      the entire interface — design system, HUD, menus
└── Resources/               asset catalogue
docs/
├── ARCHITECTURE.md          how a frame is built, and why it is built that way
└── ATTRIBUTION.md           what was learned from prior art, and what was not taken
```

No third-party dependencies. No asset files — every icon is a vector path, every
sound is synthesised at launch, and the beach, the sky and the water are
functions.

## Building

Requires Xcode 16 or newer (the project uses file-system-synchronised groups, so
adding a file to a folder adds it to the target — there is nothing to keep in
step by hand).

```
open Sandkraft.xcodeproj
```

Pick **My Mac** or an iPhone destination and run. Deployment targets are
iOS 17.0 and macOS 14.0. The Mac build is a real Mac app, not Catalyst.

Set your own team in Signing & Capabilities before running on a device.

## Playing

| | iPhone / iPad | Mac |
|---|---|---|
| Use the tool | one finger | left button |
| Orbit | two fingers | right-drag, ⌥-drag, or ⇧-scroll |
| Zoom | pinch | pinch, or ⌘-scroll |
| Pan | *(not needed — see below)* | two-finger scroll |
| Rotate the mould | two-finger twist | rotate gesture |
| Choose a tool | tap the rail | `1`–`9`, `0` |
| Brush size | the slider | `[` and `]` |
| Undo / redo | the buttons | ⌘Z / ⇧⌘Z |
| Pause | the button | space |

There is no pan gesture on the phone, and that is deliberate: **the camera
orbits the last place you touched the sand.** Work somewhere new and the pivot
comes with you. That removes the hardest of the three camera verbs to teach on a
touchscreen, and removes the mode switch games usually reach for instead.

### The three families

The tool palette is grouped into three families, and the grouping is the single
most useful thing to know about this game:

- **Material** — Dig, Pour, Drip, Mould, Wall. Changes *how much* sand is here.
  Your pail goes up or down.
- **Surface** — Pack, Wet, Carve, Level. Changes what the sand *is like*. Adds
  none.
- **Place** — adornments. Worth nothing, and the reason anyone remembers a
  particular castle.

The difference between **Wet** and **Drip** is exactly this and nothing else.
Players who never work that out spend the whole campaign confused about why
their tower will not grow.

### Modes

- **Open Shore** — no tide, no clock, every tool, unlimited sand, and the light
  is yours to set.
- **Nine Tides** — nine build-then-flood rounds. What is still standing above the
  high-water line when the water turns is your score. The sun walks down the sky
  across the campaign; the ninth comes in the dark.
- **Rising** — one beach and a tide that never stops climbing.

## The interesting parts

**The pail is not a counter.** It is `baselineVolume − currentVolume`, read
straight off the GPU metric reduction. There is no bookkeeping to get out of step
with the simulation, because there is no bookkeeping: the sand in your pail is,
by definition, the sand that is no longer on the beach. The solver conserves
volume exactly, so the meter is exactly honest.

**The water you see is the water that erodes.** `sk_gerstner` is called by the
solver and by the water shader with the same depth and the same amplitude. Not a
matched pair — the same function, out of the same header. If they ever diverged,
waves would start biting sand they are not touching.

**Packing outlives water.** Wetting sand lets you build a steep face; packing is
what holds it up after the sun has taken the water back. Sand that dries *out of
a wet state* sets, so a castle stiffens as it dries instead of slumping. This is
one line in the solver and it is most of what makes building here feel like
building.

**Nine looks, one shader.** The looks are data, not shader variants. Everything
up to the surface treatment is shared; the treatment branches exactly once, on
whether light is being shaded, banded, separated into inks, or turned into
contour lines.

**The beach has no vertex buffer.** Positions are synthesised from `vertex_id`
and displaced by a vertex texture fetch of the simulation field, so the geometry
can never be a frame behind the sand.

## Accessibility

Every control is labelled and hinted. The moisture readout — the most
information-dense thing on screen — reports as words, not as a colour. Reduce
Motion softens the grain and the camera springs. Dynamic Type is respected
throughout the interface; the HUD is built from stacks that reflow rather than
fixed frames. Haptics and sound are independently switchable, and the game is
fully playable with either off.

## Performance

Four quality tiers, chosen automatically from the device and overridable in
Settings. The heaviest per-frame costs, in order: the terrain fragment shader's
four-tap normal reconstruction, the water pass, and the solver's substeps. The
first thing to cut is substeps; the ambient-occlusion pass already runs at a
quarter rate because the sand moves slowly compared to the eye, and the sky is
re-baked only when the sun has actually moved — at "Held" day speed the
atmosphere is free after the first frame.

## Licence

MIT. See `docs/ATTRIBUTION.md` for what this project learned from prior art and
what it deliberately did not take.
