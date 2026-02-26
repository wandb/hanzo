#!/bin/bash
set -e

# Load local build env if present.
if [ -f ".env.build" ]; then
    set -a
    # shellcheck disable=SC1091
    source .env.build
    set +a
fi

# Hosted ASR build-time injection
HOSTED_ENDPOINT="${HANZO_HOSTED_SERVER_ENDPOINT:-https://grunt.zain.aaronbatilo.dev}"
HOSTED_PASSWORD="${HANZO_HOSTED_SERVER_PASSWORD:-}"

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

# Inject hosted server settings into the app bundle at build time.
plutil -replace HanzoHostedServerEndpoint -string "$HOSTED_ENDPOINT" "$APP_DIR/Info.plist"
plutil -replace HanzoHostedServerPassword -string "$HOSTED_PASSWORD" "$APP_DIR/Info.plist"

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
