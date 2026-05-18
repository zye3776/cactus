import XCTest

/// Acceptance tests for Story 1.5 — Settings persistence (UserDefaults + Codable + @Observable).
///
/// These are file-level static checks against the on-disk source: the runtime
/// codec/observability behaviour is covered by
/// `CactusVoiceTests/Persistence/SettingsCodecTests.swift`. This file enforces
/// the structural contract from the story even when the host has no Xcode.app.
final class Story1_5Tests: XCTestCase {

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
        // Match git's line-count semantics: count newline-terminated lines + 1 if there's a trailing non-newline.
        var count = 0
        for ch in s where ch == "\n" { count += 1 }
        if !s.hasSuffix("\n"), !s.isEmpty { count += 1 }
        return count
    }

    // MARK: - AC1: Settings struct + required fields

    func testSettingsFileExists() {
        XCTAssertTrue(exists("CactusVoice/Persistence/Settings.swift"),
                      "Settings.swift must live at CactusVoice/Persistence/Settings.swift")
    }

    func testSettingsHasRequiredFields() throws {
        let s = try read("CactusVoice/Persistence/Settings.swift")
        XCTAssertTrue(s.contains("struct Settings"),
                      "Settings must be declared as a Swift struct")
        XCTAssertTrue(s.contains("Codable"),
                      "Settings must conform to Codable")
        // Per deviation in story file, hotkey is persisted as a String (raw KeyboardShortcuts.Name value).
        XCTAssertTrue(s.contains("hotkey"),
                      "Settings must declare a hotkey field")
        XCTAssertTrue(s.contains("activationMode"),
                      "Settings must declare activationMode field")
        XCTAssertTrue(s.contains("whisperModelPath: String?"),
                      "Settings must declare whisperModelPath: String?")
        XCTAssertTrue(s.contains("llmModelPath: String?"),
                      "Settings must declare llmModelPath: String?")
        XCTAssertTrue(s.contains("whisperBookmark: Data?"),
                      "Settings must declare whisperBookmark: Data?")
        XCTAssertTrue(s.contains("llmBookmark: Data?"),
                      "Settings must declare llmBookmark: Data?")
    }

    // MARK: - AC2: ActivationMode enum

    func testActivationModeEnum() throws {
        let s = try read("CactusVoice/Persistence/Settings.swift")
        XCTAssertTrue(s.contains("enum ActivationMode"),
                      "ActivationMode must be declared as a Swift enum")
        XCTAssertTrue(s.contains("String") && s.contains("Codable"),
                      "ActivationMode must be String + Codable")
        XCTAssertTrue(s.contains("case hold"),
                      "ActivationMode must declare case hold")
        XCTAssertTrue(s.contains("case toggle"),
                      "ActivationMode must declare case toggle")
        // Default value must be .hold.
        XCTAssertTrue(s.contains("= .hold"),
                      "activationMode default must be .hold")
    }

    // MARK: - AC3: SettingsStore @MainActor @Observable

    func testSettingsStoreShape() throws {
        let s = try read("CactusVoice/Persistence/Settings.swift")
        XCTAssertTrue(s.contains("@MainActor"),
                      "SettingsStore must be @MainActor")
        XCTAssertTrue(s.contains("@Observable"),
                      "SettingsStore must be @Observable")
        XCTAssertTrue(s.contains("final class SettingsStore"),
                      "SettingsStore must be a final class")
        XCTAssertTrue(s.contains("var current"),
                      "SettingsStore must expose `var current: Settings`")
    }

    // MARK: - AC3 (continued): UserDefaults import isolated to Persistence/

    func testUserDefaultsImportIsolated() throws {
        // Walk all .swift files under apps/CactusVoice/CactusVoice and assert
        // that any reference to `UserDefaults` lives under Persistence/.
        let appSources = appRoot.appendingPathComponent("CactusVoice")
        let enumerator = FileManager.default.enumerator(
            at: appSources,
            includingPropertiesForKeys: nil
        )
        var offenders: [String] = []
        while let item = enumerator?.nextObject() as? URL {
            guard item.pathExtension == "swift" else { continue }
            // Whitelist Persistence/ subtree.
            if item.path.contains("/Persistence/") { continue }
            let text = (try? String(contentsOf: item, encoding: .utf8)) ?? ""
            if text.contains("UserDefaults") {
                offenders.append(item.lastPathComponent)
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "UserDefaults must only be referenced inside Persistence/. Offenders: \(offenders)")
    }

    // MARK: - AC4: key prefix com.cactusvoice.

    func testKeyPrefix() throws {
        let s = try read("CactusVoice/Persistence/Settings.swift")
        XCTAssertTrue(s.contains("com.cactusvoice."),
                      "Settings key must be prefixed com.cactusvoice.")
        XCTAssertTrue(s.contains("com.cactusvoice.settings.v1"),
                      "Settings must use a single versioned JSON blob key com.cactusvoice.settings.v1")
    }

    // MARK: - AC6: SettingsCodecTests exists

    func testSettingsCodecTestsExist() {
        XCTAssertTrue(exists("CactusVoiceTests/Persistence/SettingsCodecTests.swift"),
                      "SettingsCodecTests.swift must live at CactusVoiceTests/Persistence/SettingsCodecTests.swift")
    }

    // MARK: - AC7: file ≤ 200 LOC

    func testFileSizeUnder200LOC() throws {
        let lines = try lineCount("CactusVoice/Persistence/Settings.swift")
        XCTAssertLessThanOrEqual(lines, 200,
                                 "Settings.swift must be ≤ 200 LOC, got \(lines)")
    }
}
