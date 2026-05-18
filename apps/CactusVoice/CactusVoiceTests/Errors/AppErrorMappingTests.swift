import XCTest
@testable import CactusVoice

/// Mapping tests for `AppError`: every case produces a non-nil, bounded,
/// declarative banner per UX-DR6, and `Equatable` works on associated values.
final class AppErrorMappingTests: XCTestCase {

    /// One representative instance of every `AppError` case, including every
    /// `InferenceStage` variant of `.inferenceFailed`. Mirrored by the
    /// exhaustive switch in `ErrorBanner` (architecture §G).
    private var allRepresentativeCases: [AppError] {
        var cases: [AppError] = [
            .micDenied,
            .modelLoadFailed(path: "/tmp/whisper.bin", reason: "io"),
            .clipboardWriteFailed,
            .hotkeyConflict(existing: "Cmd+Shift+V"),
            .vadLoadFailed(reason: "io"),
            .correctionFailed(reason: "tokenizer"),
        ]
        for stage in [InferenceStage.audio, .whisper, .vad, .llm, .correction] {
            cases.append(.inferenceFailed(stage: stage, reason: "boom"))
        }
        return cases
    }

    func testEveryCaseHasBoundedBanner() {
        for err in allRepresentativeCases {
            let description = err.errorDescription
            XCTAssertNotNil(description,
                            "errorDescription must be non-nil for \(err)")
            guard let s = description else { continue }
            XCTAssertLessThanOrEqual(s.count, 48,
                                     "Banner '\(s)' for \(err) exceeds 48 chars")
            let wordCount = s.split(whereSeparator: { $0.isWhitespace }).count
            XCTAssertLessThanOrEqual(wordCount, 8,
                                     "Banner '\(s)' for \(err) exceeds 8 words (UX-DR6)")
            XCTAssertFalse(s.contains("!"),
                           "Banner '\(s)' must not contain exclamation marks (UX-DR6)")
        }
    }

    func testMicDeniedBannerMatchesUXDR6() {
        XCTAssertEqual(AppError.micDenied.errorDescription,
                       "Microphone access required.")
    }

    func testEquatableDistinguishesAssociatedValues() {
        XCTAssertEqual(AppError.modelLoadFailed(path: "/a", reason: "io"),
                       AppError.modelLoadFailed(path: "/a", reason: "io"))
        XCTAssertNotEqual(AppError.modelLoadFailed(path: "/a", reason: "io"),
                          AppError.modelLoadFailed(path: "/b", reason: "io"))
        XCTAssertNotEqual(AppError.inferenceFailed(stage: .whisper, reason: "x"),
                          AppError.inferenceFailed(stage: .llm, reason: "x"))
        XCTAssertEqual(AppError.micDenied, AppError.micDenied)
        XCTAssertNotEqual(AppError.micDenied, AppError.clipboardWriteFailed)
    }
}
