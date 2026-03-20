#!/bin/bash
set -euo pipefail

die() {
    echo "Error: $*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

usage() {
    cat <<'EOF'
Build release artifacts for Hanzo.

Usage:
  ./scripts/release.sh [options]

Options:
  --version <value>         Override CFBundleShortVersionString (default: Info.plist value)
  --build-number <value>    Override CFBundleVersion (default: Info.plist value)
  --output-dir <path>       Output directory (default: ./dist)
  --sign-identity <value>   Developer ID Application identity
  --notary-profile <value>  notarytool keychain profile name
  --skip-notarize           Build and sign artifacts, but do not notarize
  --unsigned                Build unsigned artifacts (disables notarization)
  --help                    Show this message

Environment:
  HANZO_SIGN_IDENTITY       Default signing identity
  HANZO_NOTARY_PROFILE      Default notarytool keychain profile
  HANZO_LLAMA_SERVER_PATH   Optional path to llama-server or its parent dir
  HANZO_LLAMA_RELEASE_TAG   Optional llama.cpp release tag override
  HANZO_LLAMA_RELEASE_SHA256 Required when overriding HANZO_LLAMA_RELEASE_TAG
EOF
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_PLIST="$ROOT_DIR/HanzoCore/Info.plist"
ENTITLEMENTS="$ROOT_DIR/HanzoCore/Hanzo.entitlements"
APP_ICON_SOURCE="$ROOT_DIR/assets/icons/Hanzo.icns"
DMG_BACKGROUND_SOURCE="$ROOT_DIR/assets/dmg/background.png"

VERSION=""
BUILD_NUMBER=""
OUTPUT_DIR="$ROOT_DIR/dist"
SIGN_IDENTITY="${HANZO_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${HANZO_NOTARY_PROFILE:-}"
SIGN_ARTIFACTS=true
NOTARIZE=true

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            [ "$#" -ge 2 ] || die "Missing value for --version"
            VERSION="$2"
            shift 2
            ;;
        --build-number)
            [ "$#" -ge 2 ] || die "Missing value for --build-number"
            BUILD_NUMBER="$2"
            shift 2
            ;;
        --output-dir)
            [ "$#" -ge 2 ] || die "Missing value for --output-dir"
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --sign-identity)
            [ "$#" -ge 2 ] || die "Missing value for --sign-identity"
            SIGN_IDENTITY="$2"
            shift 2
            ;;
        --notary-profile)
            [ "$#" -ge 2 ] || die "Missing value for --notary-profile"
            NOTARY_PROFILE="$2"
            shift 2
            ;;
        --skip-notarize)
            NOTARIZE=false
            shift
            ;;
        --unsigned)
            SIGN_ARTIFACTS=false
            NOTARIZE=false
            shift
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

require_cmd swift
require_cmd rsync
require_cmd curl
require_cmd shasum
require_cmd tar
require_cmd find
require_cmd mktemp
require_cmd ditto
require_cmd hdiutil
require_cmd lipo
require_cmd file
require_cmd python3
require_cmd /usr/libexec/PlistBuddy

[ -f "$INFO_PLIST" ] || die "Missing Info.plist at $INFO_PLIST"
[ -f "$ENTITLEMENTS" ] || die "Missing entitlements at $ENTITLEMENTS"
[ -f "$APP_ICON_SOURCE" ] || die "Missing app icon at $APP_ICON_SOURCE"
[ -f "$DMG_BACKGROUND_SOURCE" ] || die "Missing DMG background at $DMG_BACKGROUND_SOURCE"

if [ "$SIGN_ARTIFACTS" = true ]; then
    require_cmd codesign
    [ -n "$SIGN_IDENTITY" ] || die "Signing enabled but no identity set (--sign-identity or HANZO_SIGN_IDENTITY)"
fi

if [ "$NOTARIZE" = true ]; then
    require_cmd xcrun
    [ "$SIGN_ARTIFACTS" = true ] || die "Notarization requires signed artifacts"
    [ -n "$NOTARY_PROFILE" ] || die "Notarization enabled but no profile set (--notary-profile or HANZO_NOTARY_PROFILE)"
fi

if [ -z "$VERSION" ]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
fi

if [ -z "$BUILD_NUMBER" ]; then
    BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
fi

APP_BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"

LLAMA_RELEASE_TAG_DEFAULT="b8355"
LLAMA_RELEASE_SHA256_DEFAULT="43e831c4ccf785dfd4c4197e00fbba309823d4088a5c40def5d4d934d6aa6f9b"
LLAMA_RELEASE_TAG="${HANZO_LLAMA_RELEASE_TAG:-$LLAMA_RELEASE_TAG_DEFAULT}"
LLAMA_RELEASE_SHA256="${HANZO_LLAMA_RELEASE_SHA256:-$LLAMA_RELEASE_SHA256_DEFAULT}"

if [ "$LLAMA_RELEASE_TAG" != "$LLAMA_RELEASE_TAG_DEFAULT" ] && [ -z "${HANZO_LLAMA_RELEASE_SHA256:-}" ]; then
    die "set HANZO_LLAMA_RELEASE_SHA256 when overriding HANZO_LLAMA_RELEASE_TAG"
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
    echo "Downloading llama.cpp runtime ($LLAMA_RELEASE_TAG)..."
    curl -L --fail -o "$archive_path" "$archive_url"
    echo "$LLAMA_RELEASE_SHA256  $archive_path" | shasum -a 256 -c - >/dev/null

    rm -rf "$extract_root" "$runtime_dir"
    mkdir -p "$extract_root"
    tar -xzf "$archive_path" -C "$extract_root"

    local extracted_server
    extracted_server="$(find "$extract_root" -type f -name llama-server | head -n 1)"
    [ -n "$extracted_server" ] || die "downloaded archive did not contain llama-server"

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
        "$ROOT_DIR/tools/llama-runtime" \
        "$ROOT_DIR/vendor/llama-runtime"; do
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

WORK_DIR="$(mktemp -d /tmp/hanzo-release.XXXXXX)"
DMG_DEVICE=""
DMG_MOUNT_POINT=""

detach_dmg() {
    local device="$1"
    [ -n "$device" ] || return 0

    if hdiutil detach "$device" >/dev/null 2>&1; then
        return 0
    fi

    # Finder can briefly keep the volume busy after AppleScript layout changes.
    sleep 1
    if hdiutil detach "$device" >/dev/null 2>&1; then
        return 0
    fi

    hdiutil detach -force "$device" >/dev/null 2>&1
}

cleanup() {
    if [ -n "${DMG_DEVICE:-}" ]; then
        detach_dmg "$DMG_DEVICE" || true
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo "Building Hanzo (release)..."
BIN_DIR="$(cd "$ROOT_DIR" && swift build --disable-keychain -c release --show-bin-path)"
(cd "$ROOT_DIR" && swift build --disable-keychain -c release)

APP_EXECUTABLE="$BIN_DIR/HanzoApp"
[ -x "$APP_EXECUTABLE" ] || die "Built executable not found at $APP_EXECUTABLE"

APP_ARCHS="$(lipo -archs "$APP_EXECUTABLE")"
[ "$APP_ARCHS" = "arm64" ] || die "Expected Apple Silicon build only; got architectures: $APP_ARCHS"

APP_NAME="Hanzo"
ARTIFACT_BASENAME="${APP_NAME}-${VERSION}-${BUILD_NUMBER}"
APP_ROOT="$WORK_DIR/${APP_NAME}.app"
APP_CONTENTS="$APP_ROOT/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"

SIGNED_EXECUTABLE_PATH="$APP_EXECUTABLE"
if [ "$SIGN_ARTIFACTS" = false ]; then
    echo "Applying stable ad-hoc signature for unsigned build: $APP_BUNDLE_IDENTIFIER"
    if ! command -v codesign >/dev/null 2>&1; then
        echo "Warning: codesign not found; unsigned app will use an unstable code requirement."
    else
        SIGNED_EXECUTABLE_PATH="$WORK_DIR/HanzoApp-signed"
        cp "$APP_EXECUTABLE" "$SIGNED_EXECUTABLE_PATH"
        # Keep unsigned beta builds on a stable designated requirement so TCC
        # permission grants survive rebuilds/version bumps.
        if ! codesign --force --sign - \
            --identifier "$APP_BUNDLE_IDENTIFIER" \
            -r="designated => identifier \"$APP_BUNDLE_IDENTIFIER\"" \
            "$SIGNED_EXECUTABLE_PATH"; then
            die "Failed to apply stable ad-hoc signature for unsigned build; refusing to package an unstable TCC identity."
        fi
    fi
fi

mkdir -p "$APP_MACOS" "$APP_RESOURCES"
install -m 755 "$SIGNED_EXECUTABLE_PATH" "$APP_MACOS/Hanzo"
install -m 644 "$APP_ICON_SOURCE" "$APP_RESOURCES/Hanzo.icns"
install -m 644 "$INFO_PLIST" "$APP_CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile Hanzo" "$APP_CONTENTS/Info.plist"

# Copy dynamic runtime artifacts produced by SwiftPM so the app can load
# frameworks and dylibs resolved relative to the executable.
while IFS= read -r artifact_path; do
    artifact_name="$(basename "$artifact_path")"
    if [ -d "$artifact_path" ]; then
        rsync -a --delete "$artifact_path/" "$APP_MACOS/$artifact_name/"
    else
        install -m 755 "$artifact_path" "$APP_MACOS/$artifact_name"
    fi
done < <(find "$BIN_DIR" -maxdepth 1 \( -name "*.framework" -type d -o -name "*.dylib" -type f \) | sort)

LLAMA_RUNTIME_DIR="$(resolve_llama_runtime_dir)"
[ -x "$LLAMA_RUNTIME_DIR/llama-server" ] || die "llama-server not found in $LLAMA_RUNTIME_DIR"
mkdir -p "$APP_MACOS/llama-runtime"
rsync -a --delete "$LLAMA_RUNTIME_DIR/" "$APP_MACOS/llama-runtime/"
chmod +x "$APP_MACOS/llama-runtime/llama-server"

LLAMA_ARCHS="$(lipo -archs "$APP_MACOS/llama-runtime/llama-server" 2>/dev/null || true)"
echo "$LLAMA_ARCHS" | grep -q "arm64" || die "llama-server is not arm64: $LLAMA_ARCHS"

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

sign_macho_tree() {
    local tree_root="$1"
    while IFS= read -r -d '' candidate; do
        if file "$candidate" | grep -q "Mach-O"; then
            codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime "$candidate"
        fi
    done < <(find "$tree_root" -type f -print0)
}

sign_swiftpm_dynamic_artifacts() {
    while IFS= read -r artifact_path; do
        codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime "$artifact_path"
    done < <(find "$APP_MACOS" -maxdepth 1 \( -name "*.framework" -type d -o -name "*.dylib" -type f \) | sort)
}

if [ "$SIGN_ARTIFACTS" = true ]; then
    echo "Signing app with identity: $SIGN_IDENTITY"
    sign_swiftpm_dynamic_artifacts
    sign_macho_tree "$APP_MACOS/llama-runtime"
    codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime "$APP_MACOS/Hanzo"
    codesign --force --sign "$SIGN_IDENTITY" \
        --timestamp \
        --options runtime \
        --entitlements "$ENTITLEMENTS" \
        "$APP_ROOT"
    codesign --verify --deep --strict --verbose=2 "$APP_ROOT"
fi

notarize_file() {
    local input_file="$1"
    echo "Submitting for notarization: $(basename "$input_file")"
    xcrun notarytool submit "$input_file" --keychain-profile "$NOTARY_PROFILE" --wait
}

configure_dmg_layout() {
    local volume_name="$1"
    local app_bundle_name="$2"

    if [ -n "${CI:-}" ]; then
        return 1
    fi

    if ! command -v osascript >/dev/null 2>&1; then
        return 1
    fi

    osascript <<EOF
tell application "Finder"
    tell disk "$volume_name"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {120, 120, 780, 520}
        set iconViewOptions to the icon view options of container window
        set arrangement of iconViewOptions to not arranged
        set icon size of iconViewOptions to 102
        set text size of iconViewOptions to 16
        set background picture of iconViewOptions to file "$app_bundle_name:Contents:Resources:InstallerBackground.png"
        set position of item "$app_bundle_name" of container window to {170, 128}
        set position of item "Applications" of container window to {490, 128}
        close
        open
        update without registering applications
    end tell
end tell
EOF
}

if [ "$NOTARIZE" = true ]; then
    APP_NOTARY_ZIP="$WORK_DIR/${APP_NAME}-notary.zip"
    ditto -c -k --sequesterRsrc --keepParent "$APP_ROOT" "$APP_NOTARY_ZIP"
    notarize_file "$APP_NOTARY_ZIP"
    xcrun stapler staple "$APP_ROOT"
fi

mkdir -p "$OUTPUT_DIR"
APP_ZIP_PATH="$OUTPUT_DIR/${ARTIFACT_BASENAME}.zip"
DMG_PATH="$OUTPUT_DIR/${ARTIFACT_BASENAME}.dmg"
CHECKSUM_PATH="$OUTPUT_DIR/${ARTIFACT_BASENAME}.sha256"

ditto -c -k --sequesterRsrc --keepParent "$APP_ROOT" "$APP_ZIP_PATH"

DMG_STAGE="$WORK_DIR/dmg"
mkdir -p "$DMG_STAGE"
cp -R "$APP_ROOT" "$DMG_STAGE/"
# Provide the standard drag-to-install target in the mounted DMG.
ln -s /Applications "$DMG_STAGE/Applications"
DMG_APP_ROOT="$DMG_STAGE/${APP_NAME}.app"
install -m 644 "$DMG_BACKGROUND_SOURCE" "$DMG_APP_ROOT/Contents/Resources/InstallerBackground.png"

if command -v codesign >/dev/null 2>&1; then
    if [ "$SIGN_ARTIFACTS" = true ]; then
        codesign --force --sign "$SIGN_IDENTITY" \
            --timestamp \
            --options runtime \
            --entitlements "$ENTITLEMENTS" \
            "$DMG_APP_ROOT"
        codesign --verify --deep --strict --verbose=2 "$DMG_APP_ROOT"
    else
        # Keep unsigned builds on a stable designated requirement even after
        # injecting DMG-only resources into the staged app copy.
        if ! codesign --force --sign - \
            --identifier "$APP_BUNDLE_IDENTIFIER" \
            -r="designated => identifier \"$APP_BUNDLE_IDENTIFIER\"" \
            "$DMG_APP_ROOT"; then
            die "Failed to re-sign staged DMG app after adding background resource."
        fi
    fi
fi

DMG_RW_PATH="$WORK_DIR/${ARTIFACT_BASENAME}.rw.dmg"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGE" -ov -format UDRW "$DMG_RW_PATH" >/dev/null

ATTACH_PLIST="$WORK_DIR/dmg-attach.plist"
hdiutil attach -readwrite -noverify -noautoopen -plist "$DMG_RW_PATH" > "$ATTACH_PLIST"
DMG_INFO="$(python3 - "$ATTACH_PLIST" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    data = plistlib.load(handle)

for entity in data.get("system-entities", []):
    dev_entry = entity.get("dev-entry")
    mount_point = entity.get("mount-point")
    if dev_entry and mount_point:
        print(dev_entry)
        print(mount_point)
        break
PY
)"

DMG_DEVICE="$(printf '%s\n' "$DMG_INFO" | sed -n '1p')"
DMG_MOUNT_POINT="$(printf '%s\n' "$DMG_INFO" | sed -n '2p')"
[ -n "$DMG_DEVICE" ] || die "Failed to determine mounted DMG device from hdiutil plist output"
[ -n "$DMG_MOUNT_POINT" ] || die "Failed to determine mounted DMG path from hdiutil plist output"
DMG_VOLUME_NAME="$(basename "$DMG_MOUNT_POINT")"

if ! configure_dmg_layout "$DMG_VOLUME_NAME" "${APP_NAME}.app"; then
    echo "Warning: failed to apply Finder DMG layout customization; continuing with default layout."
fi

# Remove filesystem metadata folders from the image root so users do not see
# extra dot-directories when mounting the final read-only DMG.
rm -rf "$DMG_MOUNT_POINT/.fseventsd" "$DMG_MOUNT_POINT/.Spotlight-V100" "$DMG_MOUNT_POINT/.Trashes"

sync
if ! detach_dmg "$DMG_DEVICE"; then
    die "Failed to detach mounted DMG device: $DMG_DEVICE"
fi
DMG_DEVICE=""
DMG_MOUNT_POINT=""

hdiutil convert "$DMG_RW_PATH" -ov -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null

if [ "$SIGN_ARTIFACTS" = true ]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"
fi

if [ "$NOTARIZE" = true ]; then
    notarize_file "$DMG_PATH"
    xcrun stapler staple "$DMG_PATH"
fi

shasum -a 256 "$APP_ZIP_PATH" "$DMG_PATH" > "$CHECKSUM_PATH"

echo
echo "Release artifacts:"
echo "  $APP_ZIP_PATH"
echo "  $DMG_PATH"
echo "  $CHECKSUM_PATH"
echo
if [ "$SIGN_ARTIFACTS" = false ]; then
    echo "Built unsigned artifacts (--unsigned)."
elif [ "$NOTARIZE" = false ]; then
    echo "Built signed artifacts without notarization (--skip-notarize)."
else
    echo "Built signed and notarized artifacts."
fi
