Klinekraft mark
===============

Two empty slots, ready for artwork. Drag files onto them in Xcode's asset
catalogue editor, or drop them in this folder and add the filenames to the two
entries in Contents.json.

  Any Appearance   the dark-green mark, for light backgrounds
  Dark Appearance  the light/white mark

The title screen is near-black and the app forces dark mode, so the Dark slot is
the one that will actually be seen. Filling only Any will leave a dark-green mark
on a near-black screen.

PDF is preferred — "preserves-vector-representation" is already set, so a single
vector file covers every scale on every display. A PNG set at @1x/@2x/@3x works
too.

Template rendering is on, so the artwork is tinted by the view's foreground
colour and its own colours are ignored. If the mark should keep its brand green,
change "template-rendering-intent" to "original" here and drop the
`.renderingMode(.template)` line in BrandMark.swift.

Until a file is present, BrandMark falls back to a typeset wordmark. Nothing
breaks; it just is not your logo yet.
