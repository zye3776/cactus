# Story 1.4: AppError enum + os.Logger conventions

**Epic:** 1 — Project Foundation & FFI Seam
**Status:** done
**Owner:** story-executor-1.4

## User Story

As the **developer of any later component**,
I want **one `AppError` enum and a consistent `os.Logger` setup**,
So that **error reporting and logging never become ad-hoc per file**.

## Acceptance Criteria

1. `apps/CactusVoice/CactusVoice/Errors/AppError.swift` defines a single Swift `enum AppError` conforming to `Error`, `LocalizedError`, `Equatable`, `Sendable`.
2. Cases are exactly: `.micDenied`, `.modelLoadFailed(path: String, reason: String)`, `.inferenceFailed(stage: InferenceStage, reason: String)`, `.clipboardWriteFailed`, `.hotkeyConflict(existing: String)`, `.vadLoadFailed(reason: String)`, `.correctionFailed(reason: String)`.
3. `InferenceStage` is an enum with cases at least `.audio`, `.whisper`, `.vad`, `.llm`, `.correction`.
4. `errorDescription` returns a ≤ 8-word, declarative banner string per case matching UX-DR6 (e.g., `.micDenied` → "Microphone access required.").
5. `apps/CactusVoice/CactusVoiceTests/Errors/AppErrorMappingTests.swift` exercises representative instances of every case and asserts `errorDescription != nil` and within the ≤ 8-word / ≤ 48-char banner budget; asserts `Equatable` behavior; asserts the `.micDenied` banner equals the UX-DR6 string.
6. `apps/CactusVoice/CactusVoice/Errors/README.md` documents the `os.Logger` convention: one `private let log = Logger(subsystem: "com.cactusvoice", category: "<componentName>")` per file/type; `AppError` is logged at `.error` exactly once at creation site; user-content interpolations must use `privacy: .private`; clipboard contents are never logged.
7. `.swiftformat` lint-wiring is explicitly deferred; the README notes the rule is a future-story concern.

## Tasks

- [x] T1 — Acceptance tests (red), grep-level static checks against expected `AppError.swift` shape.
- [x] T2 — Author `Errors/AppError.swift` (enum + InferenceStage + errorDescription).
- [x] T3 — Author `CactusVoiceTests/Errors/AppErrorMappingTests.swift` (banner-string + Equatable assertions).
- [x] T4 — Author `Errors/README.md` (logger convention).
- [x] T5 — `swiftc -typecheck` the new `AppError.swift` against Foundation only.
- [x] T6 — Regenerate `.xcodeproj` via `xcodegen generate`.

## Dev Notes

- Architecture refs: §G (Observability & Errors) lines 238–246; §4 Error Handling lines 301–306; §5 Logging lines 308–313; line 741 (additional cases `.vadLoadFailed`, `.correctionFailed` from accuracy revision).
- UX refs: ux-design-specification.md line 247 (Microphone access required.), lines 455–460 (copy / microcopy rules: declarative, ≤ 8 words, no exclamation marks).
- `AppError` is `Sendable` because all associated values are `String` or another `Sendable` enum (`InferenceStage`).
- `InferenceStage` is nested into `AppError` to keep the namespace tight; one principal type per file per architecture line 281.
- Logging conventions are documented in `Errors/README.md` rather than enforced by a linter — `.swiftformat` wiring is a future story (architecture line 343 calls for `swift-format`, but no config file in v1).
- The mapping test will fail to run on this CLT-only host (no XCTest module). It is shipped to run on any host with Xcode.app; same constraint already documented in stories 1.1–1.3.

## Validation

| AC | Covered by |
|----|------------|
| 1 (enum + protocols) | `Story1_4Tests.testAppErrorFileExists`, `testAppErrorDeclaresRequiredProtocols` |
| 2 (case list) | `Story1_4Tests.testAppErrorHasAllRequiredCases` |
| 3 (InferenceStage) | `Story1_4Tests.testInferenceStageDefinedWithRequiredCases` |
| 4 (banner text) | `Story1_4Tests.testAppErrorMappingTestsExist`, runtime `AppErrorMappingTests.testEveryCaseHasBoundedBanner` |
| 5 (mapping test file) | `Story1_4Tests.testAppErrorMappingTestsExist` |
| 6 (logger README) | `Story1_4Tests.testErrorsReadmeDocumentsLoggerConvention` |
| 7 (no swiftformat wiring) | Documented in `Errors/README.md` |

## Change Log

- 2026-05-18 — Initial story file authored by story-executor-1.4.
