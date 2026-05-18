//
//  BaselinePipelineTests.swift — Story 3.5.
//
//  End-to-end baseline pipeline integration test. Wires four actors —
//  AudioCapture → SileroVAD → WhisperSession → TranscriptModel — plus
//  CactusRuntime for handle ownership, feeds a 10 s WAV file through the
//  AudioInputSource stub seam (same stub as Story 3.4's AudioCaptureTests),
//  and asserts on the committed transcript.
//
//  Assertions after AudioCapture.stop():
//    * TranscriptModel.committed.characters.count > 0 (non-empty)
//    * WER vs. Fixtures/baseline_10s.transcript.txt ≤ 0.15 (15% loose
//      baseline bound — this is bare Whisper, NOT the full Story 9.x
//      correction pipeline)
//    * language="en" was used (asserted via
//      WhisperOpts.researchDefaults(initialPrompt: nil).language == "en"
//      AND a "no Han / CJK codepoints" sweep on the committed transcript)
//    * at least one .speechStart / .speechEnd pair was emitted by the
//      owned SileroVAD on vadEventStream
//
//  Tear-down releases all model handles via CactusRuntime.unloadAll and
//  WhisperSession.close.
//
//  Host gating: XCTSkipUnless on three env vars
//  (CACTUSVOICE_WHISPER_PATH, CACTUSVOICE_VAD_PATH, CACTUSVOICE_BASELINE_WAV)
//  so the test can be authored + pushed on a CLT-only host without local
//  execution. Full runtime verification runs on a host with Xcode.app + the
//  models + the WAV.
//
//  WAV reader: AVAudioFile + AVAudioConverter to 16 kHz mono Float32
//  non-interleaved (same canonical format as AVAudioInputSource in Story
//  3.4). Wrapped in `#if canImport(AVFoundation)`; the whole test
//  XCTSkipUnless'es if AVFoundation is unavailable.
//
//  WER: inline Levenshtein on whitespace-tokenized words after the same
//  normalization the reference transcript is stored in (lowercase,
//  punctuation stripped, single-space).
//
import XCTest
@testable import CactusVoice

#if canImport(AVFoundation)
import AVFoundation
#endif

@MainActor
final class BaselinePipelineTests: XCTestCase {

    // MARK: - Tear-down state

    private var runtime: CactusRuntime?
    private var whisperSession: WhisperSession?

    override func tearDown() async throws {
        if let session = whisperSession {
            await session.close()
        }
        if let rt = runtime {
            await rt.unloadAll()
        }
        whisperSession = nil
        runtime = nil
        try await super.tearDown()
    }

    // MARK: - The single integration test

    func testEndToEndBaselinePipeline() async throws {
        // ---- Host gating -------------------------------------------------
        let env = ProcessInfo.processInfo.environment
        let whisperPath = env["CACTUSVOICE_WHISPER_PATH"] ?? ""
        let vadPath = env["CACTUSVOICE_VAD_PATH"] ?? ""
        let wavDefault = defaultWavFixturePath()
        let wavPath = env["CACTUSVOICE_BASELINE_WAV"] ?? wavDefault

        try XCTSkipUnless(
            !whisperPath.isEmpty,
            "CACTUSVOICE_WHISPER_PATH unset — skipping baseline pipeline test"
        )
        try XCTSkipUnless(
            !vadPath.isEmpty,
            "CACTUSVOICE_VAD_PATH unset — skipping baseline pipeline test"
        )
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: wavPath),
            "WAV fixture missing at \(wavPath) — skipping baseline pipeline test"
        )
        let transcriptPath = (wavPath as NSString).deletingPathExtension + ".transcript.txt"
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: transcriptPath),
            "Reference transcript missing at \(transcriptPath) — skipping baseline pipeline test"
        )

        #if !canImport(AVFoundation)
        try XCTSkipUnless(false, "AVFoundation unavailable — WAV reader unusable")
        #endif

        // ---- Decode the WAV file at 16 kHz mono Float32 ------------------
        let samples = try wavReader(at: URL(fileURLWithPath: wavPath))
        XCTAssertGreaterThan(samples.count, 16_000, "Expected ≥ 1 s of decoded audio")

        // ---- Read the reference transcript -------------------------------
        let referenceRaw = try String(contentsOfFile: transcriptPath, encoding: .utf8)
        let reference = normalize(referenceRaw)

        // ---- Wire CactusRuntime + acquire Whisper + VAD handles ----------
        let rt = CactusRuntime(mode: .minimal)
        self.runtime = rt
        let whisperHandle = try await rt.acquireWhisper(path: URL(fileURLWithPath: whisperPath))
        let vadHandle = try await rt.acquireVAD(path: URL(fileURLWithPath: vadPath))

        // ---- Construct SileroVAD with production FFI inference -----------
        let vad = SileroVAD(
            inference: FFIShimVADInference(handle: vadHandle),
            threshold: 0.5
        )

        // ---- Construct TranscriptModel + WhisperSession ------------------
        let transcript = TranscriptModel()
        let session = WhisperSession(
            runtime: rt,
            transcript: transcript,
            modelHandle: whisperHandle,
            ffi: FFIShimWhisperFFI()
        )
        self.whisperSession = session

        // ---- Construct AudioCapture wired via StubAudioInputSource -------
        let input = StubAudioInputSource()
        let gate = StubMicPermissionGate()
        let capture = AudioCapture(inputSource: input, permissions: gate, vad: vad)

        // ---- Wire WhisperSession to AudioCapture.pcmStream ---------------
        let pcm = capture.pcmStream
        let whisperEvents = session.run(stream: pcm, initialPrompt: nil, topK: 5)
        let whisperDrain = Task<Void, Never> {
            for await _ in whisperEvents { /* drain */ }
        }

        // ---- Observe VAD events on a side-task ---------------------------
        let vadStream = capture.vadEventStream
        var sawStart = false
        var sawEnd = false
        let vadObserver = Task<Void, Never> {
            for await event in vadStream {
                switch event {
                case .speechStart: sawStart = true
                case .speechEnd:   sawEnd = true
                }
            }
        }

        // ---- Start capture + push the WAV samples in 1024-sample chunks --
        try await capture.start()
        let chunkSize = 1024
        var idx = 0
        while idx < samples.count {
            let end = min(idx + chunkSize, samples.count)
            input.push(Array(samples[idx..<end]))
            idx = end
            // Small yield so the actor + VAD driver can drain between batches.
            try? await Task.sleep(nanoseconds: 1_000_000) // 1 ms
        }
        // Give the in-flight Whisper pull a moment before stopping.
        try? await Task.sleep(nanoseconds: 50_000_000) // 50 ms
        await capture.stop()
        await whisperDrain.value
        vadObserver.cancel()

        // ---- Assertions --------------------------------------------------

        // 1. Non-empty transcript
        let committed = await transcript.committed
        let committedString = String(committed.characters)
        XCTAssertGreaterThan(
            committedString.count, 0,
            "TranscriptModel.committed must be non-empty after baseline pipeline run"
        )

        // 2. language="en" was used (source-of-truth check on WhisperOpts)
        XCTAssertEqual(
            WhisperOpts.researchDefaults(initialPrompt: nil).language,
            "en",
            "WhisperOpts.researchDefaults must force language=\"en\""
        )
        // 2b. No Mandarin / Han codepoints in the committed transcript
        XCTAssertFalse(
            containsCJKHan(committedString),
            "Committed transcript contains Han/CJK codepoints — language=en was not respected"
        )

        // 3. VAD emitted at least one .speechStart / .speechEnd pair
        XCTAssertTrue(sawStart, "VAD must emit at least one .speechStart event")
        XCTAssertTrue(sawEnd, "VAD must emit at least one .speechEnd event")

        // 4. WER ≤ 15% (loose baseline bound)
        let hypothesis = normalize(committedString)
        let observedWER = wer(reference: reference, hypothesis: hypothesis)
        XCTAssertLessThanOrEqual(
            observedWER, 0.15,
            "Baseline WER \(observedWER) exceeds 0.15 (15%) loose baseline bound"
        )
    }

    // MARK: - Helpers: fixture path resolution

    private func defaultWavFixturePath() -> String {
        // CactusVoiceTests/Fixtures/baseline_10s.wav relative to this file.
        let here = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Inference/
            .deletingLastPathComponent() // CactusVoiceTests/
            .appendingPathComponent("Fixtures/baseline_10s.wav")
        return here.path
    }

    // MARK: - Helpers: text normalization

    /// Lowercase, strip punctuation, collapse whitespace. Mirrors the
    /// canonical Whisper-evaluation tokenization; the reference transcript
    /// is stored in the same form.
    private func normalize(_ s: String) -> String {
        let lower = s.lowercased()
        let stripped = lower.unicodeScalars.map { scalar -> Character in
            if CharacterSet.letters.contains(scalar) { return Character(scalar) }
            if CharacterSet.decimalDigits.contains(scalar) { return Character(scalar) }
            return " "
        }
        let collapsed = String(stripped)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return collapsed
    }

    /// Returns true if any Han (CJK) codepoint is present — used to confirm
    /// language="en" was honoured (no Mandarin transcription).
    private func containsCJKHan(_ s: String) -> Bool {
        for scalar in s.unicodeScalars {
            let v = scalar.value
            // CJK Unified Ideographs + Extension A.
            if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) {
                return true
            }
        }
        return false
    }

    // MARK: - Helpers: Levenshtein-based WER

    /// Word Error Rate via Levenshtein edit distance on whitespace-tokenized
    /// words. WER = edits / reference.count; clamped to 1.0 if reference is
    /// empty (degenerate case).
    func wer(reference: String, hypothesis: String) -> Double {
        let refWords = reference.split(separator: " ").map(String.init)
        let hypWords = hypothesis.split(separator: " ").map(String.init)
        guard !refWords.isEmpty else {
            return hypWords.isEmpty ? 0.0 : 1.0
        }
        let n = refWords.count
        let m = hypWords.count
        // Standard Levenshtein DP — 2 rows ((m+1) Ints each).
        var prev = Array(0...m)
        var curr = Array(repeating: 0, count: m + 1)
        for i in 1...n {
            curr[0] = i
            for j in 1...m {
                let cost = (refWords[i - 1] == hypWords[j - 1]) ? 0 : 1
                curr[j] = min(
                    prev[j] + 1,            // deletion
                    curr[j - 1] + 1,        // insertion
                    prev[j - 1] + cost      // substitution / match
                )
            }
            swap(&prev, &curr)
        }
        return Double(prev[m]) / Double(n)
    }

    // MARK: - Helpers: WAV reader

    #if canImport(AVFoundation)
    /// Decode a WAV file at its native format then resample / re-encode via
    /// AVAudioConverter to 16 kHz mono Float32 non-interleaved (the canonical
    /// pipeline format used by AVAudioInputSource in Story 3.4).
    func wavReader(at url: URL) throws -> [Float] {
        func fail(_ msg: String, _ code: Int = 1) -> NSError {
            NSError(domain: "BaselinePipelineTests.wavReader", code: code,
                    userInfo: [NSLocalizedDescriptionKey: msg])
        }
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000.0, channels: 1, interleaved: false
        ) else { throw fail("target format unavailable") }
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(file.length)
        ) else { throw fail("source buffer alloc failed", 2) }
        try file.read(into: sourceBuffer)
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let destCap = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio + 16)
        guard let destBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat, frameCapacity: destCap
        ) else { throw fail("destination buffer alloc failed", 3) }
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw fail("converter unavailable", 4)
        }
        var supplied = false
        var convError: NSError?
        let status = converter.convert(to: destBuffer, error: &convError) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true; outStatus.pointee = .haveData
            return sourceBuffer
        }
        if status == .error, let convError = convError { throw convError }
        guard let channelData = destBuffer.floatChannelData?[0] else {
            throw fail("channelData missing on destination buffer", 5)
        }
        let count = Int(destBuffer.frameLength)
        return Array(UnsafeBufferPointer(start: channelData, count: count))
    }
    #else
    func wavReader(at url: URL) throws -> [Float] {
        throw NSError(domain: "BaselinePipelineTests.wavReader", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "AVFoundation unavailable"])
    }
    #endif
}
