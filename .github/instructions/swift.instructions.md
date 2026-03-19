---
applyTo: "HanzoApp/**/*.swift,HanzoCore/**/*.swift,LocalASRHelper/**/*.swift"
---

# Hanzo Swift Source Instructions

- Keep `HanzoApp` minimal; place business logic in `HanzoCore`.
- When changing orchestration logic, preserve clear state transitions in `DictationOrchestrator`.
- Prefer protocol abstractions and constructor injection for cross-service dependencies.
- Keep local-first behavior as the default experience.
- Treat custom/remote ASR as opt-in and preserve existing provider selection semantics.
- Respect concurrency boundaries; avoid blocking the main actor during audio/transcription work.
- Keep user-visible behavior stable around hotkeys, recording lifecycle, and text insertion.
- If settings or defaults change, update constants and migration/default handling consistently.
