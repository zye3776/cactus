import XCTest

/// Acceptance tests for Story 3.3 — SileroVAD actor with 512-sample / 32 ms
/// windows over 16 kHz audio, configurable threshold (default 0.5), 1.5 s
/// silence-end, 300 ms stitch gap, AppError.vadLoadFailed surfacing, and a
/// VADInference protocol seam.
///
/// File-level static checks against the on-disk source so the structural
/// contract is enforced even on hosts without Xcode.app. Runtime semantics
/// (event ordering, threshold sensitivity, stitch / no-stitch behaviour) live
/// in `CactusVoiceTests/Inference/SileroVADTests.swift` with a stub
/// `VADInference` injected at the seam.
final class Story3_3Tests: XCTestCase {

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

    // MARK: - AC1: SileroVAD.swift exists at the canonical path

    func testSileroVADFileExists() {
        XCTAssertTrue(
            exists("CactusVoice/Inference/SileroVAD.swift"),
            "SileroVAD.swift must live at CactusVoice/Inference/SileroVAD.swift"
        )
    }

    // MARK: - AC1: actor SileroVAD

    func testActorSileroVAD() throws {
        let s = try read("CactusVoice/Inference/SileroVAD.swift")
        XCTAssertTrue(
            s.contains("actor SileroVAD"),
            "Must declare `actor SileroVAD`"
        )
    }

    // MARK: - AC2: VADEvent enum + speechStart/speechEnd cases

    func testVADEventEnum() throws {
        let s = try read("CactusVoice/Inference/SileroVAD.swift")
        XCTAssertTrue(
            s.contains("enum VADEvent"),
            "Must declare `enum VADEvent`"
        )
        XCTAssertTrue(
            s.contains("Sendable"),
            "VADEvent must be Sendable"
        )
        XCTAssertTrue(
            s.contains("case speechStart(at: TimeInterval)"),
            "Must declare `case speechStart(at: TimeInterval)`"
        )
        XCTAssertTrue(
            s.contains("case speechEnd(at: TimeInterval)"),
            "Must declare `case speechEnd(at: TimeInterval)`"
        )
    }

    // MARK: - AC3: run(stream:) signature

    func testRunSignature() throws {
        let s = try read("CactusVoice/Inference/SileroVAD.swift")
        XCTAssertTrue(
            s.contains("func run(stream: AsyncStream<Float>) -> AsyncStream<VADEvent>"),
            "Must declare `func run(stream: AsyncStream<Float>) -> AsyncStream<VADEvent>`"
        )
    }

    // MARK: - AC4: 512-sample window constant

    func testWindowSamplesConstant() throws {
        let s = try read("CactusVoice/Inference/SileroVAD.swift")
        XCTAssertTrue(
            s.contains("512"),
            "Must reference the literal `512` (samples per 32 ms window at 16 kHz)"
        )
    }

    // MARK: - AC5: threshold default 0.5

    func testThresholdDefault() throws {
        let s = try read("CactusVoice/Inference/SileroVAD.swift")
        // Either `threshold: Float = 0.5` (init default) or `threshold ... 0.5`.
        let normalized = s.replacingOccurrences(of: " ", with: "")
        XCTAssertTrue(
            normalized.contains("threshold:Float=0.5"),
            "Must declare init threshold default 0.5 (e.g. `threshold: Float = 0.5`)"
        )
    }

    // MARK: - AC6: 1.5 s silence-end constant

    func testSilenceEndConstant() throws {
        let s = try read("CactusVoice/Inference/SileroVAD.swift")
        // Either `1.5` (seconds) or `1500` (ms) must be present as a literal.
        XCTAssertTrue(
            s.contains("1.5") || s.contains("1500"),
            "Must declare a 1.5 s / 1500 ms silence-end constant"
        )
    }

    // MARK: - AC7: 300 ms stitch-gap constant

    func testStitchGapConstant() throws {
        let s = try read("CactusVoice/Inference/SileroVAD.swift")
        // Either `0.3` (seconds) or `300` (ms) must be present.
        XCTAssertTrue(
            s.contains("0.3") || s.contains("300"),
            "Must declare a 300 ms / 0.3 s stitch-gap constant"
        )
    }

    // MARK: - AC8: AppError.vadLoadFailed surfacing

    func testVadLoadFailedReferenced() throws {
        let s = try read("CactusVoice/Inference/SileroVAD.swift")
        XCTAssertTrue(
            s.contains("vadLoadFailed"),
            "Must reference `AppError.vadLoadFailed` for load-failure mapping"
        )
    }

    // MARK: - AC10: VADInference protocol seam

    func testVADInferenceProtocol() throws {
        let s = try read("CactusVoice/Inference/SileroVAD.swift")
        XCTAssertTrue(
            s.contains("protocol VADInference"),
            "Must declare `protocol VADInference` as the FFI seam"
        )
        XCTAssertTrue(
            s.contains("Sendable"),
            "VADInference must be Sendable"
        )
        XCTAssertTrue(
            s.contains("score(samples:"),
            "VADInference must expose `score(samples:) throws -> Float`"
        )
    }

    // MARK: - AC11: SileroVADTests.swift exists

    func testSileroVADTestsFileExists() {
        XCTAssertTrue(
            exists("CactusVoiceTests/Inference/SileroVADTests.swift"),
            "Runtime tests file must exist at CactusVoiceTests/Inference/SileroVADTests.swift"
        )
    }

    // MARK: - Budget

    func testSileroVADBudget() throws {
        let n = try lineCount("CactusVoice/Inference/SileroVAD.swift")
        XCTAssertLessThanOrEqual(
            n, 260,
            "SileroVAD.swift line count (\(n)) must be ≤ 260 (KISS — actor + protocol + adapter)"
        )
    }
}
