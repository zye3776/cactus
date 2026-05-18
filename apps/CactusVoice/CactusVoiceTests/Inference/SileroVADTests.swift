//
//  SileroVADTests.swift
//  CactusVoiceTests
//
//  Story 3.3 — runtime tests against a deterministic `VADInference` stub that
//  returns a scripted score per window. Tests cover: clean-speech sequence
//  (emit one .speechStart, no premature .speechEnd), silence sequence (no
//  .speechStart ever), threshold sensitivity (at 0.7, scores 0.6 are
//  silence), segment stitching (200 ms gap → one pair), and no-stitch
//  (500 ms gap → two pairs).
//
import XCTest
@testable import CactusVoice

/// Deterministic stub. Returns the next scripted score on each call; once
/// exhausted, returns the last scripted score forever.
final class StubVADInference: @unchecked Sendable, VADInference {

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var scripted: [Float] = []
        var cursor: Int = 0
        var callCount: Int = 0
    }
    private let state = State()

    init(constant score: Float, calls: Int) {
        state.lock.lock()
        state.scripted = Array(repeating: score, count: calls)
        state.lock.unlock()
    }

    init(scripted: [Float]) {
        state.lock.lock()
        state.scripted = scripted
        state.lock.unlock()
    }

    var callCount: Int {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.callCount
    }

    func score(samples: [Float]) throws -> Float {
        state.lock.lock(); defer { state.lock.unlock() }
        state.callCount += 1
        guard !state.scripted.isEmpty else { return 0.0 }
        let i = min(state.cursor, state.scripted.count - 1)
        state.cursor += 1
        return state.scripted[i]
    }
}

final class SileroVADTests: XCTestCase {

    // MARK: - Helpers

    /// 32 ms @ 16 kHz = 512 samples per window.
    private let windowSamples = 512
    /// Milliseconds per window.
    private let windowMs = 32

    /// Build an `AsyncStream<Float>` that yields `nWindows * 512` zero-valued
    /// samples (the actual sample values are ignored by the stub; only the
    /// window count drives the actor).
    private func pcmStream(windows: Int) -> AsyncStream<Float> {
        let total = windows * windowSamples
        return AsyncStream<Float> { cont in
            for _ in 0..<total { cont.yield(0.0) }
            cont.finish()
        }
    }

    /// Collect all events from the actor's output stream.
    private func collectEvents(_ stream: AsyncStream<VADEvent>) async -> [VADEvent] {
        var out: [VADEvent] = []
        for await e in stream { out.append(e) }
        return out
    }

    // MARK: - AC: clean speech → one .speechStart, no premature .speechEnd

    func testCleanSpeechEmitsOneStartAndStreamEndSpeechEnd() async throws {
        // 10 windows of speech (score 0.9), no silence in between.
        let stub = StubVADInference(constant: 0.9, calls: 10)
        let actor = SileroVAD(inference: stub)
        let events = await collectEvents(actor.run(stream: pcmStream(windows: 10)))

        // Exactly one .speechStart at first window's end.
        let starts = events.filter { if case .speechStart = $0 { return true }; return false }
        XCTAssertEqual(starts.count, 1, "clean speech must emit exactly one .speechStart")
        if case .speechStart(let at) = starts[0] {
            // First window covers samples 0..<512; windowEnd = 512/16000 = 0.032 s.
            XCTAssertEqual(at, 0.032, accuracy: 0.0001)
        } else {
            XCTFail("expected .speechStart, got \(starts[0])")
        }

        // No .speechEnd until stream end (synthetic close) — and exactly one
        // synthetic close at lastSpeechAt = 10 * 0.032 = 0.32 s.
        let ends = events.filter { if case .speechEnd = $0 { return true }; return false }
        XCTAssertEqual(ends.count, 1, "stream-end synthetic .speechEnd expected")
        if case .speechEnd(let at) = ends[0] {
            XCTAssertEqual(at, 0.32, accuracy: 0.0001)
        }
    }

    // MARK: - AC: pure silence → never emit .speechStart

    func testPureSilenceNeverEmitsSpeechStart() async throws {
        let stub = StubVADInference(constant: 0.1, calls: 50)
        let actor = SileroVAD(inference: stub)
        let events = await collectEvents(actor.run(stream: pcmStream(windows: 50)))

        XCTAssertTrue(events.isEmpty, "pure silence must emit zero events, got \(events)")
    }

    // MARK: - AC: threshold sensitivity — at 0.7, scores 0.6 are silence

    func testThresholdAt07TreatsScore06AsSilence() async throws {
        let stub = StubVADInference(constant: 0.6, calls: 20)
        let actor = SileroVAD(inference: stub, threshold: 0.7)
        let events = await collectEvents(actor.run(stream: pcmStream(windows: 20)))

        XCTAssertTrue(events.isEmpty, "with threshold=0.7, score=0.6 must be treated as silence")
    }

    func testThresholdAt07TreatsScore08AsSpeech() async throws {
        let stub = StubVADInference(constant: 0.8, calls: 5)
        let actor = SileroVAD(inference: stub, threshold: 0.7)
        let events = await collectEvents(actor.run(stream: pcmStream(windows: 5)))

        let starts = events.filter { if case .speechStart = $0 { return true }; return false }
        XCTAssertEqual(starts.count, 1, "with threshold=0.7, score=0.8 must be speech")
    }

    // MARK: - AC: segment stitching — 200 ms silence < 300 ms gap → one pair

    func testStitchOnShortSilenceGap() async throws {
        // 200 ms = ~7 windows of silence (7*32=224 ms; rounded up to ensure < 300).
        // Use exactly 6 windows = 192 ms to stay safely below 300 ms.
        // Script: 5 speech → 6 silence (< 300 ms) → 5 speech → enough silence
        // to close the segment (≥ 300 ms = ≥ 10 windows). We'll use 50 silence
        // windows (= 1.6 s) at the end so it well exceeds 300 ms and matches
        // the AC's "≥ 1.5 s" wording.
        let script: [Float] =
            Array(repeating: 0.9, count: 5) +    // speech segment A
            Array(repeating: 0.1, count: 6) +    // 192 ms silence (stitch)
            Array(repeating: 0.9, count: 5) +    // speech segment B (stitched)
            Array(repeating: 0.1, count: 50)     // 1.6 s silence (closes)
        let stub = StubVADInference(scripted: script)
        let actor = SileroVAD(inference: stub)
        let events = await collectEvents(actor.run(stream: pcmStream(windows: script.count)))

        let starts = events.filter { if case .speechStart = $0 { return true }; return false }
        let ends = events.filter { if case .speechEnd = $0 { return true }; return false }
        XCTAssertEqual(starts.count, 1, "200 ms silence gap must stitch into one .speechStart")
        XCTAssertEqual(ends.count, 1, "200 ms silence gap must stitch into one .speechEnd")
    }

    // MARK: - AC: NO stitching — 500 ms silence ≥ 300 ms gap → two pairs

    func testNoStitchOnLongerSilenceGap() async throws {
        // 500 ms silence = 16 windows (16*32 = 512 ms). This is ≥ 300 ms and
        // closes the first segment.
        let script: [Float] =
            Array(repeating: 0.9, count: 5) +    // speech segment A
            Array(repeating: 0.1, count: 16) +   // 512 ms silence (closes A)
            Array(repeating: 0.9, count: 5) +    // speech segment B (separate)
            Array(repeating: 0.1, count: 50)     // 1.6 s silence (closes B)
        let stub = StubVADInference(scripted: script)
        let actor = SileroVAD(inference: stub)
        let events = await collectEvents(actor.run(stream: pcmStream(windows: script.count)))

        let starts = events.filter { if case .speechStart = $0 { return true }; return false }
        let ends = events.filter { if case .speechEnd = $0 { return true }; return false }
        XCTAssertEqual(starts.count, 2, "500 ms silence gap must split into two .speechStart")
        XCTAssertEqual(ends.count, 2, "500 ms silence gap must split into two .speechEnd")
    }

    // MARK: - Threshold-default sanity

    func testDefaultThresholdIs05() async throws {
        // Score 0.5 should be treated as speech (>= 0.5).
        let stub = StubVADInference(constant: 0.5, calls: 5)
        let actor = SileroVAD(inference: stub)  // default threshold 0.5
        let events = await collectEvents(actor.run(stream: pcmStream(windows: 5)))

        let starts = events.filter { if case .speechStart = $0 { return true }; return false }
        XCTAssertEqual(starts.count, 1, "default threshold must be 0.5 — score=0.5 → speech")
    }

    // MARK: - Score-call cadence — one call per 512-sample window

    func testOneScoreCallPerWindow() async throws {
        let stub = StubVADInference(constant: 0.1, calls: 8)
        let actor = SileroVAD(inference: stub)
        _ = await collectEvents(actor.run(stream: pcmStream(windows: 8)))

        XCTAssertEqual(stub.callCount, 8, "exactly one inference call per 512-sample window")
    }
}
