# Changelog

All notable changes to Hanzo are documented in this file.

## [1.5.0] - 2026-04-21

- Add setting to Mute system audio output during dictation (#77) @adamwdraper
- Internal code-health refactor by Opus 4.7 to improve app reliability, code quality, and test coverage (#77) @adamwdraper

## [1.4.0] - 2026-04-14

- Add new HUD "standard" display mode (#75) @adamwdraper
- Harden LLM rewrite prompt to ensure transcription (#74) @adamwdraper
- Ensure even short audio clips get transcribed fully (#73) @adamwdraper

## [1.3.0] - 2026-04-08

- Refine text insertion fallbacks (#72) @adamwdraper
- Send rewrite transcript as user message (#71) @adamwdraper
- Add insert failure fallback and recent dictation history (#70) @adamwdraper
- Reorder and align General settings controls (#69) @adamwdraper
- Refactor settings persistence behind typed store (#68) @adamwdraper
- Add compact HUD display mode (#67) @adamwdraper


## [1.2.0] - 2026-04-04

- Use app picker to add custom app settings (#64) @adamwdraper
- Add hold-to-dictate hotkey flow (#63) @adamwdraper
- Fix stats formatting and shared word count (#62) @adamwdraper
- Add vanity usage stats cards to Settings (#61) @adamwdraper
- Add changelog-driven release notes and What's New (#60) @adamwdraper
- Major decrease in idle memory usage by warming rewrite model on demand (#59) @adamwdraper
- Upgrade Whisper (#59) @adamwdraper
- Filter non-speech artifacts from HUD and final transcripts (#58) @adamwdraper
- Add demo GIF and rearrange README hero section (#57) @adamwdraper


## [1.1.1] - 2026-04-04

### Highlights

- Continued local-first dictation defaults, with local Whisper transcription and local rewrite enabled by default.
- Expanded app-specific rewrite controls, including global defaults plus per-app instruction overrides and vocabulary.
- Kept Sparkle-based direct-download updates as the supported release path for signed macOS builds.

