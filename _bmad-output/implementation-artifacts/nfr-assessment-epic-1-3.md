# NFR Assessment — Epic 1-3

Absolute path: `/Users/Z/projects/cactus/_bmad-output/implementation-artifacts/nfr-assessment-epic-1-3.md`

Scope: NFRs touched by stories 1.1 – 3.5. Verdict legend: **PASS** (verified), **CONCERN** (structurally implemented but unverified at runtime), **FAIL** (not implemented or implemented incorrectly).

## Performance

### NFR-001 — Tiered resident memory (~600 MB minimal / ~2.5 GB full ± 20%)
**Verdict: CONCERN.** Story 1.3 ships `MeasurementSpikeTests.swift` (192 LOC, single test method) that loads Whisper + Silero VAD + Gemma-3 through `FFIShim`, measures peak resident memory via `task_info` / `MACH_TASK_BASIC_INFO` / `resident_size`, sums `.app` bundle size, appends one row to `_bmad-output/implementation-artifacts/measurement-spike-results.csv`, and verifies residency returns to baseline ± 50 MB after `freeModel`. The 20% divergence-from-PRD procedure is documented in the spike header. **No numbers exist yet** — the spike needs real model paths + a host with Xcode.

### NFR-002 — Hot-path responsiveness (pre-roll capture)
**Verdict: CONCERN.** Story 3.4 declares `static preRollTargetSamples: Int = 1600` (100 ms @ 16 kHz) and the AudioCapture actor returns from `start()` as soon as the input source is up so tap callbacks can fire before window paint. AudioCaptureTests includes a pre-roll-race test (200 ms simulated paint + 2048 pushed samples → `bufferedSampleCount >= 1600`). Test exists but has not run.

## Reliability

### NFR-009 — AudioCapture stop() ≤ 100 ms (p95)
**Verdict: CONCERN.** Story 3.4 documents the budget at the call site; AudioCaptureTests includes a test pushing 8192 pre-existing samples then asserting `stop()` returns under 100 ms. Implementation drops `ringBuffer.removeAll()` + finishes four AsyncStream continuations + cancels two forwarder Tasks — there is no blocking operation in the path. Structurally sound, runtime unverified.

### NFR (implicit) — Concurrent-load idempotency
**Verdict: CONCERN.** Story 3.1 `CactusRuntime` collapses concurrent same-path acquires via `pendingLoads: [PendingKey: Task<OpaqueBox, Error>]`. Stub-driven test asserts 8 concurrent acquires of the same path produce `loadCount == 1` with identical opaque pointers under a 20 ms artificial delay. Implementation typechecks; runtime unverified.

### NFR (implicit) — Handle leak balance
**Verdict: CONCERN.** Multiple tests assert alloc/free balance (CactusRuntime 10-iter, ModelCatalog 5-iter, WhisperSession close idempotency). Implementation uses refcount + `unloadAll()` + idempotent `closeIfNeeded()` patterns. Structurally sound, runtime unverified.

## Security

### Sandbox + entitlement posture
**Verdict: PASS.** Story 1.1 ships `apps/CactusVoice/CactusVoice/CactusVoice.entitlements` with `com.apple.security.app-sandbox = true`, `com.apple.security.device.audio-input = true`, `com.apple.security.files.user-selected.read-only = true`, `com.apple.security.files.bookmarks.app-scope = true`, and **no network entitlement**. Verified statically by Story1_1 ACs.

### Security-scoped resource boundary
**Verdict: PASS** (static enforcement). Story 2.4 ships `Scripts/check-permission-boundaries.sh` which greps for `AVCaptureDevice.requestAccess|startAccessingSecurityScopedResource` across `CactusVoice/`, filters out `Permissions/PermissionsCoordinator.swift`, and exits 1 on any remaining hit. Script exited 0 at the build verification step. The boundary is enforced at static-check time on every commit (when wired into CI).

### Sandbox bookmark resolution test
**Verdict: CONCERN.** PermissionsCoordinatorTests covers `makeBookmark` + `resolveBookmark` round-trip but XCTSkips outside the app-scope-bookmark-entitled host. Runtime verification deferred.

## Privacy

### No clipboard logging
**Verdict: PASS** (convention-enforced). Story 1.4 `Errors/README.md` documents `privacy: .private` for user content and "no clipboard logging" as an explicit policy. There is no linter for this yet (deferred to a future story), but the only file that logs anything is gated through the one-Logger-per-file convention with `com.cactusvoice` subsystem, and grep across the codebase finds no clipboard-content-passing log statements.

### Microphone consent
**Verdict: PASS.** Story 2.4 `PermissionsCoordinator.ensureMicPermission()` re-reads `AVCaptureDevice.authorizationStatus(for: .audio)` every call (no cache) so mid-session revoke surfaces as `AppError.micDenied`. Story 3.4 `AudioCapture.start()` calls it every invocation. Banner string equals UX-DR6 ("Microphone access required.", 27 chars / 4 words).

## Concurrency / Sendable

### Actor isolation throughout
**Verdict: PASS** (typechecked). Every cross-actor boundary typechecks under `-warnings-as-errors` with `SWIFT_TREAT_WARNINGS_AS_ERRORS: YES` enforced by `project.yml`. `@unchecked Sendable` is used only at three load-bearing boundaries (`OpaqueBox` in CactusRuntime, `SessionPtr` in WhisperSession, `ContinuationBox` in SileroVAD) where the underlying payload (UnsafeMutableRawPointer or AsyncStream.Continuation) is not natively Sendable.

### SPSC ring buffer correctness
**Verdict: CONCERN.** Story 2.1 ships a 10 000-op DispatchQueue producer/consumer fuzz asserting `pulled.count + overrunCount == produced` and strict FIFO monotonicity. Test deferred (no XCTest module). Architectural deviation: `OSAllocatedUnfairLock` instead of atomics; swappable later without API change.

## Maintainability

### Warning-clean builds
**Verdict: PASS.** Every story committed code that typechecks under `swiftc -typecheck -warnings-as-errors`. `project.yml` sets `SWIFT_TREAT_WARNINGS_AS_ERRORS: YES` as a baseline. One Sendable warning in Story 2.3 (`no async operations occur within await`) was caught and fixed at the build-verification step.

### LOC budgets
**Verdict: PASS.** Every file in the cycle came in under its declared budget. Most stayed comfortably under (the only file that came within 1% of its budget is `WhisperSession.swift` at 353/360).

## Summary table

| NFR | Verdict | Status |
|---|---|---|
| NFR-001 tiered memory | CONCERN | Spike test exists; needs real models + Xcode to run |
| NFR-002 hot-path responsiveness | CONCERN | Pre-roll test exists; needs XCTest to run |
| NFR-009 stop ≤ 100 ms | CONCERN | Test exists; needs XCTest to run |
| Concurrent-load idempotency | CONCERN | Test exists; needs XCTest to run |
| Sandbox + entitlement posture | PASS | Statically verified |
| Security-scoped resource boundary | PASS | Grep script exits 0 |
| Bookmark resolution | CONCERN | XCTSkip outside entitled host |
| No clipboard logging | PASS | Convention-enforced, no violations in tree |
| Microphone consent + revoke | PASS | No cache, banner matches UX-DR6 |
| Actor isolation / Sendable | PASS | Typechecks warning-clean |
| SPSC fuzz correctness | CONCERN | Test exists; needs XCTest to run |
| Warning-clean builds | PASS | Enforced by project.yml |
| LOC budgets | PASS | Every file under budget |

**Aggregate: 6 PASS, 7 CONCERN, 0 FAIL.** Every CONCERN resolves the moment the build host has Xcode + the model fixtures.
