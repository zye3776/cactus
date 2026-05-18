//
//  ModelCatalog.swift
//  CactusVoice
//
//  Story 2.5 — bookmark store + can-open probe.
//
//  An actor that Settings consults to validate a user-picked model file before
//  persisting its path. The validation is a *cheap* round-trip — load the
//  model via FFI and immediately free it — so that bogus file selections
//  fail in Settings rather than at first-hotkey time.
//
//  Architecture §A: bookmarks live alongside paths in UserDefaults; this
//  actor produces them and hands them back to the caller (Settings persists).
//  No in-memory cache — Settings is the bookmark store, the catalog is the
//  probe.
//
//  Architecture §E: ModelCatalog calls PermissionsCoordinator.makeBookmark
//  (the only file allowed to touch the bookmark API) and a thin FFI layer.
//  The FFI layer is injected via the `ModelLoading` protocol — so unit tests
//  can substitute a deterministic stub without depending on real model files
//  or the (stubbed-out, on this host) cactus runtime.
//
//  UX-DR8: failure reasons are exactly one of
//    "file not found", "unsupported format", "load failed".
//
//  KISS:
//    - One actor, one public method (`validate`), one protocol seam.
//    - No bookmark cache (Settings owns persistence — Story 1.5).
//    - No partial-success states; ValidationResult is binary ok|failed.
//
import Foundation
import os

// MARK: - Public types

/// Which kind of model is being probed. Mirrors `FFIShim.ModelType` at the
/// catalog layer so callers don't reach into CactusCore.
public enum ModelKind: Sendable, Equatable {
    case whisper
    case llm
    case vad
}

/// Outcome of a `validate` call.
public enum ValidationResult: Sendable, Equatable {
    case ok(bookmark: Data)
    case failed(reason: String)
}

/// Typed failure surface for the FFI seam. Keeps `ModelCatalog` ignorant of
/// raw `cactus_status_t` integers — the loader translates.
public enum FFIError: Error, Sendable, Equatable {
    case unsupportedFormat
    case loadFailed
}

/// Injectable FFI seam. Production code uses `FFIShimModelLoader` (defined
/// below); tests inject a stub that returns deterministic results and counts
/// allocate/free pairs for leak-balance assertions.
///
/// `load` returns an opaque handle (a `UUID` is fine for stub use; the real
/// implementation wraps `OpaquePointer`). `free` accepts the same handle.
/// The exact handle type is `AnyObject` so any reference-typed token works.
public protocol ModelLoading: Sendable {
    func load(path: String, kind: ModelKind) -> Result<ModelHandle, FFIError>
    func free(_ handle: ModelHandle)
}

/// Opaque token returned by `ModelLoading.load`. The catalog never inspects
/// its contents; it only round-trips it back into `free`.
public final class ModelHandle: @unchecked Sendable {
    /// Production payload — the cactus C++ handle.
    let pointer: OpaquePointer?
    /// Test payload — used by stub loaders to identify a specific allocation.
    let token: UInt64

    public init(pointer: OpaquePointer? = nil, token: UInt64 = 0) {
        self.pointer = pointer
        self.token = token
    }
}

// MARK: - ModelCatalog actor

public actor ModelCatalog {

    private let log = Logger(subsystem: "com.cactusvoice", category: "model-catalog")
    private let permissions: PermissionsCoordinator
    private let loader: ModelLoading

    public init(permissions: PermissionsCoordinator,
                loader: ModelLoading = FFIShimModelLoader()) {
        self.permissions = permissions
        self.loader = loader
    }

    /// Validate a user-picked model file. See file header for the contract.
    ///
    /// Returns one of:
    ///   - `.ok(bookmark:)` with the security-scoped bookmark blob Settings persists.
    ///   - `.failed(reason: "file not found")` — file does not exist on disk.
    ///   - `.failed(reason: "unsupported format")` — FFI reports the file is not
    ///     a model format cactus understands.
    ///   - `.failed(reason: "load failed")` — bookmark creation threw, or FFI load
    ///     failed for any other reason.
    public func validate(_ url: URL, kind: ModelKind) async -> ValidationResult {
        // 1. Cheap stat first; no FFI call if the file doesn't exist.
        guard FileManager.default.fileExists(atPath: url.path) else {
            log.error("validate: file not found at path=\(url.path, privacy: .private(mask: .hash))")
            return .failed(reason: "file not found")
        }

        // 2. Bookmark first — if Settings can't persist it, validation is moot.
        let bookmark: Data
        do {
            bookmark = try await permissions.makeBookmark(for: url)
        } catch {
            log.error("validate: bookmark creation failed: \(error.localizedDescription, privacy: .public)")
            return .failed(reason: "load failed")
        }

        // 3. Can-open probe via the injected FFI seam.
        let result = loader.load(path: url.path, kind: kind)
        switch result {
        case .success(let handle):
            // Probe never holds the model in memory beyond this call.
            loader.free(handle)
            return .ok(bookmark: bookmark)

        case .failure(.unsupportedFormat):
            log.error("validate: FFI reports unsupported format for kind=\(String(describing: kind), privacy: .public)")
            return .failed(reason: "unsupported format")

        case .failure(.loadFailed):
            log.error("validate: FFI load failed for kind=\(String(describing: kind), privacy: .public)")
            return .failed(reason: "load failed")
        }
    }
}

// MARK: - FFIShim-backed loader (production default)

/// Default `ModelLoading` implementation. Wraps `FFIShim.loadModel` /
/// `FFIShim.freeModel`. Until Story 3.1 wires the real cactus runtime, the
/// underlying `FFIStub.c` returns `cactus_status_err_unimplemented` (raw=3),
/// so this loader always reports `.loadFailed` on this CLT-only host. That
/// is exactly why the protocol seam exists — tests inject their own stub.
public struct FFIShimModelLoader: ModelLoading {
    public init() {}

    public func load(path: String, kind: ModelKind) -> Result<ModelHandle, FFIError> {
        let ffiType: FFIShim.ModelType
        switch kind {
        case .whisper: ffiType = .whisper
        case .llm:     ffiType = .llm
        case .vad:     ffiType = .onnx  // Silero VAD is an ONNX model
        }
        let (status, ptr) = FFIShim.loadModel(path: path, type: ffiType)
        if status.isOK, let p = ptr {
            return .success(ModelHandle(pointer: p))
        }
        // cactus_status_err_unsupported == 4 per cactus_c.h
        if status.raw == 4 {
            return .failure(.unsupportedFormat)
        }
        return .failure(.loadFailed)
    }

    public func free(_ handle: ModelHandle) {
        _ = FFIShim.freeModel(handle.pointer)
    }
}
