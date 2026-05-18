import XCTest

/// Acceptance tests for Story 3.5 — End-to-end baseline wiring + integration
/// test. File-level static checks against the on-disk source so the
/// structural contract is enforced even on hosts without Xcode.app. Runtime
/// semantics (real WAV decode, real Whisper + VAD models, WER computation)
/// live in `CactusVoiceTests/Inference/BaselinePipelineTests.swift` and are
/// `XCTSkipUnless`-gated on three env vars (`CACTUSVOICE_WHISPER_PATH`,
/// `CACTUSVOICE_VAD_PATH`, `CACTUSVOICE_BASELINE_WAV`) so they execute on a
/// developer / CI host with Xcode.app + the models + the fixture WAV.
final class Story3_5Tests: XCTestCase {

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

    // MARK: - AC1: BaselinePipelineTests.swift exists at the canonical path

    func testBaselinePipelineTestsFileExists() {
        XCTAssertTrue(
            exists("CactusVoiceTests/Inference/BaselinePipelineTests.swift"),
            "BaselinePipelineTests.swift must live at CactusVoiceTests/Inference/BaselinePipelineTests.swift"
        )
    }

    // MARK: - AC1: declares one XCTestCase

    func testDeclaresXCTestCase() throws {
        let s = try read("CactusVoiceTests/Inference/BaselinePipelineTests.swift")
        XCTAssertTrue(
            s.contains(": XCTestCase"),
            "Must declare a class conforming to XCTestCase"
        )
    }

    // MARK: - AC2: wires all four actor types

    func testWiresAllFourActors() throws {
        let s = try read("CactusVoiceTests/Inference/BaselinePipelineTests.swift")
        XCTAssertTrue(s.contains("AudioCapture"), "Must wire AudioCapture")
        XCTAssertTrue(s.contains("SileroVAD"), "Must wire SileroVAD")
        XCTAssertTrue(s.contains("WhisperSession"), "Must wire WhisperSession")
        XCTAssertTrue(s.contains("TranscriptModel"), "Must wire TranscriptModel")
    }

    // MARK: - AC2: uses CactusRuntime to own handles

    func testUsesCactusRuntime() throws {
        let s = try read("CactusVoiceTests/Inference/BaselinePipelineTests.swift")
        XCTAssertTrue(
            s.contains("CactusRuntime"),
            "Must acquire model handles via CactusRuntime"
        )
    }

    // MARK: - AC6: XCTSkipUnless gating on env vars

    func testXCTSkipUnlessGuards() throws {
        let s = try read("CactusVoiceTests/Inference/BaselinePipelineTests.swift")
        XCTAssertTrue(
            s.contains("XCTSkipUnless"),
            "Must use XCTSkipUnless to gate on env vars on hosts without models"
        )
        XCTAssertTrue(
            s.contains("CACTUSVOICE_WHISPER_PATH"),
            "Must reference CACTUSVOICE_WHISPER_PATH env var"
        )
        XCTAssertTrue(
            s.contains("CACTUSVOICE_VAD_PATH"),
            "Must reference CACTUSVOICE_VAD_PATH env var"
        )
        XCTAssertTrue(
            s.contains("CACTUSVOICE_BASELINE_WAV"),
            "Must reference CACTUSVOICE_BASELINE_WAV env var"
        )
    }

    // MARK: - AC4: reads TranscriptModel.committed

    func testReadsTranscriptCommitted() throws {
        let s = try read("CactusVoiceTests/Inference/BaselinePipelineTests.swift")
        XCTAssertTrue(
            s.contains("transcript.committed") || s.contains(".committed"),
            "Must read TranscriptModel.committed after stop()"
        )
    }

    // MARK: - AC7: WER helper present

    func testWERHelperPresent() throws {
        let s = try read("CactusVoiceTests/Inference/BaselinePipelineTests.swift")
        XCTAssertTrue(
            s.contains("func wer("),
            "Must define an inline `func wer(...)` helper for WER computation"
        )
        XCTAssertTrue(
            s.contains("Levenshtein") || s.contains("levenshtein"),
            "WER helper must be Levenshtein-based (documented in source)"
        )
    }

    // MARK: - AC4: 15% WER bound asserted

    func testWERBoundAsserted() throws {
        let s = try read("CactusVoiceTests/Inference/BaselinePipelineTests.swift")
        let normalized = s.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
        XCTAssertTrue(
            normalized.contains("0.15") || normalized.contains("15%") || normalized.contains("15.0"),
            "Must assert WER ≤ 15% baseline bound"
        )
    }

    // MARK: - AC4: speechStart / speechEnd assertion

    func testSpeechBoundaryAssertion() throws {
        let s = try read("CactusVoiceTests/Inference/BaselinePipelineTests.swift")
        XCTAssertTrue(
            s.contains(".speechStart"),
            "Must assert at least one VAD .speechStart event was observed"
        )
        XCTAssertTrue(
            s.contains(".speechEnd"),
            "Must assert at least one VAD .speechEnd event was observed"
        )
    }

    // MARK: - AC4: language="en" assertion

    func testLanguageEnglishAssertion() throws {
        let s = try read("CactusVoiceTests/Inference/BaselinePipelineTests.swift")
        let normalized = s.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
        XCTAssertTrue(
            normalized.contains("language:\"en\"") || normalized.contains("language==\"en\"")
            || normalized.contains(".language,\"en\"") || normalized.contains("\"en\""),
            "Must assert language=\"en\" was used (via WhisperOpts.researchDefaults)"
        )
    }

    // MARK: - AC7: wavReader helper present

    func testWavReaderHelperPresent() throws {
        let s = try read("CactusVoiceTests/Inference/BaselinePipelineTests.swift")
        XCTAssertTrue(
            s.contains("func wavReader") || s.contains("readWAV") || s.contains("decodeWAV"),
            "Must define an inline WAV reader helper"
        )
        XCTAssertTrue(
            s.contains("canImport(AVFoundation)"),
            "WAV reader must be guarded by `#if canImport(AVFoundation)`"
        )
    }

    // MARK: - AC5: releases model handles on tear-down

    func testReleasesHandlesOnTearDown() throws {
        let s = try read("CactusVoiceTests/Inference/BaselinePipelineTests.swift")
        XCTAssertTrue(
            s.contains("tearDown") || s.contains("unloadAll"),
            "Must release model handles on tear-down (tearDown / unloadAll)"
        )
    }

    // MARK: - AC8: Fixtures/README.md exists

    func testFixturesReadmeExists() {
        XCTAssertTrue(
            exists("CactusVoiceTests/Fixtures/README.md"),
            "Fixtures/README.md must exist documenting WAV + reference transcript placement + WER method"
        )
    }

    // MARK: - AC8: Fixtures README documents WAV path + transcript path + WER method

    func testFixturesReadmeContent() throws {
        let s = try read("CactusVoiceTests/Fixtures/README.md")
        XCTAssertTrue(
            s.contains("baseline_10s.wav"),
            "README must reference baseline_10s.wav file name"
        )
        XCTAssertTrue(
            s.contains("baseline_10s.transcript.txt") || s.contains("reference transcript"),
            "README must reference the reference transcript file"
        )
        XCTAssertTrue(
            s.lowercased().contains("wer") || s.lowercased().contains("word error rate"),
            "README must describe the WER computation method"
        )
    }

    // MARK: - Budget

    func testBaselinePipelineTestsBudget() throws {
        let n = try lineCount("CactusVoiceTests/Inference/BaselinePipelineTests.swift")
        XCTAssertLessThanOrEqual(
            n, 360,
            "BaselinePipelineTests.swift line count (\(n)) must be ≤ 360 (KISS — one test + WAV reader + WER + stubs)"
        )
    }
}
