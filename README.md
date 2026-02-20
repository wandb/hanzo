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
./run.sh
```

This builds the project, assembles the `.app` bundle, and launches it. An onboarding wizard will guide you through granting permissions and entering your API key on first launch.

Hanzo runs in the menu bar — there is no dock icon.

## Other commands

| Command | Description |
|---|---|
| `swift build` | Build without launching |
| `swift test` | Run the test suite |
| `pkill -x Hanzo` | Kill the running app |

## Configuration

- **Hotkey** — Configurable in the app settings (default: Ctrl + Space)
- **ASR endpoint** — Configurable (default: `https://grunt.zain.aaronbatilo.dev`)
- **API key** — Stored securely in Keychain; set during onboarding
