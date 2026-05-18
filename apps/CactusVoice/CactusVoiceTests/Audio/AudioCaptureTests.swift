//
//  AudioCaptureTests.swift
//  CactusVoiceTests
//
//  Story 3.4 — runtime tests against `StubAudioInputSource` (no AVAudioEngine)
//  and a closure-backed `MicPermissionGate` stub (no OS dialog).
//
//  Tests:
//    1. Pre-roll: race start() vs. a 200 ms simulated paint delay; assert
//       `bufferedSampleCount >= 1600` by paint time.
//    2. stop() completes in < 100 ms (NFR-009 p95 target).
//    3. Ring-buffer overrun surfaces as AppError.inferenceFailed(stage:.audio,
//       reason: "overrun") on errorStream.
//    4. Mic permission denied → start() throws AppError.micDenied.
//    5. VAD events flow through vadEventStream (StubVADInference forced to
//       speech-probability 0.9 on every window).
//
import XCTest
@testable import CactusVoice

/// Test seam: a stub `AudioInputSource` that publishes scripted batches
/// synchronously on demand. Lets tests push samples through the actor
/// without touching real audio hardware.
final class StubAudioInputSource: @unchecked Sendable, AudioInputSource {

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var onSamples: (@Sendable ([Float]) -> Void)?
        var running: Bool = false
        var startThrows: Error?
    }
    private let state = State()

    init() {}

    /// Pre-seed an error that `start()` will throw.
    func setStartError(_ error: Error?) {
        state.lock.lock(); defer { state.lock.unlock() }
        state.startThrows = error
    }

    /// Push a batch of samples through the live callback (no-op if not running).
    func push(_ samples: [Float]) {
        state.lock.lock()
        let cb = state.onSamples
        state.lock.unlock()
        cb?(samples)
    }

    var isRunning: Bool {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.running
    }

    // MARK: AudioInputSource

    func start(onSamples: @Sendable @escaping ([Float]) -> Void) throws {
        state.lock.lock()
        if let err = state.startThrows {
            state.lock.unlock()
            throw err
        }
        state.onSamples = onSamples
        state.running = true
        state.lock.unlock()
    }

    func stop() {
        state.lock.lock()
        state.running = false
        state.onSamples = nil
        state.lock.unlock()
    }
}

/// Closure-backed `MicPermissionGate`. Lets tests script "denied" without
/// invoking the OS authorization dialog.
struct StubMicPermissionGate: MicPermissionGate {
    let action: @Sendable () async throws -> Void
    init(_ action: @Sendable @escaping () async throws -> Void = {}) {
        self.action = action
    }
    func ensureMicPermission() async throws {
        try await action()
    }
}

@MainActor
final class AudioCaptureTests: XCTestCase {

    // Helper: build an AudioCapture with stubs.
    private func makeCapture(
        input: StubAudioInputSource = StubAudioInputSource(),
        gate: MicPermissionGate = StubMicPermissionGate(),
        vadInference: VADInference = StubVADInference(constant: 0.9, calls: 100)
    ) -> (AudioCapture, StubAudioInputSource) {
        let vad = SileroVAD(inference: vadInference, threshold: 0.5)
        let capture = AudioCapture(inputSource: input, permissions: gate, vad: vad)
        return (capture, input)
    }

    // MARK: - 1. Pre-roll: ≥ 1600 samples by paint time

    func testPreRollBufferContainsAtLeast100msBeforePaint() async throws {
        let input = StubAudioInputSource()
        let (capture, _) = makeCapture(input: input)

        // Caller races start() against the simulated 200 ms window-paint delay.
        async let paintDelay: Void = Task {
            // Simulate the window-paint pipeline (200 ms).
            try? await Task.sleep(nanoseconds: 200_000_000)
        }.value

        // start() returns once the source is up; the tap will keep pushing.
        try await capture.start()
        // Push 2048 samples synchronously through the stub source — equivalent
        // to ~128 ms of audio at 16 kHz arriving during pre-roll.
        let batch = Array(repeating: Float(0.01), count: 2048)
        input.push(batch)

        _ = await paintDelay
        let buffered = await capture.bufferedSampleCount
        XCTAssertGreaterThanOrEqual(
            buffered, AudioCapture.preRollTargetSamples,
            "Expected ≥ \(AudioCapture.preRollTargetSamples) pre-roll samples by paint time; got \(buffered)"
        )
        await capture.stop()
    }

    // MARK: - 2. stop() completes in < 100 ms (NFR-009)

    func testStopCompletesUnder100ms() async throws {
        let input = StubAudioInputSource()
        let (capture, _) = makeCapture(input: input)
        try await capture.start()
        // Push some samples so there is real work to drain.
        input.push(Array(repeating: Float(0.0), count: 8192))

        let t0 = Date()
        await capture.stop()
        let elapsedMs = Date().timeIntervalSince(t0) * 1000.0
        XCTAssertLessThan(
            elapsedMs, 100.0,
            "stop() must complete in < 100 ms (NFR-009 p95); took \(elapsedMs) ms"
        )
    }

    // MARK: - 3. Ring-buffer overrun → AppError.inferenceFailed(stage:.audio, reason: "overrun")

    func testOverrunSurfacedAsAppError() async throws {
        let input = StubAudioInputSource()
        let (capture, _) = makeCapture(input: input)
        let errorStream = capture.errorStream
        try await capture.start()

        // Capacity is 30 * 16_000 = 480_000 samples. Push two batches that
        // together exceed capacity to force at least one overrun event.
        let huge = Array(repeating: Float(0.0), count: 480_001)
        input.push(huge)
        input.push(huge)

        // Wait briefly for the overrun forwarder Task to yield onto errorStream.
        var observed: AppError?
        let waiter = Task {
            for await err in errorStream {
                observed = err
                return
            }
        }
        // Give the watcher up to 500 ms.
        try? await Task.sleep(nanoseconds: 500_000_000)
        waiter.cancel()
        await capture.stop()

        XCTAssertEqual(
            observed,
            AppError.inferenceFailed(stage: .audio, reason: "overrun"),
            "Overrun must surface as AppError.inferenceFailed(stage: .audio, reason: \"overrun\")"
        )
    }

    // MARK: - 4. Mic permission denied → start() throws AppError.micDenied

    func testStartThrowsOnMicDenied() async {
        let gate = StubMicPermissionGate { throw AppError.micDenied }
        let (capture, _) = makeCapture(gate: gate)
        do {
            try await capture.start()
            XCTFail("Expected start() to throw AppError.micDenied")
        } catch let err as AppError {
            XCTAssertEqual(err, AppError.micDenied)
        } catch {
            XCTFail("Expected AppError.micDenied, got \(error)")
        }
    }

    // MARK: - 5. VAD events flow through vadEventStream

    func testVADEventsFlowThroughStream() async throws {
        // VAD windows are 512 samples; push enough samples to produce at
        // least one window, with stub inference forced to 0.9 (>= 0.5 threshold)
        // so a .speechStart event is emitted.
        let input = StubAudioInputSource()
        let inference = StubVADInference(constant: 0.9, calls: 10)
        let (capture, _) = makeCapture(input: input, vadInference: inference)
        let events = capture.vadEventStream
        try await capture.start()

        // Push 512 samples (one VAD window).
        input.push(Array(repeating: Float(0.5), count: 512))

        var observed: VADEvent?
        let waiter = Task {
            for await ev in events {
                observed = ev
                return
            }
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        waiter.cancel()
        await capture.stop()

        guard let evt = observed else {
            XCTFail("Expected at least one VADEvent on vadEventStream")
            return
        }
        if case .speechStart = evt {
            // OK
        } else {
            XCTFail("Expected .speechStart, got \(evt)")
        }
    }
}
