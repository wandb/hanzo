#!/bin/bash
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    cat <<'USAGE'
scripts/changelog.sh — manage Hanzo release notes in CHANGELOG.md

Usage:
  ./scripts/changelog.sh extract --version <x.y.z> --output <path>
  ./scripts/changelog.sh prepare --version <x.y.z> [--date <YYYY-MM-DD>] [--body-file <path>] [--repo <owner/name>]

Commands:
  extract   Write the changelog body for a version to an output file.
  prepare   Insert or replace a changelog entry using the current GitHub draft release body.

Flags:
  --version <x.y.z>     Release version to extract or prepare
  --output <path>       Output file for extract
  --date <YYYY-MM-DD>   Heading date for prepare (default: today)
  --body-file <path>    Use a local markdown file instead of the GitHub draft release body
  --repo <owner/name>   Override the GitHub repository used for draft release lookup
  -h, --help            Show this help

Notes:
  - prepare updates CHANGELOG.md in place.
  - prepare requires gh authentication unless --body-file is provided.
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
Manage Hanzo release notes stored in CHANGELOG.md.

Usage:
  ./scripts/changelog.sh extract --version <x.y.z> --output <path>
  ./scripts/changelog.sh prepare --version <x.y.z> [--date <YYYY-MM-DD>] [--body-file <path>] [--repo <owner/name>]

Commands:
  extract   Write the changelog body for a version to an output file.
  prepare   Insert or replace a changelog entry using the current GitHub draft release body.

Options:
  --version <x.y.z>     Release version to extract or prepare.
  --output <path>       Output file for extract.
  --date <YYYY-MM-DD>   Heading date for prepare (default: today).
  --body-file <path>    Use a local markdown file instead of fetching the GitHub draft release body.
  --repo <owner/name>   Override the GitHub repository used for draft release lookup.
  --help                Show this message.

Notes:
  - prepare updates CHANGELOG.md in place.
  - prepare requires gh authentication unless --body-file is provided.
EOF
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHANGELOG_PATH="$ROOT_DIR/CHANGELOG.md"
TEMP_FILES=()

cleanup_temp_files() {
    if [ "${#TEMP_FILES[@]}" -eq 0 ]; then
        return
    fi

    rm -f "${TEMP_FILES[@]}" >/dev/null 2>&1 || true
}

register_temp_file() {
    TEMP_FILES+=("$1")
}

trap cleanup_temp_files EXIT

normalize_output_path() {
    local path="$1"
    local parent
    local basename

    [ -n "$path" ] || die "path must not be empty"
    if [[ "$path" != /* ]]; then
        path="$ROOT_DIR/$path"
    fi

    parent="$(dirname "$path")"
    basename="$(basename "$path")"
    mkdir -p "$parent"
    printf '%s/%s\n' "$(cd "$parent" && pwd -P)" "$basename"
}

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

trim_markdown_body() {
    local input_path="$1"
    local output_path="$2"

    awk '
        {
            gsub(/\r$/, "")
            lines[++count] = $0
        }
        END {
            start = 1
            while (start <= count && lines[start] ~ /^[[:space:]]*$/) {
                start++
            }

            end = count
            while (end >= start && lines[end] ~ /^[[:space:]]*$/) {
                end--
            }

            for (i = start; i <= end; i++) {
                print lines[i]
            }
        }
    ' "$input_path" > "$output_path"
}

write_section_file() {
    local version="$1"
    local date="$2"
    local body_path="$3"
    local output_path="$4"

    {
        printf '## [%s]' "$version"
        if [ -n "$date" ]; then
            printf ' - %s' "$date"
        fi
        printf '\n\n'
        cat "$body_path"
        printf '\n'
    } > "$output_path"
}

ensure_changelog_exists() {
    if [ -f "$CHANGELOG_PATH" ]; then
        return
    fi

    printf '# Changelog\n\nAll notable changes to Hanzo are documented in this file.\n' > "$CHANGELOG_PATH"
}

fetch_draft_release_body() {
    local repo="$1"
    local output_path="$2"

    require_cmd gh

    gh api \
        -H "Accept: application/vnd.github+json" \
        "repos/$repo/releases" \
        --jq 'map(select(.draft and (.prerelease | not))) | .[0].body // ""' > "$output_path"
}

prepare_changelog() {
    local version="$1"
    local date="$2"
    local repo="$3"
    local body_file="$4"
    local draft_body_raw
    local draft_body_trimmed
    local section_file
    local output_file

    ensure_changelog_exists

    draft_body_raw="$(mktemp /tmp/hanzo-changelog-body.XXXXXX)"
    draft_body_trimmed="$(mktemp /tmp/hanzo-changelog-trimmed.XXXXXX)"
    section_file="$(mktemp /tmp/hanzo-changelog-section.XXXXXX)"
    output_file="$(mktemp /tmp/hanzo-changelog-output.XXXXXX)"
    register_temp_file "$draft_body_raw"
    register_temp_file "$draft_body_trimmed"
    register_temp_file "$section_file"
    register_temp_file "$output_file"

    if [ -n "$body_file" ]; then
        [ -f "$body_file" ] || die "Missing body file: $body_file"
        cp "$body_file" "$draft_body_raw"
    else
        [ -n "$repo" ] || repo="$(derive_repo_from_remote)"
        fetch_draft_release_body "$repo" "$draft_body_raw"
    fi

    trim_markdown_body "$draft_body_raw" "$draft_body_trimmed"

    if ! grep -q '[^[:space:]]' "$draft_body_trimmed"; then
        die "Draft release body is empty. Update the draft release or provide --body-file."
    fi

    write_section_file "$version" "$date" "$draft_body_trimmed" "$section_file"

    awk -v target="$version" -v section_file="$section_file" '
        function print_section(   line) {
            while ((getline line < section_file) > 0) {
                print line
            }
            close(section_file)
        }

        function parse_heading_version(line,   heading) {
            heading = line
            sub(/^## \[/, "", heading)
            sub(/\].*$/, "", heading)
            return heading
        }

        {
            lines[++line_count] = $0

            if ($0 ~ /^## \[/) {
                if (!first_heading) {
                    first_heading = line_count
                }

                if (target_start && !target_end) {
                    target_end = line_count - 1
                }

                if (parse_heading_version($0) == target) {
                    target_start = line_count
                }
            }
        }

        END {
            if (target_start && !target_end) {
                target_end = line_count
            }

            if (target_start) {
                for (i = 1; i < target_start; i++) {
                    print lines[i]
                }

                print_section()

                if (target_end < line_count) {
                    print ""
                }

                for (i = target_end + 1; i <= line_count; i++) {
                    print lines[i]
                }
            } else if (first_heading) {
                for (i = 1; i < first_heading; i++) {
                    print lines[i]
                }

                print_section()
                print ""

                for (i = first_heading; i <= line_count; i++) {
                    print lines[i]
                }
            } else {
                for (i = 1; i <= line_count; i++) {
                    print lines[i]
                }

                if (line_count > 0) {
                    print ""
                }

                print_section()
            }
        }
    ' "$CHANGELOG_PATH" > "$output_file"

    mv "$output_file" "$CHANGELOG_PATH"
}

extract_changelog() {
    local version="$1"
    local output_path="$2"
    local raw_output
    local trimmed_output

    [ -f "$CHANGELOG_PATH" ] || die "Missing CHANGELOG.md at $CHANGELOG_PATH"

    raw_output="$(mktemp /tmp/hanzo-changelog-extract.XXXXXX)"
    trimmed_output="$(mktemp /tmp/hanzo-changelog-extract-trimmed.XXXXXX)"
    register_temp_file "$raw_output"
    register_temp_file "$trimmed_output"

    if ! awk -v target="$version" '
        function parse_heading_version(line,   heading) {
            heading = line
            sub(/^## \[/, "", heading)
            sub(/\].*$/, "", heading)
            return heading
        }

        BEGIN {
            in_target = 0
            found = 0
        }

        {
            if ($0 ~ /^## \[/) {
                if (in_target) {
                    exit 0
                }

                if (parse_heading_version($0) == target) {
                    in_target = 1
                    found = 1
                    next
                }
            }

            if (in_target) {
                print
            }
        }

        END {
            if (!found) {
                exit 2
            }
        }
    ' "$CHANGELOG_PATH" > "$raw_output"; then
        status=$?
        if [ "$status" -eq 2 ]; then
            die "Version $version was not found in CHANGELOG.md"
        fi
        exit "$status"
    fi

    trim_markdown_body "$raw_output" "$trimmed_output"

    if ! grep -q '[^[:space:]]' "$trimmed_output"; then
        die "Version $version exists in CHANGELOG.md but has no release notes body"
    fi

    output_path="$(normalize_output_path "$output_path")"
    cp "$trimmed_output" "$output_path"
}

command="${1:-}"
[ -n "$command" ] || {
    usage
    exit 1
}
shift

case "$command" in
    extract)
        version=""
        output=""
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --version)
                    [ "$#" -ge 2 ] || die "Missing value for --version"
                    version="$2"
                    shift 2
                    ;;
                --output)
                    [ "$#" -ge 2 ] || die "Missing value for --output"
                    output="$2"
                    shift 2
                    ;;
                --help|-h)
                    usage
                    exit 0
                    ;;
                *)
                    die "Unknown argument for extract: $1"
                    ;;
            esac
        done

        [ -n "$version" ] || die "--version is required for extract"
        [ -n "$output" ] || die "--output is required for extract"
        extract_changelog "$version" "$output"
        ;;
    prepare)
        version=""
        date="$(date +%F)"
        repo=""
        body_file=""
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --version)
                    [ "$#" -ge 2 ] || die "Missing value for --version"
                    version="$2"
                    shift 2
                    ;;
                --date)
                    [ "$#" -ge 2 ] || die "Missing value for --date"
                    date="$2"
                    shift 2
                    ;;
                --repo)
                    [ "$#" -ge 2 ] || die "Missing value for --repo"
                    repo="$2"
                    shift 2
                    ;;
                --body-file)
                    [ "$#" -ge 2 ] || die "Missing value for --body-file"
                    body_file="$2"
                    shift 2
                    ;;
                --help|-h)
                    usage
                    exit 0
                    ;;
                *)
                    die "Unknown argument for prepare: $1"
                    ;;
            esac
        done

        [ -n "$version" ] || die "--version is required for prepare"
        prepare_changelog "$version" "$date" "$repo" "$body_file"
        ;;
    --help|-h|help)
        usage
        ;;
    *)
        die "Unknown command: $command"
        ;;
esac
