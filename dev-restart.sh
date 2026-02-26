#!/bin/bash
set -e

# Kill running instance
pkill -x Hanzo || true

# Clear downloaded models
rm -rf "$HOME/Library/Application Support/com.hanzo.app/models"

# Reset permissions
tccutil reset Microphone com.hanzo.app
tccutil reset Accessibility com.hanzo.app

# Rebuild and launch
bash dev-run.sh
