# Hanzo

## Overview

Hanzo is a system-wide dictation tool for macOS.

It captures speech and sends audio to a dedicated Qwen3-ASR service for transcription.

You press.
You speak.
Hanzo forges clean text into whatever app you’re using.

Transcription is handled by a hosted ASR service operated by us. See the Privacy section below for details on data handling.

---

## Target Environment

* Apple Silicon (M-series)
* macOS Tahoe+
* Single power-user (developer / designer)

Primary use cases:

* Writing emails
* Documents
* Notes
* Forms
* Light coding comments

---

## Problem

Built-in macOS dictation lacks transparency and control.
Most high-quality transcription tools are either opaque or tightly coupled to specific platforms.

We want a fast, reliable dictation system that works anywhere text can be entered, with a clearly defined and controllable transcription backend.

---

## Goals

Hanzo should:

1. Enable fast, reliable dictation anywhere on macOS via a global hotkey.
2. Deliver secure, reliable speech-to-text via a dedicated hosted ASR service.
3. Provide a focused, interruption-free writing experience.
4. Insert finalized transcription directly into the user’s active context.
5. Feel lightweight, responsive, and trustworthy on Apple Silicon.

---

## Non-Goals

* Live streaming transcription committed into apps while speaking.
* Multi-speaker diarization.
* Cloud sync or multi-device features.
* Meeting transcription workflows.
* Translation (v1 is speech-to-text English only).

---

## Core UX

### Interaction Model

Hanzo runs exclusively as a **menu bar application**, surfaced via a global hotkey and without any Dock presence or windowed mode.

Hanzo uses a global toggle hotkey.

1. User presses the configured hotkey.
2. Recording begins immediately from the default microphone.
3. The menu bar icon updates to indicate state: Listening.
4. A lightweight popover can display the in-progress transcript in near real time.
5. User presses the hotkey again.
6. Recording stops instantly.
7. State changes to Forging (final transcription pass).
8. Once transcription completes, Hanzo inserts the finalized transcript into the previously focused app at the cursor position.
9. Any open popover closes.

No incremental typing occurs during preview. Only a single insertion happens per session.

---

## Live Preview UI

Hanzo does not use a full-screen or centered HUD.

* Primary state indicator lives in the menu bar icon.
* Icon states: Idle / Listening / Forging / Error.
* A popover anchored to the menu bar icon automatically opens when recording begins to display the live transcript preview.
* The popover blocks interaction with other apps while recording or forging.
* Escape key cancels recording and discards transcript.
* Switching away from Hanzo (changing active application) immediately cancels the session and discards the transcript.
* No transcript history is stored.

The popover automatically opens when recording starts and closes automatically after commit or cancellation.

The UI should remain minimal and unobtrusive.

---

## Recording & Commit Rules

* Recording continues until the hotkey is pressed again or canceled.
* There is no silence-based auto-stop.
* On stop:

  * A full transcription pass completes.
  * The entire finalized transcript is inserted as a single operation.
* If no valid text field is focused at commit time:

  * Transcript is copied to clipboard instead.
* No formatting normalization or cleanup is applied in v1.
* Model output is trusted as-is.

---

## Text Insertion

* Insert at current cursor location.
* Preserve punctuation and whitespace.
* If transcript is empty, insert nothing.
* Commit uses paste-based insertion for near-instant output.
* Clipboard should be restored after insertion.
* Exactly one insertion per recording session.

---

## Model & Engine

Hanzo uses a hosted ASR service built on **Qwen3-ASR** with a vLLM-backed runtime for low-latency transcription and streaming preview.

* Model: `Qwen/Qwen3-ASR-1.7B`
* Server framework: FastAPI
* Runtime: Qwen3ASRModel `LLM(...)` (vLLM-backed)

### Streaming API (used for HUD preview)

Hanzo’s HUD preview is powered by the server’s streaming session endpoints:

* `POST /v1/stream/start` → returns `{ session_id }`
* `POST /v1/stream/chunk?session_id=...` → returns partial `{ text, language }`

  * Chunk payload: raw **float32 PCM mono** (little-endian)
* `POST /v1/stream/finish?session_id=...` → returns final `{ text, language }`

### Batch API (optional)

* `POST /v1/transcribe` for one-shot transcription of an uploaded audio file

### Language

v1 is **English-only** for the product experience.

* No language UI.
* The client requests/assumes English.

### Why this approach

* High transcription quality
* Supports real-time preview via streaming sessions
* Centralized hosted inference for simplified deployment and updates

---

## Privacy

* Audio is transmitted to the configured ASR service over HTTPS (TLS).
* The ASR service is operated by us; no third-party APIs are used.
* Audio is processed for transcription and is not stored after processing.
* Hanzo does not persist audio locally after a session completes.

---

## Configuration

User-configurable:

* Hotkey (default: `Ctrl + Option + H`)
* ASR server endpoint (default: `https://grunt.zain.aaronbatilo.dev`)
* API key for ASR service (required)

API Key Handling:

* Users paste their API key into Hanzo settings.
* The API key is stored securely using macOS Keychain.
* The API key is never hardcoded in source code or committed to configuration files.

---

## First-Run Experience

On first launch, Hanzo presents a short, guided onboarding flow:

### Step 1 — Microphone Permission

* Screen explains why microphone access is required.
* User taps **Enable Microphone**.
* Hanzo triggers the macOS system permission prompt.
* Once granted, the flow automatically advances.

### Step 2 — Accessibility Permission

* Screen explains that Accessibility access is required to insert text into other apps.
* User taps **Open System Settings**.
* Hanzo directs the user to the correct macOS panel.
* UI confirms when Accessibility permission is enabled.

### Step 3 — Hotkey Confirmation

* Screen displays the default hotkey (e.g., `Ctrl + Option + H`).
* Brief explanation of toggle behavior.
* User taps **Done** to complete onboarding.

No model downloads or local setup steps are required.

The onboarding should be minimal, clear, and complete in under 30 seconds.

---

## Performance Requirements

* Optimized for short-form dictation (3–20 seconds typical).
* Responsive on Apple Silicon.
* UI must remain fluid during transcription.

Latency Targets (under typical network conditions):

* Streaming preview update cadence: ≤ 700ms between partial updates.
* Final commit latency (hotkey press to text insertion): ≤ 1.5s for typical 5–10 second dictation.

Clear error handling for:

* Missing permissions
* Server unavailable
* Authentication failure
* Transcription failure

---

## Observability

Hanzo maintains client-side logs for troubleshooting and reliability.

Client logs include:

* Timestamped state changes (Listening, Forging, Insert)
* Errors
* Recording duration
* Transcription latency (round-trip time)

Logs are written locally (e.g., `~/Library/Logs/hanzo.log`).

The ASR server is assumed to maintain its own operational logs separately.

No audio data is retained in client logs.

---

## Success Criteria

Hanzo should:

* Work in Notes, Slack, Chrome text inputs, and VS Code.
* Successfully insert text in at least 9/10 normal dictation attempts.
* Operate reliably when network connectivity to the ASR service is available.
* Display a responsive live preview HUD.
* Perform exactly one insertion into the focused app per session.

---

## Future Enhancements (v2)

* Voice formatting commands ("new paragraph", "comma", etc.).
* Optional cleanup pass for capitalization and punctuation.
* Menu bar model switching.
* Local transcript history panel.
* Toggle vs hold mode preference.

---

## Design Tone

Hanzo should feel:

* Minimal
* Precise
* Quietly powerful

---

## Deliverable

A working macOS application that satisfies the above requirements, with a clear README covering:

* Installation
* Configuration
* Permissions setup
* Troubleshooting

Hanzo should feel intentional, restrained, and built for one purpose.
