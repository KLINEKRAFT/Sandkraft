The app icon
============

Contents.json already declares every slot and points at seven filenames.
Nothing here is checked in yet — generate them from your 1024×1024 master:

    Tools/make-appicon.sh ~/Desktop/sandkraft-icon.png

That writes icon-16 / 32 / 64 / 128 / 256 / 512 / 1024.png into this folder
using `sips`, which ships with macOS. Build, and the icon is in.

Seven files, eleven slots: an asset catalogue is happy to reference one file
from several slots, and 16@2x and 32@1x are both thirty-two pixels.


macOS and iOS want different things
-----------------------------------

This matters, and it is the one place a single master cannot serve both.

**macOS** does not mask app icons. The rounded-square shape has to be part of
the artwork, which is exactly what the current master has. Correct as is.

Apple's own Mac icons sit inside about 80% of the canvas with transparent
padding around the squircle. This master fills the canvas edge to edge, so it
will read slightly larger than its neighbours in the Dock. Not wrong — a
deliberate difference is a style — but if you ever want it to sit flush with
the system icons, scale the artwork to ~820px centred on a transparent 1024
canvas and re-run the script.

**iOS** masks the icon itself, and rejects any alpha channel. A master with
rounded corners and transparency outside them gives you two problems:

  · the corners get rounded twice, so the shape reads pinched
  · App Store Connect refuses the upload outright

Xcode will warn about this on an iOS build but will still build and run, so it
is not urgent — but it must be fixed before any submission. The fix is a second
master: same artwork, **square to the edges**, background tan filled right into
the corners, alpha flattened. Then point the `platform: ios` slot at that file
instead of icon-1024.png and give it its own name.

This is not something the script can do for you. Removing corners means
inventing the pixels behind them, and it should be your call what goes there.
