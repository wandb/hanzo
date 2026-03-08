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

# 3. Allow direnv for this repo
direnv allow

# 4. Build and run
./dev-run.sh
```

This builds the project, assembles the `.app` bundle, and launches it. An onboarding wizard will guide you through granting permissions and setting up local runtime assets on first launch.

Hanzo runs in the menu bar — there is no dock icon.

## Other commands

| Command | Description |
|---|---|
| `swift build` | Build without launching |
| `swift test` | Run the test suite |
| `pkill -x Hanzo` | Kill the running app |

## Configuration

- **Hotkey** — Configurable in the app settings (default: Ctrl + Space)
- **ASR provider** — `Hosted` (default), `Local`, or `Custom Server`
- **Custom server endpoint + password** — Configurable in Settings when `Custom Server` is selected
