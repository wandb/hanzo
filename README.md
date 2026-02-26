# Hanzo

macOS menu bar dictation app. Press a hotkey, speak, and transcribed text is inserted into whatever app you're using.

Hanzo captures audio via a global hotkey (default: Ctrl + Space), streams it to a hosted ASR service, and pastes the result into the active application.

## Requirements

- macOS 15+
- Swift 6.0 toolchain
- Microphone permission
- Accessibility permission (for text insertion)

## Quick start

```sh
./dev-run.sh
```

This builds the project, assembles the `.app` bundle, and launches it. An onboarding wizard will guide you through granting permissions and setting up local runtime assets on first launch.

`dev-run.sh` supports build-time hosted server injection:

```sh
HANZO_HOSTED_SERVER_ENDPOINT="https://your-hosted-asr" \
HANZO_HOSTED_SERVER_PASSWORD="your-password" \
./dev-run.sh
```

For local development, you can also create `.env.build` (see `.env.build.example`).
`dev-run.sh` auto-loads `.env.build` when present.

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
