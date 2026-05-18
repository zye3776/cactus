import XCTest

/// Acceptance tests for Story 2.2 — TranscriptModel actor + TranscriptUpdate enum.
///
/// File-level static checks against the on-disk source so the structural
/// contract is enforced even on hosts without Xcode.app. Runtime semantics
/// (commit/revise/userEdit invariants, illegal-range throws, AsyncStream
/// ordering, concurrent commit + userEdit) live in
/// `CactusVoiceTests/Transcript/TranscriptModelTests.swift`.
final class Story2_2Tests: XCTestCase {

    // MARK: - Helpers

    private var appRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "CactusVoice" || !FileManager.default.fileExists(
            atPath: url.appendingPathComponent("project.yml").path
        ) {
            let parent = url.deletingLastPathComponent()
            if parent == url { break }
            url = parent
        }
        return url
    }

    private func read(_ relative: String) throws -> String {
        let url = appRoot.appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(
            atPath: appRoot.appendingPathComponent(relative).path
        )
    }

    private func lineCount(_ relative: String) throws -> Int {
        let s = try read(relative)
        var count = 0
        for ch in s where ch == "\n" { count += 1 }
        if !s.hasSuffix("\n"), !s.isEmpty { count += 1 }
        return count
    }

    // MARK: - AC1: TranscriptUpdate enum exists with three cases

    func testTranscriptUpdateFileExists() {
        XCTAssertTrue(exists("CactusVoice/Transcript/TranscriptUpdate.swift"),
                      "TranscriptUpdate.swift must live at CactusVoice/Transcript/TranscriptUpdate.swift")
    }

    func testTranscriptUpdateEnumShape() throws {
        let s = try read("CactusVoice/Transcript/TranscriptUpdate.swift")
        XCTAssertTrue(s.contains("enum TranscriptUpdate"),
                      "TranscriptUpdate must be declared as an enum")
        XCTAssertTrue(s.contains("case commit("),
                      "TranscriptUpdate must declare a .commit case")
        XCTAssertTrue(s.contains("case revise("),
                      "TranscriptUpdate must declare a .revise case")
        XCTAssertTrue(s.contains("case userEdit("),
                      "TranscriptUpdate must declare a .userEdit case")
        XCTAssertTrue(s.contains("Range<AttributedString.Index>"),
                      "TranscriptUpdate cases must carry Range<AttributedString.Index>")
        XCTAssertTrue(s.contains("AttributedString"),
                      "TranscriptUpdate cases must carry AttributedString text")
    }

    // MARK: - AC2: TranscriptModel actor with documented API

    func testTranscriptModelFileExists() {
        XCTAssertTrue(exists("CactusVoice/Transcript/TranscriptModel.swift"),
                      "TranscriptModel.swift must live at CactusVoice/Transcript/TranscriptModel.swift")
    }

    func testActorAndApiShape() throws {
        let s = try read("CactusVoice/Transcript/TranscriptModel.swift")
        XCTAssertTrue(s.contains("actor TranscriptModel"),
                      "TranscriptModel must be declared as an actor")
        XCTAssertTrue(s.contains("var committed"),
                      "TranscriptModel must expose `committed` state")
        XCTAssertTrue(s.contains("var provisional"),
                      "TranscriptModel must expose `provisional` state")
        XCTAssertTrue(s.contains("func commit("),
                      "TranscriptModel must declare commit(range:text:)")
        XCTAssertTrue(s.contains("func revise("),
                      "TranscriptModel must declare revise(range:text:)")
        XCTAssertTrue(s.contains("func userEdit("),
                      "TranscriptModel must declare userEdit(range:text:)")
        XCTAssertTrue(s.contains("AsyncStream<TranscriptUpdate>"),
                      "TranscriptModel must expose `updates: AsyncStream<TranscriptUpdate>`")
        XCTAssertTrue(s.contains("updates"),
                      "TranscriptModel must name the stream `updates`")
    }

    // MARK: - AC3: provisional styled distinctly (AppKit color attribute)

    func testProvisionalStylingDeclared() throws {
        let s = try read("CactusVoice/Transcript/TranscriptModel.swift")
        XCTAssertTrue(s.contains("import AppKit"),
                      "TranscriptModel must import AppKit for NSColor")
        XCTAssertTrue(s.contains("secondaryLabelColor"),
                      "Provisional region must be styled with NSColor.secondaryLabelColor")
    }

    // MARK: - AC4-6: range validation - methods marked `throws`

    func testMutationMethodsThrow() throws {
        let s = try read("CactusVoice/Transcript/TranscriptModel.swift")
        // All three mutation entry points must be `throws` so illegal ranges
        // surface to callers rather than being silently swallowed.
        XCTAssertTrue(s.contains("func commit(") && s.contains("throws"),
                      "commit(...) must be declared `throws`")
        XCTAssertTrue(s.contains("func revise("),
                      "revise(...) must be declared")
        XCTAssertTrue(s.contains("func userEdit("),
                      "userEdit(...) must be declared")
        // Cheap structural check: the literal `throws ->` or `) throws` pattern
        // must appear three times (once per mutation entry point).
        let throwsHits = s.components(separatedBy: ") throws").count - 1
        XCTAssertGreaterThanOrEqual(throwsHits, 3,
                                    "commit/revise/userEdit must all be marked throws")
    }

    // MARK: - AC7: TranscriptModelError defined

    func testTranscriptModelErrorDefined() throws {
        let s = try read("CactusVoice/Transcript/TranscriptModel.swift")
        XCTAssertTrue(s.contains("TranscriptModelError"),
                      "TranscriptModelError must be defined")
        XCTAssertTrue(s.contains(": Error") || s.contains("enum TranscriptModelError"),
                      "TranscriptModelError must conform to Error")
    }

    // MARK: - AC8: runtime tests file exists at the expected path

    func testTranscriptModelTestsExist() {
        XCTAssertTrue(exists("CactusVoiceTests/Transcript/TranscriptModelTests.swift"),
                      "TranscriptModelTests.swift must live at CactusVoiceTests/Transcript/TranscriptModelTests.swift")
    }

    // MARK: - KISS: implementation file size budget

    func testTranscriptUpdateUnder40LOC() throws {
        let lines = try lineCount("CactusVoice/Transcript/TranscriptUpdate.swift")
        XCTAssertLessThanOrEqual(lines, 40,
                                 "TranscriptUpdate.swift must be ≤ 40 LOC, got \(lines)")
    }

    func testTranscriptModelUnder200LOC() throws {
        let lines = try lineCount("CactusVoice/Transcript/TranscriptModel.swift")
        XCTAssertLessThanOrEqual(lines, 200,
                                 "TranscriptModel.swift must be ≤ 200 LOC, got \(lines)")
    }
}
