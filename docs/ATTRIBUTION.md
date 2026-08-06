# Attribution

Sandkraft was written after studying **Tidewright** by winchxyz
(<https://github.com/winchxyz/tidewright>), an MIT-licensed WebGL2 sandcastle
simulator. This document records honestly what that study produced, because
"inspired by" is usually doing a lot of quiet work in a sentence like that.

## What was taken

**The physical model, and its tuning.** The angle-of-repose function, the
eight-neighbour avalanche relaxation, the capillary and evaporation terms, the
setting-on-drying rule, the depth-limited Gerstner breaking, and the analytic
beach profile are ports. The numeric constants are preserved deliberately and
exactly: they are the difference between sand that behaves and sand that does
not, and inventing new ones would have meant re-deriving a year of somebody
else's tuning badly. Tidewright is MIT-licensed, which permits this; the model
is also, in the end, a description of how wet sand works.

Where the reference carries a comment explaining *why* a constant is what it is
— the 1/9 transfer clamp, the 0.118 relaxation ceiling, the steepness budget
across the whole Gerstner sum — that reasoning is carried across too, in this
codebase's own words, because a magic number without its reason is a magic
number that gets "cleaned up" in six months.

## What was not taken

**None of the prose.** Tidewright's fiction — the drowned country, its
place names, the campaign's title, the name of its score, the codex entries and
the tide epigraphs — is original creative writing and belongs to its author. Every
word of text in Sandkraft was written for Sandkraft. The tide names, the Field
Notes, the grade lines and the tool descriptions are new.

**None of the interface.** This was the brief. Tidewright's HTML/CSS interface,
its icon set, its layout and its interaction model were not reproduced. Sandkraft's
interface was designed from scratch for Apple platforms: the three-family tool
taxonomy, the touch-follows-work camera, the moisture-as-fill-colour pail meter,
the projected cursor, the sheet-based pickers and every one of the 40 vector
glyphs are original.

**No source code.** Nothing was copied. This is a rewrite in a different
language, for a different GPU API, with a different architecture: Metal compute
kernels instead of fragment-shader ping-pong, a threadgroup reduction instead of
a mip pyramid, a data-driven look system instead of nine hand-written style
blocks, and an atomic fixed-point deposit buffer instead of a feedback texture.

## What was deliberately fixed

Reverse-engineering a codebase in detail turns up things that are not decisions.
Two are worth recording, since a faithful port would have carried them across:

1. **The micro-normal was fed an unclamped style index** where it expected a
   wetness in 0…1. For six of the nine looks this inverted and amplified the
   detail normal — an interesting result, but not a chosen one. Sandkraft clamps
   the input and drives detail strength from an explicit per-look parameter
   instead (`Render.h`, `sk_detailNormal`).

2. **The reference draws the skirt with a polygon depth offset** and relies on a
   0.85 m geometric sink to stop the coarse mesh sawing through the fine one.
   Both are kept, but the sink is now documented as the load-bearing one: the
   depth offset alone is not enough once the sea scours the shoreline.

## Licence

Tidewright is MIT-licensed. Sandkraft is MIT-licensed. The MIT notice below
covers this work; Tidewright's own notice covers the model it contributed.

```
Copyright (c) 2026 Sandkraft contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
