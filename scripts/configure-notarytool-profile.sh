#!/bin/bash
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    cat <<'USAGE'
scripts/configure-notarytool-profile.sh — store a notarytool keychain profile for Hanzo using an App Store Connect API key

Usage:
  ./scripts/configure-notarytool-profile.sh [FLAGS]

Flags:
  --profile <value>       Keychain profile name (default: hanzo-notary)
  --key-id <value>        App Store Connect API key ID
  --issuer <value>        App Store Connect API issuer ID
  --key-file <path>       Path to AuthKey_<KEY_ID>.p8
  --key-b64-file <path>   File containing base64-encoded AuthKey_<KEY_ID>.p8
  -h, --help              Show this help

Environment:
  HANZO_NOTARY_PROFILE        Default profile name
  NOTARY_API_KEY_ID           Default API key ID
  NOTARY_API_ISSUER_ID        Default issuer ID
  NOTARY_API_PRIVATE_KEY_B64  Base64-encoded API private key contents used when
                              --key-file/--key-b64-file are omitted
USAGE
    exit 0
fi

die() {
    echo "Error: $*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

usage() {
    cat <<'EOF'
Configure a local notarytool keychain profile for Hanzo using an App Store Connect API key.

Usage:
  ./scripts/configure-notarytool-profile.sh [options]

Options:
  --profile <value>       Keychain profile name (default: hanzo-notary)
  --key-id <value>        App Store Connect API key ID
  --issuer <value>        App Store Connect API issuer ID
  --key-file <path>       Path to AuthKey_<KEY_ID>.p8
  --key-b64-file <path>   File containing base64-encoded AuthKey_<KEY_ID>.p8
  --help                  Show this message

Environment:
  HANZO_NOTARY_PROFILE    Default profile name
  NOTARY_API_KEY_ID       Default API key ID
  NOTARY_API_ISSUER_ID    Default issuer ID
  NOTARY_API_PRIVATE_KEY_B64
                          Base64-encoded API private key contents used when
                          --key-file/--key-b64-file are omitted
EOF
}

PROFILE_NAME="${HANZO_NOTARY_PROFILE:-hanzo-notary}"
KEY_ID="${NOTARY_API_KEY_ID:-}"
ISSUER_ID="${NOTARY_API_ISSUER_ID:-}"
KEY_FILE=""
KEY_B64_FILE=""
TEMP_DIR=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --profile)
            [ "$#" -ge 2 ] || die "Missing value for --profile"
            PROFILE_NAME="$2"
            shift 2
            ;;
        --key-id)
            [ "$#" -ge 2 ] || die "Missing value for --key-id"
            KEY_ID="$2"
            shift 2
            ;;
        --issuer)
            [ "$#" -ge 2 ] || die "Missing value for --issuer"
            ISSUER_ID="$2"
            shift 2
            ;;
        --key-file)
            [ "$#" -ge 2 ] || die "Missing value for --key-file"
            KEY_FILE="$2"
            shift 2
            ;;
        --key-b64-file)
            [ "$#" -ge 2 ] || die "Missing value for --key-b64-file"
            KEY_B64_FILE="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

require_cmd xcrun
require_cmd base64

[ -n "$PROFILE_NAME" ] || die "Profile name cannot be empty"
[ -n "$KEY_ID" ] || die "Missing API key ID (--key-id or NOTARY_API_KEY_ID)"
[ -n "$ISSUER_ID" ] || die "Missing issuer ID (--issuer or NOTARY_API_ISSUER_ID)"

if [ -n "$KEY_FILE" ] && [ -n "$KEY_B64_FILE" ]; then
    die "Use only one of --key-file or --key-b64-file"
fi

cleanup() {
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT

if [ -n "$KEY_B64_FILE" ]; then
    [ -f "$KEY_B64_FILE" ] || die "Base64 key file not found: $KEY_B64_FILE"
    TEMP_DIR="$(mktemp -d /tmp/hanzo-notary.XXXXXX)"
    KEY_FILE="$TEMP_DIR/AuthKey_${KEY_ID}.p8"
    tr -d '\n\r' < "$KEY_B64_FILE" | base64 --decode > "$KEY_FILE"
elif [ -z "$KEY_FILE" ] && [ -n "${NOTARY_API_PRIVATE_KEY_B64:-}" ]; then
    TEMP_DIR="$(mktemp -d /tmp/hanzo-notary.XXXXXX)"
    KEY_FILE="$TEMP_DIR/AuthKey_${KEY_ID}.p8"
    printf '%s' "$NOTARY_API_PRIVATE_KEY_B64" | tr -d '\n\r' | base64 --decode > "$KEY_FILE"
fi

[ -n "$KEY_FILE" ] || die "Provide --key-file, --key-b64-file, or NOTARY_API_PRIVATE_KEY_B64"
[ -f "$KEY_FILE" ] || die "Key file not found: $KEY_FILE"

echo "Storing notary profile '$PROFILE_NAME' in the macOS keychain..."
xcrun notarytool store-credentials "$PROFILE_NAME" \
    --key "$KEY_FILE" \
    --key-id "$KEY_ID" \
    --issuer "$ISSUER_ID" \
    --validate

echo
echo "Configured keychain profile: $PROFILE_NAME"
echo "Use it locally with:"
echo "  ./scripts/release.sh --notary-profile $PROFILE_NAME"
echo
echo "Or export the default profile for future shells:"
echo "  export HANZO_NOTARY_PROFILE=$PROFILE_NAME"
