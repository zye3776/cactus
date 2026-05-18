import XCTest

/// Acceptance tests for Story 1.1 — Initialize Xcode workspace and two targets.
///
/// These tests inspect the on-disk project skeleton (`project.yml`, workspace XML,
/// folder layout, `Info.plist`, entitlements). Anything that requires a built
/// `.app` bundle or `xcodebuild` at test-time is gated with `XCTSkipUnless`.
final class Story1_1Tests: XCTestCase {

    // MARK: - Helpers

    /// Walks up from this source file to the `apps/CactusVoice` directory so the
    /// test works whether run via `xcodebuild test`, `swift test`, or directly.
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

    // MARK: - AC1: workspace exists

    func testWorkspaceFileExists() {
        XCTAssertTrue(
            exists("CactusVoice.xcworkspace/contents.xcworkspacedata"),
            "Expected CactusVoice.xcworkspace/contents.xcworkspacedata to exist"
        )
        let xml = (try? read("CactusVoice.xcworkspace/contents.xcworkspacedata")) ?? ""
        XCTAssertTrue(xml.contains("CactusVoice.xcodeproj"),
                      "Workspace must reference CactusVoice.xcodeproj")
    }

    // MARK: - AC2: two targets declared

    func testProjectYmlDeclaresBothTargets() throws {
        let yml = try read("project.yml")
        XCTAssertTrue(yml.contains("CactusVoice:"), "Missing CactusVoice target")
        XCTAssertTrue(yml.contains("CactusCore:"), "Missing CactusCore target")
        XCTAssertTrue(yml.contains("type: application"),
                      "CactusVoice target must be an application")
        XCTAssertTrue(yml.contains("type: library.static"),
                      "CactusCore must be a static library")
        XCTAssertTrue(yml.contains("DEPLOYMENT_TARGET") || yml.contains("deploymentTarget"),
                      "Deployment target must be declared")
        XCTAssertTrue(yml.contains("14.0") || yml.contains("\"14.0\""),
                      "macOS 14.0+ deployment target required")
        XCTAssertTrue(yml.contains("arm64"),
                      "Apple Silicon only — arm64 must be the sole architecture")
    }

    // MARK: - AC3: only KeyboardShortcuts SPM dep

    func testOnlyKeyboardShortcutsDependency() throws {
        let yml = try read("project.yml")
        // Must include KeyboardShortcuts package
        XCTAssertTrue(yml.contains("KeyboardShortcuts"),
                      "KeyboardShortcuts SPM dep is required")
        XCTAssertTrue(yml.contains("sindresorhus/KeyboardShortcuts"),
                      "Must point at sindresorhus/KeyboardShortcuts upstream")
        // No other packages allowed
        let packagesSection = yml.range(of: "packages:").map { range -> String in
            String(yml[range.upperBound...])
        } ?? ""
        // Count URLs in packages: section — must be exactly 1
        let urlCount = packagesSection.components(separatedBy: "url:").count - 1
        XCTAssertEqual(urlCount, 1,
                       "Exactly one SPM dep (KeyboardShortcuts) allowed; found \(urlCount)")
    }

    // MARK: - AC4: entitlements

    func testEntitlementsContents() throws {
        let entitlements = try read("CactusVoice/CactusVoice.entitlements")
        let required = [
            "com.apple.security.app-sandbox",
            "com.apple.security.device.audio-input",
            "com.apple.security.files.user-selected.read-only",
            "com.apple.security.files.bookmarks.app-scope",
        ]
        for key in required {
            XCTAssertTrue(entitlements.contains(key),
                          "Entitlements missing required key: \(key)")
        }
        // Hard bar: no network entitlement of any kind
        XCTAssertFalse(entitlements.contains("com.apple.security.network"),
                       "Network entitlement must NOT be present (NFR-002)")
    }

    // MARK: - AC5: Info.plist

    func testInfoPlistContents() throws {
        let plist = try read("CactusVoice/Info.plist")
        XCTAssertTrue(plist.contains("com.cactusvoice"),
                      "Bundle identifier must be com.cactusvoice")
        XCTAssertTrue(plist.contains("LSMinimumSystemVersion"),
                      "LSMinimumSystemVersion key required")
        // Parse it for real
        guard
            let data = try? Data(contentsOf: appRoot.appendingPathComponent("CactusVoice/Info.plist")),
            let parsed = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            ) as? [String: Any]
        else {
            XCTFail("Info.plist must be parseable as a property list")
            return
        }
        let minVersion = (parsed["LSMinimumSystemVersion"] as? String) ?? "0.0"
        let major = Int(minVersion.split(separator: ".").first ?? "0") ?? 0
        XCTAssertGreaterThanOrEqual(major, 14,
                                    "LSMinimumSystemVersion must be >= 14.0 (got \(minVersion))")
    }

    // MARK: - AC6: folder layout matches architecture §Project Structure

    func testFolderLayoutMatchesArchitecture() {
        let appDirs = [
            "CactusVoice/App",
            "CactusVoice/Audio",
            "CactusVoice/Hotkey",
            "CactusVoice/Inference",
            "CactusVoice/Transcript",
            "CactusVoice/UI",
            "CactusVoice/Permissions",
            "CactusVoice/Persistence",
            "CactusVoice/Errors",
            "CactusVoice/Resources",
        ]
        for dir in appDirs {
            XCTAssertTrue(exists(dir), "Missing required app subfolder: \(dir)")
        }
        XCTAssertTrue(exists("CactusCore"), "Missing CactusCore target folder")
        XCTAssertTrue(exists("CactusCore/include"), "Missing CactusCore/include")
        XCTAssertTrue(exists("CactusCore/include/CactusCore.h"),
                      "Missing CactusCore umbrella header")
        XCTAssertTrue(exists("CactusCore/module.modulemap"),
                      "Missing CactusCore module.modulemap")
        XCTAssertTrue(exists("CactusVoiceTests"), "Missing CactusVoiceTests folder")
    }

    // MARK: - AC7: xcodebuild zero-warning (gated)

    func testXcodebuildSucceedsCleanly() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: "/usr/bin/xcodebuild"),
            "xcodebuild not available in this environment"
        )
        // Story executor performs this externally; in-test invocation would
        // recursively build. Treat as a story-level check, not a unit test.
        try XCTSkipIf(true, "xcodebuild is invoked by the story executor, not the test bundle")
    }

    // MARK: - AC8: .app launches & exits (gated)

    func testAppLaunchesAndExits() throws {
        try XCTSkipIf(true, "Launch-and-exit verification is performed manually post-build")
    }

    // MARK: - Project skeleton sanity

    func testAppEntrypointExists() {
        XCTAssertTrue(exists("CactusVoice/App/CactusVoiceApp.swift"),
                      "SwiftUI @main entry point must exist")
    }

    func testGitignoreCoversXcuserdata() throws {
        let gi = try read(".gitignore")
        XCTAssertTrue(gi.contains("xcuserdata"),
                      ".gitignore must exclude xcuserdata")
    }
}
