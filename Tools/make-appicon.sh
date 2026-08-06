#!/bin/bash
#
# make-appicon.sh — every app icon size, from one 1024×1024 master.
#
#   Tools/make-appicon.sh ~/Desktop/sandkraft-icon.png
#
# Uses `sips`, which ships with macOS, so there is nothing to install.
#
# Seven files rather than eleven: an asset catalogue is happy to reference the
# same file from more than one slot, and 16@2x and 32@1x are both 32 pixels.
# Generating them twice under different names would mean two files to keep in
# step for no benefit.
#
set -euo pipefail

SRC="${1:-}"

if [ -z "$SRC" ] || [ ! -f "$SRC" ]; then
    echo "usage: Tools/make-appicon.sh <path-to-1024x1024.png>" >&2
    exit 1
fi

# Run from the repository root whatever directory it was invoked from.
cd "$(dirname "$0")/.."
DEST="Sandkraft/Resources/Assets.xcassets/AppIcon.appiconset"

if [ ! -d "$DEST" ]; then
    echo "error: $DEST does not exist. Are you in the right repository?" >&2
    exit 1
fi

DIMS=$(sips -g pixelWidth -g pixelHeight "$SRC" | awk '/pixel/ {print $2}' | paste -sd'x' -)
if [ "$DIMS" != "1024x1024" ]; then
    echo "warning: master is ${DIMS}, not 1024x1024 — output will be resampled from it anyway." >&2
fi

for SIZE in 16 32 64 128 256 512 1024; do
    sips -s format png -z "$SIZE" "$SIZE" "$SRC" --out "$DEST/icon-${SIZE}.png" >/dev/null
    echo "  icon-${SIZE}.png"
done

echo
echo "Wrote 7 files to $DEST"
echo "Contents.json already points at them — build and the icon is in."
