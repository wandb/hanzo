#!/bin/bash
set -e

# Build
swift build

# Create .app bundle
APP_DIR=".build/Hanzo.app/Contents"
mkdir -p "$APP_DIR/MacOS"
mkdir -p "$APP_DIR/Resources"
mkdir -p "$APP_DIR/Helpers"

# Copy executable
cp .build/debug/HanzoApp "$APP_DIR/MacOS/Hanzo"

# Copy Info.plist
cp HanzoCore/Info.plist "$APP_DIR/Info.plist"

# Copy resources bundle if it exists
if [ -d ".build/debug/HanzoCore_HanzoCore.bundle" ]; then
    cp -R ".build/debug/HanzoCore_HanzoCore.bundle" "$APP_DIR/Resources/"
fi

# Copy local ASR helper
cp LocalASRHelper/HanzoLocalASR "$APP_DIR/Helpers/HanzoLocalASR"
cp LocalASRHelper/HanzoLocalASR.py "$APP_DIR/Helpers/HanzoLocalASR.py"
chmod +x "$APP_DIR/Helpers/HanzoLocalASR"

echo "App bundle created at .build/Hanzo.app"
echo "Launching..."
open .build/Hanzo.app
