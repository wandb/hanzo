#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_SCRIPT="$ROOT_DIR/scripts/release.sh"

if [ ! -x "$RELEASE_SCRIPT" ]; then
    chmod +x "$RELEASE_SCRIPT"
fi

if [ "$#" -eq 0 ]; then
    exec "$RELEASE_SCRIPT" --unsigned --output-dir "$ROOT_DIR/dist"
fi

exec "$RELEASE_SCRIPT" --unsigned "$@"
