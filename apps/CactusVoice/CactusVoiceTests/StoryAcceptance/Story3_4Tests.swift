import XCTest

/// Acceptance tests for Story 3.4 — AudioCapture actor with pre-roll +
/// VAD-driven segmentation. File-level static checks against the on-disk
/// source so the structural contract is enforced even on hosts without
/// Xcode.app. Runtime semantics (start-before-paint pre-roll, stop ≤ 100 ms,
/// overrun forwarding, mic-denied throw, VAD event flow) live in
/// `CactusVoiceTests/Audio/AudioCaptureTests.swift` with a stub
/// `AudioInputSource` injected at the seam.
final class Story3_4Tests: XCTestCase {

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

    // MARK: - AC1: AudioCapture.swift exists at the canonical path

    func testAudioCaptureFileExists() {
        XCTAssertTrue(
            exists("CactusVoice/Audio/AudioCapture.swift"),
            "AudioCapture.swift must live at CactusVoice/Audio/AudioCapture.swift"
        )
    }

    // MARK: - AC1: actor AudioCapture

    func testActorAudioCapture() throws {
        let s = try read("CactusVoice/Audio/AudioCapture.swift")
        XCTAssertTrue(
            s.contains("actor AudioCapture"),
            "Must declare `actor AudioCapture`"
        )
    }

    // MARK: - AC9: AudioInputSource protocol + Sendable

    func testAudioInputSourceProtocol() throws {
        let s = try read("CactusVoice/Audio/AudioCapture.swift")
        XCTAssertTrue(
            s.contains("protocol AudioInputSource"),
            "Must declare `protocol AudioInputSource` as the test seam"
        )
        XCTAssertTrue(
            s.contains("Sendable"),
            "AudioInputSource must be Sendable"
        )
        XCTAssertTrue(
            s.contains("func start(onSamples:"),
            "AudioInputSource must expose `func start(onSamples: ...) throws`"
        )
        XCTAssertTrue(
            s.contains("func stop()"),
            "AudioInputSource must expose `func stop()`"
        )
    }

    // MARK: - AC9: default AVAudioInputSource adapter

    func testAVAudioInputSourceDefaultAdapter() throws {
        let s = try read("CactusVoice/Audio/AudioCapture.swift")
        XCTAssertTrue(
            s.contains("AVAudioInputSource"),
            "Must declare default `AVAudioInputSource` adapter wrapping AVAudioEngine"
        )
        XCTAssertTrue(
            s.contains("AVAudioEngine"),
            "Default adapter must use AVAudioEngine"
        )
        XCTAssertTrue(
            s.contains("AVAudioConverter"),
            "Default adapter must use AVAudioConverter for 16 kHz mono Float32"
        )
    }

    // MARK: - AC3: start() async throws + ensureMicPermission()

    func testStartSignatureAndMicCheck() throws {
        let s = try read("CactusVoice/Audio/AudioCapture.swift")
        XCTAssertTrue(
            s.contains("func start() async throws"),
            "Must declare `func start() async throws`"
        )
        XCTAssertTrue(
            s.contains("ensureMicPermission()"),
            "start() must call ensureMicPermission()"
        )
    }

    // MARK: - AC4: stop() async

    func testStopSignature() throws {
        let s = try read("CactusVoice/Audio/AudioCapture.swift")
        XCTAssertTrue(
            s.contains("func stop() async"),
            "Must declare `func stop() async`"
        )
    }

    // MARK: - AC4: 100 ms p95 stop target documented

    func testStopTargetDocumented() throws {
        let s = try read("CactusVoice/Audio/AudioCapture.swift")
        XCTAssertTrue(
            s.contains("100 ms") || s.contains("100ms") || s.contains("NFR-009"),
            "stop() p95 ≤ 100 ms target (NFR-009) must be documented in source"
        )
    }

    // MARK: - AC6: pcmStream + vadEventStream public surface

    func testPcmStreamSurface() throws {
        let s = try read("CactusVoice/Audio/AudioCapture.swift")
        XCTAssertTrue(
            s.contains("pcmStream: AsyncStream<Float>"),
            "Must expose `pcmStream: AsyncStream<Float>`"
        )
    }

    func testVadEventStreamSurface() throws {
        let s = try read("CactusVoice/Audio/AudioCapture.swift")
        XCTAssertTrue(
            s.contains("vadEventStream: AsyncStream<VADEvent>"),
            "Must expose `vadEventStream: AsyncStream<VADEvent>`"
        )
    }

    // MARK: - AC2: BoundedSPSCBuffer<Float> usage

    func testBoundedSPSCBufferUsage() throws {
        let s = try read("CactusVoice/Audio/AudioCapture.swift")
        XCTAssertTrue(
            s.contains("BoundedSPSCBuffer<Float>"),
            "Must use BoundedSPSCBuffer<Float> for ring buffer + overrun accounting"
        )
    }

    // MARK: - AC2: SileroVAD integration

    func testSileroVADIntegration() throws {
        let s = try read("CactusVoice/Audio/AudioCapture.swift")
        XCTAssertTrue(
            s.contains("SileroVAD"),
            "Must integrate SileroVAD instance (composed via init)"
        )
    }

    // MARK: - AC2/AC5: 16 kHz sample rate + 30 s ring buffer

    func testSampleRateConstant() throws {
        let s = try read("CactusVoice/Audio/AudioCapture.swift")
        XCTAssertTrue(
            s.contains("16000") || s.contains("16_000"),
            "Must reference 16 kHz / 16_000 sample rate constant"
        )
    }

    // MARK: - AC7: pre-roll target (>= 1600 samples = 100 ms @ 16 kHz)

    func testPreRollTargetDocumented() throws {
        let s = try read("CactusVoice/Audio/AudioCapture.swift")
        XCTAssertTrue(
            s.contains("1600") || s.contains("pre-roll") || s.contains("preRoll"),
            "Pre-roll target (>= 1600 samples = 100 ms) must be documented in source"
        )
    }

    // MARK: - AC8: overrun → AppError.inferenceFailed(stage: .audio, reason: "overrun")

    func testOverrunForwardedAsAppError() throws {
        let s = try read("CactusVoice/Audio/AudioCapture.swift")
        let normalized = s.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
        XCTAssertTrue(
            normalized.contains("inferenceFailed(stage:.audio,reason:\"overrun\")"),
            "Overrun must be forwarded as AppError.inferenceFailed(stage: .audio, reason: \"overrun\")"
        )
    }

    // MARK: - AC10: AudioCaptureTests.swift exists

    func testAudioCaptureTestsFileExists() {
        XCTAssertTrue(
            exists("CactusVoiceTests/Audio/AudioCaptureTests.swift"),
            "Runtime tests file must exist at CactusVoiceTests/Audio/AudioCaptureTests.swift"
        )
    }

    // MARK: - Budget

    func testAudioCaptureBudget() throws {
        let n = try lineCount("CactusVoice/Audio/AudioCapture.swift")
        XCTAssertLessThanOrEqual(
            n, 360,
            "AudioCapture.swift line count (\(n)) must be ≤ 360 (KISS — actor + protocol + AVAudio adapter + gate)"
        )
    }
}
