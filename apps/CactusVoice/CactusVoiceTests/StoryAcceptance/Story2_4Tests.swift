import XCTest

/// Acceptance tests for Story 2.4 — PermissionsCoordinator (mic + security-scoped bookmarks).
///
/// File-level static checks against the on-disk source so the structural
/// contract is enforced even on hosts without Xcode.app. Runtime semantics
/// (bookmark round-trip, mic .authorized no-crash, release no-crash) live in
/// `CactusVoiceTests/Permissions/PermissionsCoordinatorTests.swift`.
final class Story2_4Tests: XCTestCase {

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

    // MARK: - AC1: file exists, declared as `actor PermissionsCoordinator`

    func testPermissionsCoordinatorFileExists() {
        XCTAssertTrue(
            exists("CactusVoice/Permissions/PermissionsCoordinator.swift"),
            "PermissionsCoordinator.swift must live at CactusVoice/Permissions/PermissionsCoordinator.swift"
        )
    }

    func testActorDeclaration() throws {
        let s = try read("CactusVoice/Permissions/PermissionsCoordinator.swift")
        XCTAssertTrue(
            s.contains("actor PermissionsCoordinator"),
            "Must declare `actor PermissionsCoordinator`"
        )
        XCTAssertTrue(
            s.contains("import AVFoundation"),
            "Must import AVFoundation for AVCaptureDevice"
        )
    }

    // MARK: - AC2-5: four async funcs present with the expected signatures

    func testEnsureMicPermissionSignature() throws {
        let s = try read("CactusVoice/Permissions/PermissionsCoordinator.swift")
        XCTAssertTrue(
            s.contains("func ensureMicPermission() async throws"),
            "Must declare `func ensureMicPermission() async throws`"
        )
        XCTAssertTrue(
            s.contains("AVCaptureDevice.authorizationStatus(for: .audio)"),
            "Must call AVCaptureDevice.authorizationStatus(for: .audio)"
        )
        XCTAssertTrue(
            s.contains("AVCaptureDevice.requestAccess(for: .audio)"),
            "Must call AVCaptureDevice.requestAccess(for: .audio) when status is .notDetermined"
        )
        XCTAssertTrue(
            s.contains("AppError.micDenied"),
            "Must throw AppError.micDenied on .denied / .restricted"
        )
    }

    func testResolveBookmarkSignature() throws {
        let s = try read("CactusVoice/Permissions/PermissionsCoordinator.swift")
        XCTAssertTrue(
            s.contains("func resolveBookmark(_ data: Data) async throws -> URL"),
            "Must declare `func resolveBookmark(_ data: Data) async throws -> URL`"
        )
        XCTAssertTrue(
            s.contains(".withSecurityScope"),
            "Must use .withSecurityScope resolution options"
        )
        XCTAssertTrue(
            s.contains("startAccessingSecurityScopedResource"),
            "Must call startAccessingSecurityScopedResource on the resolved URL"
        )
    }

    func testReleaseSignature() throws {
        let s = try read("CactusVoice/Permissions/PermissionsCoordinator.swift")
        XCTAssertTrue(
            s.contains("func release(_ url: URL)"),
            "Must declare `func release(_ url: URL)`"
        )
        XCTAssertTrue(
            s.contains("stopAccessingSecurityScopedResource"),
            "Must call stopAccessingSecurityScopedResource"
        )
    }

    func testMakeBookmarkSignature() throws {
        let s = try read("CactusVoice/Permissions/PermissionsCoordinator.swift")
        XCTAssertTrue(
            s.contains("func makeBookmark(for url: URL) async throws -> Data"),
            "Must declare `func makeBookmark(for url: URL) async throws -> Data`"
        )
        XCTAssertTrue(
            s.contains("bookmarkData(options: .withSecurityScope"),
            "Must call url.bookmarkData(options: .withSecurityScope, ...)"
        )
    }

    // MARK: - AC6: boundary-check script exists and references both forbidden identifiers

    func testBoundaryScriptExists() {
        XCTAssertTrue(
            exists("Scripts/check-permission-boundaries.sh"),
            "Scripts/check-permission-boundaries.sh must exist"
        )
    }

    func testBoundaryScriptReferencesForbiddenIdentifiers() throws {
        let s = try read("Scripts/check-permission-boundaries.sh")
        XCTAssertTrue(
            s.contains("AVCaptureDevice.requestAccess"),
            "Script must grep for AVCaptureDevice.requestAccess"
        )
        XCTAssertTrue(
            s.contains("startAccessingSecurityScopedResource"),
            "Script must grep for startAccessingSecurityScopedResource"
        )
        XCTAssertTrue(
            s.contains("PermissionsCoordinator.swift"),
            "Script must allowlist Permissions/PermissionsCoordinator.swift"
        )
    }

    func testBoundaryScriptInvocationDocumented() throws {
        // Per global rule: no chmod +x on shell scripts. Script header must
        // direct callers to invoke via `bash <path>`.
        let s = try read("Scripts/check-permission-boundaries.sh")
        XCTAssertTrue(
            s.contains("bash") && s.contains("check-permission-boundaries.sh"),
            "Script header must document `bash Scripts/check-permission-boundaries.sh` invocation"
        )
    }

    // MARK: - AC7: PermissionsCoordinatorTests.swift exists

    func testRuntimeTestsFileExists() {
        XCTAssertTrue(
            exists("CactusVoiceTests/Permissions/PermissionsCoordinatorTests.swift"),
            "Runtime tests file must exist at CactusVoiceTests/Permissions/PermissionsCoordinatorTests.swift"
        )
    }

    // MARK: - Budget — implementation ≤ 200 LOC

    func testImplementationBudget() throws {
        let n = try lineCount("CactusVoice/Permissions/PermissionsCoordinator.swift")
        XCTAssertLessThanOrEqual(
            n, 200,
            "PermissionsCoordinator.swift line count (\(n)) must be ≤ 200 (KISS)"
        )
    }

    func testScriptBudget() throws {
        let n = try lineCount("Scripts/check-permission-boundaries.sh")
        XCTAssertLessThanOrEqual(
            n, 40,
            "check-permission-boundaries.sh line count (\(n)) must be ≤ 40"
        )
    }
}
