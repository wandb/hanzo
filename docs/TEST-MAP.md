# DictationOrchestratorTests Component Map

`Tests/HanzoTests/DictationOrchestratorTests.swift` currently holds 99 tests in a single 2,456-line suite covering behaviors that will be owned by separate collaborators after the Phase 2 orchestrator split. This map categorizes each test by the collaborator it should live with after the split, so moving them is mechanical rather than a judgment call.

Categories:

- **SilenceDetector** — ambient-noise calibration, speech-band energy thresholds, auto-close timing. Will take `ClockProtocol` via init.
- **HotkeySessionController** — tap vs hold state machine, quick-release semantics.
- **AudioChunkStreamer** — chunk-send cadence, session epochs, late-chunk ignore, trailing chunk merge.
- **RuntimeCoordinator** — prewarm/abort/shutdown lifecycle for ASR + LLM runtimes.
- **TranscriptFinalizer** (new, implied by the LLM post-processing cluster) — post-processing/rewrite flow, divergence threshold, fallback to raw transcript.
- **OrchestratorIntegration** — true end-to-end record→transcribe→insert smoke tests that should remain at the orchestrator level even after the split. Also covers cross-collaborator interactions (e.g., silence suspension while hotkey held).

Tests that touch the existing `TranscriptArtifactFilter` or `PartialTranscriptMerger` stay as orchestrator integration tests — they exercise how the orchestrator uses those utilities, not the utilities themselves (which have their own dedicated test files).

## Test → Component Mapping

### SilenceDetector
| Line | Test |
|---|---|
| 1781 | Silence auto-close triggers after timeout |
| 1830 | Silence auto-close waits for sustained quiet before arming the countdown |
| 1861 | Silence auto-close triggers despite steady ambient noise |
| 1887 | Silence auto-close still triggers when quiet baseline is high relative to speech peak |
| 1913 | Silence auto-close ignores low-frequency rumble that lacks speech-band energy |
| 1938 | Silence auto-close is not excessively delayed by ambient jitter |
| 1968 | Silence auto-close ignores borderline ambient bumps |
| 1998 | Silence auto-close does not trigger before speech |
| 2016 | Silence timer resets when speech resumes |
| 2045 | Transcript growth during quiet does not indefinitely delay silence auto-close |
| 2085 | Silence auto-close does not trigger while low-energy moving speech continues |
| 2125 | Low-dominance moving speech keeps the session alive after transcript content goes stale |
| 2166 | Continuation audio clears a running silence timer when motion resumes |
| 2224 | Silence auto-close still triggers during low-level noise despite repeated identical partials |
| 2266 | Silence auto-close still triggers during steady fan-like noise |
| 2310 | Moving low-energy broadband audio stays alive while steady low-energy broadband closes |
| 2375 | Silence auto-close stays within the configured motion linger bound |
| 2412 | Silence auto-close does not trigger with audio but no transcription |
| 2434 | Silence auto-close disabled when timeout is 0 |

### HotkeySessionController
| Line | Test |
|---|---|
| 443 | Quick hotkey release keeps the session running as tap mode |
| 459 | Hotkey release after the hold threshold stops recording |
| 474 | Second hotkey press still stops a tap session immediately |

### AudioChunkStreamer
| Line | Test |
|---|---|
| 670 | Audio chunk below threshold does not trigger sendChunk |
| 683 | Audio chunks accumulate and trigger sendChunk at threshold |
| 696 | Audio chunk send uses correct session ID |
| 709 | Chunk response updates partialTranscript |
| 1141 | Stopping merges trailing buffered chunk response into partialTranscript |
| 1167 | Late chunk response from previous session is ignored |
| 1752 | Audio levels callback updates appState.audioLevels |
| 1764 | audioLevels resets to empty after cancel |

### RuntimeCoordinator
| Line | Test |
|---|---|
| 237 | Init does not prewarm LLM when permissions are granted |
| 257 | shutdown() stops local runtimes asynchronously |
| 273 | shutdownAndWait() stops local runtimes synchronously |
| 307 | toggle() from idle warms local LLM when LLM mode is enabled |
| 1648 | Cancelling a listening LLM session cools the local LLM runtime |

### TranscriptFinalizer (LLM post-processing)
| Line | Test |
|---|---|
| 1384 | Final transcript is unchanged when post-processing mode is off |
| 1407 | Final transcript uses LLM post-processing output when mode is LLM |
| 1465 | LLM mode passes global common terms to local rewrite |
| 1491 | Unsupported apps fall back to global rewrite variables without leaking previous app state |
| 1559 | LLM mode falls back to raw transcript when local LLM processing fails |
| 1587 | LLM mode falls back to raw transcript when local LLM processing times out |
| 1615 | LLM mode falls back to raw transcript when rewrite diverges from input |

### OrchestratorIntegration (stays at orchestrator level)
These are true state-machine / end-to-end tests or cross-collaborator interactions:

| Line | Test |
|---|---|
| 179 | Initial state is idle |
| 185 | Init loads recent dictation history into app state |
| 202 | copyRecentDictation copies selected history text to clipboard |
| 219 | clearRecentDictations clears store and app state history |
| 284 | toggle() from idle sets state to listening when mic permission granted |
| 291 | toggle() from idle starts ASR session |
| 299 | toggle() from idle starts audio capture |
| 330 | toggle() from idle sets isPopoverPresented to true |
| 337 | toggle() from idle transitions to error when mic permission denied |
| 345 | toggle() from idle is ignored when onboarding blocks dictation start |
| 362 | toggle() transitions to error state when ASR start fails |
| 372 | toggle() transitions to error state when audio capture fails |
| 384 | toggle() from listening transitions to forging |
| 394 | toggle() from listening stops audio capture |
| 403 | Transcript remains visible while forging until HUD dismissal |
| 492 | Silence auto-close is suspended while the hotkey is held (SilenceDetector ↔ HotkeySessionController) |
| 512 | Silence auto-close resumes after a quick hotkey release (SilenceDetector ↔ HotkeySessionController) |
| 558 | toggle() from forging state is ignored |
| 572 | toggle() from error resets to idle |
| 584 | cancel() from listening resets state |
| 594 | cancel() during forging does not transition to error |
| 638 | cancel() clears partialTranscript |
| 649 | cancel() stops audio capture |
| 658 | cancel() hides popover |
| 724 | Leading non-speech marker detection matches only whole-response markers |
| 735 | Leading marker-only partials do not update the visible transcript |
| 749 | Mixed partials strip known markers before updating the HUD transcript |
| 762 | Parenthetical-only partials do not update the visible transcript |
| 776 | Annotation-only partial sequences do not update the visible transcript |
| 790 | Asterisk annotation-only partials do not update the visible transcript |
| 804 | Bracket-only partials do not update the visible transcript |
| 818 | Partials strip trailing parenthetical annotations while preserving spoken text |
| 836 | Leading marker-only sessions do not arm auto-close (TranscriptArtifactFilter ↔ SilenceDetector) |
| 860 | First real speech after leading markers appears normally |
| 890 | Marker-only packets after real speech do not regress visible transcript |
| 911 | Parenthetical-only packets after real speech do not regress visible transcript |
| 932 | Asterisk annotation-only packets after real speech do not regress visible transcript |
| 953 | Bracket-only packets after real speech do not regress visible transcript |
| 974 | Manual stop on a leading marker-only final inserts nothing |
| 1003 | Manual stop on marker-only final inserts nothing even after speech appears in the HUD |
| 1025 | Manual stop inserts mixed final transcript after stripping known markers |
| 1045 | Manual stop on annotation-only final inserts nothing |
| 1067 | Manual stop on asterisk annotation-only final inserts nothing |
| 1089 | Manual stop on bracket-only final inserts nothing |
| 1111 | Manual stop strips trailing parenthetical annotations from final transcript before insertion |
| 1211 | finishStream is called with correct session ID when stopping |
| 1224 | State returns to idle after successful stop |
| 1237 | finishStream failure transitions to error state |
| 1252 | Successful insertion records recent history with inserted outcome |
| 1278 | Insertion failure copies to clipboard and stores failed history |
| 1306 | No target app triggers failure fallback and stores failed history |
| 1337 | Activation failure triggers fallback without paste attempt |
| 1364 | Empty final transcript does not append recent history |
| 1678 | Enter auto-submit runs only after text insertion completes |
| 1702 | Cmd+Enter auto-submit runs only after text insertion completes |
| 1726 | State stays forging until insertion and submit complete |

## Coverage Gaps Flagged During Audit

These invariants are NOT currently covered by a dedicated test and should be filled in Phase 0.3:

1. **Rewrite divergence exact boundary.** The orchestrator rewrites-or-falls-back around `rewriteDivergenceThreshold = 0.2` with `rewriteDivergenceMinWords = 5` (`DictationOrchestrator.swift:1015-1016`). Test 1615 exercises divergence-triggers-fallback, but there is no test that exercises the *non*-divergent case at the boundary (e.g., 0.19 divergence below the threshold, short transcript below the min-words gate). Adds: one below-threshold accept, one below-min-words accept.

2. **Fire-and-forget Task failure logging.** Prewarm and abort tasks (`DictationOrchestrator.swift:131, 333, 415, 806, 848`) currently swallow errors entirely. Phase 3 will introduce a logged wrapper — add a baseline test now that asserts the MockLogger captures the right message when a mock runtime throws during prewarm. This locks in the expectation that the Phase 3 helper preserves.

3. **RecentDictationStore ordering.** Several insertion-path tests (lines 1252, 1278, 1306, 1337) assert that history is recorded, but none asserts the *ordering* relative to text insertion completion — if an agent refactors and records history *before* insertion finishes, it silently breaks no test. Add: assert `MockRecentDictationStore.recordedAt` happens after `MockTextInsertionService.insertCompletedAt`.

4. **TestClock determinism sanity.** After Phase 0.2 lands, add one test that advances the `TestClock` across an interval straddling multiple silence thresholds in a single step and asserts the final state matches advancing in small increments — this proves the Clock injection does not introduce temporal drift.

## Notes for the Phase 2 Split

- Several **SilenceDetector** tests currently drive state through orchestrator mocks (audio chunk callbacks, partial transcripts). After the split, they should drive the detector directly via its new public API. Keep a handful (lines 492, 512, 836) as orchestrator integration tests because they exercise the detector ↔ hotkey/filter interaction.
- **HotkeySessionController** tests are sparse (3 tests). When extracting, add tests for edge cases currently implicit in the integration tests: pendingStartPress cleared on mic-denied error, double-press during error state, hold threshold boundary at exactly the configured duration.
- **AudioChunkStreamer** tests (6) are reasonable — the extracted suite should preserve the "late chunk from previous session" invariant (test 1167) as it guards the epoch-counter correctness.
- **TranscriptFinalizer** is an *implied* component from the LLM post-processing cluster — decide during Phase 2 whether to extract it or keep its logic in the orchestrator. If kept, its tests remain as orchestrator integration tests.
