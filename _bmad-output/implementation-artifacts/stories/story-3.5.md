# Story 3.5: End-to-end baseline wiring + integration test

**Epic:** 3 — Audio Capture & Whisper Streaming
**Status:** in_progress
**Owner:** story-executor-3.5

## User Story

As the **author**,
I want **a single XCTest that runs a 10 s WAV file through `AudioCapture` → `SileroVAD` → `WhisperSession` → `TranscriptModel` and asserts on the committed transcript**,
So that **P1 baseline accuracy is provable before adding any UI**.

## Acceptance Criteria

1. `apps/CactusVoice/CactusVoiceTests/Inference/BaselinePipelineTests.swift` declares one `XCTestCase` class with a single test method.
2. The test wires four actor types (`AudioCapture`, `SileroVAD`, `WhisperSession`, `TranscriptModel`) end-to-end, plus `CactusRuntime` for handle ownership.
3. The test feeds a 10 s WAV file's PCM (`apps/CactusVoice/CactusVoiceTests/Fixtures/baseline_10s.wav`) through `AudioCapture` via a stub `AudioInputSource` that pushes the decoded samples into the actor's `onSamples` callback.
4. After `AudioCapture.stop()`, the test asserts:
   - `await transcript.committed.characters.count > 0` (non-empty transcript).
   - WER vs. the fixture's reference transcript (`Fixtures/baseline_10s.transcript.txt`) ≤ **15 %** (loose baseline bound — this is the bare Whisper baseline, not the full Story 9.x correction pipeline).
   - `language="en"` was used — asserted via `WhisperOpts.researchDefaults(initialPrompt: nil).language == "en"` AND a "no Mandarin" character check on the committed transcript (no CJK Han codepoints).
   - At least one `.speechStart` / `.speechEnd` pair was emitted by the owned `SileroVAD` on `AudioCapture.vadEventStream`.
5. The test releases all model handles on tear-down (`tearDown` calls `await runtime.unloadAll()` and `await whisperSession.close()`).
6. The test is gated by three environment variables via `XCTSkipUnless`:
   - `CACTUSVOICE_WHISPER_PATH` — absolute path to a Whisper model file on disk.
   - `CACTUSVOICE_VAD_PATH` — absolute path to the Silero VAD ONNX file on disk.
   - `CACTUSVOICE_BASELINE_WAV` — optional; defaults to `Fixtures/baseline_10s.wav` if unset. If the resolved WAV does not exist on disk the test `XCTSkipUnless`s.
7. The test includes:
   - A small inline `wer(reference:hypothesis:) -> Double` helper (≤ 40 LOC) using Levenshtein on whitespace-tokenized words. No external dep.
   - A small inline `wavReader(at: URL) throws -> [Float]` helper that decodes a 16 kHz mono WAV file into `[Float]`. Wrapped in `#if canImport(AVFoundation)` and gated on `AVAudioFile` availability; resamples via `AVAudioConverter` if the source rate is not already 16 kHz. The test `XCTSkipUnless` if `canImport(AVFoundation)` is false.
8. `apps/CactusVoice/CactusVoiceTests/Fixtures/README.md` documents:
   - Where to place `baseline_10s.wav` (16 kHz mono PCM, ~10 s of recorded English speech).
   - Where the reference transcript lives (`Fixtures/baseline_10s.transcript.txt`, plain UTF-8, lowercase, no punctuation).
   - The WER computation method (Levenshtein on whitespace-tokenized words, denominator = reference word count).
   - The host-limitation note: on this Command-Line-Tools-only host the test is `XCTSkipUnless`-gated; it runs on a host with Xcode.app and the three env vars exported.

## Host limitation

The CLT-only host has no Xcode.app, no real Whisper / Silero VAD model files, and no real recorded WAV fixture. The integration test is `XCTSkipUnless`-gated on three environment variables so it can be authored, statically gated, and pushed without local execution. Static grep + structural review is the gate for this story; full runtime verification runs on a developer / CI host with Xcode.app, the three env vars exported, and the WAV + reference transcript dropped under `Fixtures/`.

## Deviation: WAV reader uses AVAudioFile + AVAudioConverter

Reading a 16 kHz mono Float32 WAV via raw byte parsing would duplicate roughly 60 LOC of header decoding. Instead, the helper opens the WAV with `AVAudioFile`, decodes via `AVAudioPCMBuffer` at the file's native format, and runs the result through `AVAudioConverter` to the canonical 16 kHz mono Float32 non-interleaved format used elsewhere in the pipeline (same target format as `AVAudioInputSource` in Story 3.4). Conditional on `#if canImport(AVFoundation)` for portability; `XCTSkipUnless` if unavailable.

## Deviation: WER helper is an inline Levenshtein

A Levenshtein-distance WER is ~25 LOC and dependency-free. Mature WER libraries (e.g. JiWER) carry Python deps. For one assertion in one test, the inline helper is the KISS choice. Tokenization is whitespace-split + lowercase + punctuation strip — matches the Whisper-evaluation convention; the reference transcript is already stored in that normalized form.

## Deviation: language="en" check is two-layer

The literal `language="en"` lives in `WhisperOpts.researchDefaults(initialPrompt:)` (Story 3.2). We assert that source-of-truth via `XCTAssertEqual(WhisperOpts.researchDefaults(initialPrompt: nil).language, "en")` AND we cross-check the produced transcript contains no Han / CJK codepoints (a Mandarin transcription would surface as Han characters). KISS — no need to thread the actual session opts back out to the test.

## Deviation: pipeline wired via the AudioInputSource seam

Even with a real WAV file we don't drive `AVAudioEngine` — we use the same `StubAudioInputSource` test seam from Story 3.4 and push the decoded WAV samples into `onSamples` in small chunks (1024 samples) to exercise the same buffering / VAD-window / Whisper-batch path as production. This keeps the test hermetic and reproducible across hosts.

## Tasks

- [ ] T1 — Author this story file (this file).
- [ ] T2 — Acceptance tests (red): `CactusVoiceTests/StoryAcceptance/Story3_5Tests.swift`.
- [ ] T3 — Implement:
  - `CactusVoiceTests/Inference/BaselinePipelineTests.swift` (~280–360 LOC including WAV reader + WER helper + stub input source reuse).
  - `CactusVoiceTests/Fixtures/README.md` (~40 LOC).
- [ ] T4 — `swiftc -typecheck -warnings-as-errors` on production files: pass (test file requires XCTest, deferred to host with Xcode.app).
- [ ] T5 — Regenerate `.xcodeproj` via `xcodegen generate`.
- [ ] T6 — KISS pass.
- [ ] T7 — Trace + sprint-status → mark 3.5 done.

## Dev Notes

- The test reuses `StubAudioInputSource` from `CactusVoiceTests/Audio/AudioCaptureTests.swift` (`@testable import CactusVoice`).
- Whisper + VAD handles are acquired via `CactusRuntime.acquireWhisper` / `acquireVAD` with the env-var paths.
- `WhisperSession` is constructed with the real `FFIShimWhisperFFI` (the env-var gating means the FFI stub returning `unimplemented` is bypassed on hosts where the test actually runs — on those hosts a real libcactus is linked in).
- `SileroVAD` is constructed with the production `FFIShimVADInference` wrapping the acquired `VADHandle`.
- The test pushes ~10 s of samples (160 000 floats at 16 kHz) through the stub source in 1024-sample chunks with a small sleep between chunks to simulate the real-time stream (lets the VAD's window accumulator + Whisper's batch boundary trigger naturally).
- After all samples are pushed, the test calls `audioCapture.stop()` then awaits the Whisper output stream's finish before reading `transcript.committed`.
- WER is computed against the lowercase+stripped committed transcript.
- LOC budget: ≤ 360 lines for the test file (KISS — single test method + helpers).
