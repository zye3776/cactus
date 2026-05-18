//
//  CactusRuntimeTests.swift
//  CactusVoiceTests
//
//  Story 3.1 — runtime tests against a deterministic `RuntimeFFI` stub that
//  counts load/free calls and surfaces deterministic identity per (path, kind).
//
import XCTest
@testable import CactusVoice

/// Sendable stub `RuntimeFFI`. Uses an actor-isolated state container so
/// concurrent acquires can race against it without data-race warnings.
final class StubRuntimeFFI: @unchecked Sendable, RuntimeFFI {

    /// Slow knobs and shared state. Wrapped in an `os_unfair_lock` because
    /// the protocol method is non-async — this is the test-side seam, not
    /// production code.
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var loadCount = 0
        var freeCount = 0
        var failNext: AppError?
        var loadDelay: TimeInterval = 0
        var allocations: [UnsafeMutableRawPointer: (path: String, kind: ModelKind)] = [:]
        var perPathHandle: [String: UnsafeMutableRawPointer] = [:]
        var nextToken: UInt = 1
    }

    private let state = State()

    var loadCount: Int { state.lock.lock(); defer { state.lock.unlock() }; return state.loadCount }
    var freeCount: Int { state.lock.lock(); defer { state.lock.unlock() }; return state.freeCount }
    var liveAllocations: Int {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.allocations.count
    }

    func setFailNext(_ err: AppError) {
        state.lock.lock(); defer { state.lock.unlock() }
        state.failNext = err
    }

    func setLoadDelay(_ secs: TimeInterval) {
        state.lock.lock(); defer { state.lock.unlock() }
        state.loadDelay = secs
    }

    func load(path: String, kind: ModelKind) throws -> UnsafeMutableRawPointer {
        let delay: TimeInterval = {
            state.lock.lock(); defer { state.lock.unlock() }
            return state.loadDelay
        }()
        if delay > 0 {
            Thread.sleep(forTimeInterval: delay)
        }
        state.lock.lock()
        if let err = state.failNext {
            state.failNext = nil
            state.lock.unlock()
            throw err
        }
        state.loadCount += 1
        // Stable per-(path) pointer identity so equality on the handle's
        // opaque pointer makes sense across re-loads.
        if let existing = state.perPathHandle[path] {
            state.allocations[existing] = (path, kind)
            state.lock.unlock()
            return existing
        }
        let token = state.nextToken
        state.nextToken += 1
        let ptr = UnsafeMutableRawPointer(bitPattern: Int(token) * 0x1000)!
        state.perPathHandle[path] = ptr
        state.allocations[ptr] = (path, kind)
        state.lock.unlock()
        return ptr
    }

    func free(_ ptr: UnsafeMutableRawPointer) {
        state.lock.lock(); defer { state.lock.unlock() }
        state.freeCount += 1
        state.allocations.removeValue(forKey: ptr)
    }
}

final class CactusRuntimeTests: XCTestCase {

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/cactusvoice-tests/\(name).bin")
    }

    // MARK: AC4 — lazy load + refcount semantics on the same path

    func testFirstAcquireLoadsOnceAndReleaseDoesNotFree() async throws {
        let ffi = StubRuntimeFFI()
        let rt = CactusRuntime(mode: .full, ffi: ffi)
        let path = url("whisper")

        let h1 = try await rt.acquireWhisper(path: path)
        XCTAssertEqual(ffi.loadCount, 1)
        XCTAssertEqual(ffi.freeCount, 0)
        XCTAssertEqual(h1.path, path)

        let h2 = try await rt.acquireWhisper(path: path)
        XCTAssertEqual(ffi.loadCount, 1, "same path must not reload")
        XCTAssertEqual(h2.opaque, h1.opaque, "same path must return same opaque")

        // Release one — refcount 2 → 1; nothing frees.
        await rt.release(.whisper(h1))
        XCTAssertEqual(ffi.freeCount, 0)
        // Release the second — refcount 1 → 0; STILL nothing frees (eager
        // free deferred to next path change / unloadAll, per KISS rule).
        await rt.release(.whisper(h2))
        XCTAssertEqual(ffi.freeCount, 0)

        let report = await rt.currentResidency()
        XCTAssertEqual(report.whisper, path)
    }

    // MARK: AC5 — slot reuse when refcount == 0; "slot in use" when > 0

    func testPathChangeFreesOldWhenRefcountZero() async throws {
        let ffi = StubRuntimeFFI()
        let rt = CactusRuntime(mode: .full, ffi: ffi)

        let p1 = url("whisper-tiny")
        let p2 = url("whisper-large")

        let h1 = try await rt.acquireWhisper(path: p1)
        await rt.release(.whisper(h1))  // refcount: 1 → 0

        XCTAssertEqual(ffi.freeCount, 0, "release alone must not free")

        let h2 = try await rt.acquireWhisper(path: p2)
        XCTAssertEqual(ffi.freeCount, 1, "path change must free the old slot first")
        XCTAssertEqual(ffi.loadCount, 2)
        XCTAssertEqual(h2.path, p2)

        let report = await rt.currentResidency()
        XCTAssertEqual(report.whisper, p2)
    }

    func testPathChangeThrowsWhenSlotInUse() async throws {
        let ffi = StubRuntimeFFI()
        let rt = CactusRuntime(mode: .full, ffi: ffi)

        let p1 = url("whisper-tiny")
        let p2 = url("whisper-large")

        let h1 = try await rt.acquireWhisper(path: p1)
        defer { Task { await rt.release(.whisper(h1)) } }

        do {
            _ = try await rt.acquireWhisper(path: p2)
            XCTFail("Expected slot-in-use throw")
        } catch let err as AppError {
            guard case .modelLoadFailed(_, let reason) = err else {
                XCTFail("Expected .modelLoadFailed, got \(err)"); return
            }
            XCTAssertEqual(reason, "slot in use")
        }
        XCTAssertEqual(ffi.loadCount, 1, "second load must not have happened")
    }

    // MARK: AC10 — load failure surfaces AppError.modelLoadFailed

    func testLoadFailurePropagatesAppError() async throws {
        let ffi = StubRuntimeFFI()
        let rt = CactusRuntime(mode: .full, ffi: ffi)

        ffi.setFailNext(.modelLoadFailed(path: "/x", reason: "bad bytes"))
        do {
            _ = try await rt.acquireWhisper(path: url("bad"))
            XCTFail("Expected throw")
        } catch let err as AppError {
            guard case .modelLoadFailed(_, let reason) = err else {
                XCTFail("Expected .modelLoadFailed, got \(err)"); return
            }
            XCTAssertEqual(reason, "bad bytes")
        }
        XCTAssertEqual(ffi.loadCount, 0, "stub failed before recording load")
        let report = await rt.currentResidency()
        XCTAssertNil(report.whisper, "failed load must not leave a slot resident")
    }

    // MARK: AC4 — concurrent acquires of the same path collapse to one load

    func testConcurrentAcquiresSamePathCollapseToOneLoad() async throws {
        let ffi = StubRuntimeFFI()
        ffi.setLoadDelay(0.02)  // make the race observable
        let rt = CactusRuntime(mode: .full, ffi: ffi)
        let path = url("whisper")

        let handles: [WhisperHandle] = await withThrowingTaskGroup(of: WhisperHandle.self) { group in
            for _ in 0..<8 {
                group.addTask { try await rt.acquireWhisper(path: path) }
            }
            var collected: [WhisperHandle] = []
            while let h = try? await group.next() { collected.append(h) }
            return collected
        }

        XCTAssertEqual(handles.count, 8)
        XCTAssertEqual(ffi.loadCount, 1, "concurrent acquires must collapse to one load")
        // All handles must point to the same opaque.
        let firstOpaque = handles[0].opaque
        for h in handles { XCTAssertEqual(h.opaque, firstOpaque) }

        // Release all 8 — refcount goes to 0; no frees (KISS rule).
        for h in handles { await rt.release(.whisper(h)) }
        XCTAssertEqual(ffi.freeCount, 0)
    }

    // MARK: unloadAll

    func testUnloadAllFreesEverySlot() async throws {
        let ffi = StubRuntimeFFI()
        let rt = CactusRuntime(mode: .full, ffi: ffi)

        let w = try await rt.acquireWhisper(path: url("whisper"))
        let l = try await rt.acquireLLM(path: url("llm"))
        let v = try await rt.acquireVAD(path: url("vad"))
        XCTAssertEqual(ffi.loadCount, 3)

        await rt.unloadAll()
        XCTAssertEqual(ffi.freeCount, 3)
        XCTAssertEqual(ffi.liveAllocations, 0)

        let report = await rt.currentResidency()
        XCTAssertNil(report.whisper)
        XCTAssertNil(report.llm)
        XCTAssertNil(report.vad)
        _ = (w, l, v)
    }

    // MARK: currentResidency reflects state

    func testCurrentResidencyReflectsLoadsAndUnloads() async throws {
        let ffi = StubRuntimeFFI()
        let rt = CactusRuntime(mode: .full, ffi: ffi)

        let initial = await rt.currentResidency()
        XCTAssertEqual(initial, ResidencyReport(whisper: nil, llm: nil, vad: nil, mode: .full))

        _ = try await rt.acquireWhisper(path: url("w1"))
        _ = try await rt.acquireVAD(path: url("v1"))
        let mid = await rt.currentResidency()
        XCTAssertEqual(mid.whisper, url("w1"))
        XCTAssertEqual(mid.vad, url("v1"))
        XCTAssertNil(mid.llm)

        await rt.unloadAll()
        let after = await rt.currentResidency()
        XCTAssertEqual(after, ResidencyReport(whisper: nil, llm: nil, vad: nil, mode: .full))
    }

    // MARK: AC6 — minimal mode gates acquireLLM but not acquireLLMForUserAction

    func testMinimalModeRejectsAcquireLLM() async throws {
        let ffi = StubRuntimeFFI()
        let rt = CactusRuntime(mode: .minimal, ffi: ffi)

        do {
            _ = try await rt.acquireLLM(path: url("gemma"))
            XCTFail("Expected throw in minimal mode")
        } catch let err as AppError {
            guard case .modelLoadFailed(_, let reason) = err else {
                XCTFail("Expected .modelLoadFailed, got \(err)"); return
            }
            XCTAssertEqual(reason, "llm disabled in minimal mode")
        }
        XCTAssertEqual(ffi.loadCount, 0)
    }

    func testMinimalModeAllowsAcquireLLMForUserAction() async throws {
        let ffi = StubRuntimeFFI()
        let rt = CactusRuntime(mode: .minimal, ffi: ffi)

        let h = try await rt.acquireLLMForUserAction(path: url("gemma"))
        XCTAssertEqual(h.path, url("gemma"))
        XCTAssertEqual(ffi.loadCount, 1)
        await rt.release(.llm(h))
    }

    func testSetModeSwitchesGating() async throws {
        let ffi = StubRuntimeFFI()
        let rt = CactusRuntime(mode: .minimal, ffi: ffi)

        do {
            _ = try await rt.acquireLLM(path: url("gemma"))
            XCTFail("expected minimal-mode throw")
        } catch is AppError {}

        await rt.setMode(.full)
        let h = try await rt.acquireLLM(path: url("gemma"))
        XCTAssertEqual(h.path, url("gemma"))
        await rt.release(.llm(h))
    }

    // MARK: Leak balance — acquire + release pairs balance to refcount 0

    func testLeakBalanceAcquireReleasePairs() async throws {
        let ffi = StubRuntimeFFI()
        let rt = CactusRuntime(mode: .full, ffi: ffi)
        let path = url("whisper")

        for _ in 0..<10 {
            let h = try await rt.acquireWhisper(path: path)
            await rt.release(.whisper(h))
        }
        // First acquire loaded; subsequent 9 reused. No frees yet.
        XCTAssertEqual(ffi.loadCount, 1)
        XCTAssertEqual(ffi.freeCount, 0)
        XCTAssertEqual(ffi.liveAllocations, 1)

        await rt.unloadAll()
        XCTAssertEqual(ffi.freeCount, 1)
        XCTAssertEqual(ffi.liveAllocations, 0)
    }
}
