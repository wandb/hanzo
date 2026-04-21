#!/bin/bash
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    cat <<'USAGE'
scripts/release-unsigned.sh — build unsigned Hanzo release artifacts into ./dist

Usage:
  ./scripts/release-unsigned.sh [FLAGS]

Behavior:
  Thin wrapper around scripts/release.sh that forces --unsigned. With no
  arguments it also sets --output-dir ./dist. Any additional flags are
  forwarded verbatim to scripts/release.sh (run it with --help for the
  full flag list).

Flags:
  -h, --help   Show this help
USAGE
    exit 0
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_SCRIPT="$ROOT_DIR/scripts/release.sh"

if [ ! -x "$RELEASE_SCRIPT" ]; then
    chmod +x "$RELEASE_SCRIPT"
fi

if [ "$#" -eq 0 ]; then
    exec "$RELEASE_SCRIPT" --unsigned --output-dir "$ROOT_DIR/dist"
fi

exec "$RELEASE_SCRIPT" --unsigned "$@"
