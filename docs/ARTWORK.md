# Artwork

Two images are referenced by the app and supplied by hand. This file is
deliberately **outside** `Assets.xcassets`: Xcode treats every file inside an
imageset or appiconset folder as a child of it, and a file the `Contents.json`
does not reference is reported as *"unassigned child"*. A README living next to
the artwork it describes is a tidy idea that makes the build complain, so the
documentation lives here instead.

## The app icon

`Contents.json` declares eleven slots and names **eight** files. A catalogue is
happy to reference one file from several slots, and 16@2x and 32@1x are both
thirty-two pixels — cutting eleven would mean four more files to keep in step
for no benefit.

Generate them from the two 1024×1024 masters in `Artwork/`:

```bash
Tools/make-appicon.sh
```

That uses `sips` and `pngcrush`, both of which ship with macOS, so there is
nothing to install. Build and the icon is in.

**Commit both masters and all eight generated files.** They are small, they
change roughly never, and the alternative has already cost us the icon once: for
most of this project's life the PNGs existed only in one working folder, because
they are generated and generating them felt like a reason not to track them.
`Contents.json` was committed and the files it names were not, so a fresh clone
built an app with no icon — and *silently*, because a missing icon is not a build
error. Deleting that folder deleted the only copy of the artwork.

The script stays useful for regenerating the sizes after a master changes. It is
not a substitute for having the masters.

### Interlaced PNGs produce an app with no icon

This has cost us the icon a second time, in a way worth writing down because
nothing in the toolchain will tell you.

An **interlaced** (Adam7) PNG is a perfectly valid PNG. Preview opens one.
Finder thumbnails one. GitHub renders one. Xcode's asset-catalogue compiler is
the only thing in the pipeline that will not take one, and the way it declines
is to build you an app bundle with no icon in it — no error, no warning, a
green build, and a generic tile in the Dock and on the Home Screen.

Icon artwork that arrives by any route other than `sips` can be interlaced
without anyone having chosen it: browser uploads, "export for web" in a design
tool, and most image generators all default to it. Check before wondering:

```bash
# byte 28 of a PNG is the IHDR interlace method — 00 is what you want
od -An -tx1 -j 28 -N 1 Sandkraft/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png
```

`file` will also say so in words: *"PNG image data, 1024 x 1024, 8-bit/color
RGBA, interlaced"*. `make-appicon.sh` now checks every file it writes and exits
non-zero rather than leave one in the catalogue.

### macOS and iOS want opposite things

This is the one place a single master cannot serve both, which is why there are
two.

**macOS does not mask app icons.** The rounded-square shape has to be part of
the artwork, and `sandkraft-icon-master.png` has it — a squircle with
transparent corners.

Apple's own Mac icons sit inside roughly 80% of the canvas with transparent
padding around the squircle. Our master fills the canvas edge to edge, so it
reads slightly larger than its neighbours in the Dock. That is a deliberate
difference rather than a mistake — but to sit flush with the system icons,
scale the artwork to about 820 px centred on a transparent 1024 canvas and
re-run the script.

**iOS masks the icon itself and rejects any alpha channel.** Pointing the
`platform: ios` slot at the macOS master gives two problems:

- the corners are rounded twice, so the shape reads pinched
- App Store Connect refuses the upload outright

So there is a second master — `sandkraft-icon-ios-master.png`, the same artwork
**square to the edges** with the sand background (`#D5BB9C`) filled right into
the corners and the alpha channel removed rather than merely set to opaque. A
fully-opaque alpha channel is still an alpha channel as far as App Store Connect
is concerned, which is what the `pngcrush -rem alpha` pass in the script is for.

If the artwork ever changes, the iOS master is not something the script can
derive on its own for a design where the corners are not flat background:
removing corners means inventing the pixels behind them, and that should be a
decision rather than something a script does quietly.

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
