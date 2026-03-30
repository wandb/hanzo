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
require_cmd create-dmg
require_cmd lipo
require_cmd file
require_cmd /usr/libexec/PlistBuddy

[ -f "$INFO_PLIST" ] || die "Missing Info.plist at $INFO_PLIST"
[ -f "$ENTITLEMENTS" ] || die "Missing entitlements at $ENTITLEMENTS"
[ -f "$APP_ICON_SOURCE" ] || die "Missing app icon at $APP_ICON_SOURCE"

DMG_BG_SOURCE="$ROOT_DIR/assets/dmg/background.png"
[ -f "$DMG_BG_SOURCE" ] || die "Missing DMG background at $DMG_BG_SOURCE"

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
cleanup() {
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

# Keep non-code license/docs out of Contents/MacOS; strict code signing rejects
# plain files there. Preserve them under Resources for attribution.
mkdir -p "$APP_RESOURCES/ThirdPartyLicenses"
for doc_name in LICENSE LICENSE.txt COPYING NOTICE README README.md; do
    if [ -f "$APP_MACOS/llama-runtime/$doc_name" ]; then
        mv "$APP_MACOS/llama-runtime/$doc_name" \
            "$APP_RESOURCES/ThirdPartyLicenses/llama-runtime-$doc_name"
    fi
done

LLAMA_ARCHS="$(lipo -archs "$APP_MACOS/llama-runtime/llama-server" 2>/dev/null || true)"
echo "$LLAMA_ARCHS" | grep -q "arm64" || die "llama-server is not arm64: $LLAMA_ARCHS"

resource_bundle_count=0
hanzo_bundle_name=""
while IFS= read -r bundle_path; do
    bundle_name="$(basename "$bundle_path")"
    # Resource bundles must live under Contents/Resources for code signing.
    rsync -a --delete "$bundle_path/" "$APP_RESOURCES/$bundle_name/"
    resource_bundle_count=$((resource_bundle_count + 1))
    case "$bundle_name" in
        *_HanzoCore.bundle) hanzo_bundle_name="$bundle_name" ;;
    esac
done < <(find "$BIN_DIR" -maxdepth 1 -name "*.bundle" -type d | sort)

[ "$resource_bundle_count" -gt 0 ] || die "No SwiftPM resource bundles found in $BIN_DIR"
[ -n "$hanzo_bundle_name" ] || die "HanzoCore resource bundle was not copied"
[ -f "$APP_RESOURCES/$hanzo_bundle_name/rewrite.txt" ] || die "rewrite.txt missing from $hanzo_bundle_name"

sign_macho_tree() {
    local tree_root="$1"
    while IFS= read -r -d '' candidate; do
        if file "$candidate" | grep -q "Mach-O"; then
            codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime "$candidate"
        fi
    done < <(find "$tree_root" -type f -print0)
}

sign_nested_bundles() {
    local root_bundle="$1"
    while IFS= read -r nested_bundle; do
        [ "$nested_bundle" = "$root_bundle" ] && continue
        codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime "$nested_bundle"
    done < <(
        find "$root_bundle" -type d \( -name "*.app" -o -name "*.xpc" -o -name "*.framework" \) \
            | awk '{ print length, $0 }' \
            | sort -rn \
            | cut -d' ' -f2-
    )
}

sign_swiftpm_dynamic_artifacts() {
    while IFS= read -r artifact_path; do
        if [ -d "$artifact_path" ] && [[ "$artifact_path" == *.framework ]]; then
            sign_macho_tree "$artifact_path"
            sign_nested_bundles "$artifact_path"
            codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime "$artifact_path"
        else
            codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime "$artifact_path"
        fi
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

# Overwrite existing release artifacts for the same version/build.
rm -f "$APP_ZIP_PATH" "$DMG_PATH" "$CHECKSUM_PATH"

ditto -c -k --sequesterRsrc --keepParent "$APP_ROOT" "$APP_ZIP_PATH"

DMG_STAGE="$WORK_DIR/dmg"
mkdir -p "$DMG_STAGE"
cp -R "$APP_ROOT" "$DMG_STAGE/"

# create-dmg returns exit code 2 when it works but "could not set icon position"
# warnings are emitted; this is expected and the DMG is still valid.
create-dmg \
    --volname "Hanzo" \
    --background "$DMG_BG_SOURCE" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 128 \
    --icon "Hanzo.app" 180 170 \
    --hide-extension "Hanzo.app" \
    --app-drop-link 480 170 \
    --volicon "$APP_ICON_SOURCE" \
    --no-internet-enable \
    "$DMG_PATH" \
    "$DMG_STAGE" \
    || [ $? -eq 2 ]

if [ ! -s "$DMG_PATH" ]; then
    die "DMG was not created or is empty: $DMG_PATH"
fi

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
