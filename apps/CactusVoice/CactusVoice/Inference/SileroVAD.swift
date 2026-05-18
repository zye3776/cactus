//
//  SileroVAD.swift — Story 3.3.
//
//  Actor wrapping the Silero VAD ONNX model. Takes 16 kHz mono Float32 PCM
//  via `AsyncStream<Float>`, accumulates 32 ms windows of exactly 512 samples,
//  scores each window via the injected `VADInference` seam, and emits
//  `.speechStart(at:)` / `.speechEnd(at:)` boundary events on an output
//  `AsyncStream<VADEvent>`.
//
//  Architecture §C accuracy revision: Silero VAD is "the single most effective
//  hallucination suppressor" for Whisper on accented speech. The same VAD
//  output drives both (1) pre-segmentation into Whisper (Story 3.4) and
//  (2) toggle-mode auto-stop on sustained silence (FR-003, HotkeyManager).
//
//  KISS stitch logic — three counters, two thresholds:
//    * `inSpeech: Bool` — currently inside an open speech segment
//    * `silenceMs: Int` — cumulative silence since the last speech window
//    * `lastSpeechAt: TimeInterval` — payload for `.speechEnd(at:)`
//
//  Thresholds:
//    * `stitchGapMs = 300` — silence < 300 ms doesn't close the segment
//      (avoids over-segmentation on accented inter-word pauses). Silence ≥
//      300 ms closes the segment and emits `.speechEnd`. This is the actor's
//      operational close threshold.
//    * `silenceEndMs = 1500` — the natural-sustained-silence duration used by
//      `HotkeyManager` to drive toggle-mode auto-stop (FR-003). Declared in
//      source so future toggle-mode logic can read it from one place; the
//      VAD actor itself does NOT delay `.speechEnd` to 1.5 s — its operational
//      close threshold is `stitchGapMs`. The 1.5 s is wall-time silence after
//      the most recent `.speechEnd`, watched by the consumer.
//
//  TimeInterval is derived from sample count (`samplesProcessed / 16_000.0`)
//  not wall clock — keeps the hot loop free of `Date()` and makes unit tests
//  deterministic.
//
//  Capture-active gating: this actor does NOT start scoring until `run(...)`
//  is invoked. AudioCapture (Story 3.4) only calls `run(...)` while the
//  floating window is up, so the VAD never runs in background per the
//  architecture's accuracy-revision risk register.
//
//  FFI seam: `VADInference` is the per-window streaming counterpart to
//  Story 3.1's `RuntimeFFI` and Story 3.2's `WhisperFFI`. Default
//  `FFIShimVADInference` wraps `FFIShim.onnxRun` and bridges its `[Float]`
//  output to the single speech-probability scalar Silero emits per window.
//  The actor itself does not own the load step — `CactusRuntime.acquireVAD`
//  is the load surface (which maps cactus errors to `AppError.modelLoadFailed`);
//  this file's `AppError.vadLoadFailed(reason:)` surface is reserved for
//  post-acquire per-window failures of the loaded ONNX session.
//
//  Stream-end behaviour: if the input `AsyncStream<Float>` terminates while
//  still inside a speech segment (no 300 ms tail), the actor yields a
//  synthetic `.speechEnd(at: lastSpeechAt)` before finishing so consumers
//  always observe balanced start/end pairs. Documented in story-3.3.md.
//
import Foundation
import os

// MARK: - Public value types

/// One event on the VAD's output stream. Timestamps are "audio time" —
/// `samplesProcessed / 16_000.0` — not wall clock.
public enum VADEvent: Sendable, Equatable {
    case speechStart(at: TimeInterval)
    case speechEnd(at: TimeInterval)
}

// MARK: - FFI seam

/// Streaming FFI seam for the VAD. Implementations score a single 512-sample
/// 32 ms window of 16 kHz mono Float32 PCM and return the speech-probability
/// scalar in [0, 1]. Distinct from Story 3.1's `RuntimeFFI` (load/free) and
/// Story 3.2's `WhisperFFI` (create/push/pull/close) — VAD inference is a
/// stateless per-window call, not a streaming session.
public protocol VADInference: Sendable {
    func score(samples: [Float]) throws -> Float
}

/// Production `VADInference`: wraps `FFIShim.onnxRun` and bridges its
/// `[Float]` output to a single scalar (`output[0]` or `0.0` on empty).
/// Maps any cactus runtime failure to `AppError.vadLoadFailed(reason:)` —
/// the model has already been loaded by `CactusRuntime.acquireVAD`, so
/// per-window failures here mean the loaded ONNX session is unusable.
public struct FFIShimVADInference: VADInference {
    private static let log = Logger(subsystem: "com.cactusvoice", category: "vad-ffi")
    private let handle: VADHandle

    public init(handle: VADHandle) {
        self.handle = handle
    }

    public func score(samples: [Float]) throws -> Float {
        let modelPtr = OpaquePointer(handle.opaque)
        let (status, output) = FFIShim.onnxRun(model: modelPtr, input: samples)
        guard status.isOK else {
            Self.log.error("onnxRun non-ok status=\(status.raw, privacy: .public)")
            throw AppError.vadLoadFailed(reason: "onnxRun failed (status=\(status.raw))")
        }
        return output.first ?? 0.0
    }
}

// MARK: - SileroVAD actor

actor SileroVAD {

    /// `@unchecked Sendable` wrapper so the non-Sendable continuation can be
    /// carried into a `Task` body. Only the actor-isolated driver touches it.
    private struct ContinuationBox: @unchecked Sendable {
        let cont: AsyncStream<VADEvent>.Continuation
    }

    // MARK: Constants (architecture §C accuracy revision)

    /// 32 ms @ 16 kHz = 512 samples per window.
    private let windowSamples: Int = 512
    /// 16 kHz sample rate — divisor for "audio time" TimeInterval.
    private let sampleRate: Double = 16_000.0
    /// Milliseconds per 32 ms window.
    private let windowMs: Int = 32
    /// Inter-segment silence below this duration keeps the segment open
    /// (avoids over-segmentation on accented inter-word pauses). Silence at
    /// or above this threshold closes the segment and emits `.speechEnd`.
    private let stitchGapMs: Int = 300
    /// FR-003 toggle-mode auto-stop hint = 1.5 s. Declared in source so the
    /// future `HotkeyManager` wire-up (Story 3.4 and beyond) can read it from
    /// one place. The VAD actor itself does NOT delay `.speechEnd` to 1.5 s —
    /// see file header.
    static let silenceEndMs: Int = 1500

    // MARK: Injected dependencies

    private let log = Logger(subsystem: "com.cactusvoice", category: "silero-vad")
    private let inference: VADInference
    private let threshold: Float

    init(inference: VADInference, threshold: Float = 0.5) {
        self.inference = inference
        self.threshold = threshold
    }

    // MARK: Public surface

    /// Drives the input PCM stream into 512-sample windows, scores each via
    /// the injected `VADInference`, and emits `.speechStart` / `.speechEnd`
    /// events on the returned output stream. The output stream finishes when
    /// the input stream terminates.
    nonisolated func run(stream: AsyncStream<Float>) -> AsyncStream<VADEvent> {
        let (events, continuation) = AsyncStream<VADEvent>.makeStream(
            of: VADEvent.self,
            bufferingPolicy: .unbounded
        )
        let box = ContinuationBox(cont: continuation)
        Task { [weak self] in
            await self?.drive(stream: stream, box: box)
        }
        return events
    }

    // MARK: Driver

    private func drive(stream: AsyncStream<Float>, box: ContinuationBox) async {
        // Window accumulator + counters.
        var window: [Float] = []
        window.reserveCapacity(windowSamples)
        var samplesProcessed: Int = 0

        // Three-counter state machine (see file header).
        var inSpeech: Bool = false
        var silenceMs: Int = 0
        var lastSpeechAt: TimeInterval = 0.0

        for await sample in stream {
            window.append(sample)
            if window.count < windowSamples { continue }

            // We have a complete 512-sample window — score it.
            samplesProcessed += windowSamples
            let windowEnd = Double(samplesProcessed) / sampleRate

            let score: Float
            do {
                score = try inference.score(samples: window)
            } catch {
                log.error("score threw: \(String(describing: error), privacy: .public)")
                box.cont.finish()
                window.removeAll(keepingCapacity: true)
                return
            }
            window.removeAll(keepingCapacity: true)

            let isSpeech = score >= threshold
            if isSpeech {
                if !inSpeech {
                    inSpeech = true
                    box.cont.yield(.speechStart(at: windowEnd))
                }
                lastSpeechAt = windowEnd
                silenceMs = 0
            } else if inSpeech {
                silenceMs += windowMs
                if silenceMs >= stitchGapMs {
                    inSpeech = false
                    silenceMs = 0
                    box.cont.yield(.speechEnd(at: lastSpeechAt))
                }
                // Silence < stitchGapMs: keep the segment open (stitch).
            }
            // else: silence with `inSpeech == false` — nothing to do.
        }

        // Stream end. If we're mid-speech, emit synthetic .speechEnd so
        // consumers see balanced start/end pairs.
        if inSpeech {
            box.cont.yield(.speechEnd(at: lastSpeechAt))
        }
        box.cont.finish()
    }
}
