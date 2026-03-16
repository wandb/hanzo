# Hanzo

macOS menu bar dictation app. Press a hotkey, speak, and transcribed text is inserted into whatever app you're using.

Hanzo captures audio via a global hotkey (default: Ctrl + Space), streams it to a hosted ASR service, and pastes the result into the active application.

## Requirements

- macOS 15+
- Swift 6.0 toolchain
- [direnv](https://direnv.net/) (`brew install direnv`) — manages build-time env vars
- Microphone permission
- Accessibility permission (for text insertion)

## Quick start

```sh
# 1. Install direnv and hook it into your shell
brew install direnv
# Add the direnv hook to your shell profile — see https://direnv.net/docs/hook.html

# 2. Set up build secrets (shared across git worktrees)
mkdir -p ~/.config/hanzo
cp .env.build.example ~/.config/hanzo/.env.build
# Edit ~/.config/hanzo/.env.build with your values
# Optional: set HANZO_LLAMA_SERVER_PATH if you want to use a specific local llama-server

# 3. Allow direnv in this worktree (run once per worktree)
direnv allow

# 4. Build and run
./dev-run.sh
```

This builds the project, assembles the `.app` bundle at `~/.local/share/hanzo/Hanzo.app`, and launches it. The fixed bundle path ensures macOS retains permissions across git worktrees. An onboarding wizard will guide you through granting permissions and preparing the on-device Whisper model on first launch.

`dev-run.sh` also bundles the local LLM runtime (`llama-server` + dylibs). If no local runtime is found, it auto-downloads a pinned llama.cpp macOS arm64 release into `~/.cache/hanzo/llama.cpp/` and reuses it on subsequent runs.

Hanzo runs in the menu bar — there is no dock icon.

## Other commands

| Command | Description |
|---|---|
| `./dev-run.sh --reset-models` | Clear downloaded models before building |
| `./dev-run.sh --reset-permissions` | Reset Microphone & Accessibility permissions (useful for testing onboarding) |
| `./dev-run.sh --no-launch` | Build and assemble the app bundle without launching it |
| `swift build` | Build without launching |
| `swift test` | Run the test suite |
| `pkill -x Hanzo` | Kill the running app |

## Configuration

- **Hotkey** — Configurable in the app settings (default: Ctrl + Space)
- **ASR provider** — `Hosted` (default), `Local (Whisper)`, or `Custom Server`
- **Custom server endpoint + password** — Configurable in Settings when `Custom Server` is selected
- **App-specific behavior** — Configure per-app auto-submit and silence timeout overrides (global values remain fallback defaults)
- **Local model** — Uses `base.en` from `argmaxinc/whisperkit-coreml`, downloaded on first use
- **Local LLM post-processing** — Uses bundled `llama-server` + `Qwen3-4B-Q4_K_M.gguf` (downloaded on first use)

## Example Servers

- `reference/` includes the hosted-compatible Qwen3 reference server for Custom Server mode
- `LocalASRHelper/` remains an example local Qwen3 server helper for users who want to run their own runtime
