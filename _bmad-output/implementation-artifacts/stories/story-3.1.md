# Story 3.1: CactusRuntime actor (lazy load, residency, three model slots)

**Epic:** 3 — Audio Capture & Whisper Streaming
**Status:** in_progress
**Owner:** story-executor-3.1

## User Story

As the **inference sessions**,
I want **a single actor that owns FFI model handles with lazy load, residency tracking, and three slots (Whisper / LLM / VAD)**,
So that **no other component talks to `FFIShim` directly and memory governance lives in one place**.

## Acceptance Criteria

1. `apps/CactusVoice/CactusVoice/Inference/CactusRuntime.swift` declares `actor CactusRuntime`.
2. Three model slots — Whisper, LLM, VAD — each tracked as `URL -> (handle, refcount)` in a dict on the actor.
3. Async surface:
   - `func acquireWhisper(path: URL) async throws -> WhisperHandle`
   - `func acquireLLM(path: URL) async throws -> LLMHandle`
   - `func acquireVAD(path: URL) async throws -> VADHandle`
   - `func release(_ handle: AnyHandle) async`
   - `func unloadAll() async`
   - `func currentResidency() async -> ResidencyReport`
4. Lazy load: the model is loaded **only on the first** `acquire` for a given path. Subsequent
   `acquire` for the same path returns the existing handle with refcount++. Concurrent acquires
   of the same path must collapse to **one** underlying `load` call.
5. Path change: `acquire<Kind>(path: newPath)` when the slot already holds a different path:
   - If the old path's refcount is 0 → free the old handle before loading the new one (slot reused).
   - If the old path is still in use (refcount > 0) → throws `AppError.modelLoadFailed(path: newPath, reason: "slot in use")`.
   This is the KISS rule (see Deviation below).
6. `mode: RuntimeMode { case minimal, full }` switch:
   - In `.minimal`: `acquireLLM(path:)` throws `AppError.modelLoadFailed(path:, reason: "llm disabled in minimal mode")`.
   - `func acquireLLMForUserAction(path: URL) async throws -> LLMHandle` succeeds regardless of mode
     (placeholder for the user-invoked Rewrite call site that lands in a later story; for now
     it is just a separate entry point with no mode gating).
   - Whisper + VAD acquisition is always allowed in both modes.
7. Handle types (top-level in this file):
   - `struct WhisperHandle: Sendable { let opaque: UnsafeMutableRawPointer; let path: URL }`
   - `struct LLMHandle: Sendable     { let opaque: UnsafeMutableRawPointer; let path: URL }`
   - `struct VADHandle: Sendable     { let opaque: UnsafeMutableRawPointer; let path: URL }`
   - `enum AnyHandle: Sendable { case whisper(WhisperHandle); case llm(LLMHandle); case vad(VADHandle) }`
8. `ResidencyReport: Sendable` carries the currently-loaded path per slot plus the mode:
   `struct ResidencyReport: Sendable, Equatable { let whisper: URL?; let llm: URL?; let vad: URL?; let mode: RuntimeMode }`.
9. FFI seam is a `RuntimeFFI` protocol declared in this file (see Deviation), with a
   default `FFIShimRuntimeFFI` adapter wrapping `FFIShim.loadModel` / `FFIShim.freeModel`.
10. Failure surfaces as `AppError.modelLoadFailed(path: url.path, reason: …)` exactly — never
    raw `cactus_status_t` integers and never `FFIError`.
11. Tests:
    - `apps/CactusVoice/CactusVoiceTests/Inference/CactusRuntimeTests.swift` covers: ok path,
      refcount semantics (load once across N acquires same path), refcount frees only on last
      release, slot-reuse on path change when refcount==0, slot-in-use error when refcount>0,
      load failure surfaces `AppError.modelLoadFailed`, `unloadAll()` zeroes all slots,
      `currentResidency()` reflects state, minimal mode rejects `acquireLLM` but accepts
      `acquireLLMForUserAction`, concurrent-acquires-same-path collapse to one load, leak balance
      via stub counter.
    - `apps/CactusVoice/CactusVoiceTests/StoryAcceptance/Story3_1Tests.swift` covers static
      greps: actor declaration, six async methods, three handle structs, `AnyHandle` enum,
      `RuntimeMode` + `.minimal` + `.full`, `ResidencyReport` struct + four fields, protocol
      seam, `AppError.modelLoadFailed` usage.

## Deviation: Separate `RuntimeFFI` protocol (instead of reusing `ModelLoading`)

`ModelLoading` (Story 2.5) is shaped for the validate-once-and-free probe: it returns
`Result<ModelHandle, FFIError>` where `ModelHandle` is a reference type carrying both an
`OpaquePointer?` and a test token, designed for a leak-balance test in the catalog's
StubLoader. That shape is correct for the probe but slightly off for the runtime, which needs:

- `UnsafeMutableRawPointer` (not `OpaquePointer?`) because the slot's residency dict stores
  the raw pointer alongside an `Int` refcount, and we want it non-optional in the loaded
  state.
- Distinct error reason strings (`"slot in use"`, `"llm disabled in minimal mode"`) that
  don't fit `FFIError`'s `.unsupportedFormat | .loadFailed` two-case shape — the runtime
  wants to throw a real `AppError.modelLoadFailed(path:reason:)` directly from inside the
  actor.

So this file declares a small `protocol RuntimeFFI` with `load(path: String, kind: ModelKind)
throws(AppError) -> UnsafeMutableRawPointer` and `free(_ ptr: UnsafeMutableRawPointer)`.
The default `FFIShimRuntimeFFI` wraps `FFIShim.loadModel`/`FFIShim.freeModel` and maps the
raw cactus status to `AppError.modelLoadFailed` directly. Tests inject a stub that counts
load/free calls.

`ModelKind` is reused from `ModelCatalog.swift` as-is — same three cases, same semantics.

## Deviation: Path change while refcount > 0 throws (KISS) — does not queue or wait

The acceptance criteria allow either "throw immediately" or "wait until refcount drops".
We pick **throw**, returning `AppError.modelLoadFailed(path: newPath, reason: "slot in use")`.
Reasons:

- No async load queue needed — no priority inversion, no fairness rules, no cancellation
  story.
- The only realistic caller sequence is "stop one session before starting another"; if a
  caller forgets to `release`, throwing is the right signal (vs. deadlocking on a wait).
- The architecture's "memory governance lives in one place" goal is served by an explicit
  rejection rather than implicit serialization.

## Deviation: No memory-pressure eviction in v1

The architecture §B sketches a residency policy that could evict on memory pressure. This
story implements **only** the explicit lifetime (acquire/release/unloadAll); pressure-based
eviction is deferred to a later story when there is a real pressure signal to react to. The
`mode: .minimal | .full` switch is the v1 memory governance lever.

## Tasks

- [x] T1 — Author this story file.
- [ ] T2 — Acceptance tests (red): `CactusVoiceTests/StoryAcceptance/Story3_1Tests.swift`.
- [ ] T3 — Implement `Inference/CactusRuntime.swift` (~250-320 LOC) and
       `CactusVoiceTests/Inference/CactusRuntimeTests.swift` (~200-260 LOC).
- [ ] T4 — `swiftc -typecheck CactusRuntime.swift`: pass (exit 0).
- [ ] T5 — Regenerate `.xcodeproj` via `xcodegen generate`.
- [ ] T6 — KISS pass.

## Dev Notes

- `actor` isolation is the only concurrency primitive — no locks, no DispatchQueue, no
  `os_unfair_lock`. Refcount is a plain `Int` in an actor-private dict.
- Concurrent-acquire-collapse is achieved by suspending all in-flight callers on a single
  pending `Task<UnsafeMutableRawPointer, Error>` stored per slot; the second caller awaits
  the same task rather than initiating a second `load`.
- Logging via `Logger(subsystem: "com.cactusvoice", category: "runtime")` per Story 1.4
  conventions. Log once at the creation site of each `AppError` (not on rethrow).
- The runtime is the only component allowed to import `CactusCore` outside of `FFIShim`
  itself — but it does so transitively through `FFIShimRuntimeFFI`, not directly.
