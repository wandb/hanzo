#!/bin/bash
set -euo pipefail

die() {
    echo "Error: $*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

escape_regex() {
    printf '%s' "$1" | sed -e 's/[][(){}.^$+*?|\\]/\\&/g'
}

plist_escape_string() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s' "$value"
}

reset_tcc_permission() {
    local service="$1"
    local bundle_identifier="$2"
    local output=""

    if ! output="$(tccutil reset "$service" "$bundle_identifier" 2>&1)"; then
        if [[ "$output" == *"No such bundle identifier"* ]]; then
            echo "No existing $service permission record for $bundle_identifier; continuing."
            return 0
        fi

        echo "$output" >&2
        return 1
    fi
}

RESET_MODELS=false
RESET_PERMISSIONS=false
RESET_SETTINGS=false
NO_LAUNCH=false
SIGNED_EXECUTABLE_TEMP=""
DEV_BUNDLE_IDENTIFIER_DEFAULT="com.hanzo.app.dev"
APP_BUNDLE_IDENTIFIER="${HANZO_DEV_BUNDLE_IDENTIFIER:-$DEV_BUNDLE_IDENTIFIER_DEFAULT}"
APP_DISPLAY_NAME="${HANZO_DEV_APP_NAME:-Hanzo Dev}"
APP_ROOT="${HANZO_DEV_APP_ROOT:-$HOME/.local/share/hanzo/Hanzo Dev.app}"
APP_DIR="$APP_ROOT/Contents"
APP_EXECUTABLE_TARGET="$APP_DIR/MacOS/Hanzo"
APP_LLAMA_SERVER_TARGET="$APP_DIR/MacOS/llama-runtime/llama-server"
DEV_APP_ICON_SOURCE="assets/icons/HanzoDev.icns"
APP_EXECUTABLE_REGEX="$(escape_regex "$APP_EXECUTABLE_TARGET")"
APP_LLAMA_SERVER_REGEX="$(escape_regex "$APP_LLAMA_SERVER_TARGET")"
APP_DISPLAY_NAME_PLIST="$(plist_escape_string "$APP_DISPLAY_NAME")"

cleanup_signed_executable_temp() {
    if [ -n "${SIGNED_EXECUTABLE_TEMP:-}" ] && [ -f "$SIGNED_EXECUTABLE_TEMP" ]; then
        rm -f "$SIGNED_EXECUTABLE_TEMP"
    fi
}

trap cleanup_signed_executable_temp EXIT

for arg in "$@"; do
    case "$arg" in
        --reset-models) RESET_MODELS=true ;;
        --reset-permissions) RESET_PERMISSIONS=true ;;
        --reset-settings) RESET_SETTINGS=true ;;
        --no-launch) NO_LAUNCH=true ;;
        *) die "Unknown argument: $arg" ;;
    esac
done

# Kill running instance
require_cmd pkill
pkill -f "^${APP_EXECUTABLE_REGEX}$" || true
# Also kill orphaned bundled llama runtimes from previous app exits.
pkill -f "^${APP_LLAMA_SERVER_REGEX}$" || true
pkill -f "^${APP_LLAMA_SERVER_REGEX} " || true

# Reset app UserDefaults (opt-in)
if [ "$RESET_SETTINGS" = true ]; then
    require_cmd defaults
    defaults delete "$APP_BUNDLE_IDENTIFIER" >/dev/null 2>&1 || true
fi

# Clear downloaded models (opt-in): Whisper + local rewrite LLM model.
if [ "$RESET_MODELS" = true ]; then
    MODELS_ROOT="$HOME/Library/Application Support/$APP_BUNDLE_IDENTIFIER/models"
    LEGACY_LLM_ROOT="$HOME/Library/Application Support/$APP_BUNDLE_IDENTIFIER/llm"
    rm -rf "$MODELS_ROOT"
    rm -rf "$LEGACY_LLM_ROOT"
fi

# Reset permissions (opt-in)
if [ "$RESET_PERMISSIONS" = true ]; then
    require_cmd tccutil
    reset_tcc_permission Microphone "$APP_BUNDLE_IDENTIFIER"
    reset_tcc_permission Accessibility "$APP_BUNDLE_IDENTIFIER"
fi

LLAMA_RELEASE_TAG_DEFAULT="b8355"
LLAMA_RELEASE_SHA256_DEFAULT="43e831c4ccf785dfd4c4197e00fbba309823d4088a5c40def5d4d934d6aa6f9b"
LLAMA_RELEASE_TAG="${HANZO_LLAMA_RELEASE_TAG:-$LLAMA_RELEASE_TAG_DEFAULT}"
LLAMA_RELEASE_SHA256="${HANZO_LLAMA_RELEASE_SHA256:-$LLAMA_RELEASE_SHA256_DEFAULT}"

if [ "$LLAMA_RELEASE_TAG" != "$LLAMA_RELEASE_TAG_DEFAULT" ] && [ -z "${HANZO_LLAMA_RELEASE_SHA256:-}" ]; then
    die "set HANZO_LLAMA_RELEASE_SHA256 when overriding HANZO_LLAMA_RELEASE_TAG."
fi

download_llama_runtime() {
    local cache_root="$HOME/.cache/hanzo/llama.cpp/$LLAMA_RELEASE_TAG"
    local runtime_dir="$cache_root/runtime"
    local archive_url="https://github.com/ggml-org/llama.cpp/releases/download/$LLAMA_RELEASE_TAG/llama-$LLAMA_RELEASE_TAG-bin-macos-arm64.tar.gz"
    local archive_path="$cache_root/llama-bin-macos-arm64.tar.gz"
    local extract_root="$cache_root/extract"

    if [ -x "$runtime_dir/llama-server" ]; then
        echo "$runtime_dir"
        return
    fi

    mkdir -p "$cache_root"
    echo "Downloading llama.cpp runtime ($LLAMA_RELEASE_TAG)..." >&2
    curl -L --fail -o "$archive_path" "$archive_url"
    echo "$LLAMA_RELEASE_SHA256  $archive_path" | shasum -a 256 -c - >/dev/null

    rm -rf "$extract_root" "$runtime_dir"
    mkdir -p "$extract_root"
    tar -xzf "$archive_path" -C "$extract_root"

    local extracted_server
    extracted_server="$(find "$extract_root" -type f -name llama-server | head -n 1)"
    if [ -z "$extracted_server" ]; then
        die "downloaded archive did not contain llama-server."
    fi

    local extracted_dir
    extracted_dir="$(dirname "$extracted_server")"
    mv "$extracted_dir" "$runtime_dir"
    chmod +x "$runtime_dir/llama-server"
    rm -rf "$extract_root"

    echo "$runtime_dir"
}

resolve_llama_runtime_dir() {
    local override_path="${HANZO_LLAMA_SERVER_PATH:-}"
    if [ -n "$override_path" ]; then
        if [ -x "$override_path" ]; then
            dirname "$override_path"
            return
        fi
        if [ -x "$override_path/llama-server" ]; then
            echo "$override_path"
            return
        fi
    fi

    for candidate_dir in \
        "./tools/llama-runtime" \
        "./vendor/llama-runtime"; do
        if [ -x "$candidate_dir/llama-server" ]; then
            echo "$candidate_dir"
            return
        fi
    done

    local installed
    installed="$(command -v llama-server || true)"
    if [ -n "$installed" ]; then
        dirname "$installed"
        return
    fi

    download_llama_runtime
}

# Build and discover canonical SwiftPM artifact directory.
require_cmd swift
require_cmd rsync
require_cmd curl
require_cmd shasum
require_cmd tar
require_cmd find
require_cmd /usr/libexec/PlistBuddy

BIN_DIR="$(swift build --disable-keychain --show-bin-path)"
swift build --disable-keychain
APP_EXECUTABLE="$BIN_DIR/HanzoApp"
[ -x "$APP_EXECUTABLE" ] || die "Built executable not found at $APP_EXECUTABLE"
[ -f "HanzoCore/Info.plist" ] || die "Missing HanzoCore/Info.plist"
[ -f "$DEV_APP_ICON_SOURCE" ] || die "Missing dev app icon at $DEV_APP_ICON_SOURCE"

# Create .app bundle at a fixed location so macOS retains permissions across worktrees
mkdir -p "$APP_DIR/MacOS"
mkdir -p "$APP_DIR/Resources"
rm -rf "$APP_DIR/_CodeSignature"

# Copy executable.
#
# SwiftPM signs products ad-hoc with a cdhash-only designated requirement.
# That cdhash changes across rebuilds/worktrees, which causes macOS TCC to
# treat Accessibility trust as a different client and can stall onboarding.
# Re-sign a temp copy with a stable designated requirement before installing.
SIGNED_EXECUTABLE="$APP_EXECUTABLE"
if command -v codesign >/dev/null 2>&1; then
    SIGNED_EXECUTABLE_TEMP="$(mktemp /tmp/hanzo-signed.XXXXXX)"
    SIGNED_EXECUTABLE="$SIGNED_EXECUTABLE_TEMP"
    cp "$APP_EXECUTABLE" "$SIGNED_EXECUTABLE"
    codesign --force --sign - \
        --identifier "$APP_BUNDLE_IDENTIFIER" \
        -r="designated => identifier \"$APP_BUNDLE_IDENTIFIER\"" \
        "$SIGNED_EXECUTABLE"
fi
install -m 755 "$SIGNED_EXECUTABLE" "$APP_DIR/MacOS/Hanzo"

# Copy dynamic runtime artifacts produced by SwiftPM.
# `swift build` places dynamic frameworks next to the executable and this
# binary resolves them via @loader_path, so mirror that layout inside MacOS.
find "$APP_DIR/MacOS" -maxdepth 1 -name "*.framework" -type d -exec rm -rf {} +
find "$APP_DIR/MacOS" -maxdepth 1 -name "*.dylib" -type f -exec rm -f {} +

while IFS= read -r artifact_path; do
    artifact_name="$(basename "$artifact_path")"
    if [ -d "$artifact_path" ]; then
        rsync -a --delete "$artifact_path/" "$APP_DIR/MacOS/$artifact_name/"
    else
        install -m 755 "$artifact_path" "$APP_DIR/MacOS/$artifact_name"
    fi
done < <(find "$BIN_DIR" -maxdepth 1 \( -name "*.framework" -type d -o -name "*.dylib" -type f \) | sort)

# Copy bundled llama.cpp runtime (llama-server + required dylibs)
LLAMA_RUNTIME_DIR="$(resolve_llama_runtime_dir)"
[ -x "$LLAMA_RUNTIME_DIR/llama-server" ] || die "llama-server not found in $LLAMA_RUNTIME_DIR"
mkdir -p "$APP_DIR/MacOS/llama-runtime"
rsync -a --delete "$LLAMA_RUNTIME_DIR/" "$APP_DIR/MacOS/llama-runtime/"
chmod +x "$APP_DIR/MacOS/llama-runtime/llama-server"
install -m 644 "$DEV_APP_ICON_SOURCE" "$APP_DIR/Resources/HanzoDev.icns"

# Copy Info.plist
install -m 644 HanzoCore/Info.plist "$APP_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $APP_BUNDLE_IDENTIFIER" "$APP_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName \"$APP_DISPLAY_NAME_PLIST\"" "$APP_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile HanzoDev" "$APP_DIR/Info.plist"
if /usr/libexec/PlistBuddy -c "Print :CFBundleDisplayName" "$APP_DIR/Info.plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName \"$APP_DISPLAY_NAME_PLIST\"" "$APP_DIR/Info.plist"
else
    /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string \"$APP_DISPLAY_NAME_PLIST\"" "$APP_DIR/Info.plist"
fi

# Copy all SwiftPM resource bundles (including transitive dependency bundles).
# Start from a clean bundle set so stale resources cannot survive between runs.
find "$APP_ROOT" -maxdepth 1 -name "*.bundle" -type d -exec rm -rf {} +
find "$APP_DIR/Resources" -maxdepth 1 -name "*.bundle" -type d -exec rm -rf {} +

resource_bundle_count=0
hanzo_bundle_name=""
while IFS= read -r bundle_path; do
    bundle_name="$(basename "$bundle_path")"
    rsync -a --delete "$bundle_path/" "$APP_ROOT/$bundle_name/"
    rsync -a --delete "$bundle_path/" "$APP_DIR/Resources/$bundle_name/"
    resource_bundle_count=$((resource_bundle_count + 1))
    case "$bundle_name" in
        *_HanzoCore.bundle) hanzo_bundle_name="$bundle_name" ;;
    esac
done < <(find "$BIN_DIR" -maxdepth 1 -name "*.bundle" -type d | sort)

[ "$resource_bundle_count" -gt 0 ] || die "No SwiftPM resource bundles found in $BIN_DIR"
[ -n "$hanzo_bundle_name" ] || die "HanzoCore resource bundle was not copied"
[ -f "$APP_ROOT/$hanzo_bundle_name/rewrite.txt" ] || die "rewrite.txt missing from $hanzo_bundle_name"

echo "App bundle created at $APP_ROOT"
if [ "$NO_LAUNCH" = true ]; then
    echo "Skipping launch (--no-launch)."
else
    require_cmd open
    echo "Launching..."
    open "$APP_ROOT"
fi
