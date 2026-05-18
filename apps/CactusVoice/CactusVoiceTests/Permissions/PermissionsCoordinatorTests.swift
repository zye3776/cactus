//
//  PermissionsCoordinatorTests.swift
//  CactusVoiceTests
//
//  Runtime tests for Story 2.4 — PermissionsCoordinator.
//
//  Mic-permission tests cannot run unattended (require the OS dialog). We
//  test only the no-crash path when the host's status is already
//  `.authorized`, and otherwise XCTSkip.
//
//  Bookmark round-trip requires the `com.apple.security.files.bookmarks.app-scope`
//  entitlement; the CactusVoice app test host inherits it. If the test is
//  invoked outside that host (e.g. raw `swift test`), `makeBookmark` will
//  raise and we XCTSkip rather than fail.
//
import AVFoundation
import XCTest
@testable import CactusVoice

final class PermissionsCoordinatorTests: XCTestCase {

    // MARK: - Bookmarks

    func testMakeAndResolveBookmarkRoundTrip() async throws {
        let coord = PermissionsCoordinator()

        // Create a real file in NSTemporaryDirectory.
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cactusvoice-bookmark-\(UUID().uuidString).txt")
        let payload = Data("hello permissions".utf8)
        try payload.write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        // makeBookmark may fail outside an entitled test host.
        let bookmark: Data
        do {
            bookmark = try await coord.makeBookmark(for: tmpURL)
        } catch {
            throw XCTSkip("makeBookmark unavailable in this host (no app-scope bookmark entitlement): \(error)")
        }
        XCTAssertFalse(bookmark.isEmpty, "Bookmark blob must be non-empty")

        let resolved = try await coord.resolveBookmark(bookmark)
        defer { Task { await coord.release(resolved) } }

        XCTAssertEqual(
            resolved.standardizedFileURL.path,
            tmpURL.standardizedFileURL.path,
            "Resolved URL must point at the original file"
        )

        // Verify we can read through the security-scoped URL.
        let readBack = try Data(contentsOf: resolved)
        XCTAssertEqual(readBack, payload, "Must be able to read the file via the resolved security-scoped URL")
    }

    func testReleaseOnNeverStartedURLDoesNotCrash() async {
        let coord = PermissionsCoordinator()
        let phantom = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("definitely-not-started-\(UUID().uuidString).txt")
        // Should be a no-op rather than crash.
        await coord.release(phantom)
    }

    // MARK: - Mic permission

    func testEnsureMicPermissionWhenAuthorizedDoesNotThrow() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .authorized else {
            throw XCTSkip("Skipping mic test — current authorization is \(status.rawValue), not .authorized")
        }
        let coord = PermissionsCoordinator()
        try await coord.ensureMicPermission()
    }
}
