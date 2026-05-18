# Story 3.2: WhisperSession actor with research-informed decoding flags

**Epic:** 3 — Audio Capture & Whisper Streaming
**Status:** in_progress
**Owner:** story-executor-3.2

## User Story

As the **audio pipeline**,
I want **an actor that streams PCM into Whisper and emits top-K hypotheses with per-token logprobs, configured with the P1 decoding flags**,
So that **the baseline accuracy gains from `language="en"`, `condition_on_previous_text=false`, temperature fallback, and `no_repeat_ngram_size=3` are captured before any prompting or LLM rerank is added**.

## Acceptance Criteria

1. `apps/CactusVoice/CactusVoice/Inference/WhisperSessionType.swift` — `protocol WhisperSessionType: Sendable` exposing the `run(stream:initialPrompt:topK:)` method so consumers can mock the session.
2. `apps/CactusVoice/CactusVoice/Inference/WhisperEvent.swift` — supporting types:
   - `struct WhisperHypothesis: Sendable { let text: String; let tokenLogprobs: [Float]; let aggregateConfidence: Float }`
   - `enum WhisperEvent: Sendable { case partial(top1: WhisperHypothesis); case finalized(topK: [WhisperHypothesis], confidence: Float) }`
3. `apps/CactusVoice/CactusVoice/Inference/WhisperSession.swift` — `actor WhisperSession: WhisperSessionType`:
   - `func run(stream: AsyncStream<Float>, initialPrompt: String?, topK: Int = 5) -> AsyncStream<WhisperEvent>`
   - Forces decoding flags:
     - `language = "en"`
     - `condition_on_previous_text = false`
     - `temperature_fallback = [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]`
     - `no_repeat_ngram_size = 3`
     - `compression_ratio_threshold = 2.4`
     - `logprob_threshold = -0.8` (stricter than OpenAI's -1.0, per accuracy research)
   - Top-1 hypothesis flows immediately to `TranscriptModel.revise(...)` on each pull as the provisional tail.
   - On segment finalization (stream end / hard buffer flush), emits `.finalized(topK:, confidence:)` and pipes top-1 to `TranscriptModel.commit(...)`.
   - Session close is idempotent and releases the FFI handle via `CactusRuntime.release`.
4. Init takes: `CactusRuntime`, `TranscriptModel`, `modelHandle: WhisperHandle` (acquired by the caller), and a `WhisperFFI` protocol for the streaming FFI seam:
   - `createSession(handle:opts:topK:) throws -> SessionPtr`
   - `pushPCM(session:samples:)`
   - `pullPartial(session:topK:) throws -> (hypotheses: [WhisperHypothesis], aggregateConfidence: Float)`
   - `closeSession(_:)`
5. Tests in `apps/CactusVoice/CactusVoiceTests/Inference/WhisperSessionTests.swift` (XCTest + mock `WhisperFFI`) cover:
   - Top-K emission contract (stub returns predetermined hypotheses → event stream delivers them).
   - Decoding-flag pass-through (stub captures `WhisperOpts` → assert exact flag values).
   - Language forcing through prompt overrides (initialPrompt nil or non-English still forces `language="en"`).
   - Session close releases FFI handle (createSession count == 1, closeSession count == 1).
   - Top-1 piped to `TranscriptModel.revise` on partial; finalize → `TranscriptModel.commit` top-1 + emit `.finalized` topK.

## Deviation: VAD-driven finalization deferred to Story 3.4

The ACs describe finalization on "VAD boundary or hard buffer flush". Story 3.3 (Silero VAD)
and 3.4 (AudioCapture wiring) haven't landed yet — there is no segment-boundary signal
available to this actor in Epic 3 chronology. For Story 3.2 we finalize on:

1. **Stream end** — when the input `AsyncStream<Float>` terminates (consumer closes the
   capture or `AVAudioEngine` stops).
2. **Hard buffer flush** — an explicit `finalize()` async method on the actor that the
   future AudioCapture wire-up will call when VAD emits `.speechEnd`.

Story 3.4 will add a second async-input axis (a `boundaries: AsyncStream<Void>` parameter
on `run(...)` or a separate `onBoundary()` async method) once `VADEvent.speechEnd`
exists to drive it. Documented in source header of `WhisperSession.swift`.

## Deviation: Separate `WhisperFFI` protocol (parallel to Story 3.1's `RuntimeFFI`)

Just as Story 3.1's runtime defined a `RuntimeFFI` seam distinct from Story 2.5's
`ModelLoading`, this story defines a small `WhisperFFI` protocol for the *streaming*
calls (create-session / push-PCM / pull-partial / close-session). The default
`FFIShimWhisperFFI` wraps `FFIShim.whisperCreateSession`, `FFIShim.whisperPushPCM`,
`FFIShim.whisperPullPartial`, `FFIShim.whisperCloseSession`. Tests inject a mock that
captures `WhisperOpts` for flag pass-through assertions and counts create/close calls
for handle-release verification.

`SessionPtr` is a typealias for `OpaquePointer` so the test seam can produce arbitrary
sentinel pointers without unsafely materializing raw pointers.

## Deviation: `WhisperOpts` is a re-declared struct (not the FFIShim version)

`FFIShim.WhisperOpts` exists but is shaped for raw marshaling. The session-level
`WhisperOpts` here is a `let`-constants-only struct with exactly the seven
research-informed flags (six required + `initialPrompt`) so that the test seam can
inspect the values without crossing into FFIShim. The adapter `FFIShimWhisperFFI`
translates session-level `WhisperOpts` → `FFIShim.WhisperOpts` at the call site.

## Tasks

- [x] T1 — Author this story file.
- [ ] T2 — Acceptance tests (red): `CactusVoiceTests/StoryAcceptance/Story3_2Tests.swift`.
- [ ] T3 — Implement:
  - `Inference/WhisperSessionType.swift` (~25 LOC)
  - `Inference/WhisperEvent.swift` (~40 LOC)
  - `Inference/WhisperSession.swift` (~220-280 LOC)
  - `CactusVoiceTests/Inference/WhisperSessionTests.swift` (~200-260 LOC)
- [ ] T4 — `swiftc -typecheck` the three new implementation files together with prior model files: pass (exit 0).
- [ ] T5 — Regenerate `.xcodeproj` via `xcodegen generate`.
- [ ] T6 — KISS pass.

## Dev Notes

- Actor isolation is the only concurrency primitive — no locks, no DispatchQueue.
- The `run(...)` AsyncStream is produced eagerly; the actor spawns one `Task` to drain
  the input PCM stream and one to perform `pullPartial` polling. Both tasks terminate
  on stream end / `close()` / `finalize()`.
- Logging via `Logger(subsystem: "com.cactusvoice", category: "whisper-session")`.
- The actor is the only component allowed to call `FFIShim.whisper*` outside of the
  `FFIShimWhisperFFI` adapter.
