#!/usr/bin/env bash
set -euo pipefail

AERIALS_DIR="$HOME/Library/Application Support/com.apple.wallpaper/aerials/videos"
MANIFEST="$HOME/Library/Application Support/com.apple.wallpaper/aerials/manifest/entries.json"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <video.mov> [aerial-name]"
    echo ""
    echo "Replaces a system aerial wallpaper video with your own."
    echo ""
    echo "Downloaded aerials:"
    for f in "$AERIALS_DIR"/*.mov; do
        [ -f "$f" ] || continue
        UUID=$(basename "$f" .mov)
        NAME=$(python3 -c "
import json
with open('$MANIFEST') as f:
    data = json.load(f)
for a in data['assets']:
    if a['id'] == '$UUID':
        print(a.get('accessibilityLabel', 'Unknown'))
        break
" 2>/dev/null || echo "Unknown")
        SIZE=$(du -h "$f" | cut -f1)
        echo "  $NAME ($UUID) - $SIZE"
    done
    exit 1
fi

VIDEO="$1"
if [ ! -f "$VIDEO" ]; then
    echo "Error: File not found: $VIDEO" >&2
    exit 1
fi

# Find target aerial to replace
if [ $# -ge 2 ]; then
    # Search by name
    SEARCH="$2"
    TARGET_UUID=$(python3 -c "
import json
with open('$MANIFEST') as f:
    data = json.load(f)
for a in data['assets']:
    if '$SEARCH'.lower() in a.get('accessibilityLabel', '').lower():
        print(a['id'])
        break
" 2>/dev/null)
    if [ -z "$TARGET_UUID" ]; then
        echo "Error: No aerial found matching '$SEARCH'" >&2
        exit 1
    fi
else
    # Default: replace the largest downloaded aerial (likely the active one)
    TARGET_UUID=$(ls -S "$AERIALS_DIR"/*.mov 2>/dev/null | head -1 | sed 's|.*/||; s|\.mov$||')
fi

TARGET_FILE="$AERIALS_DIR/$TARGET_UUID.mov"

if [ ! -f "$TARGET_FILE" ]; then
    echo "Error: Aerial video not found: $TARGET_FILE" >&2
    echo "The aerial may not be downloaded yet. Select it in System Settings first." >&2
    exit 1
fi

# Get aerial name for display
AERIAL_NAME=$(python3 -c "
import json
with open('$MANIFEST') as f:
    data = json.load(f)
for a in data['assets']:
    if a['id'] == '$TARGET_UUID':
        print(a.get('accessibilityLabel', 'Unknown'))
        break
" 2>/dev/null || echo "Unknown")

echo "Replacing: $AERIAL_NAME ($TARGET_UUID)"
echo "With:      $VIDEO"

# Backup original
BACKUP="$AERIALS_DIR/$TARGET_UUID.mov.bak"
if [ ! -f "$BACKUP" ]; then
    echo "Backing up original to .bak..."
    cp "$TARGET_FILE" "$BACKUP"
fi

# Replace video
echo "Replacing video..."
cp "$VIDEO" "$TARGET_FILE"

# Restart wallpaper agent
echo "Restarting WallpaperAgent..."
killall WallpaperAgent 2>/dev/null || true

echo ""
echo "Done! Your video is now the '$AERIAL_NAME' wallpaper."
echo "If the wallpaper doesn't update, try toggling it in System Settings > Wallpaper."
echo ""
echo "To restore the original: $0 --restore $TARGET_UUID"
