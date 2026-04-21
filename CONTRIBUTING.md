# Contributing to Hanzo

Hanzo is a local-first macOS dictation app. Before opening a pull request, run the local checks below and skim `AGENTS.md` for architectural conventions.

## Before Opening a PR

Run from the repo root:

```sh
swift build --disable-keychain
swift test --disable-keychain
swiftformat --lint .
```

All three must pass. CI runs the same checks on macOS 15.

## Local Setup

See `README.md` (Developer Guide → Quick Start). In short: install `direnv`, set up `~/.config/hanzo/.env.build`, run `direnv allow`, then `./scripts/dev-run.sh`.

## Code Style

- Swift 6.0 toolchain, `.v5` language mode, concurrency strictness: minimal.
- `@Observable` macro (not `ObservableObject`).
- async/await throughout.
- `// MARK: -` section dividers.
- PascalCase filenames, one primary class per file.
- Formatting enforced by SwiftFormat (`.swiftformat` checked in at repo root). Install locally with `brew install swiftformat`. To auto-fix: `swiftformat .`.

## Tests

- Framework: Swift Testing (`import Testing`).
- Mocks in `Tests/HanzoTests/Mocks/` — protocol-based fakes. No hardware/permission dependencies in tests; all system boundaries mocked.
- When changing silence/auto-close logic in `DictationOrchestrator`, update or add regression coverage in `Tests/HanzoTests/DictationOrchestratorTests.swift`.
- Run a single suite: `swift test --filter HanzoTests.AppStateTests`.

## Security

- Never hardcode API keys, passwords, or server URLs in source, tests, or prompts.
- Local ASR and local rewrite are the default path. External ASR is explicit opt-in only.
- Prefer Keychain-backed storage for credentials; redact secrets from logs.

## Agent Notes

If you are an AI agent working in a Conductor workspace, there is also a gitignored `.context/notes.md` for durable cross-session notes. See `docs/TEST-MAP.md` for component-level test categorization.
