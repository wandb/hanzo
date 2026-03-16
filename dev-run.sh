#!/bin/bash
set -euo pipefail

die() {
    echo "Error: $*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

RESET_MODELS=false
RESET_PERMISSIONS=false
NO_LAUNCH=false
for arg in "$@"; do
    case "$arg" in
        --reset-models) RESET_MODELS=true ;;
        --reset-permissions) RESET_PERMISSIONS=true ;;
        --no-launch) NO_LAUNCH=true ;;
        *) die "Unknown argument: $arg" ;;
    esac
done

# Kill running instance
pkill -x Hanzo || true

# Clear downloaded models (opt-in): Whisper + local rewrite LLM model.
if [ "$RESET_MODELS" = true ]; then
    MODELS_ROOT="$HOME/Library/Application Support/com.hanzo.app/models"
    LEGACY_LLM_ROOT="$HOME/Library/Application Support/com.hanzo.app/llm"
    rm -rf "$MODELS_ROOT"
    rm -rf "$LEGACY_LLM_ROOT"
fi

# Reset permissions (opt-in)
if [ "$RESET_PERMISSIONS" = true ]; then
    tccutil reset Microphone com.hanzo.app
    tccutil reset Accessibility com.hanzo.app
fi

# Hosted ASR build-time injection (env vars loaded by direnv via .envrc)
HOSTED_ENDPOINT="${HANZO_HOSTED_SERVER_ENDPOINT:-https://grunt.zain.aaronbatilo.dev}"
HOSTED_PASSWORD="${HANZO_HOSTED_SERVER_PASSWORD:-}"
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
require_cmd plutil
require_cmd rsync

swift build
BIN_DIR="$(swift build --show-bin-path)"
APP_EXECUTABLE="$BIN_DIR/HanzoApp"
[ -x "$APP_EXECUTABLE" ] || die "Built executable not found at $APP_EXECUTABLE"
[ -f "HanzoCore/Info.plist" ] || die "Missing HanzoCore/Info.plist"

# Create .app bundle at a fixed location so macOS retains permissions across worktrees
APP_DIR="$HOME/.local/share/hanzo/Hanzo.app/Contents"
APP_ROOT="$HOME/.local/share/hanzo/Hanzo.app"
mkdir -p "$APP_DIR/MacOS"
mkdir -p "$APP_DIR/Resources"

# Copy executable
install -m 755 "$APP_EXECUTABLE" "$APP_DIR/MacOS/Hanzo"

# Copy bundled llama.cpp runtime (llama-server + required dylibs)
LLAMA_RUNTIME_DIR="$(resolve_llama_runtime_dir)"
[ -x "$LLAMA_RUNTIME_DIR/llama-server" ] || die "llama-server not found in $LLAMA_RUNTIME_DIR"
mkdir -p "$APP_DIR/MacOS/llama-runtime"
rsync -a --delete "$LLAMA_RUNTIME_DIR/" "$APP_DIR/MacOS/llama-runtime/"
chmod +x "$APP_DIR/MacOS/llama-runtime/llama-server"

# Copy Info.plist
install -m 644 HanzoCore/Info.plist "$APP_DIR/Info.plist"

# Inject hosted server settings into the app bundle at build time.
plutil -replace HanzoHostedServerEndpoint -string "$HOSTED_ENDPOINT" "$APP_DIR/Info.plist"
plutil -replace HanzoHostedServerPassword -string "$HOSTED_PASSWORD" "$APP_DIR/Info.plist"

# Copy all SwiftPM resource bundles (including transitive dependency bundles).
# Start from a clean bundle set so stale resources cannot survive between runs.
find "$APP_ROOT" -maxdepth 1 -name "*.bundle" -type d -exec rm -rf {} +

resource_bundle_count=0
hanzo_bundle_name=""
while IFS= read -r bundle_path; do
    bundle_name="$(basename "$bundle_path")"
    rsync -a --delete "$bundle_path/" "$APP_ROOT/$bundle_name/"
    resource_bundle_count=$((resource_bundle_count + 1))
    case "$bundle_name" in
        *_HanzoCore.bundle) hanzo_bundle_name="$bundle_name" ;;
    esac
done < <(find "$BIN_DIR" -maxdepth 1 -name "*.bundle" -type d | sort)

[ "$resource_bundle_count" -gt 0 ] || die "No SwiftPM resource bundles found in $BIN_DIR"
[ -n "$hanzo_bundle_name" ] || die "HanzoCore resource bundle was not copied"
[ -f "$APP_ROOT/$hanzo_bundle_name/rewrite.txt" ] || die "rewrite.txt missing from $hanzo_bundle_name"

echo "App bundle created at $HOME/.local/share/hanzo/Hanzo.app"
if [ "$NO_LAUNCH" = true ]; then
    echo "Skipping launch (--no-launch)."
else
    echo "Launching..."
    open "$HOME/.local/share/hanzo/Hanzo.app"
fi
