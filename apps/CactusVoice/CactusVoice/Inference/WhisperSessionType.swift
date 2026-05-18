//
//  WhisperSessionType.swift — Story 3.2.
//
//  Protocol seam so consumers (CorrectionPipeline, AudioCapture wire-up,
//  later epics) can be tested against a mock `WhisperSession`. The single
//  method captures the actor's primary surface — feed an `AsyncStream<Float>`
//  of 16 kHz mono Float32 PCM, get back an `AsyncStream<WhisperEvent>`
//  carrying provisional partials + finalized top-K + confidence.
//
//  Concrete conformance lives in `WhisperSession.swift`.
//
import Foundation

/// Whisper streaming session. Conforming types take an `AsyncStream<Float>`
/// of 16 kHz mono PCM and return an `AsyncStream<WhisperEvent>` that
/// delivers `.partial(top1:)` on every pull and `.finalized(topK:, confidence:)`
/// at segment boundaries (stream end / hard buffer flush in Story 3.2;
/// VAD-driven boundaries added in Story 3.4).
public protocol WhisperSessionType: Sendable {
    func run(stream: AsyncStream<Float>,
             initialPrompt: String?,
             topK: Int) -> AsyncStream<WhisperEvent>
}
