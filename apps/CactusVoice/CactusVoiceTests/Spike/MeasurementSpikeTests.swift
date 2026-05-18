import XCTest
import Darwin
import Foundation
@testable import CactusCore

/// Story 1.3 — Measurement spike.
///
/// Throwaway test that loads real Whisper-Turbo + Gemma-3 E2B INT4 + Silero
/// VAD through `FFIShim`, measures stripped `.app` bundle size and peak
/// resident memory in two modes, and appends one CSV row to
/// `_bmad-output/implementation-artifacts/measurement-spike-results.csv`.
///
/// Gated behind four environment variables so it does **not** run in CI by
/// default: `CACTUSVOICE_WHISPER_PATH`, `CACTUSVOICE_GEMMA_PATH`,
/// `CACTUSVOICE_VAD_PATH`, `CACTUSVOICE_APP_BUNDLE_PATH`. When any is
/// missing the test skips via `XCTSkipUnless`.
///
/// Divergence procedure (NFR-001): the working targets are ~600 MB minimal
/// (Whisper + Silero) and ~2.5 GB full (adds Gemma-3). If measured values
/// diverge by more than 20% the dev MUST file a revision PR against PRD
/// NFR-001 and the architecture's tiered budget *before* any other epic
/// starts. See `_bmad-output/planning-artifacts/architecture.md` line 722.
final class MeasurementSpikeTests: XCTestCase {

    func testMeasure_minimal_and_full_modes_and_bundle() throws {
        let env = ProcessInfo.processInfo.environment
        let whisperPath = env["CACTUSVOICE_WHISPER_PATH"] ?? ""
        let gemmaPath   = env["CACTUSVOICE_GEMMA_PATH"]   ?? ""
        let vadPath     = env["CACTUSVOICE_VAD_PATH"]     ?? ""
        let bundlePath  = env["CACTUSVOICE_APP_BUNDLE_PATH"] ?? ""

        try XCTSkipUnless(
            !whisperPath.isEmpty && !gemmaPath.isEmpty &&
            !vadPath.isEmpty && !bundlePath.isEmpty,
            "Skipped: set CACTUSVOICE_WHISPER_PATH, CACTUSVOICE_GEMMA_PATH, CACTUSVOICE_VAD_PATH, CACTUSVOICE_APP_BUNDLE_PATH to run the measurement spike."
        )

        // 0. Baseline.
        _ = FFIShim.runtimeInit()
        let baseline = Self.currentResidentBytes()

        // 1. Minimal mode: Whisper + Silero VAD.
        let (sW1, whisper1) = FFIShim.loadModel(path: whisperPath, type: .whisper)
        XCTAssertEqual(sW1.rawValue, 0, "Whisper load (minimal) failed: status=\(sW1.rawValue)")
        let (sV1, vad1) = FFIShim.loadModel(path: vadPath, type: .onnx)
        XCTAssertEqual(sV1.rawValue, 0, "Silero VAD load (minimal) failed: status=\(sV1.rawValue)")
        let minimalPeak = Self.peakResidentDuring(seconds: 5.0)
        _ = FFIShim.freeModel(whisper1)
        _ = FFIShim.freeModel(vad1)

        // 1a. Verify return to baseline ± 50 MB.
        let afterMinimal = Self.currentResidentBytes()
        let minimalDelta = Int64(afterMinimal) - Int64(baseline)
        XCTAssertLessThan(abs(minimalDelta), 50 * 1024 * 1024,
                          "After freeing minimal-mode handles, resident memory drifted \(minimalDelta) bytes from baseline")

        // 2. Full mode: Whisper + Silero VAD + Gemma-3 E2B INT4.
        let (sW2, whisper2) = FFIShim.loadModel(path: whisperPath, type: .whisper)
        XCTAssertEqual(sW2.rawValue, 0, "Whisper load (full) failed: status=\(sW2.rawValue)")
        let (sV2, vad2) = FFIShim.loadModel(path: vadPath, type: .onnx)
        XCTAssertEqual(sV2.rawValue, 0, "Silero VAD load (full) failed: status=\(sV2.rawValue)")
        let (sG, gemma) = FFIShim.loadModel(path: gemmaPath, type: .llm)
        XCTAssertEqual(sG.rawValue, 0, "Gemma load (full) failed: status=\(sG.rawValue)")
        let fullPeak = Self.peakResidentDuring(seconds: 5.0)
        _ = FFIShim.freeModel(whisper2)
        _ = FFIShim.freeModel(vad2)
        _ = FFIShim.freeModel(gemma)
        _ = FFIShim.runtimeShutdown()

        // 2a. Verify return to baseline ± 50 MB.
        let afterFull = Self.currentResidentBytes()
        let fullDelta = Int64(afterFull) - Int64(baseline)
        XCTAssertLessThan(abs(fullDelta), 50 * 1024 * 1024,
                          "After freeing full-mode handles, resident memory drifted \(fullDelta) bytes from baseline")

        // 3. Bundle size.
        let bundleBytes = Self.appBundleSizeBytes(at: bundlePath)
        XCTAssertGreaterThan(bundleBytes, 0, "Bundle size at \(bundlePath) is zero — did you point at a real stripped .app?")

        // 4. Append CSV row.
        let csvPath = Self.csvOutputPath()
        try Self.appendCsvRow(
            csvPath: csvPath,
            bundleBytes: bundleBytes,
            minimalPeak: minimalPeak,
            fullPeak: fullPeak,
            baseline: baseline
        )

        // 5. Working-target sanity log (no assertion — exceeding 20% triggers a PRD revision PR, not a test failure).
        let minimalTargetMB: Double = 600.0
        let fullTargetMB: Double = 2500.0
        let minimalActualMB = Double(minimalPeak) / 1_048_576.0
        let fullActualMB = Double(fullPeak) / 1_048_576.0
        let minimalDeviation = abs(minimalActualMB - minimalTargetMB) / minimalTargetMB
        let fullDeviation = abs(fullActualMB - fullTargetMB) / fullTargetMB
        if minimalDeviation > 0.20 || fullDeviation > 0.20 {
            print("[MeasurementSpike] WARNING: measured residency deviates from NFR-001 working targets by more than 20%. File a PRD revision PR before starting the next epic.")
            print("  minimal: measured \(minimalActualMB) MB vs target \(minimalTargetMB) MB (Δ \(minimalDeviation * 100)%)")
            print("  full:    measured \(fullActualMB) MB vs target \(fullTargetMB) MB (Δ \(fullDeviation * 100)%)")
        }
    }

    // MARK: - Helpers

    /// Current resident memory in bytes via `task_info` / `mach_task_basic_info` /
    /// `MACH_TASK_BASIC_INFO`. The struct's `resident_size` is the figure of merit.
    static func currentResidentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kerr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_,
                          task_flavor_t(MACH_TASK_BASIC_INFO),
                          intPtr,
                          &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return 0 }
        return info.resident_size
    }

    /// Polls `currentResidentBytes` every 1 ms for up to `seconds` and returns
    /// the peak observed. Single foreground thread — KISS.
    static func peakResidentDuring(seconds: Double) -> UInt64 {
        var peak: UInt64 = currentResidentBytes()
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let now = currentResidentBytes()
            if now > peak { peak = now }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return peak
    }

    /// Sums regular-file `fileSize` under the given `.app` directory.
    static func appBundleSizeBytes(at path: String) -> UInt64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
              let it = fm.enumerator(at: URL(fileURLWithPath: path),
                                     includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var total: UInt64 = 0
        for case let url as URL in it {
            let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if vals?.isRegularFile == true, let sz = vals?.fileSize {
                total += UInt64(sz)
            }
        }
        return total
    }

    /// Repo-relative CSV output path.
    static func csvOutputPath() -> String {
        var url = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(
            atPath: url.appendingPathComponent("_bmad-output").path
        ) {
            let parent = url.deletingLastPathComponent()
            if parent == url { break }
            url = parent
        }
        return url
            .appendingPathComponent("_bmad-output/implementation-artifacts/measurement-spike-results.csv")
            .path
    }

    /// Appends one row; writes a header first if the file does not yet exist.
    static func appendCsvRow(csvPath: String,
                             bundleBytes: UInt64,
                             minimalPeak: UInt64,
                             fullPeak: UInt64,
                             baseline: UInt64) throws {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: csvPath)
        if !exists {
            let dir = (csvPath as NSString).deletingLastPathComponent
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let header = "timestamp,host,bundle_bytes,baseline_bytes,minimal_peak_bytes,full_peak_bytes\n"
            try header.write(toFile: csvPath, atomically: true, encoding: .utf8)
        }
        let host = ProcessInfo.processInfo.hostName
        let stamp = ISO8601DateFormatter().string(from: Date())
        let row = "\(stamp),\(host),\(bundleBytes),\(baseline),\(minimalPeak),\(fullPeak)\n"
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: csvPath))
        defer { try? handle.close() }
        try handle.seekToEnd()
        if let data = row.data(using: .utf8) { try handle.write(contentsOf: data) }
    }
}
