import XCTest

/// Acceptance tests for Story 2.1 — BoundedSPSCBuffer<Float>.
///
/// File-level static checks against the on-disk source so the structural
/// contract is enforced even on hosts without Xcode.app. Runtime correctness
/// (round-trip, overrun semantics, concurrency stress, AsyncStream delivery)
/// is covered by `CactusVoiceTests/Audio/BoundedSPSCBufferTests.swift`.
final class Story2_1Tests: XCTestCase {

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

    // MARK: - AC1: file exists, final class, generic over T

    func testBufferFileExists() {
        XCTAssertTrue(exists("CactusVoice/Audio/BoundedSPSCBuffer.swift"),
                      "BoundedSPSCBuffer.swift must live at CactusVoice/Audio/BoundedSPSCBuffer.swift")
    }

    func testFinalClassGeneric() throws {
        let s = try read("CactusVoice/Audio/BoundedSPSCBuffer.swift")
        XCTAssertTrue(s.contains("final class BoundedSPSCBuffer<"),
                      "BoundedSPSCBuffer must be a final class generic over T")
        XCTAssertFalse(s.contains("actor BoundedSPSCBuffer"),
                       "BoundedSPSCBuffer must NOT be an actor (audio thread must not hop executors)")
    }

    // MARK: - AC2: capacity is a required init parameter

    func testCapacityInInit() throws {
        let s = try read("CactusVoice/Audio/BoundedSPSCBuffer.swift")
        XCTAssertTrue(s.contains("init(capacity:"),
                      "BoundedSPSCBuffer must accept capacity in its initializer")
    }

    // MARK: - AC3: SPSC contract documented

    func testSPSCDocumented() throws {
        let s = try read("CactusVoice/Audio/BoundedSPSCBuffer.swift")
        let lower = s.lowercased()
        XCTAssertTrue(lower.contains("single-producer") || lower.contains("spsc"),
                      "File must document the SPSC contract (single-producer/single-consumer)")
        XCTAssertTrue(lower.contains("undefined") || lower.contains("not safe"),
                      "File must document that concurrent writers/readers are undefined behavior")
    }

    // MARK: - AC4: overrun count + drop-oldest documented in source

    func testOverrunCountAndDropOldest() throws {
        let s = try read("CactusVoice/Audio/BoundedSPSCBuffer.swift")
        XCTAssertTrue(s.contains("overrunCount"),
                      "BoundedSPSCBuffer must expose overrunCount")
        let lower = s.lowercased()
        XCTAssertTrue(lower.contains("drop") && lower.contains("oldest"),
                      "File must document drop-oldest semantics on overrun")
    }

    // MARK: - AC5: read returns ArraySlice<T>

    func testReadReturnsArraySlice() throws {
        let s = try read("CactusVoice/Audio/BoundedSPSCBuffer.swift")
        XCTAssertTrue(s.contains("func read(") && s.contains("ArraySlice<"),
                      "read(...) must return ArraySlice<T>")
        XCTAssertTrue(s.contains("func write("),
                      "BoundedSPSCBuffer must expose write(...)")
        XCTAssertTrue(s.contains("func removeAll("),
                      "BoundedSPSCBuffer must expose removeAll()")
    }

    // MARK: - AC7: overrunStream is an AsyncStream<Int>

    func testOverrunStreamShape() throws {
        let s = try read("CactusVoice/Audio/BoundedSPSCBuffer.swift")
        XCTAssertTrue(s.contains("overrunStream"),
                      "BoundedSPSCBuffer must expose overrunStream")
        XCTAssertTrue(s.contains("AsyncStream<Int>"),
                      "overrunStream must be an AsyncStream<Int>")
    }

    // MARK: - AC8: runtime test file exists

    func testBufferTestsExist() {
        XCTAssertTrue(exists("CactusVoiceTests/Audio/BoundedSPSCBufferTests.swift"),
                      "BoundedSPSCBufferTests.swift must live at CactusVoiceTests/Audio/BoundedSPSCBufferTests.swift")
    }

    // MARK: - KISS: file ≤ 200 LOC

    func testFileSizeUnder200LOC() throws {
        let lines = try lineCount("CactusVoice/Audio/BoundedSPSCBuffer.swift")
        XCTAssertLessThanOrEqual(lines, 200,
                                 "BoundedSPSCBuffer.swift must be ≤ 200 LOC, got \(lines)")
    }
}
