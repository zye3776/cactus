# Story 2.2: TranscriptModel actor + TranscriptUpdate enum

**Epic:** 2 — Headless Core
**Status:** in_progress
**Owner:** story-executor-2.2

## User Story

As the **inference layer**,
I want **a headless actor that owns transcript state as `committed: AttributedString` + `provisional: AttributedString` with `commit`/`revise`/`userEdit` operations**,
So that **streaming engine commits, engine revisions, and concurrent user edits compose without races or corruption**.

## Acceptance Criteria

1. `apps/CactusVoice/CactusVoice/Transcript/TranscriptUpdate.swift` declares `enum TranscriptUpdate` with `.commit(range:text:)`, `.revise(range:text:)`, `.userEdit(range:text:)` cases. `range` is `Range<AttributedString.Index>`, `text` is `AttributedString`.
2. `apps/CactusVoice/CactusVoice/Transcript/TranscriptModel.swift` declares `actor TranscriptModel` exposing:
   - `var committed: AttributedString`
   - `var provisional: AttributedString`
   - `func commit(range:text:) throws`
   - `func revise(range:text:) throws`
   - `func userEdit(range:text:) throws`
   - `var updates: AsyncStream<TranscriptUpdate>` — broadcasts every state change.
3. Committed and provisional regions are visually distinct via `AttributedString` attributes (provisional region styled with secondary label color via `AppKit.NSColor.secondaryLabelColor`).
4. `commit(range:text:)` accepts only operations whose range is entirely within the *provisional* region (the operation moves text from provisional → end of committed). Illegal ranges throw `TranscriptModelError`.
5. `revise(range:text:)` accepts only operations whose range is entirely within the *provisional* region. Illegal ranges throw.
6. `userEdit(range:text:)` accepts only operations whose range is entirely within the *committed* region. Illegal ranges throw.
7. `TranscriptModelError` is a defined error type with cases covering invalid ranges.
8. Tests in `apps/CactusVoice/CactusVoiceTests/Transcript/TranscriptModelTests.swift` cover: empty-init invariants, commit grows committed prefix, revise mutates provisional tail, userEdit mutates committed prefix, illegal ranges throw, AsyncStream delivers every update in order, concurrent commit + userEdit from two tasks preserves invariants.

## Deviation: range-axis interpretation

`TranscriptUpdate` cases carry a single `Range<AttributedString.Index>`. But the actor stores two separate `AttributedString`s (committed + provisional), and an `AttributedString.Index` is only meaningful relative to one specific `AttributedString` instance. Rather than maintaining a "merged view" `AttributedString` (which would add a third source of truth that has to be kept consistent — violates KISS and Concern #3's "one writer" property), this story interprets the range axis as follows:

- `commit(range:text:)` and `revise(range:text:)` — `range` is an index range into `self.provisional`.
- `userEdit(range:text:)` — `range` is an index range into `self.committed`.

This matches each AC literally: "commit accepts only operations entirely within the provisional region" → the caller already names indices into provisional; the actor only needs to validate they are in `provisional.startIndex..<provisional.endIndex`. The actor never mixes indices across the two fields.

The `TranscriptUpdate` broadcast carries the same range that was passed in — consumers (e.g. `TranscriptTextStorage` in Story 2.3) decide how to map it into their combined view by tracking which case was emitted (commit/revise → provisional offset; userEdit → committed offset).

This is documented in the file header of `TranscriptModel.swift` and `TranscriptUpdate.swift` and revisited in Story 2.3 if the storage layer needs a different shape.

## Tasks

- [x] T1 — Acceptance tests (red): static greps + structural checks on the two source files (actor, enum, three methods, `updates: AsyncStream<TranscriptUpdate>`, error type, tests file present).
- [x] T2 — Implement `Transcript/TranscriptUpdate.swift` (≤ 40 LOC).
- [x] T3 — Implement `Transcript/TranscriptModel.swift` (~150-180 LOC).
- [x] T4 — Implement `CactusVoiceTests/Transcript/TranscriptModelTests.swift` (XCTest).
- [x] T5 — `swiftc -typecheck` both production files (Foundation + AppKit, macOS 14, arm64): pass.
- [x] T6 — Regenerate `.xcodeproj` via `xcodegen generate`.
- [x] T7 — KISS pass.

## Dev Notes

- Architecture refs: §A (transcript state row, line 176) + cross-cutting concern #3 (line 72 — committed/provisional state machine).
- `AppKit` is imported because the provisional styling uses `NSColor.secondaryLabelColor`. This file is macOS-only, consistent with the app target.
- The `updates` stream is built with `AsyncStream.makeStream(of:)`; the continuation is held by the actor and yielded on every successful mutation. No replay buffering — subscribers must subscribe before the first update they care about. (Story 2.3's view-model subscribes once at app launch, so this is fine.)
- Tests run under XCTest. On this CLT-only host the test target won't build (no XCTest module); static greps in `Story2_2Tests.swift` enforce the on-disk contract.

## Validation

| AC | Covered by |
|----|------------|
| 1 (TranscriptUpdate enum shape)        | `Story2_2Tests.testTranscriptUpdateEnumShape` |
| 2 (TranscriptModel actor shape)        | `Story2_2Tests.testActorAndApiShape` |
| 3 (provisional styled distinctly)      | `Story2_2Tests.testProvisionalStylingDeclared` |
| 4-6 (range validation)                 | runtime `TranscriptModelTests` illegal-range cases |
| 7 (error type defined)                 | `Story2_2Tests.testTranscriptModelErrorDefined` |
| 8 (test file present + key cases)      | `Story2_2Tests.testTranscriptModelTestsExist` + runtime tests |

## Change Log

- 2026-05-18 — Initial story file authored by story-executor-2.2.
