# Hanzo Copilot Instructions

Hanzo is a macOS menu bar dictation app for technical users. Keep behavior local-first by default and treat external ASR as explicit opt-in.

## Product Priorities

- Preserve the record -> transcribe -> insert flow without adding extra user steps.
- Keep local transcription and local rewrite as defaults when available.
- Do not make remote/custom ASR the default path.
- Maintain permission-sensitive behavior for Microphone and Accessibility.
- Preserve menu bar app behavior (`LSUIElement: true`).

## Architecture Rules

- Keep `HanzoApp/` focused on `@main` bootstrapping only.
- Put app logic in `HanzoCore`, especially `DictationOrchestrator` and services.
- Prefer protocol-based dependency injection via `HanzoCore/Protocols`.
- Keep system boundaries (audio capture, hotkeys, insertion, permissions, network) inside services.
- Avoid coupling UI code directly to service internals.

## Swift Conventions

- Target Swift 6 style and current package settings.
- Use `@Observable` (not `ObservableObject`) for observable app models.
- Prefer async/await and avoid blocking the main thread.
- Use `// MARK: -` section headers.
- Keep PascalCase filenames and one primary type per file.

## Testing Expectations

- Add or update tests for behavior changes.
- Use Swift Testing conventions in this repo (`import Testing`).
- Prefer protocol mocks from `Tests/HanzoTests/Mocks`.
- Keep tests deterministic and independent of OS permissions/hardware.

## Review Priorities

- Permission-flow regressions (onboarding, denied/re-request flows).
- Dictation state machine and cleanup regressions.
- Text insertion reliability and active-app targeting.
- Local ASR runtime setup, model lifecycle, and fallback behavior.
- Streaming API integration correctness (`/v1/stream/start`, `/v1/stream/chunk`, `/v1/stream/finish`).
