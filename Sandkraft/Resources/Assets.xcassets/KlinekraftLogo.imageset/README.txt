Klinekraft mark
===============

Drop ONE file in. Its colour does not matter.

Template rendering is switched on, so the artwork's own colours are discarded and
the mark is tinted to match the interface — light grey on the near-black title
screen. That means the dark-green original works exactly as well as a white
version, and there is nothing to keep in sync.

  1. Open Assets.xcassets in Xcode, select KlinekraftLogo
  2. Drag the file onto the "Any Appearance" slot

A PDF is preferred: "preserves-vector-representation" is already set, so one
vector file covers every scale on every display. A PNG set at @1x/@2x/@3x works
too. The second (Dark Appearance) slot can stay empty — it exists only for the
case below.

To keep the brand green instead
-------------------------------
Change "template-rendering-intent" to "original" in Contents.json and remove the
`.renderingMode(.template)` line from BrandMark.swift. Then the Dark slot starts
to matter, because #17543F on a near-black screen is invisible — put the light
version there and the green one in Any.

Until a file is present, BrandMark falls back to a typeset wordmark shaped like
the real mark. Nothing breaks; it just is not your logo yet.
