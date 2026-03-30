#!/bin/bash
set -euo pipefail

die() {
    echo "Error: $*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

decode_base64() {
    if base64 --help 2>&1 | grep -q -- "--decode"; then
        base64 --decode
    else
        base64 -D
    fi
}

usage() {
    cat <<'EOF'
Build a GitHub Pages site for Sparkle appcasts from GitHub Releases.

Usage:
  ./scripts/build-sparkle-appcast-site.sh [options]

Options:
  --repo <owner/name>      GitHub repository to read releases from
  --site-url <url>         Public GitHub Pages base URL
  --output-dir <path>      Output directory (default: ./dist/sparkle-site)
  --release-limit <count>  Number of published releases to mirror (default: 6)
  --ed-key-file <path>     Sparkle private EdDSA key file
  --link-url <url>         Product or release page URL shown by Sparkle
  --help                   Show this message

Environment:
  GH_TOKEN                 GitHub token used by gh CLI
  SPARKLE_PRIVATE_ED_KEY   Sparkle private EdDSA key contents used if --ed-key-file is omitted
EOF
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATE_APPCAST="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"

REPO=""
SITE_URL=""
OUTPUT_DIR="$ROOT_DIR/dist/sparkle-site"
RELEASE_LIMIT=6
ED_KEY_FILE=""
LINK_URL=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --repo)
            [ "$#" -ge 2 ] || die "Missing value for --repo"
            REPO="$2"
            shift 2
            ;;
        --site-url)
            [ "$#" -ge 2 ] || die "Missing value for --site-url"
            SITE_URL="$2"
            shift 2
            ;;
        --output-dir)
            [ "$#" -ge 2 ] || die "Missing value for --output-dir"
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --release-limit)
            [ "$#" -ge 2 ] || die "Missing value for --release-limit"
            RELEASE_LIMIT="$2"
            shift 2
            ;;
        --ed-key-file)
            [ "$#" -ge 2 ] || die "Missing value for --ed-key-file"
            ED_KEY_FILE="$2"
            shift 2
            ;;
        --link-url)
            [ "$#" -ge 2 ] || die "Missing value for --link-url"
            LINK_URL="$2"
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

require_cmd gh
require_cmd jq
[ -x "$GENERATE_APPCAST" ] || die "Missing generate_appcast at $GENERATE_APPCAST"

derive_repo_from_remote() {
    local remote_url
    remote_url="$(git -C "$ROOT_DIR" config --get remote.origin.url || true)"
    [ -n "$remote_url" ] || die "Could not derive GitHub repo from git remote.origin.url"

    case "$remote_url" in
        https://github.com/*)
            remote_url="${remote_url#https://github.com/}"
            ;;
        git@github.com:*)
            remote_url="${remote_url#git@github.com:}"
            ;;
        ssh://git@github.com/*)
            remote_url="${remote_url#ssh://git@github.com/}"
            ;;
        *)
            die "Unsupported GitHub remote URL format: $remote_url"
            ;;
    esac

    remote_url="${remote_url%.git}"
    printf '%s\n' "$remote_url"
}

derive_site_url() {
    local repo="$1"
    local owner="${repo%%/*}"
    local name="${repo##*/}"
    local owner_lower
    local name_lower
    owner_lower="$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')"
    name_lower="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"

    if [ "$name_lower" = "${owner_lower}.github.io" ]; then
        printf 'https://%s.github.io\n' "$owner_lower"
    else
        printf 'https://%s.github.io/%s\n' "$owner_lower" "$name_lower"
    fi
}

if [ -z "$REPO" ]; then
    REPO="$(derive_repo_from_remote)"
fi

if [ -z "$SITE_URL" ]; then
    SITE_URL="$(derive_site_url "$REPO")"
fi

if [ -z "$LINK_URL" ]; then
    LINK_URL="https://github.com/$REPO/releases"
fi

[ "$RELEASE_LIMIT" -gt 0 ] 2>/dev/null || die "--release-limit must be a positive integer"

if [ -n "$ED_KEY_FILE" ]; then
    [ -f "$ED_KEY_FILE" ] || die "Missing EdDSA key file: $ED_KEY_FILE"
elif [ -z "${SPARKLE_PRIVATE_ED_KEY:-}" ]; then
    die "Provide --ed-key-file or set SPARKLE_PRIVATE_ED_KEY"
fi

WORK_DIR="$(mktemp -d /tmp/hanzo-sparkle-site.XXXXXX)"
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

RELEASES_JSON="$WORK_DIR/releases.json"
echo "Fetching GitHub releases from $REPO..."
gh api \
    -H "Accept: application/vnd.github+json" \
    --paginate \
    --slurp \
    "repos/$REPO/releases?per_page=100" > "$RELEASES_JSON"

mapfile -t RELEASE_ROWS < <(
    jq -r --argjson limit "$RELEASE_LIMIT" '
        [.[]
         | .[]
         | select(.draft | not)
         | select(.prerelease | not)
         | . as $release
         | {
             tag: $release.tag_name,
             body: ($release.body // ""),
             asset_name: (
                 [$release.assets[]? | select(.name | endswith(".zip")) | .name][0] // empty
             )
           }
         | select(.asset_name != "")
        ][: $limit]
        | .[]
        | @base64
    ' "$RELEASES_JSON"
)

[ "${#RELEASE_ROWS[@]}" -gt 0 ] || die "No published releases with .zip assets found in $REPO"

rm -rf "$OUTPUT_DIR"
DOWNLOADS_DIR="$OUTPUT_DIR/downloads"
mkdir -p "$DOWNLOADS_DIR"

for encoded_release in "${RELEASE_ROWS[@]}"; do
    release_json="$(printf '%s' "$encoded_release" | decode_base64)"
    tag_name="$(printf '%s' "$release_json" | jq -r '.tag')"
    asset_name="$(printf '%s' "$release_json" | jq -r '.asset_name')"
    release_body="$(printf '%s' "$release_json" | jq -r '.body')"

    echo "Downloading $asset_name from $tag_name..."
    gh release download "$tag_name" \
        --repo "$REPO" \
        --pattern "$asset_name" \
        --dir "$DOWNLOADS_DIR" \
        --clobber

    if [ -n "$(printf '%s' "$release_body" | tr -d '[:space:]')" ]; then
        printf '%s\n' "$release_body" > "$DOWNLOADS_DIR/${asset_name%.zip}.md"
    fi
done

echo "Generating appcast..."
APPCAST_ARGS=(
    --download-url-prefix "$SITE_URL/downloads/"
    --release-notes-url-prefix "$SITE_URL/downloads/"
    --link "$LINK_URL"
    --maximum-versions 3
    --maximum-deltas 5
    -o "$OUTPUT_DIR/appcast.xml"
)

if [ -n "$ED_KEY_FILE" ]; then
    "$GENERATE_APPCAST" \
        --ed-key-file "$ED_KEY_FILE" \
        "${APPCAST_ARGS[@]}" \
        "$DOWNLOADS_DIR"
else
    printf '%s' "$SPARKLE_PRIVATE_ED_KEY" | \
        "$GENERATE_APPCAST" \
            --ed-key-file - \
            "${APPCAST_ARGS[@]}" \
            "$DOWNLOADS_DIR"
fi

rm -rf "$DOWNLOADS_DIR/old_updates"
touch "$OUTPUT_DIR/.nojekyll"

cat > "$OUTPUT_DIR/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Hanzo Updates</title>
</head>
<body>
  <h1>Hanzo Updates</h1>
  <p><a href="./appcast.xml">Sparkle appcast</a></p>
  <p><a href="$LINK_URL">GitHub Releases</a></p>
</body>
</html>
EOF

echo
echo "Sparkle site output:"
echo "  $OUTPUT_DIR"
echo "Feed URL:"
echo "  $SITE_URL/appcast.xml"
