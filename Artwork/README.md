# Artwork masters

Source artwork, at the size it was drawn, from which everything else is derived.

- `sandkraft-icon-master.png` — 1024×1024, the app icon.
  Run `Tools/make-appicon.sh Artwork/sandkraft-icon-master.png` to regenerate
  the seven files in `Sandkraft/Resources/Assets.xcassets/AppIcon.appiconset/`.

Masters belong in the repository. See `docs/ARTWORK.md` for why, and for the
constraints macOS and iOS place on the icon — they want opposite things about
alpha and corner rounding, and it matters before a submission rather than
during one.
