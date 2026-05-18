import XCTest

/// Acceptance tests for Story 3.2 — WhisperSession actor with research-informed decoding flags.
///
/// File-level static checks against the on-disk source so the structural
/// contract is enforced even on hosts without Xcode.app. Runtime semantics
/// (top-K emission, decoding-flag pass-through, top-1 → revise piping,
/// finalize → commit + emit, handle release) live in
/// `CactusVoiceTests/Inference/WhisperSessionTests.swift` with a stub
/// `WhisperFFI` injected at the seam.
final class Story3_2Tests: XCTestCase {

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

    // MARK: - AC1: WhisperSessionType protocol exists

    func testWhisperSessionTypeFileExists() {
        XCTAssertTrue(
            exists("CactusVoice/Inference/WhisperSessionType.swift"),
            "WhisperSessionType.swift must live at CactusVoice/Inference/WhisperSessionType.swift"
        )
    }

    func testWhisperSessionTypeProtocol() throws {
        let s = try read("CactusVoice/Inference/WhisperSessionType.swift")
        XCTAssertTrue(
            s.contains("protocol WhisperSessionType: Sendable")
                || s.contains("protocol WhisperSessionType : Sendable"),
            "Must declare `protocol WhisperSessionType: Sendable`"
        )
        XCTAssertTrue(
            s.contains("run(stream:"),
            "Protocol must expose `run(stream:initialPrompt:topK:)`"
        )
    }

    // MARK: - AC2: WhisperEvent.swift declares WhisperHypothesis + WhisperEvent

    func testWhisperEventFileExists() {
        XCTAssertTrue(
            exists("CactusVoice/Inference/WhisperEvent.swift"),
            "WhisperEvent.swift must live at CactusVoice/Inference/WhisperEvent.swift"
        )
    }

    func testWhisperHypothesisStruct() throws {
        let s = try read("CactusVoice/Inference/WhisperEvent.swift")
        XCTAssertTrue(
            s.contains("struct WhisperHypothesis"),
            "Must declare `struct WhisperHypothesis`"
        )
        XCTAssertTrue(
            s.contains("let text: String"),
            "WhisperHypothesis must carry `let text: String`"
        )
        XCTAssertTrue(
            s.contains("let tokenLogprobs: [Float]"),
            "WhisperHypothesis must carry `let tokenLogprobs: [Float]`"
        )
        XCTAssertTrue(
            s.contains("let aggregateConfidence: Float"),
            "WhisperHypothesis must carry `let aggregateConfidence: Float`"
        )
    }

    func testWhisperEventEnum() throws {
        let s = try read("CactusVoice/Inference/WhisperEvent.swift")
        XCTAssertTrue(
            s.contains("enum WhisperEvent"),
            "Must declare `enum WhisperEvent`"
        )
        XCTAssertTrue(
            s.contains("case partial(top1: WhisperHypothesis)"),
            "WhisperEvent must carry `case partial(top1: WhisperHypothesis)`"
        )
        XCTAssertTrue(
            s.contains("case finalized(topK: [WhisperHypothesis], confidence: Float)"),
            "WhisperEvent must carry `case finalized(topK: [WhisperHypothesis], confidence: Float)`"
        )
    }

    // MARK: - AC3: actor WhisperSession + run(...) signature + WhisperFFI seam

    func testWhisperSessionFileExists() {
        XCTAssertTrue(
            exists("CactusVoice/Inference/WhisperSession.swift"),
            "WhisperSession.swift must live at CactusVoice/Inference/WhisperSession.swift"
        )
    }

    func testActorWhisperSessionConformsToType() throws {
        let s = try read("CactusVoice/Inference/WhisperSession.swift")
        XCTAssertTrue(
            s.contains("actor WhisperSession: WhisperSessionType"),
            "Must declare `actor WhisperSession: WhisperSessionType`"
        )
    }

    func testRunSignature() throws {
        let s = try read("CactusVoice/Inference/WhisperSession.swift")
        // Allow either nonisolated or default-isolated; check the signature shape.
        XCTAssertTrue(
            s.contains("func run(stream: AsyncStream<Float>, initialPrompt: String?, topK: Int = 5) -> AsyncStream<WhisperEvent>"),
            "Must declare `func run(stream: AsyncStream<Float>, initialPrompt: String?, topK: Int = 5) -> AsyncStream<WhisperEvent>`"
        )
    }

    func testWhisperFFIProtocol() throws {
        let s = try read("CactusVoice/Inference/WhisperSession.swift")
        XCTAssertTrue(
            s.contains("protocol WhisperFFI"),
            "Must declare `protocol WhisperFFI` as the streaming FFI seam"
        )
        XCTAssertTrue(
            s.contains("createSession("),
            "WhisperFFI must expose `createSession(...)`"
        )
        XCTAssertTrue(
            s.contains("pushPCM("),
            "WhisperFFI must expose `pushPCM(...)`"
        )
        XCTAssertTrue(
            s.contains("pullPartial("),
            "WhisperFFI must expose `pullPartial(...)`"
        )
        XCTAssertTrue(
            s.contains("closeSession("),
            "WhisperFFI must expose `closeSession(...)`"
        )
    }

    // MARK: - Decoding-flag constants — research-informed values must be present literally

    func testLanguageForcedToEN() throws {
        let s = try read("CactusVoice/Inference/WhisperSession.swift")
        XCTAssertTrue(
            s.contains("\"en\""),
            "Must force `language = \"en\"`"
        )
        XCTAssertTrue(
            s.contains("language"),
            "Must reference `language` flag explicitly"
        )
    }

    func testConditionOnPreviousTextFalse() throws {
        let s = try read("CactusVoice/Inference/WhisperSession.swift")
        XCTAssertTrue(
            s.contains("conditionOnPreviousText") || s.contains("condition_on_previous_text"),
            "Must reference `conditionOnPreviousText` flag"
        )
        XCTAssertTrue(
            s.contains("false"),
            "Must set conditionOnPreviousText = false"
        )
    }

    func testTemperatureFallbackArray() throws {
        let s = try read("CactusVoice/Inference/WhisperSession.swift")
        // Match the exact literal sequence with whitespace normalization.
        let normalized = s.replacingOccurrences(of: " ", with: "")
        XCTAssertTrue(
            normalized.contains("[0.0,0.2,0.4,0.6,0.8,1.0]"),
            "Must declare `temperature_fallback = [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]`"
        )
    }

    func testNoRepeatNgramSize3() throws {
        let s = try read("CactusVoice/Inference/WhisperSession.swift")
        XCTAssertTrue(
            s.contains("noRepeatNgramSize") || s.contains("no_repeat_ngram_size"),
            "Must reference `noRepeatNgramSize` flag"
        )
        XCTAssertTrue(
            s.contains(": 3") || s.contains("= 3"),
            "Must set noRepeatNgramSize = 3"
        )
    }

    func testCompressionRatioThreshold24() throws {
        let s = try read("CactusVoice/Inference/WhisperSession.swift")
        XCTAssertTrue(
            s.contains("compressionRatioThreshold") || s.contains("compression_ratio_threshold"),
            "Must reference `compressionRatioThreshold` flag"
        )
        XCTAssertTrue(
            s.contains("2.4"),
            "Must set compressionRatioThreshold = 2.4"
        )
    }

    func testLogprobThresholdNegative08() throws {
        let s = try read("CactusVoice/Inference/WhisperSession.swift")
        XCTAssertTrue(
            s.contains("logprobThreshold") || s.contains("logprob_threshold"),
            "Must reference `logprobThreshold` flag"
        )
        XCTAssertTrue(
            s.contains("-0.8"),
            "Must set logprobThreshold = -0.8 (stricter than OpenAI default of -1.0)"
        )
    }

    // MARK: - Init wiring + handle release via CactusRuntime

    func testInitTakesCactusRuntime() throws {
        let s = try read("CactusVoice/Inference/WhisperSession.swift")
        XCTAssertTrue(
            s.contains("CactusRuntime"),
            "Init must take a `CactusRuntime` reference"
        )
    }

    func testInitTakesTranscriptModel() throws {
        let s = try read("CactusVoice/Inference/WhisperSession.swift")
        XCTAssertTrue(
            s.contains("TranscriptModel"),
            "Init must take a `TranscriptModel` reference"
        )
    }

    func testInitTakesWhisperHandle() throws {
        let s = try read("CactusVoice/Inference/WhisperSession.swift")
        XCTAssertTrue(
            s.contains("modelHandle: WhisperHandle"),
            "Init must take `modelHandle: WhisperHandle`"
        )
    }

    func testReleaseViaCactusRuntime() throws {
        let s = try read("CactusVoice/Inference/WhisperSession.swift")
        XCTAssertTrue(
            s.contains(".release("),
            "Must release the FFI handle via `CactusRuntime.release(...)`"
        )
    }

    // MARK: - AC5: runtime test file exists

    func testWhisperSessionTestsFileExists() {
        XCTAssertTrue(
            exists("CactusVoiceTests/Inference/WhisperSessionTests.swift"),
            "Runtime tests file must exist at CactusVoiceTests/Inference/WhisperSessionTests.swift"
        )
    }

    // MARK: - Budgets

    func testWhisperSessionTypeBudget() throws {
        let n = try lineCount("CactusVoice/Inference/WhisperSessionType.swift")
        XCTAssertLessThanOrEqual(
            n, 60,
            "WhisperSessionType.swift line count (\(n)) must be ≤ 60 (KISS — protocol-only file)"
        )
    }

    func testWhisperEventBudget() throws {
        let n = try lineCount("CactusVoice/Inference/WhisperEvent.swift")
        XCTAssertLessThanOrEqual(
            n, 80,
            "WhisperEvent.swift line count (\(n)) must be ≤ 80 (KISS — value types only)"
        )
    }

    func testWhisperSessionBudget() throws {
        let n = try lineCount("CactusVoice/Inference/WhisperSession.swift")
        XCTAssertLessThanOrEqual(
            n, 360,
            "WhisperSession.swift line count (\(n)) must be ≤ 360 (KISS)"
        )
    }
}
