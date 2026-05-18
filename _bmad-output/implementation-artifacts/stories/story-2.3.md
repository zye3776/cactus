# Story 2.3: TranscriptTextStorage (NSTextStorage subclass)

**Epic:** 2 — Headless Core
**Status:** in_progress
**Owner:** story-executor-2.3

## User Story

As the **floating window's NSTextView**,
I want **an `NSTextStorage` subclass that reflects `TranscriptModel`'s state read-only and routes user edits back through the actor**,
So that **the NSTextView and the TranscriptModel never diverge**.

## Acceptance Criteria

1. `apps/CactusVoice/CactusVoice/Transcript/TranscriptTextStorage.swift` declares `final class TranscriptTextStorage: NSTextStorage`, annotated `@MainActor` to bind it to the main run loop (NSTextView mutates storage on the main thread; the subscription task also publishes to the main actor — pinning the class avoids racing the cached snapshot with the AsyncStream observer).
2. The class overrides the four `NSTextStorage` primitives:
   - `var string: String { get }`
   - `func attributes(at:effectiveRange:) -> [NSAttributedString.Key: Any]`
   - `func replaceCharacters(in:with:)`
   - `func setAttributes(_:range:)`
3. Init signature `init(model: TranscriptModel)` — takes one `TranscriptModel` reference, holds it `let`, and subscribes once to `model.updates` via a `Task { for await … }` on the main actor. The subscription task is retained on the instance for the lifetime of the storage (cancelled in `deinit`).
4. Read overrides (`string`, `attributes(at:effectiveRange:)`) read from a cached `NSMutableAttributedString` snapshot, never from the actor directly (NSTextStorage primitives are synchronous and `TranscriptModel.committed`/`provisional` are actor-isolated — sync reads through the actor are impossible).
5. The snapshot is rebuilt from the actor's `committed` + `provisional` AttributedStrings on every received `TranscriptUpdate`. Committed substrings are coloured `.labelColor`; provisional substrings are coloured `.secondaryLabelColor`.
6. After each rebuild the storage calls `beginEditing()` / `edited(.editedCharacters | .editedAttributes, range: oldRange, changeInLength: newLength - oldLength)` / `endEditing()` so the bound `NSTextView` (via `NSLayoutManager`) re-layouts within one runloop tick.
7. `replaceCharacters(in:with:)` — when invoked from NSTextView's editing path — dispatches a `Task { await model.userEdit(…) }` translating the NSRange into `committed`'s `Range<AttributedString.Index>` (clamping to committed bounds; spans crossing into provisional are dropped because the user is not allowed to mutate engine output per Concern #3). The local cached snapshot is also updated optimistically (see Deviation: optimistic local apply).
8. `setAttributes(_:range:)` is implemented as a write into the cached snapshot only (NSTextView calls it during compose/layout). The model never carries attributes back — provisional/committed colour is the storage's responsibility, derived per-rebuild.
9. Tests live in:
   - `apps/CactusVoice/CactusVoiceTests/Transcript/TranscriptTextStorageTests.swift` — runtime XCTest (deferred to host with XCTest, same as other stories).
   - `apps/CactusVoice/CactusVoiceTests/StoryAcceptance/Story2_3Tests.swift` — static grep checks (final class declaration, `: NSTextStorage`, `@MainActor`, all four overrides present, `init(model: TranscriptModel)`, `model.updates` subscription, `.labelColor` + `.secondaryLabelColor` usage).

## Deviation: optimistic local apply + reconcile

NSTextView calls `replaceCharacters(in:with:)` synchronously on the main thread and expects the storage to reflect the new characters before returning so the cursor advances correctly. But our source of truth — `TranscriptModel` — is an actor; we cannot reach it synchronously.

The KISS pattern adopted here:

1. NSTextView calls `replaceCharacters(in:with:)`.
2. We update the cached `NSMutableAttributedString` snapshot **immediately** with the user's text (so the view shows the keystroke at the next layout pass) and emit the `edited(...)` notification.
3. We dispatch `Task { await model.userEdit(range, text) }` to forward the edit to the actor.
4. The actor's broadcast (via `updates`) eventually arrives at our subscription task, which rebuilds the snapshot from the now-authoritative model state. In the common case this is identical to the optimistic snapshot, so the rebuild is idempotent (no visible flicker).
5. If the actor *rejects* the edit (e.g. range was actually in the provisional region — the storage's range-translation should prevent this but defence-in-depth), the next rebuild overwrites the optimistic snapshot with truth and the bad keystroke disappears.

This pattern is the documented compromise between (a) "block NSTextView on an actor hop" (terrible UX, the editing path would freeze) and (b) "let the cache drift indefinitely from the model" (violates the Story 2.3 invariant). Documented in the file header of `TranscriptTextStorage.swift`.

## Deviation: full-snapshot replacement vs. fine-grained diffing

On each `TranscriptUpdate` the implementation rebuilds the **entire** combined `committed + provisional` snapshot and emits a single `edited(.editedCharacters | .editedAttributes, range: NSRange(location: 0, length: oldLength), changeInLength: newLength - oldLength)` notification. Architecture §A's NSTextView row implies fine-grained diffs are possible, but for the transcript size we're targeting (an interactive utterance — tens to hundreds of chars), wholesale replacement is correct, simpler, and well within layout-perf budget. NSLayoutManager handles full re-layout for short strings without measurable lag.

## Tasks

- [ ] T1 — Authored story file (this document) with both deviations.
- [ ] T2 — Acceptance tests (red): `CactusVoiceTests/StoryAcceptance/Story2_3Tests.swift` with static grep checks against the on-disk file shape (subclass, @MainActor, init takes model, four overrides, updates subscription, labelColor/secondaryLabelColor).
- [ ] T3 — Implement `Transcript/TranscriptTextStorage.swift` (~180-220 LOC).
- [ ] T4 — Implement `CactusVoiceTests/Transcript/TranscriptTextStorageTests.swift` (XCTest):
  - On commit from model, storage.string contains the committed text within one runloop tick.
  - replaceCharacters(in:with:) translates to `model.userEdit` and the model's `committed` shows the edit.
  - Attributes at a committed offset have `.labelColor`; at a provisional offset have `.secondaryLabelColor`.
- [ ] T5 — `swiftc -typecheck` TranscriptUpdate.swift + TranscriptModel.swift + TranscriptTextStorage.swift (Foundation + AppKit, target arm64-apple-macos14.0): pass.
- [ ] T6 — Regenerate `.xcodeproj` via `xcodegen generate`.
- [ ] T7 — KISS pass: confirm only the four overrides + init are public; one subscription task; full-snapshot rebuild only.

## Dev Notes

- Architecture refs: §A "Transcript view" row (line 210) — `NSTextView` backed by a custom `NSTextStorage` reflecting `TranscriptModel`. Cross-cutting concern #3 (line 72, 317) — `TranscriptModel` is the only writer; `NSTextStorage` mutation surface routes back through the actor.
- AppKit is imported because `NSTextStorage`, `NSColor.labelColor`, `NSColor.secondaryLabelColor`, and `NSAttributedString` are AppKit types.
- The storage is `@MainActor`. Its subscription task uses `MainActor.run` implicitly (the task body is a closure on a `@MainActor` instance method).
- The cached snapshot is an `NSMutableAttributedString` because (a) `NSTextStorage` semantics are mutable, (b) we hand its `.string` and `.attributes(at:)` back via the overrides verbatim — no copy.
- Range translation for `replaceCharacters`: the NSRange is into the combined `committed + provisional` snapshot. If `NSRange.location >= committedLength` we drop the call (user can't edit provisional). Otherwise clamp `range.upperBound` to `committedLength`, convert to `Range<AttributedString.Index>` on the model's `committed` snapshot fetched at dispatch time (await in the Task body), and call `model.userEdit`.

## Validation

| AC | Covered by |
|----|------------|
| 1 (final class + @MainActor)                  | `Story2_3Tests.testClassDeclaration` |
| 2 (four overrides present)                    | `Story2_3Tests.testFourOverridesPresent` |
| 3 (init takes TranscriptModel + subscription) | `Story2_3Tests.testInitTakesModel` + `testSubscribesToUpdates` |
| 4-5 (snapshot + label colours)                | `Story2_3Tests.testUsesLabelColors` + runtime `TranscriptTextStorageTests.testCommitReachesStorage` |
| 6 (edited(…) notifications)                   | runtime `TranscriptTextStorageTests.testEditedNotificationFires` |
| 7 (replaceCharacters routes to userEdit)      | runtime `TranscriptTextStorageTests.testReplaceCharactersRoutesToModel` |
| 8 (setAttributes touches cache only)          | covered by the override existing + non-throwing |
| 9 (test files present)                        | `Story2_3Tests.testRuntimeTestFileExists` |

## Change Log

- 2026-05-18 — Initial story file authored by story-executor-2.3.
