# Hanzo

<p align="center">
  <img src="HanzoCore/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" alt="Hanzo logo" width="128" />
</p>

Typing is too slow when you are driving coding agents all day. Dictation is faster, but most voice tools send your raw speech to third-party servers.

Hanzo keeps that workflow local: what you say stays on your laptop, transcribed with local Whisper, rewritten with a local model, and customized per-app before insertion.

Requires an Apple Silicon Mac running macOS 15+.

[![Download](https://img.shields.io/github/v/release/wandb/hanzo?label=Download&style=for-the-badge)](https://github.com/wandb/hanzo/releases/latest)

## Why Hanzo

- **Faster than typing** — dictation is the quickest way to drive coding agents and chat tools.
- **Private by default** — audio and transcripts stay on your Mac. Nothing is sent to any server unless you explicitly enable a custom endpoint.
- **Smart per-app output** — different rewrite behavior for terminals, editors, Slack, ChatGPT, and more.
- **Configurable** — tune silence timeout, auto-submit, global rewrite style, and domain-specific vocabulary.

## How It Works

1. Press your hotkey (`Ctrl + Space` by default) to start recording.
2. Hanzo transcribes locally with Whisper.
3. A local rewrite model polishes the transcript for the active app.
4. The final text is inserted at your cursor, with optional auto-submit.

---

## Developer Guide

If you want to build, fork, or contribute, everything below is for you.

### Requirements

- Apple Silicon Mac, macOS 15+
- Swift 6.0 toolchain
- [direnv](https://direnv.net/) (`brew install direnv`)
- Microphone and Accessibility permissions

### Quick Start

```sh
# 1. Install direnv and hook it into your shell
brew install direnv
# Add the direnv hook to your shell profile — https://direnv.net/docs/hook.html

# 2. Set up shared build env file (works across git worktrees)
mkdir -p ~/.config/hanzo
cp .env.build.example ~/.config/hanzo/.env.build
# Optional: set overrides in ~/.config/hanzo/.env.build (for example HANZO_LLAMA_SERVER_PATH)

# 3. Allow direnv in this worktree (run once per worktree)
direnv allow

# 4. Build and launch
./scripts/dev-run.sh
```

This builds and launches `~/.local/share/hanzo/Hanzo Dev.app` (bundle id `com.hanzo.app.dev`). The fixed bundle path lets macOS retain permissions across worktrees.

The dev script bundles local LLM runtime binaries (`llama-server` + dylibs). If not found locally, it downloads a pinned `llama.cpp` release into `~/.cache/hanzo/llama.cpp/`.

### Commands

| Command | Description |
|---|---|
| `./scripts/dev-run.sh` | Build and launch |
| `./scripts/dev-run.sh --reset-models` | Clear downloaded models before building |
| `./scripts/dev-run.sh --reset-permissions` | Reset Microphone and Accessibility permissions |
| `./scripts/dev-run.sh --reset-settings` | Clear app UserDefaults |
| `./scripts/dev-run.sh --no-launch` | Build and assemble without launching |
| `swift build --disable-keychain` | Build only |
| `swift test --disable-keychain` | Run all tests |
| `./scripts/version.sh show` | Print current version and build number |
| `./scripts/version.sh bump-build` | Increment build number |
| `./scripts/release-unsigned.sh` | Build unsigned DMG/ZIP into `dist/` |

### Local Models

- **ASR (default):** WhisperKit `base.en` from `argmaxinc/whisperkit-coreml`
- **Rewrite (default):** `Qwen3-4B-Q4_K_M.gguf` via bundled `llama-server`
- **Custom ASR:** optional server endpoint + password, configured in Settings

### Distribution

See `docs/RELEASING.md` for signing, notarization, and Sparkle update setup.

```sh
# Unsigned local release
./scripts/version.sh bump-build
./scripts/release-unsigned.sh

# Signed + notarized
./scripts/version.sh bump-build
./scripts/release.sh
```

### Example Servers

- `reference/` — Qwen3 reference server for Custom Server mode
- `LocalASRHelper/` — example local Qwen3 helper runtime
