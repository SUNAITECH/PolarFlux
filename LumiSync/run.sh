#!/bin/bash

APP_NAME="LumiSync"
SOURCES="Sources/*.swift"
OUT_DIR="$APP_NAME.app/Contents/MacOS"
RESOURCES_DIR="$APP_NAME.app/Contents/Resources"

# Clean
rm -rf "$APP_NAME.app"

# Create Structure
mkdir -p "$OUT_DIR"
mkdir -p "$RESOURCES_DIR"

# Copy Info.plist
cp Info.plist "$APP_NAME.app/Contents/"

# Compile
echo "Compiling..."
swiftc $SOURCES -o "$OUT_DIR/$APP_NAME" -target arm64-apple-macosx14.0

# Sign (Ad-hoc) to run locally
codesign --force --deep --sign - "$APP_NAME.app"

echo "Build complete: $APP_NAME.app"
echo "To run: open $APP_NAME.app"
