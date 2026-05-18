# Quality Gate — Epic 1-3

Absolute path: `/Users/Z/projects/cactus/_bmad-output/implementation-artifacts/quality-gate-epic-1-3.md`

## Decision: **CONCERNS**

## Justification

**What shipped (in favour of PASS):**
- 15 stories complete across Epic 1 (5), Epic 2 (5), Epic 3 (5). All pushed to `origin/main` on the fork `zye3776/cactus`.
- Every production Swift file in the closure (`AppError`, `PermissionsCoordinator`, `ModelCatalog`, `BoundedSPSCBuffer`, `AudioCapture`, `SileroVAD`, `Settings`, `TranscriptUpdate`, `TranscriptModel`, `TranscriptTextStorage`, `CactusRuntime`, `WhisperSessionType`, `WhisperEvent`, `WhisperSession`, `FFIShim`) typechecks clean under `swiftc -typecheck -warnings-as-errors`, target `arm64-apple-macos14.0`, with `SWIFT_TREAT_WARNINGS_AS_ERRORS: YES` enforced by `project.yml`.
- The strict-C11 FFI header (`cactus_c.h`) parses clean under `clang -fsyntax-only -Wall -Wpedantic -Werror -std=c11`.
- Consistent protocol-seam pattern at every FFI / IO boundary (RuntimeFFI, WhisperFFI, VADInference, AudioInputSource, MicPermissionGate, ModelLoading) makes every actor unit-testable.
- KISS budgets respected everywhere; no file exceeded its declared LOC ceiling.
- Sandbox + entitlement posture (app-sandbox on, no network, mic + user-selected files + app-scope bookmarks) is statically verified.
- TDD discipline: every story shipped a red ATDD commit before any implementation; ~110 test methods authored across the suite.

**What did not ship (against PASS):**
- **No XCTest module on the build host.** The cycle was executed on a CLT-only machine. None of the ~110 runtime tests have actually executed. Every NFR with a runtime budget (NFR-001 tiered memory, NFR-009 stop ≤ 100 ms, pre-roll race, concurrent-load idempotency, SPSC fuzz) is structurally implemented but unverified at runtime.
- **No `xcodebuild` verification.** ACs 7-8 of Story 1.1 ("xcodebuild clean" + ".app launches") have never run.
- **`FFIStub.c` returns `cactus_status_err_unimplemented` for every call.** Real `libcactus` is not wired. The default loader / runtime FFI shims always fail; tests bypass them via injected stubs. No real audio has flowed through real Whisper or real Silero VAD on the project's own code yet.
- **No baseline pipeline run.** Story 3.5's `BaselinePipelineTests` is the keystone E2E test. It requires `CACTUSVOICE_WHISPER_PATH` + `CACTUSVOICE_VAD_PATH` + `CACTUSVOICE_BASELINE_WAV` + the reference transcript + a host with Xcode. Until it runs and produces a measured WER, the "the pipeline transcribes a 10 s clip with WER ≤ 0.15" claim is structural only.
- Two SPM dependencies are absent (`swift-atomics`, `KeyboardShortcuts`) and worked around with deviations (`OSAllocatedUnfairLock`, raw `String?` hotkey via bridge file). These will collapse cleanly once the SPM dep is added on a real Xcode host but they're current technical debt.

## Why CONCERNS rather than PASS or FAIL

- Not **PASS** because nothing has run. Every quality claim past "the source typechecks" is currently structural. A reviewer cannot certify production-readiness from this evidence alone.
- Not **FAIL** because the code is well-structured, follows the architecture (with documented and well-reasoned deviations), and is set up such that the next blocker is purely environmental ("set up a real build host"). No design rework is needed, no story needs to be re-opened, no AC was skipped.

## Recommendation

Move to a host with full Xcode 15+ on Apple Silicon, install the two missing SPM dependencies, wire real `libcactus`, and run `xcodebuild test` + the measurement spike + the baseline pipeline integration test. At that point, expect this gate to flip to **PASS** without code changes to Epic 1-3. The detailed steps are in `_bmad-output/implementation-artifacts/user-guide-epic-1-3.md`; the per-test env-var requirements are in `_bmad-output/implementation-artifacts/p1-gap-remediation-epic-1-3.md`.

## Sign-off

- Decision date: 2026-05-19
- Decided by: Trace Agent (post-epic synthesis)
- Next gate review: after first successful `xcodebuild test` run on a full-Xcode host
