import XCTest

/// Acceptance tests for Story 3.1 — CactusRuntime actor (lazy load, residency, three slots).
///
/// File-level static checks against the on-disk source so the structural
/// contract is enforced even on hosts without Xcode.app. Runtime semantics
/// (refcount, slot reuse, mode gating, leak balance, concurrent acquire
/// collapse) live in `CactusVoiceTests/Inference/CactusRuntimeTests.swift`
/// with a stub `RuntimeFFI` injected at the seam.
final class Story3_1Tests: XCTestCase {

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

    // MARK: - AC1: file exists, `actor CactusRuntime`

    func testCactusRuntimeFileExists() {
        XCTAssertTrue(
            exists("CactusVoice/Inference/CactusRuntime.swift"),
            "CactusRuntime.swift must live at CactusVoice/Inference/CactusRuntime.swift"
        )
    }

    func testActorDeclaration() throws {
        let s = try read("CactusVoice/Inference/CactusRuntime.swift")
        XCTAssertTrue(
            s.contains("actor CactusRuntime"),
            "Must declare `actor CactusRuntime`"
        )
    }

    // MARK: - AC3: six async methods on the actor surface

    func testAcquireWhisperSignature() throws {
        let s = try read("CactusVoice/Inference/CactusRuntime.swift")
        XCTAssertTrue(
            s.contains("func acquireWhisper(path: URL) async throws -> WhisperHandle"),
            "Must declare `func acquireWhisper(path: URL) async throws -> WhisperHandle`"
        )
    }

    func testAcquireLLMSignature() throws {
        let s = try read("CactusVoice/Inference/CactusRuntime.swift")
        XCTAssertTrue(
            s.contains("func acquireLLM(path: URL) async throws -> LLMHandle"),
            "Must declare `func acquireLLM(path: URL) async throws -> LLMHandle`"
        )
    }

    func testAcquireVADSignature() throws {
        let s = try read("CactusVoice/Inference/CactusRuntime.swift")
        XCTAssertTrue(
            s.contains("func acquireVAD(path: URL) async throws -> VADHandle"),
            "Must declare `func acquireVAD(path: URL) async throws -> VADHandle`"
        )
    }

    func testReleaseSignature() throws {
        let s = try read("CactusVoice/Inference/CactusRuntime.swift")
        XCTAssertTrue(
            s.contains("func release(_ handle: AnyHandle) async"),
            "Must declare `func release(_ handle: AnyHandle) async`"
        )
    }

    func testUnloadAllSignature() throws {
        let s = try read("CactusVoice/Inference/CactusRuntime.swift")
        XCTAssertTrue(
            s.contains("func unloadAll() async"),
            "Must declare `func unloadAll() async`"
        )
    }

    func testCurrentResidencySignature() throws {
        let s = try read("CactusVoice/Inference/CactusRuntime.swift")
        XCTAssertTrue(
            s.contains("func currentResidency() async -> ResidencyReport"),
            "Must declare `func currentResidency() async -> ResidencyReport`"
        )
    }

    func testAcquireLLMForUserActionSignature() throws {
        let s = try read("CactusVoice/Inference/CactusRuntime.swift")
        XCTAssertTrue(
            s.contains("func acquireLLMForUserAction(path: URL) async throws -> LLMHandle"),
            "Must declare `func acquireLLMForUserAction(path: URL) async throws -> LLMHandle`"
        )
    }

    // MARK: - AC7: handle structs + AnyHandle enum

    func testWhisperHandleStruct() throws {
        let s = try read("CactusVoice/Inference/CactusRuntime.swift")
        XCTAssertTrue(
            s.contains("struct WhisperHandle"),
            "Must declare `struct WhisperHandle`"
        )
    }

    func testLLMHandleStruct() throws {
        let s = try read("CactusVoice/Inference/CactusRuntime.swift")
        XCTAssertTrue(
            s.contains("struct LLMHandle"),
            "Must declare `struct LLMHandle`"
        )
    }

    func testVADHandleStruct() throws {
        let s = try read("CactusVoice/Inference/CactusRuntime.swift")
        XCTAssertTrue(
            s.contains("struct VADHandle"),
            "Must declare `struct VADHandle`"
        )
    }

    func testAnyHandleEnum() throws {
        let s = try read("CactusVoice/Inference/CactusRuntime.swift")
        XCTAssertTrue(
            s.contains("enum AnyHandle"),
            "Must declare `enum AnyHandle`"
        )
        XCTAssertTrue(
            s.contains("case whisper(WhisperHandle)"),
            "AnyHandle must carry `case whisper(WhisperHandle)`"
        )
        XCTAssertTrue(
            s.contains("case llm(LLMHandle)"),
            "AnyHandle must carry `case llm(LLMHandle)`"
        )
        XCTAssertTrue(
            s.contains("case vad(VADHandle)"),
            "AnyHandle must carry `case vad(VADHandle)`"
        )
    }

    // MARK: - AC6: RuntimeMode enum

    func testRuntimeModeEnum() throws {
        let s = try read("CactusVoice/Inference/CactusRuntime.swift")
        XCTAssertTrue(
            s.contains("enum RuntimeMode"),
            "Must declare `enum RuntimeMode`"
        )
        XCTAssertTrue(
            s.contains("case minimal") && s.contains("case full"),
            "RuntimeMode must declare `case minimal` and `case full`"
        )
    }

    // MARK: - AC8: ResidencyReport struct

    func testResidencyReportStruct() throws {
        let s = try read("CactusVoice/Inference/CactusRuntime.swift")
        XCTAssertTrue(
            s.contains("struct ResidencyReport"),
            "Must declare `struct ResidencyReport`"
        )
        XCTAssertTrue(
            s.contains("whisper: URL?"),
            "ResidencyReport must carry `whisper: URL?`"
        )
        XCTAssertTrue(
            s.contains("llm: URL?"),
            "ResidencyReport must carry `llm: URL?`"
        )
        XCTAssertTrue(
            s.contains("vad: URL?"),
            "ResidencyReport must carry `vad: URL?`"
        )
        XCTAssertTrue(
            s.contains("mode: RuntimeMode"),
            "ResidencyReport must carry `mode: RuntimeMode`"
        )
    }

    // MARK: - AC9: protocol seam

    func testRuntimeFFIProtocol() throws {
        let s = try read("CactusVoice/Inference/CactusRuntime.swift")
        XCTAssertTrue(
            s.contains("protocol RuntimeFFI"),
            "Must declare `protocol RuntimeFFI` as the injectable FFI seam"
        )
    }

    // MARK: - AC10: errors surface as AppError.modelLoadFailed

    func testAppErrorUsed() throws {
        let s = try read("CactusVoice/Inference/CactusRuntime.swift")
        XCTAssertTrue(
            s.contains("AppError.modelLoadFailed"),
            "Must throw `AppError.modelLoadFailed` for load + mode + slot-in-use failures"
        )
    }

    // MARK: - AC11: runtime test file exists

    func testRuntimeTestsFileExists() {
        XCTAssertTrue(
            exists("CactusVoiceTests/Inference/CactusRuntimeTests.swift"),
            "Runtime tests file must exist at CactusVoiceTests/Inference/CactusRuntimeTests.swift"
        )
    }

    // MARK: - Budget — implementation ≤ 360 LOC

    func testImplementationBudget() throws {
        let n = try lineCount("CactusVoice/Inference/CactusRuntime.swift")
        XCTAssertLessThanOrEqual(
            n, 360,
            "CactusRuntime.swift line count (\(n)) must be ≤ 360 (KISS)"
        )
    }
}
