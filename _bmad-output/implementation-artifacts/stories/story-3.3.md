# Story 3.3: SileroVAD actor

**Epic:** 3 — Audio Capture & Whisper Streaming
**Status:** in_progress
**Owner:** story-executor-3.3

## User Story

As the **audio pipeline**,
I want **an actor wrapping the Silero VAD ONNX model that scores PCM windows and emits speech/silence boundary events**,
So that **Whisper receives pre-segmented audio (suppressing hallucinations on accented inter-word pauses) and toggle-mode capture can stop on sustained silence**.

## Acceptance Criteria

1. `apps/CactusVoice/CactusVoice/Inference/SileroVAD.swift` declares `actor SileroVAD`.
2. `enum VADEvent: Sendable { case speechStart(at: TimeInterval); case speechEnd(at: TimeInterval) }`
   is declared as a top-level type in `SileroVAD.swift`.
3. The actor exposes a non-async, eager-stream entry point:
   `func run(stream: AsyncStream<Float>) -> AsyncStream<VADEvent>`.
4. The VAD operates on 32 ms windows of 16 kHz audio = exactly **512 samples per window**.
   The constant is declared in source as `let windowSamples = 512` (or similar literal `512`).
5. The speech-probability threshold is configurable at init time with a default of **0.5**.
6. Sustained silence ≥ **1.5 s** after a `.speechStart` emits a single `.speechEnd` event;
   the constant `1.5` (or `1500` ms) is declared as a source-level constant.
7. Consecutive speech segments are stitched into one `.speechStart`/`.speechEnd` pair when the
   inter-segment silence gap is < **300 ms**; the constant `0.3` (or `300` ms) is declared as a
   source-level constant.
8. VAD load failure surfaces `AppError.vadLoadFailed(reason:)`.
9. The actor does not start scoring until `run(stream:)` is invoked (capture-active gating is
   the caller's responsibility; documented in the source header).
10. FFI seam: `protocol VADInference: Sendable { func score(samples: [Float]) throws -> Float }`
    with a default `FFIShimVADInference` adapter wrapping `FFIShim.onnxRun`. Tests inject a
    deterministic stub.
11. Tests in `apps/CactusVoice/CactusVoiceTests/Inference/SileroVADTests.swift` cover:
    - Clean-speech sequence (stub returns 0.9 for all windows) → emits one `.speechStart` early,
      no `.speechEnd` until stream end / silence-tail.
    - Silence sequence (stub returns 0.1) → never emits `.speechStart`.
    - Threshold sensitivity at 0.7: scores 0.6 are treated as silence.
    - Stitch case: speech → 200 ms silence → speech → 1.5 s silence → exactly one
      `.speechStart`/`.speechEnd` pair.
    - No-stitch case: speech → 500 ms silence → speech → 1.5 s silence → two pairs.

## Deviation: Tail-silence is the only `.speechEnd` trigger

Per the AC wording ("sustained silence ≥ 1.5 s emits `.speechEnd`"), `.speechEnd` is emitted
**only** when 1.5 s of cumulative silence elapses after the last speech window. If the input
`AsyncStream<Float>` terminates mid-speech (no 1.5 s tail), the actor finalizes by yielding a
synthetic `.speechEnd(at: lastSpeechTime)` immediately before closing the output stream so
downstream consumers always see balanced start/end pairs. Documented in the source header.

## Deviation: Time-base derived from sample count, not wall clock

`TimeInterval` for `.speechStart(at:)` / `.speechEnd(at:)` is computed as
`Double(samplesProcessed) / 16_000.0`. This avoids `Date()` calls inside the hot loop, makes
the actor deterministic under unit tests (any test scripting a known number of samples gets
predictable timestamps), and matches the architecture's "audio time" semantics elsewhere in
the pipeline.

## Deviation: `VADInference.score(samples:)` returns a single `Float` (not `[Float]`)

`FFIShim.onnxRun` returns `[Float]` because the generic ONNX runtime can emit arbitrary
tensors, but Silero VAD's specific output for a 512-sample window is a single speech
probability scalar. The default `FFIShimVADInference` adapter pulls `output[0]` (or `0.0` on
empty output) and bridges. This keeps the actor's loop one-line per window and aligns the
seam shape with the actual Silero contract. Documented in the source header.

## Deviation: Stitch logic uses three integer counters (KISS)

Rather than a state machine with named transitions, the driver carries:

1. `inSpeech: Bool` — currently inside a speech segment.
2. `silenceMs: Int` — cumulative silence after the last speech window (0 while `inSpeech` is
   false but a recent `.speechEnd` was not yet emitted; reset on every speech window).
3. `lastSpeechAt: TimeInterval` — captured at every speech window for the `.speechEnd(at:)`
   payload.

Two thresholds: `stitchGapMs = 300` (silence < 300 ms while `inSpeech == true` keeps the
segment open; ≥ 300 ms but < 1500 ms is a sub-stitch gap that doesn't close the segment yet),
and `silenceEndMs = 1500` (silence ≥ 1500 ms closes the segment via `.speechEnd`). No event
queue, no priority handling, no separate `.speechContinue` event — just the two cases on the
external surface.

## Tasks

- [x] T1 — Author this story file.
- [ ] T2 — Acceptance tests (red): `CactusVoiceTests/StoryAcceptance/Story3_3Tests.swift`.
- [ ] T3 — Implement:
  - `Inference/SileroVAD.swift` (~180-220 LOC)
  - `CactusVoiceTests/Inference/SileroVADTests.swift` (~180-240 LOC)
- [ ] T4 — `swiftc -typecheck` SileroVAD.swift + dependent files: pass (exit 0).
- [ ] T5 — Regenerate `.xcodeproj` via `xcodegen generate`.
- [ ] T6 — KISS pass.

## Dev Notes

- Actor isolation is the only concurrency primitive — no locks, no DispatchQueue.
- `run(...)` produces its `AsyncStream<VADEvent>` eagerly; spawns one `Task` to drain the
  PCM input, accumulate it into 512-sample windows, call `VADInference.score`, and update
  the three-counter state machine. The task terminates when the input stream ends.
- The default `FFIShimVADInference` does NOT itself load the model — it expects a
  `VADHandle` from `CactusRuntime.acquireVAD` (acquired by the caller) and forwards the raw
  pointer into `FFIShim.onnxRun`. If `CactusRuntime.acquireVAD` throws, the load failure is
  surfaced as `AppError.vadLoadFailed(reason:)` at the **caller** site — the actor itself
  does not own the load step. The actor accepts an already-acquired `VADHandle` in its init
  for parity with `WhisperSession`. The `vadLoadFailed` mapping in this actor's source path
  applies if a future load step is added inside the actor; for Story 3.3 the surface is
  threaded through `FFIShimVADInference` initializers that take a `VADHandle`.
- Logging via `Logger(subsystem: "com.cactusvoice", category: "silero-vad")`.
- No DSP inside the actor — the FFI / stub computes the score. The actor only batches,
  thresholds, and tracks the three counters.
