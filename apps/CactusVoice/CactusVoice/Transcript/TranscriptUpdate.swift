//
//  TranscriptUpdate.swift
//  CactusVoice
//
//  Event payload broadcast by `TranscriptModel.updates` on every state change.
//
//  Range axis: `range` is an index range into the AttributedString the operation
//  targets — `.commit` and `.revise` carry indices into the *provisional* field;
//  `.userEdit` carries indices into the *committed* field. The two fields are
//  separate `AttributedString` instances; the actor never crosses indices.
//  See TranscriptModel.swift for the full rationale.
//
import Foundation

enum TranscriptUpdate: Sendable {
    /// Engine commit: text moves from the provisional region to the end of
    /// the committed region. `range` is into `TranscriptModel.provisional`.
    case commit(range: Range<AttributedString.Index>, text: AttributedString)

    /// Engine revision of the provisional tail. `range` is into
    /// `TranscriptModel.provisional`.
    case revise(range: Range<AttributedString.Index>, text: AttributedString)

    /// User edit of the committed prefix. `range` is into
    /// `TranscriptModel.committed`.
    case userEdit(range: Range<AttributedString.Index>, text: AttributedString)
}
