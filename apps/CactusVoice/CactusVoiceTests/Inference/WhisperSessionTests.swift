//
//  WhisperSessionTests.swift
//  CactusVoiceTests
//
//  Story 3.2 — runtime tests against a deterministic `WhisperFFI` stub that
//  captures `WhisperOpts` for flag pass-through, returns scripted top-K
//  hypotheses, and counts create/close calls for handle-release.
//
import XCTest
@testable import CactusVoice

/// Mock `WhisperFFI`. NSLock-guarded mutable state because the protocol
/// methods are non-async; the actor calls them from its isolation domain
/// but tests inspect the mutations from the test-thread side.
final class MockWhisperFFI: @unchecked Sendable, WhisperFFI {

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var createCount: Int = 0
        var closeCount: Int = 0
        var capturedOpts: WhisperOpts?
        var capturedTopK: Int = 0
        var scriptedPartials: [(hyps: [WhisperHypothesis], conf: Float)] = []
        var partialCursor: Int = 0
        var pushedSampleBatches: [[Float]] = []
        var nextSessionToken: UInt = 1
        var liveSessions: Set<UInt> = []
    }
    private let state = State()

    var createCount: Int { state.lock.lock(); defer { state.lock.unlock() }; return state.createCount }
    var closeCount: Int { state.lock.lock(); defer { state.lock.unlock() }; return state.closeCount }
    var capturedOpts: WhisperOpts? {
        state.lock.lock(); defer { state.lock.unlock() }; return state.capturedOpts
    }
    var capturedTopK: Int {
        state.lock.lock(); defer { state.lock.unlock() }; return state.capturedTopK
    }
    var totalPushedSamples: Int {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.pushedSampleBatches.reduce(0) { $0 + $1.count }
    }

    func setScriptedPartials(_ partials: [(hyps: [WhisperHypothesis], conf: Float)]) {
        state.lock.lock(); defer { state.lock.unlock() }
        state.scriptedPartials = partials
        state.partialCursor = 0
    }

    func createSession(handle: WhisperHandle,
                       opts: WhisperOpts,
                       topK: Int) throws -> SessionPtr {
        state.lock.lock()
        state.createCount += 1
        state.capturedOpts = opts
        state.capturedTopK = topK
        let token = state.nextSessionToken
        state.nextSessionToken += 1
        state.liveSessions.insert(token)
        state.lock.unlock()
        return SessionPtr(opaque: UnsafeMutableRawPointer(bitPattern: Int(token) * 0x1000)!)
    }

    func pushPCM(session: SessionPtr, samples: [Float]) {
        state.lock.lock()
        state.pushedSampleBatches.append(samples)
        state.lock.unlock()
    }

    func pullPartial(session: SessionPtr,
                     topK: Int) throws -> (hypotheses: [WhisperHypothesis],
                                           aggregateConfidence: Float) {
        state.lock.lock()
        defer { state.lock.unlock() }
        guard state.partialCursor < state.scriptedPartials.count else {
            // Return the last partial repeatedly when scripted list is exhausted.
            if let last = state.scriptedPartials.last {
                return (last.hyps, last.conf)
            }
            return ([], 0)
        }
        let p = state.scriptedPartials[state.partialCursor]
        state.partialCursor += 1
        return (p.hyps, p.conf)
    }

    func closeSession(_ session: SessionPtr) {
        state.lock.lock()
        state.closeCount += 1
        state.lock.unlock()
    }
}

/// `RuntimeFFI` stub good enough to mint a `WhisperHandle` and accept
/// `release` calls without touching real cactus. The handle's opaque
/// pointer is just a sentinel.
final class WhisperSessionTests_RuntimeFFIStub: @unchecked Sendable, RuntimeFFI {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var releaseCount: Int = 0
    }
    private let state = State()
    var releaseCount: Int { state.lock.lock(); defer { state.lock.unlock() }; return state.releaseCount }

    func load(path: String, kind: ModelKind) throws -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer(bitPattern: 0xDEAD_BEEF)!
    }
    func free(_ ptr: UnsafeMutableRawPointer) {
        state.lock.lock(); state.releaseCount += 1; state.lock.unlock()
    }
}

final class WhisperSessionTests: XCTestCase {

    // MARK: - Fixtures

    private func makeHandle() -> WhisperHandle {
        WhisperHandle(
            opaque: UnsafeMutableRawPointer(bitPattern: 0xBEEF)!,
            path: URL(fileURLWithPath: "/tmp/whisper.bin")
        )
    }

    private func pcmStream(_ samples: [Float]) -> AsyncStream<Float> {
        AsyncStream<Float> { cont in
            for s in samples { cont.yield(s) }
            cont.finish()
        }
    }

    private func hyp(_ text: String, conf: Float = 0.9) -> WhisperHypothesis {
        WhisperHypothesis(text: text,
                          tokenLogprobs: [-0.1, -0.2, -0.3],
                          aggregateConfidence: conf)
    }

    // MARK: - Top-K emission contract

    func testTopKEmissionContract() async throws {
        let mock = MockWhisperFFI()
        let topKHyps = [hyp("hello world"), hyp("hello word"), hyp("hello whirled")]
        mock.setScriptedPartials([
            (hyps: [hyp("hello")], conf: 0.5),
            (hyps: topKHyps, conf: 0.91),
        ])
        let transcript = TranscriptModel()
        let runtime = CactusRuntime(mode: .full, ffi: WhisperSessionTests_RuntimeFFIStub())
        let session = WhisperSession(
            runtime: runtime,
            transcript: transcript,
            modelHandle: makeHandle(),
            ffi: mock
        )

        // 1024 samples → exactly one batch; finish triggers final pull.
        let samples = Array(repeating: Float(0.0), count: 1024)
        let events = session.run(stream: pcmStream(samples), initialPrompt: nil, topK: 5)

        var collected: [WhisperEvent] = []
        for await event in events { collected.append(event) }

        // Expect: one .partial then one .finalized.
        XCTAssertEqual(collected.count, 2, "expected one partial + one finalized")
        guard case .partial(let p) = collected[0] else {
            return XCTFail("first event must be .partial, got \(collected[0])")
        }
        XCTAssertEqual(p.text, "hello")
        guard case .finalized(let fin, let conf) = collected[1] else {
            return XCTFail("second event must be .finalized, got \(collected[1])")
        }
        XCTAssertEqual(fin.count, 3, "finalized must carry top-K = 3 hyps from second pull")
        XCTAssertEqual(fin[0].text, "hello world")
        XCTAssertEqual(conf, 0.91, accuracy: 0.0001)
    }

    // MARK: - Decoding-flag pass-through

    func testDecodingFlagsPassedThroughVerbatim() async throws {
        let mock = MockWhisperFFI()
        mock.setScriptedPartials([(hyps: [hyp("ok")], conf: 0.5)])
        let transcript = TranscriptModel()
        let runtime = CactusRuntime(mode: .full, ffi: WhisperSessionTests_RuntimeFFIStub())
        let session = WhisperSession(
            runtime: runtime,
            transcript: transcript,
            modelHandle: makeHandle(),
            ffi: mock
        )
        let events = session.run(stream: pcmStream([0.0]),
                                 initialPrompt: nil,
                                 topK: 5)
        for await _ in events { /* drain */ }

        let opts = mock.capturedOpts
        XCTAssertNotNil(opts)
        XCTAssertEqual(opts?.language, "en", "language must be forced to en")
        XCTAssertEqual(opts?.conditionOnPreviousText, false)
        XCTAssertEqual(opts?.temperatureFallback, [0.0, 0.2, 0.4, 0.6, 0.8, 1.0])
        XCTAssertEqual(opts?.noRepeatNgramSize, 3)
        XCTAssertEqual(opts?.compressionRatioThreshold ?? 0, 2.4, accuracy: 0.0001)
        XCTAssertEqual(opts?.logprobThreshold ?? 0, -0.8, accuracy: 0.0001)
        XCTAssertEqual(mock.capturedTopK, 5)
    }

    // MARK: - Language forcing — non-English initialPrompt still forces en

    func testLanguageForcedDespiteNonEnglishInitialPrompt() async throws {
        let mock = MockWhisperFFI()
        mock.setScriptedPartials([(hyps: [hyp("ok")], conf: 0.5)])
        let transcript = TranscriptModel()
        let runtime = CactusRuntime(mode: .full, ffi: WhisperSessionTests_RuntimeFFIStub())
        let session = WhisperSession(
            runtime: runtime,
            transcript: transcript,
            modelHandle: makeHandle(),
            ffi: mock
        )
        // A Spanish prompt — but language must STILL be forced to "en".
        let events = session.run(stream: pcmStream([0.0]),
                                 initialPrompt: "Hola, este es un dictado en español.",
                                 topK: 3)
        for await _ in events { /* drain */ }

        let opts = mock.capturedOpts
        XCTAssertEqual(opts?.language, "en",
                       "language must be forced to en regardless of initialPrompt content")
        XCTAssertEqual(opts?.initialPrompt,
                       "Hola, este es un dictado en español.",
                       "initialPrompt must pass through verbatim (Whisper still hard-decodes en)")
    }

    func testLanguageForcedWhenInitialPromptIsNil() async throws {
        let mock = MockWhisperFFI()
        mock.setScriptedPartials([(hyps: [hyp("ok")], conf: 0.5)])
        let transcript = TranscriptModel()
        let runtime = CactusRuntime(mode: .full, ffi: WhisperSessionTests_RuntimeFFIStub())
        let session = WhisperSession(
            runtime: runtime,
            transcript: transcript,
            modelHandle: makeHandle(),
            ffi: mock
        )
        let events = session.run(stream: pcmStream([0.0]),
                                 initialPrompt: nil,
                                 topK: 5)
        for await _ in events { /* drain */ }
        XCTAssertEqual(mock.capturedOpts?.language, "en")
        XCTAssertNil(mock.capturedOpts?.initialPrompt)
    }

    // MARK: - Session close releases FFI handle

    func testSessionCloseReleasesFFIHandle() async throws {
        let mock = MockWhisperFFI()
        mock.setScriptedPartials([(hyps: [hyp("done")], conf: 0.7)])
        let runtimeFFI = WhisperSessionTests_RuntimeFFIStub()
        let transcript = TranscriptModel()
        let runtime = CactusRuntime(mode: .full, ffi: runtimeFFI)
        let session = WhisperSession(
            runtime: runtime,
            transcript: transcript,
            modelHandle: makeHandle(),
            ffi: mock
        )
        let events = session.run(stream: pcmStream([0.0]),
                                 initialPrompt: nil,
                                 topK: 5)
        for await _ in events { /* drain */ }

        XCTAssertEqual(mock.createCount, 1, "session created exactly once")
        XCTAssertEqual(mock.closeCount, 1, "session closed exactly once on stream end")
    }

    func testCloseIsIdempotent() async throws {
        let mock = MockWhisperFFI()
        mock.setScriptedPartials([(hyps: [hyp("done")], conf: 0.7)])
        let transcript = TranscriptModel()
        let runtime = CactusRuntime(mode: .full, ffi: WhisperSessionTests_RuntimeFFIStub())
        let session = WhisperSession(
            runtime: runtime,
            transcript: transcript,
            modelHandle: makeHandle(),
            ffi: mock
        )
        let events = session.run(stream: pcmStream([0.0]),
                                 initialPrompt: nil,
                                 topK: 5)
        for await _ in events { /* drain */ }

        // Explicit close after stream-end close: still one closeSession call.
        await session.close()
        await session.close()
        XCTAssertEqual(mock.closeCount, 1, "close must be idempotent")
    }

    // MARK: - Top-1 piped to TranscriptModel.revise on partial; commit on finalize

    func testTop1PipedToTranscriptOnPartialAndCommit() async throws {
        let mock = MockWhisperFFI()
        mock.setScriptedPartials([
            (hyps: [hyp("hello")], conf: 0.5),
            (hyps: [hyp("hello world")], conf: 0.9),
        ])
        let transcript = TranscriptModel()
        let runtime = CactusRuntime(mode: .full, ffi: WhisperSessionTests_RuntimeFFIStub())
        let session = WhisperSession(
            runtime: runtime,
            transcript: transcript,
            modelHandle: makeHandle(),
            ffi: mock
        )
        // 1024 samples → one batch + finalize.
        let samples = Array(repeating: Float(0.0), count: 1024)
        let events = session.run(stream: pcmStream(samples), initialPrompt: nil, topK: 5)
        for await _ in events { /* drain */ }

        let committed = await transcript.committed
        let committedStr = String(committed.characters)
        XCTAssertEqual(committedStr, "hello world",
                       "finalize must commit the final top-1 into committed prefix")
        let provisional = await transcript.provisional
        XCTAssertTrue(provisional.characters.isEmpty,
                      "after commit, provisional must be empty")
    }
}
