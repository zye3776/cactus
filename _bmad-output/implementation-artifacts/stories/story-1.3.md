# Story 1.3: Measurement spike — bundle + tiered resident memory

**Epic:** 1 — Project Foundation & FFI Seam
**Status:** done
**Owner:** story-executor-1.3

## User Story

As the **author**,
I want **a throwaway test that loads real Whisper-Turbo + Gemma-3 E2B INT4 + Silero VAD through the FFI shim and reports bundle and resident memory**,
So that **NFR-001's tiered budgets become contractual numbers rather than working targets**.

## Acceptance Criteria

1. The spike lives in `CactusVoiceTests/Spike/MeasurementSpikeTests.swift` and is gated behind `XCTSkipUnless` checks for real model paths in env vars `CACTUSVOICE_WHISPER_PATH`, `CACTUSVOICE_GEMMA_PATH`, `CACTUSVOICE_VAD_PATH`, and `CACTUSVOICE_APP_BUNDLE_PATH`. It does **not** run in CI by default.
2. When the env vars are set and real model files exist, the test loads Whisper-Turbo + Silero VAD (minimal mode) and Whisper-Turbo + Silero VAD + Gemma-3 E2B INT4 (full mode) through `CactusCore.FFIShim`.
3. The test reports: stripped `.app` bundle size, peak resident memory in minimal mode, peak resident memory in full mode.
4. A CSV row is appended to `_bmad-output/implementation-artifacts/measurement-spike-results.csv` (header written if file does not yet exist).
5. The test releases all model handles before exiting and verifies `task_info` (via `mach_task_basic_info`) shows resident memory returning to baseline ± 50 MB.
6. Documented expectation: if measured numbers diverge from the working targets (~600 MB minimal / ~2.5 GB full) by > 20 %, the dev files a revision PR against PRD NFR-001 and architecture tiered budget *before* any other epic starts.

## Tasks

- [x] T1 — Write Story 1.3 acceptance tests (red), grep-level static checks.
- [x] T2 — Author `apps/CactusVoice/CactusVoiceTests/Spike/MeasurementSpikeTests.swift`.
- [x] T3 — Confirm `project.yml` test-target globs pick up `CactusVoiceTests/Spike/` (no project.yml change required).
- [x] T4 — Regenerate `.xcodeproj` via `xcodegen generate`.

## Dev Notes

- Architecture refs: `architecture.md` lines 722, 750, 775 (tiered NFR-001 revision); `epics.md` story 1.3.
- Real model files and a built `.app` are **not** present on the dev host. FFIStub.c returns `cactus_status_err_unimplemented`. The test therefore **skips at runtime** under `XCTSkipUnless`, which is the documented and expected behavior per AC1.
- `currentResidentBytes()` uses `task_info` with `MACH_TASK_BASIC_INFO` to read `resident_size`. No third-party process introspection needed.
- Peak resident memory is captured by spawning a low-frequency polling thread (1 ms tick, max 5 s window) around each load phase. No queues/actors — KISS.
- The test loads via the existing `FFIShim` static methods. When the real cactus runtime is wired in (story 3.1), this same test should produce numbers without code changes.
- Bundle size walks the `.app` directory tree via `FileManager.enumerator` summing `fileSize` of regular files.

## Validation

| AC | Covered by |
|----|------------|
| 1 (file location + env-var gating) | `Story1_3Tests.testSpikeFileExistsAtRequiredPath`, `Story1_3Tests.testSpikeUsesEnvVarGating` |
| 2-3 (load + measure) | `MeasurementSpikeTests.testMeasure_minimal_and_full_modes_and_bundle` (runtime, skipped on CI) |
| 4 (CSV output path) | `Story1_3Tests.testCsvPathIsCorrect` |
| 5 (task_info residency check) | `Story1_3Tests.testSpikeCallsTaskInfoForResidency` |
| 6 (deviation procedure) | Documented in `Story 1.3 Dev Notes` + this story file. |

## Change Log

- 2026-05-18 — Initial story file authored by story-executor-1.3.
