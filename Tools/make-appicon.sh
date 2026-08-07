#!/bin/bash
#
# make-appicon.sh — every app icon size, from two 1024×1024 masters.
#
#   Tools/make-appicon.sh
#   Tools/make-appicon.sh Artwork/sandkraft-icon-master.png Artwork/sandkraft-icon-ios-master.png
#
# Uses `sips` and `pngcrush`, both of which ship with macOS, so there is nothing
# to install.
#
# Two masters rather than one, because macOS and iOS want opposite things and
# the difference is not something a resize can invent — see docs/ARTWORK.md:
#
#   · the macOS master has the rounded-square shape drawn into the artwork and
#     transparent padding outside it. macOS does not mask icons.
#   · the iOS master is the same artwork square to the edges, background filled
#     right into the corners, with no alpha channel at all. iOS masks the icon
#     itself, and App Store Connect rejects an icon that has alpha.
#
# Eight files rather than eleven slots: an asset catalogue is happy to reference
# the same file from more than one slot, and 16@2x and 32@1x are both 32 pixels.
#
# Every output is written **non-interlaced**. An interlaced (Adam7) PNG is a
# valid PNG and every image viewer will show you one quite happily, which is
# exactly what makes it such a bad afternoon: the asset catalogue is the only
# thing that objects, and it objects by producing an app with no icon rather
# than by failing the build. `sips` always writes non-interlaced, so this is
# only a hazard for artwork that arrived some other way — a browser upload, a
# design tool's "export for web", an image generator. The check at the end of
# this script is here because that has already happened once.
#
set -euo pipefail

cd "$(dirname "$0")/.."

MAC_SRC="${1:-Artwork/sandkraft-icon-master.png}"
IOS_SRC="${2:-Artwork/sandkraft-icon-ios-master.png}"
DEST="Sandkraft/Resources/Assets.xcassets/AppIcon.appiconset"

for f in "$MAC_SRC" "$IOS_SRC"; do
    if [ ! -f "$f" ]; then
        echo "error: no such master: $f" >&2
        echo "usage: Tools/make-appicon.sh [mac-master.png] [ios-master.png]" >&2
        exit 1
    fi
    DIMS=$(sips -g pixelWidth -g pixelHeight "$f" | awk '/pixel/ {print $2}' | paste -sd'x' -)
    if [ "$DIMS" != "1024x1024" ]; then
        echo "warning: $f is ${DIMS}, not 1024x1024 — it will be resampled anyway." >&2
    fi
done

if [ ! -d "$DEST" ]; then
    echo "error: $DEST does not exist. Are you in the right repository?" >&2
    exit 1
fi

# macOS: seven sizes, alpha preserved.
for SIZE in 16 32 64 128 256 512 1024; do
    sips -s format png -z "$SIZE" "$SIZE" "$MAC_SRC" --out "$DEST/icon-${SIZE}.png" >/dev/null
    echo "  icon-${SIZE}.png"
done

# iOS: one size, and the alpha channel removed rather than merely unused.
# `-rem alpha` is the whole point of the pngcrush pass; a fully-opaque alpha
# channel is still an alpha channel as far as App Store Connect is concerned.
sips -s format png -z 1024 1024 "$IOS_SRC" --out "$DEST/icon-ios-1024.png" >/dev/null
pngcrush -q -ow -rem alpha "$DEST/icon-ios-1024.png" >/dev/null 2>&1 || {
    echo "warning: pngcrush not available — icon-ios-1024.png may still carry an" >&2
    echo "         alpha channel, which App Store Connect will reject." >&2
}
echo "  icon-ios-1024.png"

# Verify, in hex, straight out of the IHDR. Offset 25 is the colour type — 4 and
# 6 are the two that carry alpha — and offset 28 is the interlace method.
FAILED=0
for f in "$DEST"/icon-*.png; do
    NAME=$(basename "$f")
    CTYPE=$(od -An -tx1 -j 25 -N 1 "$f" | tr -d ' \n')
    INTERLACE=$(od -An -tx1 -j 28 -N 1 "$f" | tr -d ' \n')
    if [ "$INTERLACE" != "00" ]; then
        echo "error: $NAME is interlaced — the icon will not appear." >&2
        FAILED=1
    fi
    if [ "$NAME" = "icon-ios-1024.png" ] && { [ "$CTYPE" = "06" ] || [ "$CTYPE" = "04" ]; }; then
        echo "error: $NAME still has an alpha channel." >&2
        FAILED=1
    fi
done
[ "$FAILED" = "0" ] || exit 1

echo
echo "Wrote 8 files to $DEST — all non-interlaced, iOS opaque."
echo "Contents.json already points at them; build and the icon is in."
