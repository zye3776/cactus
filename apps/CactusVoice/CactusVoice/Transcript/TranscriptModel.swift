//
//  TranscriptModel.swift
//  CactusVoice
//
//  Headless actor that owns transcript state as two AttributedStrings:
//    * `committed`   — user-owned prefix; only `userEdit` mutates it.
//    * `provisional` — engine-owned tail; only `commit` / `revise` mutate it.
//
//  Every mutation broadcasts a `TranscriptUpdate` on `updates` so views and
//  storage adapters (Story 2.3) can mirror state without polling.
//
//  Range axis (deviation from a naive single-string interpretation):
//    `TranscriptUpdate` cases carry one `Range<AttributedString.Index>`. Because
//    committed and provisional are *separate* AttributedString instances and
//    AttributedString.Index is only meaningful relative to one instance, we
//    interpret the range as:
//      * commit / revise — range into `provisional`
//      * userEdit        — range into `committed`
//    Validation rejects ranges that cross the relevant field's bounds.
//    Rationale: maintaining a merged "view" AttributedString would add a third
//    source of truth — explicitly forbidden by cross-cutting concern #3
//    (TranscriptModel is the only writer). Documented in story-2.2.md.
//
//  Provisional styling: applied as an AttributedString attribute
//  (`NSColor.secondaryLabelColor` via AppKit). The visible seam is part of
//  the model, not the view — Story 2.3's NSTextStorage subclass renders
//  the attributes verbatim.
//
import AppKit
import Foundation

/// Errors thrown by `TranscriptModel` mutation entry points.
enum TranscriptModelError: Error, Equatable, Sendable {
    /// The supplied range is not entirely within the provisional region.
    case rangeNotInProvisional
    /// The supplied range is not entirely within the committed region.
    case rangeNotInCommitted
}

actor TranscriptModel {

    // MARK: - State

    /// User-owned prefix. Mutated only by `userEdit`.
    private(set) var committed: AttributedString

    /// Engine-owned tail. Mutated only by `commit` / `revise`.
    /// Always styled with `secondaryLabelColor` so consumers can render the
    /// committed/provisional seam without inspecting state.
    private(set) var provisional: AttributedString

    // MARK: - Update broadcast

    /// Subscribers receive every successful mutation in order. No replay buffer;
    /// subscribe before the first update of interest.
    let updates: AsyncStream<TranscriptUpdate>
    private let updatesContinuation: AsyncStream<TranscriptUpdate>.Continuation

    // MARK: - Init

    init(committed: AttributedString = AttributedString(),
         provisional: AttributedString = AttributedString()) {
        self.committed = committed
        var styled = provisional
        Self.applyProvisionalStyle(&styled)
        self.provisional = styled
        let (stream, continuation) = AsyncStream<TranscriptUpdate>.makeStream(
            of: TranscriptUpdate.self, bufferingPolicy: .unbounded
        )
        self.updates = stream
        self.updatesContinuation = continuation
    }

    deinit {
        updatesContinuation.finish()
    }

    // MARK: - Mutations

    /// Engine commit: the substring of `provisional` identified by `range` is
    /// replaced with `text`, then appended (with provisional styling stripped)
    /// to the end of `committed`. `range` must be entirely within
    /// `provisional`.
    func commit(range: Range<AttributedString.Index>, text: AttributedString) throws {
        try requireProvisionalRange(range)
        var newProvisional = provisional
        newProvisional.replaceSubrange(range, with: text)
        // Take the freshly-replaced span (without provisional styling) and
        // append it to the committed prefix.
        let replacedStart = newProvisional.index(
            newProvisional.startIndex,
            offsetByCharacters: provisional.characters.distance(from: provisional.startIndex, to: range.lowerBound)
        )
        let replacedEnd = newProvisional.index(
            replacedStart,
            offsetByCharacters: text.characters.count
        )
        var committedSpan = AttributedString(newProvisional[replacedStart..<replacedEnd])
        Self.stripProvisionalStyle(&committedSpan)
        committed.append(committedSpan)
        // Drop the now-committed span from the provisional buffer.
        newProvisional.removeSubrange(replacedStart..<replacedEnd)
        Self.applyProvisionalStyle(&newProvisional)
        provisional = newProvisional
        updatesContinuation.yield(.commit(range: range, text: text))
    }

    /// Engine revision of the provisional tail: replace `range` in
    /// `provisional` with `text`. `range` must be entirely within
    /// `provisional`.
    func revise(range: Range<AttributedString.Index>, text: AttributedString) throws {
        try requireProvisionalRange(range)
        var newProvisional = provisional
        newProvisional.replaceSubrange(range, with: text)
        Self.applyProvisionalStyle(&newProvisional)
        provisional = newProvisional
        updatesContinuation.yield(.revise(range: range, text: text))
    }

    /// User edit of the committed prefix: replace `range` in `committed`
    /// with `text`. `range` must be entirely within `committed`.
    func userEdit(range: Range<AttributedString.Index>, text: AttributedString) throws {
        try requireCommittedRange(range)
        committed.replaceSubrange(range, with: text)
        updatesContinuation.yield(.userEdit(range: range, text: text))
    }

    // MARK: - Range validation

    private func requireProvisionalRange(_ range: Range<AttributedString.Index>) throws {
        if range.lowerBound < provisional.startIndex
            || range.upperBound > provisional.endIndex {
            throw TranscriptModelError.rangeNotInProvisional
        }
    }

    private func requireCommittedRange(_ range: Range<AttributedString.Index>) throws {
        if range.lowerBound < committed.startIndex
            || range.upperBound > committed.endIndex {
            throw TranscriptModelError.rangeNotInCommitted
        }
    }

    // MARK: - Styling helpers

    private static func applyProvisionalStyle(_ s: inout AttributedString) {
        guard !s.characters.isEmpty else { return }
        var container = AttributeContainer()
        container.foregroundColor = NSColor.secondaryLabelColor
        s.setAttributes(container)
    }

    private static func stripProvisionalStyle(_ s: inout AttributedString) {
        s.foregroundColor = nil
    }
}
