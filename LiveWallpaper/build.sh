#!/bin/bash
set -e

APP_NAME="LiveWallpaper"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

cd "$(dirname "$0")"

# Clean previous build
rm -rf "$BUILD_DIR"

# Create .app bundle structure
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Build LiveLockscreen.saver and embed it
echo "Building LiveLockscreen..."
(cd ../LiveLockscreen && bash build.sh)
cp -R ../LiveLockscreen/build/LiveLockscreen.saver "$APP_BUNDLE/Contents/Resources/"

# Compile
echo "Building LiveWallpaper..."
swiftc Sources/*.swift \
    -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
    -framework Cocoa \
    -framework AVFoundation \
    -framework QuartzCore \
    -framework IOKit \
    -swift-version 5 \
    -O

# Copy Info.plist
cp Resources/Info.plist "$APP_BUNDLE/Contents/"

# Ad-hoc code sign
codesign --force --deep --sign - "$APP_BUNDLE"

echo ""
echo "Built: $APP_BUNDLE"
echo "Run:   open $APP_BUNDLE"
