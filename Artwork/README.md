# Artwork masters

Source artwork, at the size it was drawn, from which everything else is derived.

- `sandkraft-icon-master.png` — 1024×1024 RGBA, the macOS app icon. The rounded
  square is part of the artwork; the corners outside it are transparent.
- `sandkraft-icon-ios-master.png` — 1024×1024 RGB, the same artwork square to
  the edges with no alpha channel, because iOS masks the corners itself and
  App Store Connect rejects an icon that has alpha.

Run `Tools/make-appicon.sh` to regenerate the eight files in
`Sandkraft/Resources/Assets.xcassets/AppIcon.appiconset/` from both masters.
The script refuses to finish if anything it wrote came out interlaced.

Masters belong in the repository. See `docs/ARTWORK.md` for why, and for the
constraints macOS and iOS place on the icon — they want opposite things about
alpha and corner rounding, and it matters before a submission rather than
during one.
