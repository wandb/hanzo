---
applyTo: "Tests/**/*.swift"
---

# Hanzo Test Instructions

- Use Swift Testing (`import Testing`) and existing repository patterns.
- Prefer protocol-based fakes/mocks in `Tests/HanzoTests/Mocks`.
- Do not add tests that depend on microphone, accessibility permission prompts, or other hardware/OS UI state.
- Do not call live network endpoints from tests; use request interception/mocking (for example `MockURLProtocol` patterns).
- Cover positive, failure, and fallback paths for behavior changes.
- Keep tests deterministic and fast; avoid time-based flakiness.
- For orchestrator changes, assert state transitions and side effects (record/transcribe/insert lifecycle).
