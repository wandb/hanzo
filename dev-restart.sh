#!/bin/bash
set -e

KEEP_MODELS=false
for arg in "$@"; do
    case "$arg" in
        --keep-models) KEEP_MODELS=true ;;
    esac
done

# Kill running instance
pkill -x Hanzo || true

# Clear downloaded models
if [ "$KEEP_MODELS" = false ]; then
    rm -rf "$HOME/Library/Application Support/com.hanzo.app/models"
fi

# Reset permissions
tccutil reset Microphone com.hanzo.app
tccutil reset Accessibility com.hanzo.app

# Rebuild and launch
bash dev-run.sh
