#!/bin/bash
set -e

# Build
swift build

# Create .app bundle
APP_DIR=".build/Hanzo.app/Contents"
mkdir -p "$APP_DIR/MacOS"
mkdir -p "$APP_DIR/Resources"

# Copy executable
cp .build/debug/Hanzo "$APP_DIR/MacOS/Hanzo"

# Copy Info.plist
cp Hanzo/Info.plist "$APP_DIR/Info.plist"

# Copy resources bundle if it exists
if [ -d ".build/debug/Hanzo_Hanzo.bundle" ]; then
    cp -R ".build/debug/Hanzo_Hanzo.bundle" "$APP_DIR/Resources/"
fi

echo "App bundle created at .build/Hanzo.app"
echo "Launching..."
open .build/Hanzo.app
