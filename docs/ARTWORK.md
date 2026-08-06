# Artwork

Two images are referenced by the app and supplied by hand. This file is
deliberately **outside** `Assets.xcassets`: Xcode treats every file inside an
imageset or appiconset folder as a child of it, and a file the `Contents.json`
does not reference is reported as *"unassigned child"*. A README living next to
the artwork it describes is a tidy idea that makes the build complain, so the
documentation lives here instead.

## The app icon

`Contents.json` declares eleven slots and names **seven** files. A catalogue is
happy to reference one file from several slots, and 16@2x and 32@1x are both
thirty-two pixels — cutting eleven would mean four more files to keep in step
for no benefit.

Generate them from a single 1024×1024 master:

```bash
Tools/make-appicon.sh ~/Desktop/sandkraft-icon.png
```

That uses `sips`, which ships with macOS, so there is nothing to install. Build
and the icon is in.

### macOS and iOS want opposite things

This is the one place a single master cannot serve both, and it is worth
knowing before a submission rather than during one.

**macOS does not mask app icons.** The rounded-square shape has to be part of
the artwork. The current master has it, so macOS is correct as supplied.

Apple's own Mac icons sit inside roughly 80% of the canvas with transparent
padding around the squircle. A master that fills the canvas edge to edge reads
slightly larger than its neighbours in the Dock. That is a deliberate
difference rather than a mistake — but to sit flush with the system icons,
scale the artwork to about 820 px centred on a transparent 1024 canvas and
re-run the script.

**iOS masks the icon itself and rejects any alpha channel.** A master with
rounded corners and transparency outside them gives two problems:

- the corners are rounded twice, so the shape reads pinched
- App Store Connect refuses the upload outright

Xcode only warns about this, so an iOS build still runs today. Before any
submission it needs a second master: the same artwork, **square to the edges**,
the background filled right into the corners, alpha flattened. Point the
`platform: ios` slot at that file under its own name.

`make-appicon.sh` deliberately does not do this. Removing corners means
inventing the pixels behind them, and that should be a decision rather than
something a script does quietly.

## The Klinekraft mark

Drop **one** file in. Its colour does not matter.

Template rendering is switched on, so the artwork's own colours are discarded
and the mark is tinted to match the interface — light grey on the near-black
title screen. The dark-green original therefore works exactly as well as a
white version, and there is nothing to keep in sync.

1. Open `Assets.xcassets` in Xcode, select **KlinekraftLogo**
2. Drag the file onto the **Any Appearance** slot

A PDF is preferred: `preserves-vector-representation` is already set, so one
vector file covers every scale on every display. A PNG set at @1x/@2x/@3x works
too. The **Dark Appearance** slot can stay empty; it exists only for the case
below.

### Keeping the brand green instead

Change `template-rendering-intent` to `original` in that imageset's
`Contents.json` and remove the `.renderingMode(.template)` line from
`BrandMark.swift`. The Dark slot then starts to matter, because `#17543F` on a
near-black screen is invisible — put the light version there and the green one
in Any.

Until a file is present, `BrandMark` falls back to a typeset wordmark shaped
like the real mark. Nothing breaks; it simply is not your logo yet.
