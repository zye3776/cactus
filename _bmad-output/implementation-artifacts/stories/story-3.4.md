# Story 3.4: AudioCapture actor with pre-roll + VAD-driven segmentation

**Epic:** 3 — Audio Capture & Whisper Streaming
**Status:** in_progress
**Owner:** story-executor-3.4

## User Story

As the **app's hotkey handler**,
I want **an actor that owns `AVAudioEngine`, drives `BoundedSPSCBuffer<Float>`, feeds both `SileroVAD` and `WhisperSession`, and supports pre-roll capture (mic hot before window paint)**,
So that **the first syllable of speech is never lost and the rest of the architecture sees clean 16 kHz mono Float32 PCM streams plus VAD boundary events**.

## Acceptance Criteria

1. `apps/CactusVoice/CactusVoice/Audio/AudioCapture.swift` declares `actor AudioCapture`.
2. The actor owns:
   - An `AudioInputSource` (default `AVAudioInputSource` wrapping `AVAudioEngine` + a tap on the input node + an `AVAudioConverter` to 16 kHz mono Float32).
   - One `BoundedSPSCBuffer<Float>` instance with capacity = `30 * 16_000` (30 s of audio at 16 kHz).
   - One `SileroVAD` instance, driven from `pcmStream`.
3. `func start() async throws`:
   - Calls `permissions.ensureMicPermission()` on **every** call so a mid-session revoke surfaces as `AppError.micDenied` (FR-010, NFR-003).
   - Starts the underlying `AudioInputSource` and begins writing converted samples into the ring buffer and yielding them onto `pcmStream`.
   - Returns as soon as the input source is started — sample production runs in the source's callback thread. Pre-roll is satisfied because the tap is active before the window paints.
4. `func stop() async`:
   - Stops the input source, finishes `pcmStream`, finishes `vadEventStream`, drains the ring buffer to empty.
   - Documented p95 target: completes in ≤ **100 ms** (NFR-009).
5. Format conversion to 16 kHz mono Float32 happens **inside the tap callback** via `AVAudioConverter` (no DSP, single Apple-supplied step). Implemented in `AVAudioInputSource` (the default `AudioInputSource` adapter).
6. Public surface:
   - `var pcmStream: AsyncStream<Float>` — consumed by both VAD (internally wired) and downstream Whisper.
   - `var vadEventStream: AsyncStream<VADEvent>` — the VAD's output, wired by piping `pcmStream` (a forked copy) into the owned `SileroVAD.run(stream:)`.
7. Pre-roll requirement: by the time the floating window has painted (simulated 200 ms delay in the test), the ring buffer contains ≥ **1600 samples** (= 100 ms @ 16 kHz). The test races `start()` against the 200 ms delay; assertion `buffer.count >= 1600` documents the pre-roll target in source as a comment.
8. Ring-buffer overrun events from `BoundedSPSCBuffer.overrunStream` are forwarded as a non-fatal `AppError.inferenceFailed(stage: .audio, reason: "overrun")` (logged once at the forward site, never throws, never interrupts capture).
9. `AudioInputSource: Sendable` protocol is the test seam:
   ```swift
   public protocol AudioInputSource: Sendable {
       func start(onSamples: @Sendable @escaping ([Float]) -> Void) throws
       func stop()
   }
   ```
   The default `AVAudioInputSource` wraps `AVAudioEngine` + `AVAudioConverter`. Tests inject `StubAudioInputSource` which simulates pushing scripted samples.
10. Tests in `apps/CactusVoice/CactusVoiceTests/Audio/AudioCaptureTests.swift` cover:
    - **Start before paint:** race `start()` against a 200 ms simulated paint delay; assert `await capture.bufferedSampleCount >= 1600` by paint time.
    - **Stop completes < 100 ms:** time `await capture.stop()` with `Date()` deltas; assert under 100 ms.
    - **Overrun events surface:** stub flood the source; assert at least one `AppError.inferenceFailed(stage: .audio, reason: "overrun")` was observed via the actor's exposed `errorStream: AsyncStream<AppError>`.
    - **Mic permission denied:** `start()` throws `AppError.micDenied` when `PermissionsCoordinator` returns denied. (Permission seam is injected via `MicPermissionGate` protocol so tests don't need OS dialog.)
    - **VAD events flow:** stub source emits enough samples for the injected VAD inference to score one speech window; assert `.speechStart` event arrives on `vadEventStream`.

## Deviation: `AudioInputSource` protocol seam

`AVAudioEngine` is hard to fake in unit tests (real device required, format negotiation depends on hardware, tap callback is fragile under load). The `AudioInputSource` protocol is the test seam: the actor depends on the protocol, not on `AVAudioEngine` directly. The default `AVAudioInputSource` adapter is the production path. Tests inject `StubAudioInputSource` that publishes scripted `[Float]` batches synchronously into the actor's sample handler. This is the same pattern used by Stories 3.1 (`RuntimeFFI`), 3.2 (`WhisperFFI`), and 3.3 (`VADInference`) — protocol seams at every FFI / OS boundary.

## Deviation: `MicPermissionGate` protocol for the permissions seam

`PermissionsCoordinator.ensureMicPermission()` is `async throws` and requires the actor — fine for production, but the runtime tests want to script "denied" without touching the OS. The actor takes a `MicPermissionGate: Sendable` protocol with a single `func ensureMicPermission() async throws` method; the default `PermissionsCoordinatorGate` wraps the real `PermissionsCoordinator`. Tests inject a closure-backed stub that throws `AppError.micDenied` on demand.

## Deviation: Pre-roll semantics

The architecture says "mic hot before window paint." Implementation: `start()` returns as soon as `AudioInputSource.start(onSamples:)` returns — sample production runs on the source's callback thread (real `AVAudioEngine` tap callback for production; immediate synchronous callbacks for `StubAudioInputSource`). The caller (HotkeyManager, future Story 5.x) invokes `start()` *before* the window paint pipeline; by the time the window paints, ≥ 100 ms of samples have already accumulated in the ring buffer. The 100 ms / 1600-sample number is documented in source as a comment AND asserted in the pre-roll test.

## Deviation: `pcmStream` is the single PCM fan-out point

The actor owns one `BoundedSPSCBuffer<Float>` (for overrun accounting) and one `AsyncStream<Float>` (the public `pcmStream`). Samples are written to BOTH on each tap callback — the ring buffer is the bounded-memory surface (for overrun events + diagnostic `bufferedSampleCount`), and the AsyncStream is the consumer-facing surface for VAD + Whisper. KISS: no second multiplexer layer, no fan-out tee — both consumers (VAD internally + Whisper externally) subscribe to the same `pcmStream` continuation.

Wait — `AsyncStream` is single-consumer. Resolution: the actor owns the SileroVAD internally and feeds it via a *forked* `AsyncStream<Float>` that the actor pipes from the master continuation. Externally, `pcmStream` is the master stream. Internally, `vadPcmStream` is a second `AsyncStream<Float>` whose continuation receives the same samples. Both `yield()` calls happen inside the actor's `onSamples` handler. Two `AsyncStream`s, one shared sample flow, KISS over Combine / multicast.

## Deviation: 30 s ring buffer capacity

The buffer capacity (30 s = 480 000 samples) is governed by the hard ceiling on capture duration (FR-004: 5 min) and the realistic memory cost (480k Floats × 4 bytes = ~1.9 MB — negligible). 30 s is the working budget for "drain on stop within 100 ms" (we drain via removeAll, not by iterating samples). The 5-min ceiling itself is enforced by HotkeyManager (future story), not by AudioCapture — AudioCapture is responsible for steady-state behaviour, not for hold-time bounds.

## Tasks

- [ ] T1 — Author this story file (this file).
- [ ] T2 — Acceptance tests (red): `CactusVoiceTests/StoryAcceptance/Story3_4Tests.swift`.
- [ ] T3 — Implement:
  - `Audio/AudioCapture.swift` (~260-340 LOC; actor + `AudioInputSource` protocol + `AVAudioInputSource` default adapter + `MicPermissionGate` seam).
  - `CactusVoiceTests/Audio/AudioCaptureTests.swift` (~220-280 LOC; `StubAudioInputSource` + 5 test methods).
- [ ] T4 — `swiftc -typecheck -warnings-as-errors` on the implementation file + all dependent files: pass (exit 0).
- [ ] T5 — Regenerate `.xcodeproj` via `xcodegen generate`.
- [ ] T6 — KISS pass.

## Dev Notes

- Actor isolation is the only concurrency primitive — no locks, no DispatchQueue, no Combine.
- `AVAudioInputSource`:
  - On `start(onSamples:)`: configure `AVAudioEngine.inputNode`, install a tap at the hardware sample rate, build one `AVAudioConverter` to the 16 kHz mono Float32 format, and in the tap callback push the converted `[Float]` to `onSamples`.
  - On `stop()`: `engine.stop()`, remove the tap, release the converter.
  - All `AVAudioEngine` calls happen on `AVAudioInputSource`'s side — the actor never touches `AVAudioEngine` directly.
- The actor's `onSamples` handler:
  1. Writes the batch to `ringBuffer.write(samples)` (for overrun accounting).
  2. For each sample, `pcmContinuation.yield(s)` and `vadPcmContinuation.yield(s)`.
- The owned `SileroVAD` is started in `start()` by calling `vad.run(stream: vadPcmStream)` and forwarding its events to the actor's `vadEventContinuation`.
- The actor exposes `errorStream: AsyncStream<AppError>` — overrun events (and any future audio-stage non-fatals) are yielded onto this stream. The future floating window (Epic 4) subscribes to drive `ErrorBanner`. For Story 3.4 the test asserts on this stream directly.
- Logging via `Logger(subsystem: "com.cactusvoice", category: "audio-capture")`. Log overruns at `.error` once per emission (not per sample).
- KISS: no DSP, no silence detection inside the capture layer (that's SileroVAD's job), no multi-source mixing, no sample-rate-conversion path beyond the one `AVAudioConverter`, no eager VAD load (the caller hands an already-acquired `VADHandle` to the `SileroVAD` constructor outside the actor, or — KISS option chosen — the caller hands a fully-constructed `SileroVAD` to the actor's init).
