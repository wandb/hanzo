#!/bin/bash
set -euo pipefail

die() {
    echo "Error: $*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Manage Hanzo app version metadata in HanzoCore/Info.plist.

Usage:
  ./scripts/version.sh show
  ./scripts/version.sh set [--version <x.y.z>] [--build-number <n>]
  ./scripts/version.sh bump-build
  ./scripts/version.sh bump-patch
  ./scripts/version.sh bump-minor
  ./scripts/version.sh bump-major

Notes:
  - Semantic version commands expect version format x.y.z.
  - bump-build increments CFBundleVersion only.
  - bump-patch/minor/major reset CFBundleVersion to 1.
EOF
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_PLIST="$ROOT_DIR/HanzoCore/Info.plist"
PLIST_BUDDY="/usr/libexec/PlistBuddy"

[ -x "$PLIST_BUDDY" ] || die "Missing $PLIST_BUDDY"
[ -f "$INFO_PLIST" ] || die "Missing Info.plist at $INFO_PLIST"

read_version() {
    "$PLIST_BUDDY" -c 'Print :CFBundleShortVersionString' "$INFO_PLIST"
}

read_build_number() {
    "$PLIST_BUDDY" -c 'Print :CFBundleVersion' "$INFO_PLIST"
}

is_uint() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

parse_semver() {
    local version="$1"
    local major minor patch extra
    IFS='.' read -r major minor patch extra <<<"$version"
    [ -n "${major:-}" ] || die "Invalid semantic version '$version' (expected x.y.z)"
    [ -n "${minor:-}" ] || die "Invalid semantic version '$version' (expected x.y.z)"
    [ -n "${patch:-}" ] || die "Invalid semantic version '$version' (expected x.y.z)"
    [ -z "${extra:-}" ] || die "Invalid semantic version '$version' (expected x.y.z)"
    is_uint "$major" || die "Invalid major version '$major'"
    is_uint "$minor" || die "Invalid minor version '$minor'"
    is_uint "$patch" || die "Invalid patch version '$patch'"
    echo "$major" "$minor" "$patch"
}

set_values() {
    local version="$1"
    local build_number="$2"
    parse_semver "$version" >/dev/null
    is_uint "$build_number" || die "Build number must be an integer, got '$build_number'"

    "$PLIST_BUDDY" -c "Set :CFBundleShortVersionString $version" "$INFO_PLIST"
    "$PLIST_BUDDY" -c "Set :CFBundleVersion $build_number" "$INFO_PLIST"
}

show_values() {
    echo "CFBundleShortVersionString=$(read_version)"
    echo "CFBundleVersion=$(read_build_number)"
}

bump_build() {
    local version build_number next_build
    version="$(read_version)"
    build_number="$(read_build_number)"
    is_uint "$build_number" || die "Current build number is not an integer: '$build_number'"
    next_build=$((10#$build_number + 1))
    set_values "$version" "$next_build"
    show_values
}

bump_semver() {
    local part="$1"
    local version major minor patch next_version
    version="$(read_version)"
    read -r major minor patch <<<"$(parse_semver "$version")"

    case "$part" in
        patch)
            patch=$((10#$patch + 1))
            ;;
        minor)
            minor=$((10#$minor + 1))
            patch=0
            ;;
        major)
            major=$((10#$major + 1))
            minor=0
            patch=0
            ;;
        *)
            die "Unsupported semantic bump part: $part"
            ;;
    esac

    next_version="$major.$minor.$patch"
    set_values "$next_version" "1"
    show_values
}

command="${1:-show}"
if [ "$#" -gt 0 ]; then
    shift
fi

case "$command" in
    show)
        show_values
        ;;
    set)
        version=""
        build_number=""
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --version)
                    [ "$#" -ge 2 ] || die "Missing value for --version"
                    version="$2"
                    shift 2
                    ;;
                --build-number)
                    [ "$#" -ge 2 ] || die "Missing value for --build-number"
                    build_number="$2"
                    shift 2
                    ;;
                --help|-h)
                    usage
                    exit 0
                    ;;
                *)
                    die "Unknown argument for set: $1"
                    ;;
            esac
        done

        [ -n "$version" ] || version="$(read_version)"
        [ -n "$build_number" ] || build_number="$(read_build_number)"
        set_values "$version" "$build_number"
        show_values
        ;;
    bump-build)
        [ "$#" -eq 0 ] || die "bump-build takes no additional arguments"
        bump_build
        ;;
    bump-patch)
        [ "$#" -eq 0 ] || die "bump-patch takes no additional arguments"
        bump_semver "patch"
        ;;
    bump-minor)
        [ "$#" -eq 0 ] || die "bump-minor takes no additional arguments"
        bump_semver "minor"
        ;;
    bump-major)
        [ "$#" -eq 0 ] || die "bump-major takes no additional arguments"
        bump_semver "major"
        ;;
    --help|-h|help)
        usage
        ;;
    *)
        die "Unknown command: $command (use --help for usage)"
        ;;
esac
