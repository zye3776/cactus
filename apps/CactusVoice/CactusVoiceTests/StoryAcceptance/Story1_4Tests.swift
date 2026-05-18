import XCTest

/// Acceptance tests for Story 1.4 — AppError enum + os.Logger conventions.
///
/// These are file-level static checks that grep the `AppError.swift` source
/// and verify the contract from the story's acceptance criteria. The runtime
/// mapping behaviour is covered by `CactusVoiceTests/Errors/AppErrorMappingTests.swift`,
/// which executes under XCTest at build time; this file only asserts the
/// shape of the on-disk source so the contract is enforced even when the
/// host has no Xcode.app.
final class Story1_4Tests: XCTestCase {

    // MARK: - Helpers

    /// Walks up from this source file to the `apps/CactusVoice` directory.
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

    // MARK: - AC1: file location + protocol conformance

    func testAppErrorFileExists() {
        XCTAssertTrue(exists("CactusVoice/Errors/AppError.swift"),
                      "AppError.swift must live at CactusVoice/Errors/AppError.swift")
    }

    func testAppErrorDeclaresRequiredProtocols() throws {
        let s = try read("CactusVoice/Errors/AppError.swift")
        // Match the enum declaration line, tolerating spacing variations.
        XCTAssertTrue(s.contains("enum AppError"),
                      "AppError must be declared as a Swift enum")
        for proto in ["Error", "LocalizedError", "Equatable", "Sendable"] {
            XCTAssertTrue(s.contains(proto),
                          "AppError must conform to \(proto)")
        }
    }

    // MARK: - AC2: every required case is present

    func testAppErrorHasAllRequiredCases() throws {
        let s = try read("CactusVoice/Errors/AppError.swift")
        let requiredCases = [
            "case micDenied",
            "case modelLoadFailed(path: String, reason: String)",
            "case inferenceFailed(stage: InferenceStage, reason: String)",
            "case clipboardWriteFailed",
            "case hotkeyConflict(existing: String)",
            "case vadLoadFailed(reason: String)",
            "case correctionFailed(reason: String)",
        ]
        for c in requiredCases {
            XCTAssertTrue(s.contains(c),
                          "AppError must declare exactly: \(c)")
        }
    }

    // MARK: - AC3: InferenceStage with required cases

    func testInferenceStageDefinedWithRequiredCases() throws {
        let s = try read("CactusVoice/Errors/AppError.swift")
        XCTAssertTrue(s.contains("enum InferenceStage"),
                      "InferenceStage must be declared as a Swift enum")
        for c in ["case audio", "case whisper", "case vad", "case llm", "case correction"] {
            XCTAssertTrue(s.contains(c),
                          "InferenceStage must declare \(c)")
        }
    }

    // MARK: - AC4: errorDescription per UX-DR6 (the .micDenied banner is canonical)

    func testMicDeniedBannerMatchesUXDR6() throws {
        let s = try read("CactusVoice/Errors/AppError.swift")
        XCTAssertTrue(s.contains("Microphone access required."),
                      "errorDescription for .micDenied must be exactly 'Microphone access required.' per UX-DR6 and ux-design-specification.md line 247")
    }

    func testErrorDescriptionIsImplemented() throws {
        let s = try read("CactusVoice/Errors/AppError.swift")
        XCTAssertTrue(s.contains("var errorDescription"),
                      "AppError must implement errorDescription for LocalizedError")
    }

    // MARK: - AC5: mapping test file exists

    func testAppErrorMappingTestsExist() {
        XCTAssertTrue(exists("CactusVoiceTests/Errors/AppErrorMappingTests.swift"),
                      "Mapping tests must live at CactusVoiceTests/Errors/AppErrorMappingTests.swift")
    }

    // MARK: - AC6: README documents the os.Logger convention

    func testErrorsReadmeDocumentsLoggerConvention() throws {
        let s = try read("CactusVoice/Errors/README.md")
        XCTAssertTrue(s.contains("com.cactusvoice"),
                      "Errors README must name the os.Logger subsystem com.cactusvoice")
        XCTAssertTrue(s.contains("Logger(subsystem:"),
                      "Errors README must show the canonical Logger initializer")
        XCTAssertTrue(s.lowercased().contains("once"),
                      "Errors README must state that AppError is logged once at creation site")
        XCTAssertTrue(s.contains("privacy: .private"),
                      "Errors README must require privacy: .private for user-content interpolations")
    }
}
