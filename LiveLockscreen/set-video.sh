#!/usr/bin/env bash
set -euo pipefail

DEST="$HOME/Library/Screen Savers/LiveLockscreen.saver"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <video.mp4>" >&2
    exit 1
fi

VIDEO="$1"
if [ ! -f "$VIDEO" ]; then
    echo "Error: File not found: $VIDEO" >&2
    exit 1
fi

if [ ! -d "$DEST" ]; then
    echo "Error: LiveLockscreen.saver not installed. Run install.sh first." >&2
    exit 1
fi

EXT="${VIDEO##*.}"

echo "Replacing video..."
rm -f "$DEST/Contents/Resources/video.mp4" "$DEST/Contents/Resources/video.mov"
cp "$VIDEO" "$DEST/Contents/Resources/video.$EXT"

# Re-sign
codesign --force --deep --sign - "$DEST"

echo "Done. Video updated."
