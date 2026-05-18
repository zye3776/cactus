import XCTest

/// Acceptance tests for Story 2.3 — TranscriptTextStorage (NSTextStorage subclass).
///
/// File-level static checks against the on-disk source so the structural
/// contract is enforced even on hosts without Xcode.app. Runtime semantics
/// (snapshot rebuild on commit, replaceCharacters routes to model.userEdit,
/// label-colour attribution) live in
/// `CactusVoiceTests/Transcript/TranscriptTextStorageTests.swift`.
final class Story2_3Tests: XCTestCase {

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

    // MARK: - AC1: file exists, declared as final class subclass of NSTextStorage, @MainActor

    func testTranscriptTextStorageFileExists() {
        XCTAssertTrue(exists("CactusVoice/Transcript/TranscriptTextStorage.swift"),
                      "TranscriptTextStorage.swift must live at CactusVoice/Transcript/TranscriptTextStorage.swift")
    }

    func testClassDeclaration() throws {
        let s = try read("CactusVoice/Transcript/TranscriptTextStorage.swift")
        XCTAssertTrue(s.contains("final class TranscriptTextStorage: NSTextStorage"),
                      "Must declare `final class TranscriptTextStorage: NSTextStorage`")
        XCTAssertTrue(s.contains("@MainActor"),
                      "Class must be annotated @MainActor to bind storage mutation to the main thread")
        XCTAssertTrue(s.contains("import AppKit"),
                      "Must import AppKit for NSTextStorage / NSColor")
    }

    // MARK: - AC2: four NSTextStorage overrides

    func testFourOverridesPresent() throws {
        let s = try read("CactusVoice/Transcript/TranscriptTextStorage.swift")
        XCTAssertTrue(s.contains("override var string"),
                      "Must override `var string`")
        XCTAssertTrue(s.contains("override func attributes(at"),
                      "Must override `func attributes(at:effectiveRange:)`")
        XCTAssertTrue(s.contains("override func replaceCharacters(in"),
                      "Must override `func replaceCharacters(in:with:)`")
        XCTAssertTrue(s.contains("override func setAttributes("),
                      "Must override `func setAttributes(_:range:)`")
    }

    // MARK: - AC3: init takes a TranscriptModel and subscribes to updates

    func testInitTakesModel() throws {
        let s = try read("CactusVoice/Transcript/TranscriptTextStorage.swift")
        XCTAssertTrue(s.contains("init(model: TranscriptModel)"),
                      "Must declare `init(model: TranscriptModel)`")
    }

    func testSubscribesToUpdates() throws {
        let s = try read("CactusVoice/Transcript/TranscriptTextStorage.swift")
        XCTAssertTrue(s.contains("model.updates"),
                      "Must subscribe to `model.updates` AsyncStream")
        XCTAssertTrue(s.contains("for await") || s.contains("for try await"),
                      "Must consume model.updates with `for await`")
    }

    // MARK: - AC5: committed → labelColor, provisional → secondaryLabelColor

    func testUsesLabelColors() throws {
        let s = try read("CactusVoice/Transcript/TranscriptTextStorage.swift")
        XCTAssertTrue(s.contains("labelColor"),
                      "Committed text must render with NSColor.labelColor")
        XCTAssertTrue(s.contains("secondaryLabelColor"),
                      "Provisional text must render with NSColor.secondaryLabelColor")
    }

    // MARK: - AC7: replaceCharacters dispatches userEdit on the actor

    func testReplaceCharactersRoutesToUserEdit() throws {
        let s = try read("CactusVoice/Transcript/TranscriptTextStorage.swift")
        XCTAssertTrue(s.contains("userEdit"),
                      "replaceCharacters(in:with:) must dispatch `model.userEdit`")
        XCTAssertTrue(s.contains("Task"),
                      "userEdit dispatch must occur inside a Task (actor hop from sync NSTextStorage call)")
    }

    // MARK: - AC6: emits edited(...) notifications

    func testEmitsEditedNotifications() throws {
        let s = try read("CactusVoice/Transcript/TranscriptTextStorage.swift")
        XCTAssertTrue(s.contains("edited("),
                      "Must call `edited(_:range:changeInLength:)` to drive NSTextView re-layout")
        XCTAssertTrue(s.contains("beginEditing") && s.contains("endEditing"),
                      "Snapshot rebuild must be wrapped in beginEditing()/endEditing()")
    }

    // MARK: - AC9: runtime tests file exists

    func testRuntimeTestFileExists() {
        XCTAssertTrue(exists("CactusVoiceTests/Transcript/TranscriptTextStorageTests.swift"),
                      "TranscriptTextStorageTests.swift must live at CactusVoiceTests/Transcript/TranscriptTextStorageTests.swift")
    }

    // MARK: - KISS: implementation file size budget

    func testTranscriptTextStorageUnder260LOC() throws {
        let lines = try lineCount("CactusVoice/Transcript/TranscriptTextStorage.swift")
        XCTAssertLessThanOrEqual(lines, 260,
                                 "TranscriptTextStorage.swift must be ≤ 260 LOC, got \(lines)")
    }
}
