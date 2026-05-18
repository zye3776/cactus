//
//  CactusRuntime.swift — Story 3.1.
//
//  Architecture §B THICK layer of the two-layer cactus interop seam:
//  `FFIShim` does pure marshaling; this actor owns lifetime, residency,
//  refcounting, mode gating, and error mapping. WhisperSession / LLMSession
//  / SileroVAD acquire handles through this actor only.
//
//  Slot model: each kind (Whisper / LLM / VAD) has at most one resident
//  model. Same-path acquire → refcount++. Different-path acquire → free
//  old if refcount==0, otherwise throw "slot in use" (KISS — see
//  story-3.1.md). release decrements refcount but does NOT eagerly free;
//  unloadAll() or the next path change does. Concurrent acquires of the
//  same path collapse to one underlying load via a pending Task per slot.
//
//  Mode gating: .full = all three slots usable. .minimal = acquireLLM
//  rejects with "llm disabled in minimal mode"; acquireLLMForUserAction
//  is the user-invoked-Rewrite escape hatch and succeeds in either mode.
//
//  Error mapping: every failure → AppError.modelLoadFailed(path:reason:),
//  logged once at the throw site.
//
//  KISS: no memory-pressure eviction, no priority queues, no wait on
//  slot-in-use, no atomic refcounts (actor isolation suffices).
//
import Foundation
import os

// MARK: - Public value types

/// Memory-governance mode (architecture §B accuracy revision, NFR-001 tiered).
public enum RuntimeMode: Sendable, Equatable {
    /// Whisper + VAD only. LLM disabled to fit the ~600 MB working set.
    case minimal
    /// All three slots. ~2.5 GB peak with Gemma-3 + Whisper.
    case full
}

/// Snapshot of which path is loaded per slot, plus the current mode.
public struct ResidencyReport: Sendable, Equatable {
    public let whisper: URL?
    public let llm: URL?
    public let vad: URL?
    public let mode: RuntimeMode

    public init(whisper: URL?, llm: URL?, vad: URL?, mode: RuntimeMode) {
        self.whisper = whisper
        self.llm = llm
        self.vad = vad
        self.mode = mode
    }
}

/// Whisper model handle. The opaque pointer is the raw cactus handle —
/// downstream sessions pass it back into `FFIShim.whisperCreateSession`.
///
/// `@unchecked Sendable`: `UnsafeMutableRawPointer` is not Sendable, but the
/// handle's identity is read-only and the cactus runtime is thread-safe for
/// concurrent reads of an already-loaded model. The pointer's *lifetime* is
/// owned by `CactusRuntime` (refcount); ownership crossings only flow
/// through actor-isolated paths.
public struct WhisperHandle: @unchecked Sendable, Equatable {
    public let opaque: UnsafeMutableRawPointer
    public let path: URL
}

/// LLM (Gemma-3) model handle. See `WhisperHandle` for the Sendable rationale.
public struct LLMHandle: @unchecked Sendable, Equatable {
    public let opaque: UnsafeMutableRawPointer
    public let path: URL
}

/// VAD (Silero) model handle. See `WhisperHandle` for the Sendable rationale.
public struct VADHandle: @unchecked Sendable, Equatable {
    public let opaque: UnsafeMutableRawPointer
    public let path: URL
}

/// Type-erased handle for the `release` entry point.
public enum AnyHandle: Sendable, Equatable {
    case whisper(WhisperHandle)
    case llm(LLMHandle)
    case vad(VADHandle)
}

// MARK: - FFI seam

/// Injectable FFI seam for the runtime. Distinct from `ModelLoading`
/// (Story 2.5) because the runtime's residency dict stores
/// `UnsafeMutableRawPointer` non-optionally and the error surface is
/// `AppError` directly. See story-3.1.md for the deviation rationale.
public protocol RuntimeFFI: Sendable {
    /// Load a model file. Returns the raw cactus handle on success;
    /// throws `AppError.modelLoadFailed(path:reason:)` on any failure.
    func load(path: String, kind: ModelKind) throws -> UnsafeMutableRawPointer

    /// Free a previously-loaded handle. Errors here are best-effort
    /// (logged by the implementation) — there's nothing the runtime can
    /// do about a free that fails.
    func free(_ ptr: UnsafeMutableRawPointer)
}

/// Production `RuntimeFFI`: wraps `FFIShim.loadModel` / `FFIShim.freeModel`
/// and maps raw `cactus_status_t` → `AppError.modelLoadFailed`.
public struct FFIShimRuntimeFFI: RuntimeFFI {
    private static let log = Logger(subsystem: "com.cactusvoice", category: "runtime-ffi")

    public init() {}

    public func load(path: String, kind: ModelKind) throws -> UnsafeMutableRawPointer {
        let ffiType: FFIShim.ModelType
        switch kind {
        case .whisper: ffiType = .whisper
        case .llm:     ffiType = .llm
        case .vad:     ffiType = .onnx  // Silero VAD is ONNX (architecture §C accuracy revision)
        }
        let (status, opaque) = FFIShim.loadModel(path: path, type: ffiType)
        guard status.isOK, let opaque else {
            let reason: String
            switch status.raw {
            case 4: reason = "unsupported format"
            case 2: reason = "io error"
            case 3: reason = "unimplemented"
            default: reason = "load failed (status=\(status.raw))"
            }
            Self.log.error("load failed: kind=\(String(describing: kind), privacy: .public) status=\(status.raw, privacy: .public) reason=\(reason, privacy: .public)")
            throw AppError.modelLoadFailed(path: path, reason: reason)
        }
        return UnsafeMutableRawPointer(opaque)
    }

    public func free(_ ptr: UnsafeMutableRawPointer) {
        let status = FFIShim.freeModel(OpaquePointer(ptr))
        if !status.isOK {
            Self.log.error("free returned non-zero status=\(status.raw, privacy: .public)")
        }
    }
}

// MARK: - CactusRuntime actor

public actor CactusRuntime {

    private struct SlotEntry {
        let opaque: UnsafeMutableRawPointer
        var refcount: Int
    }

    /// Tracks an in-flight load so concurrent acquires collapse to one
    /// underlying `RuntimeFFI.load` call. Keyed by `(kind, path)`.
    private struct PendingKey: Hashable {
        let kind: ModelKind
        let path: URL
    }

    /// `@unchecked Sendable` wrapper so a `Task<_, Error>` can carry a raw
    /// pointer across the suspension boundary. The pointer is loaded inside
    /// the task and re-published to the actor on resume; no cross-isolation
    /// mutation occurs.
    private struct OpaqueBox: @unchecked Sendable {
        let ptr: UnsafeMutableRawPointer
    }

    private let log = Logger(subsystem: "com.cactusvoice", category: "runtime")
    private let ffi: RuntimeFFI

    /// Current memory-governance mode. Settable via `setMode`.
    private(set) public var mode: RuntimeMode

    // One slot per kind: at most one resident URL per slot at a time.
    private var whisperSlot: (url: URL, entry: SlotEntry)?
    private var llmSlot:     (url: URL, entry: SlotEntry)?
    private var vadSlot:     (url: URL, entry: SlotEntry)?

    // In-flight loads (concurrent-acquire collapse). Carries OpaqueBox
    // (Sendable wrapper) so the Task can cross the suspension boundary.
    private var pendingLoads: [PendingKey: Task<OpaqueBox, Error>] = [:]

    public init(mode: RuntimeMode = .full, ffi: RuntimeFFI = FFIShimRuntimeFFI()) {
        self.mode = mode
        self.ffi = ffi
    }

    // MARK: Mode

    public func setMode(_ newMode: RuntimeMode) {
        self.mode = newMode
    }

    // MARK: Public acquire/release surface

    public func acquireWhisper(path: URL) async throws -> WhisperHandle {
        let opaque = try await acquireSlot(kind: .whisper, path: path)
        return WhisperHandle(opaque: opaque, path: path)
    }

    public func acquireLLM(path: URL) async throws -> LLMHandle {
        if mode == .minimal {
            log.error("acquireLLM rejected: minimal mode")
            throw AppError.modelLoadFailed(path: path.path, reason: "llm disabled in minimal mode")
        }
        let opaque = try await acquireSlot(kind: .llm, path: path)
        return LLMHandle(opaque: opaque, path: path)
    }

    /// Mode-bypassing LLM acquire for the user-invoked Rewrite call site.
    /// Used by the Rewrite path (later story); succeeds in either mode.
    public func acquireLLMForUserAction(path: URL) async throws -> LLMHandle {
        let opaque = try await acquireSlot(kind: .llm, path: path)
        return LLMHandle(opaque: opaque, path: path)
    }

    public func acquireVAD(path: URL) async throws -> VADHandle {
        let opaque = try await acquireSlot(kind: .vad, path: path)
        return VADHandle(opaque: opaque, path: path)
    }

    public func release(_ handle: AnyHandle) async {
        switch handle {
        case .whisper(let h): releaseSlot(kind: .whisper, path: h.path)
        case .llm(let h):     releaseSlot(kind: .llm,     path: h.path)
        case .vad(let h):     releaseSlot(kind: .vad,     path: h.path)
        }
    }

    public func unloadAll() async {
        if let slot = whisperSlot { ffi.free(slot.entry.opaque); whisperSlot = nil }
        if let slot = llmSlot     { ffi.free(slot.entry.opaque); llmSlot = nil }
        if let slot = vadSlot     { ffi.free(slot.entry.opaque); vadSlot = nil }
    }

    public func currentResidency() async -> ResidencyReport {
        ResidencyReport(
            whisper: whisperSlot?.url,
            llm: llmSlot?.url,
            vad: vadSlot?.url,
            mode: mode
        )
    }

    // MARK: Internal slot mechanics

    private func acquireSlot(kind: ModelKind, path: URL) async throws -> UnsafeMutableRawPointer {
        // Same path → refcount++ and return existing handle.
        if let existing = readSlot(kind), existing.url == path {
            mutateSlot(kind) { entry in entry.refcount += 1 }
            return existing.entry.opaque
        }

        // Different path → only reusable if refcount == 0.
        if let existing = readSlot(kind), existing.url != path {
            if existing.entry.refcount > 0 {
                log.error("slot in use: kind=\(String(describing: kind), privacy: .public) loaded=\(existing.url.path, privacy: .private(mask: .hash)) requested=\(path.path, privacy: .private(mask: .hash)) refcount=\(existing.entry.refcount, privacy: .public)")
                throw AppError.modelLoadFailed(path: path.path, reason: "slot in use")
            }
            // Old refcount == 0: free before loading new.
            ffi.free(existing.entry.opaque)
            clearSlot(kind)
        }

        // Concurrent-acquire collapse: reuse any in-flight load for the same
        // (kind, path) instead of starting a second one.
        let key = PendingKey(kind: kind, path: path)
        if let pending = pendingLoads[key] {
            let box = try await pending.value
            // The first awaiter materialized the slot; ours just refcount++.
            mutateSlot(kind) { entry in entry.refcount += 1 }
            return box.ptr
        }

        let ffi = self.ffi
        let pathStr = path.path
        let task = Task<OpaqueBox, Error> {
            let ptr = try ffi.load(path: pathStr, kind: kind)
            return OpaqueBox(ptr: ptr)
        }
        pendingLoads[key] = task

        let opaque: UnsafeMutableRawPointer
        do {
            opaque = try await task.value.ptr
        } catch {
            pendingLoads.removeValue(forKey: key)
            throw error
        }
        pendingLoads.removeValue(forKey: key)

        // Materialize the slot with refcount=1 IF nobody else already did
        // (the collapse path increments refcount on the existing entry).
        if let existing = readSlot(kind), existing.url == path {
            mutateSlot(kind) { entry in entry.refcount += 1 }
        } else {
            writeSlot(kind, url: path, entry: SlotEntry(opaque: opaque, refcount: 1))
        }
        return opaque
    }

    private func releaseSlot(kind: ModelKind, path: URL) {
        guard let existing = readSlot(kind), existing.url == path else {
            log.error("release for non-resident path: kind=\(String(describing: kind), privacy: .public) path=\(path.path, privacy: .private(mask: .hash))")
            return
        }
        mutateSlot(kind) { entry in
            if entry.refcount > 0 { entry.refcount -= 1 }
        }
    }

    // MARK: Slot accessors (kind-keyed wrappers around the three stored tuples)

    private func readSlot(_ kind: ModelKind) -> (url: URL, entry: SlotEntry)? {
        switch kind {
        case .whisper: return whisperSlot
        case .llm:     return llmSlot
        case .vad:     return vadSlot
        }
    }

    private func writeSlot(_ kind: ModelKind, url: URL, entry: SlotEntry) {
        switch kind {
        case .whisper: whisperSlot = (url, entry)
        case .llm:     llmSlot     = (url, entry)
        case .vad:     vadSlot     = (url, entry)
        }
    }

    private func clearSlot(_ kind: ModelKind) {
        switch kind {
        case .whisper: whisperSlot = nil
        case .llm:     llmSlot     = nil
        case .vad:     vadSlot     = nil
        }
    }

    private func mutateSlot(_ kind: ModelKind, _ body: (inout SlotEntry) -> Void) {
        switch kind {
        case .whisper:
            guard var slot = whisperSlot else { return }
            body(&slot.entry); whisperSlot = slot
        case .llm:
            guard var slot = llmSlot else { return }
            body(&slot.entry); llmSlot = slot
        case .vad:
            guard var slot = vadSlot else { return }
            body(&slot.entry); vadSlot = slot
        }
    }
}
