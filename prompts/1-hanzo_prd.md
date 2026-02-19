# Hanzo

## Overview

Hanzo is a privacy-first, system-wide dictation tool for macOS.

It runs entirely on-device using a local speech-to-text model.

You press.  
You speak.  
Hanzo forges clean text into whatever app you’re using.

No cloud.  
No external APIs.  
No data leaving the machine.

---

## Target Environment

- Apple Silicon (M-series)
- macOS Tahoe+
- Single power-user (developer / designer)

Primary use cases:
- Writing emails
- Documents
- Notes
- Forms
- Light coding comments

---

## Problem

Built-in macOS dictation lacks transparency and control.  
Most high-quality transcription tools require sending audio to the cloud.

We want a fast, private, reliable dictation system that works anywhere text can be entered.

---

## Goals

Hanzo should:

1. Enable fast, reliable dictation anywhere on macOS via a global hotkey.
2. Deliver fully local, privacy-preserving speech-to-text.
3. Provide a focused, interruption-free writing experience.
4. Insert finalized transcription directly into the user’s active context.
5. Feel lightweight, responsive, and trustworthy on Apple Silicon.

---

## Non-Goals

- Live streaming transcription committed into apps while speaking.
- Multi-speaker diarization.
- Cloud sync or multi-device features.
- Meeting transcription workflows.
- Translation (v1 is speech-to-text only).

---

## Core UX

### Interaction Model

Hanzo uses a global toggle hotkey.

1. User presses the configured hotkey.
2. Recording begins immediately from the default microphone.
3. A centered HUD appears showing state: **Listening**.
4. A live preview displays the in-progress transcript in near real time.
5. User presses the hotkey again.
6. Recording stops instantly.
7. State changes to **Forging** (final transcription pass).
8. Once transcription completes, Hanzo inserts the finalized transcript into the previously focused app at the cursor position.
9. HUD disappears.

No incremental typing occurs during preview. Only a single insertion happens per session.

---

## Live Preview HUD

- Centered floating overlay.
- Always-on-top while active.
- Blocks interaction with underlying apps while recording or forging.
- Displays current state: Listening / Forging / Error.
- Streams partial transcript during recording.
- Escape key cancels recording and discards transcript.
- Switching apps during recording cancels and discards transcript.
- No transcript history is stored.

The HUD exists to provide clarity and trust — not decoration.

---

## Recording & Commit Rules

- Recording continues until the hotkey is pressed again or canceled.
- There is no silence-based auto-stop.
- On stop:
  - A full transcription pass completes.
  - The entire finalized transcript is inserted as a single operation.
- If no valid text field is focused at commit time:
  - Transcript is copied to clipboard instead.
- No formatting normalization or cleanup is applied in v1.
- Model output is trusted as-is.

---

## Text Insertion

- Insert at current cursor location.
- Preserve punctuation and whitespace.
- If transcript is empty, insert nothing.
- Commit uses paste-based insertion for near-instant output.
- Clipboard should be restored after insertion.
- Exactly one insertion per recording session.

---

## Model & Engine

Hanzo uses a local Whisper-based speech-to-text engine optimized for Apple Silicon. v1 supports English transcription only.

Implementation details:

- Engine: `whisper.cpp` (Metal-accelerated for Apple Silicon)
- Repository: https://github.com/ggml-org/whisper.cpp
- Default model: `small.en`
- Optional higher-accuracy model: `medium.en`

Rationale:

- High transcription accuracy for general dictation
- Strong performance on M-series Macs
- Fully offline operation
- Mature open-source ecosystem

Model execution is entirely local. No audio or transcripts leave the device.

---

## Privacy

- All processing is local.
- No network calls during dictation.
- Temporary audio files stored locally (e.g., `/tmp`).
- Temporary files automatically deleted after use.
- Local logs are stored for observability and troubleshooting.

---

## Configuration

User-configurable:

- Hotkey (default: `Ctrl + Option + H`)
- Whisper model selection (`tiny.en`, `base.en`, `small.en` [default], `medium.en`) — English-only models




---

## First-Run Experience

If dependencies or models are missing:

- Guide user to install required components.
- Guide user to download local model.
- Provide clear instructions for enabling:
  - Microphone permission
  - Accessibility permission

The setup experience should be direct and transparent.

---

## Performance Requirements

- Optimized for short-form dictation (3–20 seconds typical).
- Responsive on Apple Silicon.
- UI must remain fluid during transcription.
- Clear error handling for:
  - Missing permissions
  - Missing model
  - Microphone unavailable
  - Transcription failure

---

## Observability

Hanzo maintains local logs for troubleshooting and reliability.

Logs include:

- Timestamped state changes
- Errors
- Recording duration
- Transcription duration

Logs are always written locally (e.g., `~/Library/Logs/hanzo.log`).

No audio data is retained in logs.

---

## Success Criteria

Hanzo should:

- Work in Notes, Slack, Chrome text inputs, and VS Code.
- Successfully insert text in at least 9/10 normal dictation attempts.
- Require no internet connection after setup.
- Display a responsive live preview HUD.
- Perform exactly one insertion into the focused app per session.

---

## Future Enhancements (v2)

- Voice formatting commands ("new paragraph", "comma", etc.).
- Optional cleanup pass for capitalization and punctuation.
- Menu bar model switching.
- Local transcript history panel.
- Toggle vs hold mode preference.

---

## Design Tone

Hanzo should feel:

- Minimal
- Precise
- Quietly powerful
- Invisible when not in use

No gimmicks.  
No flash.  
Just steel.

---

## Deliverable

A working macOS application that satisfies the above requirements, with a clear README covering:

- Installation
- Configuration
- Permissions setup
- Troubleshooting

Hanzo should feel intentional, restrained, and built for one purpose.

