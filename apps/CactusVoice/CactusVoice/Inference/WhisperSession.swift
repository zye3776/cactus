//
//  WhisperSession.swift — Story 3.2.
//
//  Actor that wraps one streaming Whisper decoding session. Takes PCM in
//  via `AsyncStream<Float>`, emits `WhisperEvent` (partial / finalized) out,
//  pipes the top-1 hypothesis into `TranscriptModel.revise` on every pull,
//  and pipes the finalized top-1 into `TranscriptModel.commit` at segment
//  boundaries.
//
//  Decoding flags (architecture §B accuracy revision, Story 3.2 ACs) are
//  forced regardless of caller intent: `language="en"`,
//  `condition_on_previous_text=false`, `temperature_fallback=[0.0,0.2,0.4,0.6,0.8,1.0]`,
//  `no_repeat_ngram_size=3`, `compression_ratio_threshold=2.4`,
//  `logprob_threshold=-0.8` (stricter than OpenAI's -1.0 default per research).
//  The caller's `initialPrompt` is forwarded as-is (Whisper still
//  hard-decodes English because `language="en"` overrides any language
//  hint embedded in the prompt — verified in WhisperSessionTests).
//
//  Finalization in Story 3.2: two triggers only —
//    1. Input `AsyncStream<Float>` terminates (consumer/AVAudioEngine stops).
//    2. Explicit `finalize()` call (used by the future AudioCapture wire-up
//       when VAD emits `.speechEnd`).
//  VAD-driven finalization is added in Story 3.4. Documented in story-3.2.md.
//
//  FFI seam: `WhisperFFI` protocol is the streaming counterpart to
//  Story 3.1's `RuntimeFFI`. Default `FFIShimWhisperFFI` wraps
//  `FFIShim.whisperCreateSession` / `pushPCM` / `pullPartial` / `closeSession`.
//  Tests inject a mock that captures `WhisperOpts` and counts create/close
//  calls for handle-release verification.
//
//  KISS: no retry on pull failure (propagate or finalize-with-error),
//  no internal PCM buffering beyond what `pushPCM` accepts, one consumer
//  (TranscriptModel) on the output stream — no multiplexer.
//
import Foundation
import os

// MARK: - Decoding options (session-level value type)

/// Session-level decoding options. The seven research-informed flags as
/// `let` constants — tests assert on these by name, the
/// `FFIShimWhisperFFI` adapter translates to `FFIShim.WhisperOpts` at the
/// call site. `initialPrompt` is the only caller-overridable field.
public struct WhisperOpts: Sendable, Equatable {
    public let language: String
    public let conditionOnPreviousText: Bool
    public let temperatureFallback: [Float]
    public let noRepeatNgramSize: UInt8
    public let compressionRatioThreshold: Float
    public let logprobThreshold: Float
    public let initialPrompt: String?

    /// Builds the research-informed default opts (language="en",
    /// condition_on_previous_text=false, temperature_fallback=
    /// [0.0, 0.2, 0.4, 0.6, 0.8, 1.0], no_repeat_ngram_size=3,
    /// compression_ratio_threshold=2.4, logprob_threshold=-0.8).
    public static func researchDefaults(initialPrompt: String?) -> WhisperOpts {
        WhisperOpts(
            language: "en",
            conditionOnPreviousText: false,
            temperatureFallback: [0.0, 0.2, 0.4, 0.6, 0.8, 1.0],
            noRepeatNgramSize: 3,
            compressionRatioThreshold: 2.4,
            logprobThreshold: -0.8,
            initialPrompt: initialPrompt
        )
    }

    public init(language: String,
                conditionOnPreviousText: Bool,
                temperatureFallback: [Float],
                noRepeatNgramSize: UInt8,
                compressionRatioThreshold: Float,
                logprobThreshold: Float,
                initialPrompt: String?) {
        self.language = language
        self.conditionOnPreviousText = conditionOnPreviousText
        self.temperatureFallback = temperatureFallback
        self.noRepeatNgramSize = noRepeatNgramSize
        self.compressionRatioThreshold = compressionRatioThreshold
        self.logprobThreshold = logprobThreshold
        self.initialPrompt = initialPrompt
    }
}

// MARK: - WhisperFFI seam

/// Opaque streaming-session pointer. `@unchecked Sendable` because the
/// underlying cactus session pointer's lifetime is owned by `WhisperSession`
/// (the actor) — no cross-isolation mutation occurs.
public struct SessionPtr: @unchecked Sendable, Equatable {
    public let opaque: UnsafeMutableRawPointer
    public init(opaque: UnsafeMutableRawPointer) { self.opaque = opaque }
}

/// Streaming FFI seam. Distinct from Story 3.1's `RuntimeFFI` because the
/// shapes are different (create-session takes a model handle + opts + topK,
/// pull-partial returns a `[WhisperHypothesis]` plus an aggregate
/// confidence float, etc.).
public protocol WhisperFFI: Sendable {
    func createSession(handle: WhisperHandle,
                       opts: WhisperOpts,
                       topK: Int) throws -> SessionPtr
    func pushPCM(session: SessionPtr, samples: [Float])
    func pullPartial(session: SessionPtr,
                     topK: Int) throws -> (hypotheses: [WhisperHypothesis],
                                           aggregateConfidence: Float)
    func closeSession(_ session: SessionPtr)
}

/// Production `WhisperFFI`: wraps `FFIShim.whisper*` and maps cactus
/// status codes to `AppError.inferenceFailed(stage: .whisper, reason:)`.
public struct FFIShimWhisperFFI: WhisperFFI {
    private static let log = Logger(subsystem: "com.cactusvoice", category: "whisper-ffi")

    public init() {}

    public func createSession(handle: WhisperHandle,
                              opts: WhisperOpts,
                              topK: Int) throws -> SessionPtr {
        let shimOpts = FFIShim.WhisperOpts(
            language: opts.language,
            conditionOnPreviousText: opts.conditionOnPreviousText,
            temperatureFallback: opts.temperatureFallback,
            noRepeatNgramSize: opts.noRepeatNgramSize,
            logprobThreshold: opts.logprobThreshold,
            compressionRatioThreshold: opts.compressionRatioThreshold,
            initialPrompt: opts.initialPrompt
        )
        let modelPtr = OpaquePointer(handle.opaque)
        let (status, sessionOpaque) = FFIShim.whisperCreateSession(
            model: modelPtr,
            opts: shimOpts,
            topK: UInt32(topK)
        )
        guard status.isOK, let sessionOpaque else {
            Self.log.error("createSession failed status=\(status.raw, privacy: .public)")
            throw AppError.inferenceFailed(stage: .whisper,
                                           reason: "createSession failed (status=\(status.raw))")
        }
        return SessionPtr(opaque: UnsafeMutableRawPointer(sessionOpaque))
    }

    public func pushPCM(session: SessionPtr, samples: [Float]) {
        guard !samples.isEmpty else { return }
        let sessionPtr = OpaquePointer(session.opaque)
        let status = samples.withUnsafeBufferPointer { buf -> CactusStatus in
            guard let base = buf.baseAddress else { return CactusStatus(0) }
            return FFIShim.whisperPushPCM(session: sessionPtr, samples: base, count: buf.count)
        }
        if !status.isOK {
            Self.log.error("pushPCM non-ok status=\(status.raw, privacy: .public)")
        }
    }

    public func pullPartial(session: SessionPtr,
                            topK: Int) throws -> (hypotheses: [WhisperHypothesis],
                                                  aggregateConfidence: Float) {
        let sessionPtr = OpaquePointer(session.opaque)
        let (status, shimHyps) = FFIShim.whisperPullPartial(session: sessionPtr)
        guard status.isOK else {
            Self.log.error("pullPartial failed status=\(status.raw, privacy: .public)")
            throw AppError.inferenceFailed(stage: .whisper,
                                           reason: "pullPartial failed (status=\(status.raw))")
        }
        let hyps = shimHyps.prefix(topK).map { h in
            WhisperHypothesis(text: h.text,
                              tokenLogprobs: h.tokenLogprobs,
                              aggregateConfidence: h.aggregateConfidence)
        }
        let agg = hyps.first?.aggregateConfidence ?? 0
        return (Array(hyps), agg)
    }

    public func closeSession(_ session: SessionPtr) {
        let sessionPtr = OpaquePointer(session.opaque)
        let status = FFIShim.whisperCloseSession(sessionPtr)
        if !status.isOK {
            Self.log.error("closeSession non-ok status=\(status.raw, privacy: .public)")
        }
    }
}

// MARK: - WhisperSession actor

actor WhisperSession: WhisperSessionType {

    /// `@unchecked Sendable` wrapper so a non-Sendable continuation can be
    /// carried into a `Task` body. The continuation is only touched by the
    /// actor-isolated draining tasks, so no cross-isolation mutation occurs.
    private struct ContinuationBox: @unchecked Sendable {
        let cont: AsyncStream<WhisperEvent>.Continuation
    }

    private let log = Logger(subsystem: "com.cactusvoice", category: "whisper-session")
    private let runtime: CactusRuntime
    private let transcript: TranscriptModel
    private let modelHandle: WhisperHandle
    private let ffi: WhisperFFI

    /// `nil` until `run(...)` is invoked. Cleared by `closeIfNeeded()` on
    /// stream end / finalize / close. Idempotent close.
    private var session: SessionPtr?
    private var closed: Bool = false
    private var finalizeRequested: Bool = false

    init(runtime: CactusRuntime,
         transcript: TranscriptModel,
         modelHandle: WhisperHandle,
         ffi: WhisperFFI = FFIShimWhisperFFI()) {
        self.runtime = runtime
        self.transcript = transcript
        self.modelHandle = modelHandle
        self.ffi = ffi
    }

    // MARK: - WhisperSessionType conformance

    nonisolated func run(stream: AsyncStream<Float>, initialPrompt: String?, topK: Int = 5) -> AsyncStream<WhisperEvent> {
        let (events, continuation) = AsyncStream<WhisperEvent>.makeStream(
            of: WhisperEvent.self,
            bufferingPolicy: .unbounded
        )
        let box = ContinuationBox(cont: continuation)
        Task { [weak self] in
            await self?.drive(stream: stream, initialPrompt: initialPrompt, topK: topK, box: box)
        }
        return events
    }

    /// Hard buffer flush — drains any pending top-K, emits `.finalized`,
    /// pipes top-1 into `TranscriptModel.commit`. Idempotent.
    func finalize() {
        finalizeRequested = true
    }

    /// Idempotent close. Releases the FFI session (via `WhisperFFI.closeSession`)
    /// and the model handle (via `CactusRuntime.release`).
    func close() async {
        await closeIfNeeded()
    }

    // MARK: - Driver

    private func drive(stream: AsyncStream<Float>,
                       initialPrompt: String?,
                       topK: Int,
                       box: ContinuationBox) async {
        // 1. Open the session with research-informed flags.
        let opts = WhisperOpts.researchDefaults(initialPrompt: initialPrompt)
        do {
            session = try ffi.createSession(handle: modelHandle, opts: opts, topK: topK)
        } catch {
            log.error("createSession threw: \(String(describing: error), privacy: .public)")
            box.cont.finish()
            return
        }

        // 2. Drain PCM → push to FFI; after every batch, pull-partial → emit
        //    `.partial(top1:)` + pipe to TranscriptModel.revise.
        var lastTopK: [WhisperHypothesis] = []
        var lastConfidence: Float = 0
        var batch: [Float] = []
        batch.reserveCapacity(1024)

        for await sample in stream {
            batch.append(sample)
            if batch.count >= 1024 {
                await pumpBatch(batch, topK: topK, box: box,
                                lastTopK: &lastTopK, lastConfidence: &lastConfidence)
                batch.removeAll(keepingCapacity: true)
            }
            if finalizeRequested {
                break
            }
        }

        // 3. Flush any remaining PCM through the FFI before finalizing.
        if !batch.isEmpty {
            await pumpBatch(batch, topK: topK, box: box,
                            lastTopK: &lastTopK, lastConfidence: &lastConfidence)
        }

        // 4. Stream-end / finalize → emit `.finalized` + commit top-1.
        await emitFinalized(topK: lastTopK, confidence: lastConfidence, box: box)
        box.cont.finish()
        await closeIfNeeded()
    }

    private func pumpBatch(_ batch: [Float],
                           topK: Int,
                           box: ContinuationBox,
                           lastTopK: inout [WhisperHypothesis],
                           lastConfidence: inout Float) async {
        guard let sess = session else { return }
        ffi.pushPCM(session: sess, samples: batch)
        do {
            let (hyps, conf) = try ffi.pullPartial(session: sess, topK: topK)
            if let top1 = hyps.first {
                lastTopK = hyps
                lastConfidence = conf
                box.cont.yield(.partial(top1: top1))
                await reviseTop1(text: top1.text)
            }
        } catch {
            log.error("pullPartial threw: \(String(describing: error), privacy: .public)")
            // KISS: propagate via stream finish; no retry.
            box.cont.finish()
        }
    }

    private func emitFinalized(topK: [WhisperHypothesis],
                               confidence: Float,
                               box: ContinuationBox) async {
        guard let top1 = topK.first else { return }
        box.cont.yield(.finalized(topK: topK, confidence: confidence))
        await commitTop1(text: top1.text)
    }

    // MARK: - Transcript piping

    private func reviseTop1(text: String) async {
        let provisional = await transcript.provisional
        let range = provisional.startIndex..<provisional.endIndex
        do {
            try await transcript.revise(range: range, text: AttributedString(text))
        } catch {
            log.error("transcript.revise threw: \(String(describing: error), privacy: .public)")
        }
    }

    private func commitTop1(text: String) async {
        let provisional = await transcript.provisional
        let range = provisional.startIndex..<provisional.endIndex
        do {
            try await transcript.commit(range: range, text: AttributedString(text))
        } catch {
            log.error("transcript.commit threw: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Idempotent close

    private func closeIfNeeded() async {
        guard !closed else { return }
        closed = true
        if let sess = session {
            ffi.closeSession(sess)
            session = nil
        }
        await runtime.release(.whisper(modelHandle))
    }
}
