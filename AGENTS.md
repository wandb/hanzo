# Hanzo

macOS menu bar dictation app. Captures speech via global hotkey, transcribes locally by default, inserts transcribed text into the active app.

## Audience & Product Direction

- Primary audience is technical developers.
- Local-first operation is a core value: default to local transcription and local rewrite when possible.
- Users may run their own models and tune runtime parameters (for example, model/context settings) to trade off memory, latency, and quality.
- External ASR is optional and should be treated as an explicit opt-in.

## Build & Run

- `./scripts/dev-run.sh` — kill running instance, rebuild and launch
- `./scripts/dev-run.sh --reset-models` — clear downloaded models before building
- `./scripts/dev-run.sh --reset-permissions` — reset Microphone & Accessibility permissions (useful for testing onboarding)
- `./scripts/dev-run.sh --reset-settings` — clear app UserDefaults (onboarding + preferences)
- `./scripts/release-unsigned.sh` — build unsigned distribution artifacts into `dist/`
- `./scripts/version.sh show` — print current app version/build from `HanzoCore/Info.plist`
- `./scripts/version.sh bump-build` — increment app build number
- `swift build` — build only
- `swift test` — run all tests
- XcodeGen (`project.yml`) exists for Xcode workflows but SPM via `scripts/dev-run.sh` is primary

## Architecture

Package split into two targets: `HanzoCore` (library) and `HanzoApp` (executable entry point).

- `HanzoApp/` — @main entry point only (HanzoApp.swift)
- `HanzoCore/App/` — AppDelegate (menu bar icon, windows)
- `HanzoCore/Orchestrator/` — DictationOrchestrator: coordinates record → transcribe → insert flow
- `HanzoCore/Services/` — ASRClient, AudioCaptureService, HotkeyService, TextInsertionService, PermissionService, LoggingService, LocalASRRuntimeManager, LocalLLMRuntimeManager, LocalWhisperASRClient, LocalWhisperRuntime
- `HanzoCore/Protocols/` — Service protocols for DI (ASRClientProtocol, AudioCaptureProtocol, TextInsertionProtocol, PermissionServiceProtocol, LoggingServiceProtocol, LocalASRRuntimeManagerProtocol, LocalLLMRuntimeManagerProtocol)
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
- WhisperKit (local ASR runtime/client) — SPM
- Sparkle (app updates) — SPM

## Tests

- `swift test` — run all tests
- `swift test --filter HanzoTests.AppStateTests` — run a specific test suite
- Framework: Swift Testing (`import Testing`)
- Tests use `@testable import HanzoCore`
- Mocks in `Tests/HanzoTests/Mocks/` — protocol-based fakes for all services
- ASRClient tests use `MockURLProtocol` to intercept HTTP requests
- DictationOrchestrator tests use mock services injected via init
- No hardware/permission dependencies in tests — all system boundaries are mocked
- CI: GitHub Actions runs `swift build --disable-keychain` + `swift test --disable-keychain` on PRs and pushes to main (`.github/workflows/test.yml`)

## Instruction Maintenance

- Keep Copilot/custom instruction files stable by default.
- Do not update instruction files on every feature or bugfix.
- Update instruction files only when there is a durable repo-wide policy change (for example: required test patterns, architecture constraints, PR/review standards) or when explicitly requested.
- When changing silence/auto-close logic in `DictationOrchestrator`, update or add regression coverage in `Tests/HanzoTests/DictationOrchestratorTests.swift` for ambient-noise behavior and timing robustness.

## External Service

- Optional custom ASR server (configurable endpoint in Settings)
- Streaming API: `/v1/stream/start` → `/v1/stream/chunk` → `/v1/stream/finish`
- Optional API key/password for custom server mode

## Security Considerations

- Keep local ASR/rewrite as the default path; external ASR is explicit opt-in only.
- Do not hardcode API keys or passwords in source, tests, or prompts.
- Prefer Keychain-backed storage for credentials and redact secrets from logs.
- Treat custom ASR endpoints as untrusted input; validate configuration and prefer HTTPS for non-local endpoints.
- Never require real microphone/accessibility permissions in automated tests; continue using mocked boundaries.

## Permissions

- Microphone and Accessibility access required
- LSUIElement: true (menu bar only, no dock icon)
