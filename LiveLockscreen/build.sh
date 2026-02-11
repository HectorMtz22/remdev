#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$DIR/Sources/LiveLockscreenView.swift"
BUILD="$DIR/build"
SAVER="$BUILD/LiveLockscreen.saver"
CONTENTS="$SAVER/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
BINARY="$MACOS/LiveLockscreen"

rm -rf "$BUILD"
mkdir -p "$MACOS" "$RESOURCES"

# Copy Info.plist
cp "$DIR/Resources/Info.plist" "$CONTENTS/Info.plist"

# Step 1: compile to object file
echo "Compiling..."
swiftc \
    -parse-as-library \
    -c "$SRC" \
    -o "$BUILD/LiveLockscreenView.o" \
    -target arm64-apple-macos14.0 \
    -sdk "$(xcrun --show-sdk-path)"

# Step 2: link as MH_BUNDLE
echo "Linking..."
swiftc \
    "$BUILD/LiveLockscreenView.o" \
    -o "$BINARY" \
    -target arm64-apple-macos14.0 \
    -sdk "$(xcrun --show-sdk-path)" \
    -Xlinker -bundle \
    -framework ScreenSaver \
    -framework AVFoundation \
    -framework QuartzCore

# Verify binary type
FILE_TYPE=$(file "$BINARY")
if echo "$FILE_TYPE" | grep -q "Mach-O 64-bit bundle arm64"; then
    echo "OK: Binary is MH_BUNDLE"
else
    echo "ERROR: Unexpected binary type: $FILE_TYPE" >&2
    exit 1
fi

# Ad-hoc sign
codesign --force --deep --sign - "$SAVER"
echo "Build complete: $SAVER"
