# Hanzo

macOS menu bar dictation app. Captures speech via global hotkey, transcribes locally by default, inserts transcribed text into the active app.

## Build & Run

- `./dev-run.sh` — kill running instance, rebuild and launch
- `./dev-run.sh --reset-models` — clear downloaded models before building
- `./dev-run.sh --reset-permissions` — reset Microphone & Accessibility permissions (useful for testing onboarding)
- `./dev-run.sh --reset-settings` — clear app UserDefaults (onboarding + preferences)
- `swift build` — build only
- `swift test` — run all tests
- XcodeGen (`project.yml`) exists for Xcode workflows but SPM via `dev-run.sh` is primary

## Architecture

Package split into two targets: `HanzoCore` (library) and `HanzoApp` (executable entry point).

- `HanzoApp/` — @main entry point only (HanzoApp.swift)
- `HanzoCore/App/` — AppDelegate (menu bar icon, windows)
- `HanzoCore/Orchestrator/` — DictationOrchestrator: coordinates record → transcribe → insert flow
- `HanzoCore/Services/` — ASRClient, AudioCaptureService, HotkeyService, TextInsertionService, PermissionService, LoggingService, LocalASRRuntimeManager
- `HanzoCore/Protocols/` — Service protocols for DI (ASRClientProtocol, AudioCaptureProtocol, TextInsertionProtocol, PermissionServiceProtocol, LoggingServiceProtocol, LocalASRRuntimeManagerProtocol)
- `HanzoCore/Models/` — AppState (@Observable with DictationState enum), TranscriptionSession
- `HanzoCore/Views/` — SwiftUI views; onboarding wizard in Views/Onboarding/
- `HanzoCore/Utilities/` — Constants (UserDefaults keys, audio params), ASRProvider, PartialTranscriptMerger
- `Tests/HanzoTests/` — Unit tests (Swift Testing framework)

## Code Style

- Swift 6.0 toolchain, `.v5` language mode, concurrency strictness: minimal
- `@Observable` macro (not ObservableObject)
- async/await throughout
- `// MARK: -` section dividers
- PascalCase filenames, one primary class per file
- No linter or formatter configured

## Dependencies

- HotKey (global hotkeys) — SPM
- KeychainAccess (secure storage) — XcodeGen only

## Tests

- `swift test` — run all tests
- `swift test --filter HanzoTests.AppStateTests` — run a specific test suite
- Framework: Swift Testing (`import Testing`)
- Tests use `@testable import HanzoCore`
- Mocks in `Tests/HanzoTests/Mocks/` — protocol-based fakes for all services
- ASRClient tests use `MockURLProtocol` to intercept HTTP requests
- DictationOrchestrator tests use mock services injected via init
- No hardware/permission dependencies in tests — all system boundaries are mocked
- CI: GitHub Actions runs `swift build` + `swift test` on PRs and pushes to main (`.github/workflows/test.yml`)

## External Service

- Optional custom ASR server (configurable endpoint in Settings)
- Streaming API: `/v1/stream/start` → `/v1/stream/chunk` → `/v1/stream/finish`
- Optional API key/password for custom server mode

## Permissions

- Microphone and Accessibility access required
- LSUIElement: true (menu bar only, no dock icon)
