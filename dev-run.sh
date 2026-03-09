#!/bin/bash
set -e

KEEP_MODELS=false
RESET_PERMISSIONS=false
for arg in "$@"; do
    case "$arg" in
        --keep-models) KEEP_MODELS=true ;;
        --reset-permissions) RESET_PERMISSIONS=true ;;
    esac
done

# Kill running instance
pkill -x Hanzo || true

# Clear downloaded models
if [ "$KEEP_MODELS" = false ]; then
    rm -rf "$HOME/Library/Application Support/com.hanzo.app/models"
fi

# Reset permissions (opt-in)
if [ "$RESET_PERMISSIONS" = true ]; then
    tccutil reset Microphone com.hanzo.app
    tccutil reset Accessibility com.hanzo.app
fi

# Hosted ASR build-time injection (env vars loaded by direnv via .envrc)
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
