import XCTest

/// Acceptance tests for Story 2.5 — ModelCatalog (bookmark store + can-open probe).
///
/// File-level static checks against the on-disk source so the structural
/// contract is enforced even on hosts without Xcode.app. Runtime semantics
/// (ok path, file-not-found, malformed bytes, handle-leak balance) live in
/// `CactusVoiceTests/Permissions/ModelCatalogTests.swift` with a stub
/// `ModelLoading` injected at the seam.
final class Story2_5Tests: XCTestCase {

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

    // MARK: - AC1: file exists, declared as `actor ModelCatalog`

    func testModelCatalogFileExists() {
        XCTAssertTrue(
            exists("CactusVoice/Permissions/ModelCatalog.swift"),
            "ModelCatalog.swift must live at CactusVoice/Permissions/ModelCatalog.swift"
        )
    }

    func testActorDeclaration() throws {
        let s = try read("CactusVoice/Permissions/ModelCatalog.swift")
        XCTAssertTrue(
            s.contains("actor ModelCatalog"),
            "Must declare `actor ModelCatalog`"
        )
    }

    // MARK: - AC2: ModelKind enum + three cases

    func testModelKindEnum() throws {
        let s = try read("CactusVoice/Permissions/ModelCatalog.swift")
        XCTAssertTrue(
            s.contains("enum ModelKind"),
            "Must declare `enum ModelKind`"
        )
        XCTAssertTrue(
            s.contains("case whisper") && s.contains("case llm") && s.contains("case vad"),
            "ModelKind must have cases .whisper, .llm, .vad"
        )
    }

    // MARK: - AC3: ValidationResult enum

    func testValidationResultEnum() throws {
        let s = try read("CactusVoice/Permissions/ModelCatalog.swift")
        XCTAssertTrue(
            s.contains("enum ValidationResult"),
            "Must declare `enum ValidationResult`"
        )
        XCTAssertTrue(
            s.contains("case ok(bookmark: Data)"),
            "ValidationResult must declare `case ok(bookmark: Data)`"
        )
        XCTAssertTrue(
            s.contains("case failed(reason: String)"),
            "ValidationResult must declare `case failed(reason: String)`"
        )
    }

    // MARK: - AC4: validate signature

    func testValidateSignature() throws {
        let s = try read("CactusVoice/Permissions/ModelCatalog.swift")
        XCTAssertTrue(
            s.contains("func validate(_ url: URL, kind: ModelKind) async -> ValidationResult"),
            "Must declare `func validate(_ url: URL, kind: ModelKind) async -> ValidationResult`"
        )
        XCTAssertTrue(
            s.contains("FileManager.default.fileExists"),
            "validate must check FileManager.default.fileExists before the FFI call"
        )
        XCTAssertTrue(
            s.contains("makeBookmark(for:"),
            "validate must call PermissionsCoordinator.makeBookmark(for:)"
        )
    }

    // MARK: - AC5: exact failure reason strings (UX-DR8)

    func testFailureReasonStringsExact() throws {
        let s = try read("CactusVoice/Permissions/ModelCatalog.swift")
        XCTAssertTrue(
            s.contains("\"file not found\""),
            "Must use the exact literal `\"file not found\"`"
        )
        XCTAssertTrue(
            s.contains("\"unsupported format\""),
            "Must use the exact literal `\"unsupported format\"`"
        )
        XCTAssertTrue(
            s.contains("\"load failed\""),
            "Must use the exact literal `\"load failed\"`"
        )
    }

    // MARK: - AC6: protocol seam for FFI

    func testModelLoadingProtocol() throws {
        let s = try read("CactusVoice/Permissions/ModelCatalog.swift")
        XCTAssertTrue(
            s.contains("protocol ModelLoading"),
            "Must declare `protocol ModelLoading` as the injectable FFI seam"
        )
    }

    func testInitSignatureTakesPermissionsAndLoader() throws {
        let s = try read("CactusVoice/Permissions/ModelCatalog.swift")
        XCTAssertTrue(
            s.contains("permissions: PermissionsCoordinator"),
            "Init must take `permissions: PermissionsCoordinator`"
        )
        XCTAssertTrue(
            s.contains("loader:") && s.contains("ModelLoading"),
            "Init must take `loader: ModelLoading` (or `some ModelLoading`)"
        )
    }

    // MARK: - AC7: probe never leaks — `free` is invoked on success path

    func testFreeCalledOnProbeSuccess() throws {
        let s = try read("CactusVoice/Permissions/ModelCatalog.swift")
        // Look for any call surface that ends with `.free(` — either
        // `loader.free(` or `FFIShim.freeModel(`.
        XCTAssertTrue(
            s.contains(".free(") || s.contains("freeModel("),
            "validate must call free/freeModel on the handle returned by load to avoid handle leak"
        )
    }

    // MARK: - AC8: runtime test file exists

    func testRuntimeTestsFileExists() {
        XCTAssertTrue(
            exists("CactusVoiceTests/Permissions/ModelCatalogTests.swift"),
            "Runtime tests file must exist at CactusVoiceTests/Permissions/ModelCatalogTests.swift"
        )
    }

    // MARK: - Budget — implementation ≤ 200 LOC

    func testImplementationBudget() throws {
        let n = try lineCount("CactusVoice/Permissions/ModelCatalog.swift")
        XCTAssertLessThanOrEqual(
            n, 200,
            "ModelCatalog.swift line count (\(n)) must be ≤ 200 (KISS)"
        )
    }
}
