# Story 2.1: BoundedSPSCBuffer<Float>

**Epic:** 2 — Headless Core
**Status:** done
**Owner:** story-executor-2.1

## User Story

As the **audio capture actor (later)**,
I want **a bounded single-producer/single-consumer ring buffer with explicit drop-oldest overflow semantics**,
So that **mic samples never silently grow memory and overflow events are observable**.

## Acceptance Criteria

1. `apps/CactusVoice/CactusVoice/Audio/BoundedSPSCBuffer.swift` declares `final class BoundedSPSCBuffer<T>` (NOT an actor — capture/consume paths must not hop executors per audio thread).
2. Capacity is fixed at init (production usage: 30 s × 16 kHz Float32 = 480 000).
3. Single-producer single-consumer; concurrent writers or readers are undefined behavior (documented in file header).
4. Writes that would overflow drop *oldest* samples, increment `overrunCount`, never block, never reallocate.
5. Reads return `ArraySlice<T>` of available samples and advance the read cursor.
6. `removeAll()` zero-retains storage (state reset, no allocation).
7. Overrun events surfaced via `var overrunStream: AsyncStream<Int>` for `AudioCapture` to log later.
8. Tests cover write-then-read round-trip, partial reads, overrun increments + drops-oldest correctness, concurrent producer/consumer fuzz (10 000 ops), zero retain after `removeAll`, overrun AsyncStream delivers values.

## Tasks

- [x] T1 — Acceptance tests (red): static greps on `BoundedSPSCBuffer.swift` shape (final class, generic, capacity-in-init, write/read/removeAll/overrunCount/overrunStream).
- [x] T2 — Implement `Audio/BoundedSPSCBuffer.swift` (≤ 200 LOC).
- [x] T3 — Implement `CactusVoiceTests/Audio/BoundedSPSCBufferTests.swift` (XCTest, including concurrency stress).
- [x] T4 — `swiftc -typecheck BoundedSPSCBuffer.swift` (Foundation-only) passes.
- [x] T5 — Regenerate `.xcodeproj` via `xcodegen generate`.

## Deviation: `OSAllocatedUnfairLock` instead of lock-free atomics

The architecture and the AC say "no locks; use `Atomic` head/tail indices". The story brief explicitly authorizes a pragmatic deviation here:

- **No SPM dep for `swift-atomics`.** Adding `apple/swift-atomics` would change `project.yml`, force an extra package resolution on every CI/dev pass, and is not justified at this stage.
- **`Synchronization.UnsafeAtomic<Int>` is Swift 6 stdlib only.** Project Swift version is 5.10 (`SWIFT_VERSION: "5.10"` in `project.yml`), so the stdlib `Synchronization` module is not available.
- **`OSAllocatedUnfairLock` (Foundation, macOS 13+) is available** with the current deployment target (macOS 14+). The lock is held for O(1) integer operations (head/tail/overrun bumps); contention between exactly one producer and one consumer is negligible.
- **KISS.** Shipping a correct, simple lock-guarded ring buffer beats shipping a hand-rolled atomics-based one that we cannot empirically validate under contention on this CLT-only host.

Documented at the top of `BoundedSPSCBuffer.swift`. Swappable for `Atomic` head/tail in a follow-up story when (a) we have swift-atomics on SPM or (b) we move to Swift 6 stdlib `Synchronization`. The public API stays unchanged.

## Dev Notes

- Architecture refs: §A line 177 (drop-oldest bounded ring buffer, overruns to inline error surface).
- The buffer stores `[T]` (capacity-sized) with `head` (write index) and `tail` (read index); both monotonically increasing; modulo `capacity` to get slot indices. `count = head - tail`.
- Overrun semantics: if `incoming > available`, advance `tail` to drop oldest, bump `overrunCount` by the dropped amount, emit the new total via `overrunStream`'s continuation.
- `read()` returns `ArraySlice<T>` — for the contiguous case we return `storage[start..<end]`; if the read window wraps, we return a flat materialized `[T]` slice (still `ArraySlice<T>`). This is documented; the audio pipeline normally reads small windows that don't wrap, so the cost is negligible in practice.
- `removeAll()` resets head=tail=0 and overrunCount=0 without touching storage capacity (zero retain meaning: no live samples remain; we do not free the backing buffer — the contract is "no live data retained", which is what consumers care about).
- Tests run under XCTest. On this CLT-only host the test target won't build (no XCTest module), same constraint as 1.1–1.5. Greps in `Story2_1Tests.swift` enforce the on-disk contract statically; the concurrency stress test runs on any machine with Xcode.

## Validation

| AC | Covered by |
|----|------------|
| 1 (final class, generic)         | `Story2_1Tests.testFinalClassGeneric` |
| 2 (capacity-at-init)             | `Story2_1Tests.testCapacityInInit` |
| 3 (SPSC documented)              | `Story2_1Tests.testSPSCDocumented` |
| 4 (overrun + drop-oldest)        | runtime `BoundedSPSCBufferTests.testOverrunDropsOldestAndCounts` |
| 5 (read returns ArraySlice)      | `Story2_1Tests.testReadReturnsArraySlice` + runtime round-trip |
| 6 (removeAll zero retain)        | runtime `BoundedSPSCBufferTests.testRemoveAllZeroRetain` |
| 7 (overrunStream AsyncStream)    | `Story2_1Tests.testOverrunStreamShape` + runtime delivery test |
| 8 (test suite present)           | `Story2_1Tests.testBufferTestsExist` |

## Change Log

- 2026-05-18 — Initial story file authored by story-executor-2.1.
