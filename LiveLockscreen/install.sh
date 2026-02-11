#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD="$DIR/build"
SAVER="$BUILD/LiveLockscreen.saver"
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

# Build
echo "Building..."
"$DIR/build.sh"

# Embed video
echo "Embedding video..."
EXT="${VIDEO##*.}"
cp "$VIDEO" "$SAVER/Contents/Resources/video.$EXT"

# Re-sign (video changes bundle hash)
codesign --force --deep --sign - "$SAVER"

# Install
echo "Installing to ~/Library/Screen Savers/..."
rm -rf "$DEST"
cp -R "$SAVER" "$DEST"

echo "Done. Select 'Live Lockscreen' in System Settings → Screen Saver."
