//
//  AudioCapture.swift — Story 3.4.
//
//  Actor that owns the microphone capture pipeline:
//    * `AudioInputSource` — protocol seam; default `AVAudioInputSource`
//      wraps `AVAudioEngine` + a tap on the input node + `AVAudioConverter`
//      to 16 kHz mono Float32. Tests inject `StubAudioInputSource`.
//    * `BoundedSPSCBuffer<Float>` — 30 s capacity at 16 kHz; used for
//      overrun accounting + diagnostic `bufferedSampleCount` getter.
//    * One internal `SileroVAD` — driven from `vadPcmStream` (a second
//      `AsyncStream<Float>` whose continuation receives the same samples
//      as the public `pcmStream`).
//
//  Pre-roll semantics (architecture §C, Story 3.4 AC7):
//    `start()` returns as soon as `AudioInputSource.start(onSamples:)`
//    returns — sample production runs on the source's callback thread.
//    The caller (HotkeyManager, future story) invokes `start()` BEFORE
//    the floating-window paint pipeline; by paint time the ring buffer
//    already contains ≥ 100 ms (= 1600 samples) of pre-roll audio. The
//    1600-sample number is asserted in `AudioCaptureTests` against a
//    simulated 200 ms paint delay.
//
//  Stop target (NFR-009): `stop()` completes in ≤ 100 ms p95.
//
//  Mic permission (FR-010, NFR-003): `ensureMicPermission()` is called
//  on EVERY `start()` invocation so a mid-session revoke surfaces as
//  `AppError.micDenied`. The `MicPermissionGate` protocol is the test
//  seam; the production gate wraps `PermissionsCoordinator`.
//
//  Overrun handling: `BoundedSPSCBuffer.overrunStream` is forwarded to
//  `errorStream` as a non-fatal `AppError.inferenceFailed(stage: .audio,
//  reason: "overrun")`. Capture continues; the error banner in Epic 4
//  consumes `errorStream`.
//
//  KISS: no DSP beyond the one `AVAudioConverter`, no silence detection
//  inside this layer (that's `SileroVAD`'s job), no multi-source mixing,
//  one ring buffer, one tap, one converter, one VAD.
//
import AVFoundation
import Foundation
import os

// MARK: - AudioInputSource protocol (test seam)

/// Test seam: hides `AVAudioEngine` behind a `Sendable` protocol. The
/// default `AVAudioInputSource` wraps `AVAudioEngine` + `AVAudioConverter`
/// for production. `StubAudioInputSource` in `AudioCaptureTests` publishes
/// scripted `[Float]` batches into the actor's sample handler without
/// touching real audio hardware.
public protocol AudioInputSource: Sendable {
    /// Begin capture. The implementation MUST call `onSamples` with batches
    /// of 16 kHz mono Float32 samples for each tap callback. May be called
    /// before the window has painted (pre-roll).
    func start(onSamples: @Sendable @escaping ([Float]) -> Void) throws
    /// End capture. Idempotent — multiple calls are safe.
    func stop()
}

// MARK: - MicPermissionGate protocol (test seam)

/// Test seam over `PermissionsCoordinator.ensureMicPermission()`. The
/// production gate wraps the real coordinator; tests inject a closure-backed
/// stub that throws `AppError.micDenied` on demand without touching the OS.
public protocol MicPermissionGate: Sendable {
    func ensureMicPermission() async throws
}

/// Production `MicPermissionGate`: delegates to the real
/// `PermissionsCoordinator`. Held as an `actor` reference; calling into it
/// crosses isolation but that's expected per call (cheap).
public struct PermissionsCoordinatorGate: MicPermissionGate {
    private let coordinator: PermissionsCoordinator
    public init(coordinator: PermissionsCoordinator) {
        self.coordinator = coordinator
    }
    public func ensureMicPermission() async throws {
        try await coordinator.ensureMicPermission()
    }
}

// MARK: - AVAudioInputSource (production default)

/// Production `AudioInputSource`: owns one `AVAudioEngine`, installs a tap
/// on the input node, builds one `AVAudioConverter` to 16 kHz mono Float32,
/// and forwards converted samples through `onSamples`. All `AVAudioEngine`
/// calls are encapsulated here — `AudioCapture` never touches AVFoundation
/// directly, which is what makes the actor unit-testable.
public final class AVAudioInputSource: AudioInputSource, @unchecked Sendable {
    private static let log = Logger(subsystem: "com.cactusvoice", category: "audio-input")
    private static let targetSampleRate: Double = 16_000.0

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var isRunning: Bool = false

    public init() {}

    public func start(onSamples: @Sendable @escaping ([Float]) -> Void) throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw AppError.inferenceFailed(stage: .audio, reason: "invalid input format")
        }
        // Target: 16 kHz mono Float32, non-interleaved.
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AppError.inferenceFailed(stage: .audio, reason: "target format unavailable")
        }
        guard let conv = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AppError.inferenceFailed(stage: .audio, reason: "converter unavailable")
        }
        self.converter = conv

        let bufferSize: AVAudioFrameCount = 1024
        input.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { buffer, _ in
            guard let converter = self.converter else { return }
            let outFrameCapacity = AVAudioFrameCount(
                Double(buffer.frameLength) * Self.targetSampleRate / inputFormat.sampleRate + 16
            )
            guard let outBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: outFrameCapacity
            ) else { return }
            var error: NSError?
            var supplied = false
            let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
                if supplied {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                outStatus.pointee = .haveData
                return buffer
            }
            if status == .error || error != nil {
                Self.log.error("converter error: \(error?.localizedDescription ?? "unknown", privacy: .public)")
                return
            }
            guard let channelData = outBuffer.floatChannelData?[0] else { return }
            let count = Int(outBuffer.frameLength)
            guard count > 0 else { return }
            let samples = Array(UnsafeBufferPointer(start: channelData, count: count))
            onSamples(samples)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.converter = nil
            Self.log.error("engine.start failed: \(error.localizedDescription, privacy: .public)")
            throw AppError.inferenceFailed(stage: .audio, reason: "engine.start failed")
        }
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        isRunning = false
    }
}

// MARK: - AudioCapture actor

actor AudioCapture {

    /// `@unchecked Sendable` wrapper carries non-Sendable continuations
    /// into nonisolated callbacks (the input-source's `onSamples` closure).
    private struct ContinuationBox<T>: @unchecked Sendable {
        let cont: AsyncStream<T>.Continuation
    }

    // MARK: Constants

    /// Target sample rate of the entire downstream pipeline (16 kHz).
    private let sampleRate: Int = 16_000
    /// Ring-buffer capacity: 30 s at 16 kHz = 480 000 Float samples (~1.9 MB).
    /// Sized for steady-state operation; the 5-min hard ceiling is enforced
    /// by HotkeyManager, not here.
    private let ringCapacity: Int = 30 * 16_000
    /// Documented pre-roll target: ≥ 1600 samples = 100 ms @ 16 kHz must be
    /// in the ring buffer by window-paint time. Asserted in AudioCaptureTests.
    static let preRollTargetSamples: Int = 1600

    // MARK: Dependencies

    private let log = Logger(subsystem: "com.cactusvoice", category: "audio-capture")
    private let inputSource: AudioInputSource
    private let permissions: MicPermissionGate
    private let vad: SileroVAD
    private let ringBuffer: BoundedSPSCBuffer<Float>

    // MARK: Public streams

    /// PCM stream — 16 kHz mono Float32 samples, one per `yield`. Consumed
    /// downstream by `WhisperSession`. Finishes when `stop()` is called.
    public nonisolated var pcmStream: AsyncStream<Float> { _pcmStream }

    /// VAD event stream — `.speechStart` / `.speechEnd` emitted by the
    /// owned `SileroVAD`. Finishes when `stop()` is called (or the VAD
    /// itself finishes its output stream first).
    public nonisolated var vadEventStream: AsyncStream<VADEvent> { _vadEventStream }

    /// Non-fatal audio-stage errors (currently just ring-buffer overruns
    /// surfaced as `AppError.inferenceFailed(stage: .audio, reason: "overrun")`).
    public nonisolated var errorStream: AsyncStream<AppError> { _errorStream }

    // MARK: Private streams

    private let _pcmStream: AsyncStream<Float>
    private let pcmContinuation: AsyncStream<Float>.Continuation
    private let _vadPcmStream: AsyncStream<Float>
    private let vadPcmContinuation: AsyncStream<Float>.Continuation
    private let _vadEventStream: AsyncStream<VADEvent>
    private let vadEventContinuation: AsyncStream<VADEvent>.Continuation
    private let _errorStream: AsyncStream<AppError>
    private let errorContinuation: AsyncStream<AppError>.Continuation

    private var overrunWatcherTask: Task<Void, Never>?
    private var vadForwardTask: Task<Void, Never>?
    private var started: Bool = false

    // MARK: Init

    public init(
        inputSource: AudioInputSource = AVAudioInputSource(),
        permissions: MicPermissionGate,
        vad: SileroVAD
    ) {
        self.inputSource = inputSource
        self.permissions = permissions
        self.vad = vad
        self.ringBuffer = BoundedSPSCBuffer<Float>(capacity: 30 * 16_000)

        let (pcm, pcmCont) = AsyncStream<Float>.makeStream(
            of: Float.self, bufferingPolicy: .unbounded
        )
        self._pcmStream = pcm
        self.pcmContinuation = pcmCont

        let (vadPcm, vadPcmCont) = AsyncStream<Float>.makeStream(
            of: Float.self, bufferingPolicy: .unbounded
        )
        self._vadPcmStream = vadPcm
        self.vadPcmContinuation = vadPcmCont

        let (vadEv, vadEvCont) = AsyncStream<VADEvent>.makeStream(
            of: VADEvent.self, bufferingPolicy: .unbounded
        )
        self._vadEventStream = vadEv
        self.vadEventContinuation = vadEvCont

        let (errs, errsCont) = AsyncStream<AppError>.makeStream(
            of: AppError.self, bufferingPolicy: .unbounded
        )
        self._errorStream = errs
        self.errorContinuation = errsCont
    }

    // MARK: Diagnostics

    /// Number of samples currently sitting in the ring buffer. Used by
    /// the pre-roll test to assert ≥ 1600 samples (100 ms) by paint time.
    public var bufferedSampleCount: Int {
        ringBuffer.count
    }

    // MARK: Lifecycle

    /// Start capture. Calls `ensureMicPermission()` every time so mid-session
    /// revoke surfaces as `AppError.micDenied`. Then starts the input source
    /// and wires the owned VAD onto `vadPcmStream`.
    public func start() async throws {
        guard !started else { return }
        try await permissions.ensureMicPermission()

        // Wire overrun forwarder.
        let errBox = ContinuationBox(cont: errorContinuation)
        let overrunStream = ringBuffer.overrunStream
        overrunWatcherTask = Task { [log] in
            for await _ in overrunStream {
                log.error("ring-buffer overrun")
                errBox.cont.yield(
                    AppError.inferenceFailed(stage: .audio, reason: "overrun")
                )
            }
        }

        // Wire VAD: forward its events to the public vadEventStream.
        let vadEvents = vad.run(stream: _vadPcmStream)
        let vadBox = ContinuationBox(cont: vadEventContinuation)
        vadForwardTask = Task {
            for await event in vadEvents {
                vadBox.cont.yield(event)
            }
        }

        // Start the input source. The callback may fire before `start()`
        // returns — that is the pre-roll path.
        let ring = ringBuffer
        let pcmBox = ContinuationBox(cont: pcmContinuation)
        let vadPcmBox = ContinuationBox(cont: vadPcmContinuation)
        do {
            try inputSource.start { samples in
                ring.write(samples)
                for s in samples {
                    pcmBox.cont.yield(s)
                    vadPcmBox.cont.yield(s)
                }
            }
        } catch {
            overrunWatcherTask?.cancel()
            vadForwardTask?.cancel()
            overrunWatcherTask = nil
            vadForwardTask = nil
            if let appErr = error as? AppError { throw appErr }
            throw AppError.inferenceFailed(stage: .audio, reason: "input source failed")
        }
        started = true
    }

    /// Stop capture. Target: p95 ≤ 100 ms (NFR-009). Stops the input source,
    /// drains the ring buffer, finishes all streams, cancels forwarder tasks.
    public func stop() async {
        guard started else { return }
        started = false
        inputSource.stop()
        ringBuffer.removeAll()
        pcmContinuation.finish()
        vadPcmContinuation.finish()
        vadEventContinuation.finish()
        errorContinuation.finish()
        overrunWatcherTask?.cancel()
        vadForwardTask?.cancel()
        overrunWatcherTask = nil
        vadForwardTask = nil
    }
}
