//
//  WhisperEvent.swift — Story 3.2.
//
//  Value types delivered on `WhisperSession.run(...)`'s output stream.
//  `WhisperHypothesis` mirrors `FFIShim.WhisperHypothesis` at the policy
//  layer so consumers never import the FFI seam — the adapter inside
//  `WhisperSession` translates one to the other.
//
import Foundation

/// One decoded hypothesis from the Whisper top-K list.
/// `tokenLogprobs` is per-token log-probability for the chosen tokens;
/// `aggregateConfidence` is the mean exp(logprob) (or whatever metric the
/// cactus runtime supplies via `cactus_whisper_hypothesis_t.aggregate_confidence`).
public struct WhisperHypothesis: Sendable, Equatable {
    public let text: String
    public let tokenLogprobs: [Float]
    public let aggregateConfidence: Float

    public init(text: String, tokenLogprobs: [Float], aggregateConfidence: Float) {
        self.text = text
        self.tokenLogprobs = tokenLogprobs
        self.aggregateConfidence = aggregateConfidence
    }
}

/// One event on the session's output stream.
///
/// * `.partial(top1:)` — provisional tail, delivered on every successful
///   `pullPartial`. The session also pipes this to `TranscriptModel.revise(...)`.
/// * `.finalized(topK:, confidence:)` — emitted at a segment boundary
///   (stream end / `finalize()` in Story 3.2; VAD `.speechEnd` in Story 3.4).
///   The session also pipes the top-1 to `TranscriptModel.commit(...)`.
public enum WhisperEvent: Sendable, Equatable {
    case partial(top1: WhisperHypothesis)
    case finalized(topK: [WhisperHypothesis], confidence: Float)
}
