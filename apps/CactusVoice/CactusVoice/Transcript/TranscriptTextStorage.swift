//
//  TranscriptTextStorage.swift
//  CactusVoice
//
//  NSTextStorage subclass that mirrors `TranscriptModel`'s state in the
//  bound `NSTextView` and routes user edits back through the actor.
//
//  Architecture refs:
//    * §A "Transcript view" row — NSTextView backed by a custom NSTextStorage
//      reflecting TranscriptModel; committed text styled distinctly from
//      provisional via NSAttributedString attributes.
//    * Cross-cutting concern #3 — TranscriptModel is the only writer to the
//      transcript text; the storage subclass is externally read-only and its
//      mutation surface routes back through the actor.
//
//  Threading: the class is pinned to `@MainActor`. NSTextView mutates storage
//  on the main thread; the AsyncStream subscription rebuilds the snapshot on
//  the main actor as well — pinning the class eliminates races on the cache.
//
//  Snapshot strategy (KISS, full replacement):
//    * The class caches one `NSMutableAttributedString` snapshot.
//    * On every `TranscriptUpdate` received from `model.updates`, the snapshot
//      is rebuilt wholesale from `await model.committed` + `await model.provisional`.
//      The committed prefix is rendered with `NSColor.labelColor`; the
//      provisional tail with `NSColor.secondaryLabelColor`.
//    * Rebuilds emit one `edited(.editedCharacters | .editedAttributes, …)`
//      notification spanning the old length with `changeInLength = newLen - oldLen`.
//      NSLayoutManager handles short-string re-layout without measurable lag.
//
//  Optimistic local apply + reconcile (deviation, documented in story-2.3.md):
//    NSTextView calls `replaceCharacters(in:with:)` synchronously and expects
//    the storage to reflect the new characters before returning. The model is
//    an actor and cannot be reached synchronously. The compromise:
//      1. Update the cached snapshot immediately with the user's edit and
//         emit the `edited(...)` notification so the view sees the keystroke.
//      2. Dispatch `Task { await model.userEdit(…) }`.
//      3. The model's broadcast on `updates` eventually rebuilds the snapshot
//         from authoritative state — usually identical, so no flicker.
//      4. If the model rejects (range outside committed), the rebuild
//         overwrites the optimistic state and the bad keystroke disappears.
//
//  Edit-routing safety:
//    `replaceCharacters(in:with:)` only forwards an edit to the actor if the
//    NSRange falls entirely within the committed prefix length. Edits that
//    cross into the provisional region are dropped (per Concern #3 — the
//    user cannot mutate engine output).
//
import AppKit
import Foundation

@MainActor
final class TranscriptTextStorage: NSTextStorage {

    // MARK: - Stored state

    private let model: TranscriptModel
    private let snapshot: NSMutableAttributedString = NSMutableAttributedString()

    /// Length of the committed prefix in the cached snapshot. Used to
    /// distinguish user-edit-eligible offsets from provisional-region
    /// offsets when NSTextView calls `replaceCharacters(in:with:)`.
    private var committedLength: Int = 0

    /// Subscription task that consumes `model.updates`. Cancelled in `deinit`
    /// so the actor's continuation does not keep us alive past tear-down.
    private var subscriptionTask: Task<Void, Never>?

    // MARK: - Init / deinit

    init(model: TranscriptModel) {
        self.model = model
        super.init()
        startObservingModel()
        // Seed the cache from initial actor state so the bound NSTextView
        // shows any pre-existing committed/provisional text at first layout.
        Task { [weak self] in
            await self?.rebuildFromModel()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TranscriptTextStorage does not support NSCoder")
    }

    @available(*, unavailable)
    required init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType) {
        fatalError("TranscriptTextStorage does not support pasteboard init")
    }

    deinit {
        subscriptionTask?.cancel()
    }

    // MARK: - NSTextStorage primitives

    override var string: String {
        snapshot.string
    }

    override func attributes(at location: Int,
                             effectiveRange range: NSRangePointer?) -> [NSAttributedString.Key: Any] {
        snapshot.attributes(at: location, effectiveRange: range)
    }

    override func replaceCharacters(in range: NSRange, with str: String) {
        // Drop edits that cross into the provisional region; the user is not
        // allowed to mutate engine output (Concern #3).
        guard range.location <= committedLength else { return }
        let clampedUpper = min(range.location + range.length, committedLength)
        let clampedRange = NSRange(location: range.location,
                                   length: clampedUpper - range.location)

        // Optimistic local apply — patch the cached snapshot now so the view
        // sees the keystroke before the actor round-trip completes.
        let oldLength = snapshot.length
        snapshot.replaceCharacters(in: clampedRange, with: str)
        // Re-apply committed colour to the user's inserted text (cache was
        // pre-coloured by rebuildFromModel; replaceCharacters strips attrs
        // on inserted runs).
        let insertedRange = NSRange(location: clampedRange.location, length: (str as NSString).length)
        if insertedRange.length > 0 {
            snapshot.setAttributes([.foregroundColor: NSColor.labelColor],
                                   range: insertedRange)
        }
        committedLength += insertedRange.length - clampedRange.length
        let delta = snapshot.length - oldLength
        edited([.editedCharacters, .editedAttributes],
               range: clampedRange,
               changeInLength: delta)

        // Forward to the model. The next `updates` broadcast will reconcile
        // (rebuild) the snapshot from authoritative state.
        let editText = AttributedString(str)
        let nsRangeForActor = clampedRange
        Task { [model] in
            let committed = await model.committed
            guard let actorRange = Self.attributedRange(in: committed, nsRange: nsRangeForActor) else {
                return
            }
            try? await model.userEdit(range: actorRange, text: editText)
        }
    }

    override func setAttributes(_ attrs: [NSAttributedString.Key: Any]?,
                                range: NSRange) {
        // NSTextView uses this during compose/layout. We honour the call
        // on the cached snapshot only — the model never carries attributes
        // back; provisional/committed colour is the storage's responsibility,
        // re-applied on each rebuildFromModel.
        snapshot.setAttributes(attrs, range: range)
        edited(.editedAttributes, range: range, changeInLength: 0)
    }

    // MARK: - Update subscription

    private func startObservingModel() {
        // `model.updates` is an `AsyncStream` (nonisolated stored let on the
        // actor) so a sync capture suffices — no actor hop required to read it.
        let stream = model.updates
        subscriptionTask = Task { [weak self] in
            for await _ in stream {
                if Task.isCancelled { return }
                await self?.rebuildFromModel()
            }
        }
    }

    /// Pull committed + provisional from the actor, rebuild the cache, and
    /// emit one `edited(...)` notification covering the wholesale change.
    /// Public-ish (internal) so the seed-on-init path can call it as well.
    private func rebuildFromModel() async {
        let committed = await model.committed
        let provisional = await model.provisional

        let committedNS = NSAttributedString(
            string: String(committed.characters),
            attributes: [.foregroundColor: NSColor.labelColor]
        )
        let provisionalNS = NSAttributedString(
            string: String(provisional.characters),
            attributes: [.foregroundColor: NSColor.secondaryLabelColor]
        )

        let oldLength = snapshot.length
        beginEditing()
        snapshot.setAttributedString(NSAttributedString())
        snapshot.append(committedNS)
        snapshot.append(provisionalNS)
        committedLength = committedNS.length
        let newLength = snapshot.length
        edited([.editedCharacters, .editedAttributes],
               range: NSRange(location: 0, length: oldLength),
               changeInLength: newLength - oldLength)
        endEditing()
    }

    // MARK: - Range translation (NSRange in snapshot → Range<AttributedString.Index> in committed)

    /// Translate a snapshot NSRange (which we have already clamped to the
    /// committed prefix) into a `Range<AttributedString.Index>` on the
    /// supplied `committed` AttributedString. Returns nil if the offsets
    /// fall outside the AttributedString (the actor may have advanced
    /// since the optimistic update — we drop the routed edit in that case).
    private static func attributedRange(in committed: AttributedString,
                                        nsRange: NSRange) -> Range<AttributedString.Index>? {
        let total = committed.characters.count
        guard nsRange.location >= 0,
              nsRange.location <= total,
              nsRange.location + nsRange.length <= total else {
            return nil
        }
        let lo = committed.index(committed.startIndex, offsetByCharacters: nsRange.location)
        let hi = committed.index(lo, offsetByCharacters: nsRange.length)
        return lo..<hi
    }
}
