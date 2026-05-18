//
//  ModelCatalogTests.swift
//  CactusVoiceTests
//
//  Runtime tests for Story 2.5 — ModelCatalog can-open probe.
//
//  All paths run against an injected `StubLoader` so the tests exercise the
//  catalog deterministically without touching the (currently stubbed) cactus
//  runtime or requiring real model files.
//
//  The bookmark round-trip half of the OK path requires the app-scope
//  bookmark entitlement (see Story 2.4 notes). Outside an entitled test host
//  `makeBookmark` raises and the catalog returns `.failed("load failed")`;
//  the relevant test XCTSkips in that case rather than asserts the negative
//  shape — we want a true OK assertion to remain meaningful.
//
import Foundation
import XCTest
@testable import CactusVoice

/// Deterministic in-memory loader. Counts allocations and frees so leak
/// balance can be asserted directly.
final class StubLoader: ModelLoading, @unchecked Sendable {
    enum Mode {
        case success
        case unsupported
        case loadFailed
    }

    var mode: Mode
    var allocCount = 0
    var freeCount = 0
    var lastLoadedPath: String?
    var lastLoadedKind: ModelKind?
    private var nextToken: UInt64 = 1

    init(mode: Mode) {
        self.mode = mode
    }

    func load(path: String, kind: ModelKind) -> Result<ModelHandle, FFIError> {
        lastLoadedPath = path
        lastLoadedKind = kind
        switch mode {
        case .success:
            allocCount += 1
            let h = ModelHandle(pointer: nil, token: nextToken)
            nextToken += 1
            return .success(h)
        case .unsupported:
            return .failure(.unsupportedFormat)
        case .loadFailed:
            return .failure(.loadFailed)
        }
    }

    func free(_ handle: ModelHandle) {
        freeCount += 1
    }
}

final class ModelCatalogTests: XCTestCase {

    // MARK: - Helpers

    private func tempFile(named: String = UUID().uuidString) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cactusvoice-modelcatalog-\(named).bin")
        try Data("dummy bytes".utf8).write(to: url)
        return url
    }

    // MARK: - OK path

    func testOkPathReturnsBookmarkAndCallsFreeOnce() async throws {
        let stub = StubLoader(mode: .success)
        let perms = PermissionsCoordinator()
        let catalog = ModelCatalog(permissions: perms, loader: stub)

        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        // makeBookmark may fail outside an entitled host — XCTSkip rather
        // than fail because the catalog would report `.failed("load failed")`
        // which conflates the bookmark and FFI failure modes for this test.
        do {
            _ = try await perms.makeBookmark(for: url)
        } catch {
            throw XCTSkip("makeBookmark unavailable in this host (no app-scope bookmark entitlement): \(error)")
        }

        let result = await catalog.validate(url, kind: .whisper)
        switch result {
        case .ok(let bookmark):
            XCTAssertFalse(bookmark.isEmpty, "Bookmark blob must be non-empty on .ok")
        case .failed(let reason):
            XCTFail("Expected .ok, got .failed(reason: \(reason))")
        }

        // Probe never holds the model in memory longer than the probe call.
        XCTAssertEqual(stub.allocCount, 1, "Probe must allocate exactly once")
        XCTAssertEqual(stub.freeCount, 1, "Probe must free exactly once — no leaks")
        XCTAssertEqual(stub.lastLoadedKind, .whisper, "Kind must be forwarded to loader")
        XCTAssertEqual(stub.lastLoadedPath, url.path, "Path must be forwarded to loader")
    }

    // MARK: - File-not-found path

    func testFileNotFoundReturnsFileNotFoundAndSkipsFFICall() async {
        let stub = StubLoader(mode: .success) // would succeed if called
        let perms = PermissionsCoordinator()
        let catalog = ModelCatalog(permissions: perms, loader: stub)

        let phantom = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("definitely-does-not-exist-\(UUID().uuidString).bin")

        let result = await catalog.validate(phantom, kind: .whisper)

        switch result {
        case .failed(let reason):
            XCTAssertEqual(reason, "file not found",
                           "Missing file must surface as the exact UX-DR8 reason string")
        case .ok:
            XCTFail("Expected .failed(file not found), got .ok")
        }

        XCTAssertEqual(stub.allocCount, 0, "FFI load must NOT be called when file is missing")
        XCTAssertEqual(stub.freeCount, 0, "FFI free must NOT be called when file is missing")
        XCTAssertNil(stub.lastLoadedPath, "Loader must not be consulted at all")
    }

    // MARK: - Malformed-bytes path (load failure)

    func testLoadFailureReturnsLoadFailed() async throws {
        let stub = StubLoader(mode: .loadFailed)
        let perms = PermissionsCoordinator()
        let catalog = ModelCatalog(permissions: perms, loader: stub)

        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        // Outside the entitled host, makeBookmark fails first and we'd also
        // see "load failed". That's fine for this test (the assertion is the
        // string, not the cause) — no XCTSkip needed.
        let result = await catalog.validate(url, kind: .llm)

        switch result {
        case .failed(let reason):
            XCTAssertEqual(reason, "load failed",
                           "Generic load failure must surface as the exact UX-DR8 reason string")
        case .ok:
            XCTFail("Expected .failed(load failed), got .ok")
        }

        XCTAssertEqual(stub.allocCount, 0, "Stub returned .loadFailed; no handle was produced")
        XCTAssertEqual(stub.freeCount, 0, "No free on a never-allocated handle")
    }

    // MARK: - Unsupported-format path

    func testUnsupportedFormatReturnsUnsupportedFormat() async throws {
        let stub = StubLoader(mode: .unsupported)
        let perms = PermissionsCoordinator()
        let catalog = ModelCatalog(permissions: perms, loader: stub)

        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        // Skip if the host can't even make the bookmark — otherwise the
        // catalog returns "load failed" from the bookmark stage and the
        // unsupported branch is never reached.
        do {
            _ = try await perms.makeBookmark(for: url)
        } catch {
            throw XCTSkip("makeBookmark unavailable in this host: \(error)")
        }

        let result = await catalog.validate(url, kind: .vad)

        switch result {
        case .failed(let reason):
            XCTAssertEqual(reason, "unsupported format",
                           "Unsupported-format failure must surface as the exact UX-DR8 reason string")
        case .ok:
            XCTFail("Expected .failed(unsupported format), got .ok")
        }
    }

    // MARK: - Handle-leak balance across repeated probes

    func testRepeatedSuccessfulProbesBalanceAllocAndFree() async throws {
        let stub = StubLoader(mode: .success)
        let perms = PermissionsCoordinator()
        let catalog = ModelCatalog(permissions: perms, loader: stub)

        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            _ = try await perms.makeBookmark(for: url)
        } catch {
            throw XCTSkip("makeBookmark unavailable in this host: \(error)")
        }

        for _ in 0..<5 {
            _ = await catalog.validate(url, kind: .whisper)
        }

        XCTAssertEqual(stub.allocCount, 5, "Each successful probe allocates once")
        XCTAssertEqual(stub.freeCount, 5, "Each successful probe frees once — perfect balance")
    }
}
