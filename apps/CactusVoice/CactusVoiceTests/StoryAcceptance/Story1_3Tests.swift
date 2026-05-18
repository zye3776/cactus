import XCTest

/// Acceptance tests for Story 1.3 — Measurement spike (bundle + tiered resident memory).
///
/// These are file-level static checks that grep the spike source file and
/// verify the contract from the story's acceptance criteria. The spike test
/// itself is intentionally a runtime test that skips under `XCTSkipUnless`
/// when real model paths are not provided via environment variables, so we
/// cannot exercise its body here — but we *can* assert it is shaped correctly.
final class Story1_3Tests: XCTestCase {

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

    /// Walks up further to the repo root (the directory containing `_bmad-output`).
    private var repoRoot: URL {
        var url = appRoot
        while !FileManager.default.fileExists(
            atPath: url.appendingPathComponent("_bmad-output").path
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

    // MARK: - AC1: file location + env-var gating

    func testSpikeFileExistsAtRequiredPath() {
        XCTAssertTrue(exists("CactusVoiceTests/Spike/MeasurementSpikeTests.swift"),
                      "Spike file must live at CactusVoiceTests/Spike/MeasurementSpikeTests.swift")
    }

    func testSpikeUsesEnvVarGating() throws {
        let s = try read("CactusVoiceTests/Spike/MeasurementSpikeTests.swift")
        let requiredEnvVars = [
            "CACTUSVOICE_WHISPER_PATH",
            "CACTUSVOICE_GEMMA_PATH",
            "CACTUSVOICE_VAD_PATH",
            "CACTUSVOICE_APP_BUNDLE_PATH",
        ]
        for envVar in requiredEnvVars {
            XCTAssertTrue(s.contains(envVar),
                          "Spike must reference env var \(envVar)")
        }
        XCTAssertTrue(s.contains("XCTSkipUnless"),
                      "Spike must use XCTSkipUnless so it does not run in CI by default")
    }

    // MARK: - AC4: CSV output path

    func testCsvPathIsCorrect() throws {
        let s = try read("CactusVoiceTests/Spike/MeasurementSpikeTests.swift")
        XCTAssertTrue(
            s.contains("_bmad-output/implementation-artifacts/measurement-spike-results.csv"),
            "Spike must append to _bmad-output/implementation-artifacts/measurement-spike-results.csv"
        )
    }

    // MARK: - AC5: task_info for residency

    func testSpikeCallsTaskInfoForResidency() throws {
        let s = try read("CactusVoiceTests/Spike/MeasurementSpikeTests.swift")
        XCTAssertTrue(s.contains("task_info"),
                      "Spike must call task_info to read resident memory")
        XCTAssertTrue(s.contains("mach_task_basic_info") ||
                      s.contains("MACH_TASK_BASIC_INFO"),
                      "Spike must use mach_task_basic_info flavor for resident_size")
        XCTAssertTrue(s.contains("resident_size"),
                      "Spike must read resident_size out of the task_info result")
    }

    // MARK: - AC2-3: load three model types + minimal/full modes referenced

    func testSpikeMeasuresBothModes() throws {
        let s = try read("CactusVoiceTests/Spike/MeasurementSpikeTests.swift")
        XCTAssertTrue(s.contains("minimal"),
                      "Spike must measure minimal-accuracy mode (Whisper + VAD)")
        XCTAssertTrue(s.contains("full"),
                      "Spike must measure full-accuracy mode (adds Gemma-3)")
        XCTAssertTrue(s.contains("loadModel"),
                      "Spike must call FFIShim.loadModel to bring models resident")
        XCTAssertTrue(s.contains("freeModel"),
                      "Spike must call FFIShim.freeModel to release handles before exit")
    }

    // MARK: - AC6: divergence-procedure comment present in spike

    func testSpikeDocumentsDivergenceProcedure() throws {
        let s = try read("CactusVoiceTests/Spike/MeasurementSpikeTests.swift")
        XCTAssertTrue(s.contains("NFR-001"),
                      "Spike must reference NFR-001 so the divergence procedure is discoverable")
        XCTAssertTrue(s.contains("20"),
                      "Spike must document the 20% deviation threshold")
    }
}
