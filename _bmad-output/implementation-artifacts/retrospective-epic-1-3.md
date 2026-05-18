# Retrospective — Epic 1-3 (CactusVoice)

Absolute path: `/Users/Z/projects/cactus/_bmad-output/implementation-artifacts/retrospective-epic-1-3.md`

Cycle: 2026-05-18 → 2026-05-19. 15 stories complete (Epic 1: 5, Epic 2: 5, Epic 3: 5). All work pushed to `origin/main` on the fork `zye3776/cactus`.

## What went well

- **Uniform protocol-seam pattern.** Every external boundary (FFI load/free, Whisper streaming, VAD scoring, audio input, mic permission) was put behind a `protocol … : Sendable` with a `FFIShim*` / `AVAudio*` / `PermissionsCoordinator*` default adapter. Unit tests inject stubs/mocks without any AVFoundation, XCTest mocking, or `#if DEBUG` branches. Made every actor testable without a device or a real model.
- **KISS budgets respected on every story.** No file exceeded its declared LOC budget. `WhisperSession.swift` and `CactusRuntime.swift` came closest (353/347 of 360) and earned it through real complexity (decoder flags, refcount + concurrent-load collapse).
- **Two-string TranscriptModel design.** Keeping `committed` and `provisional` as two separate `AttributedString`s (one writer) avoided merge-view contention and let the NSTextStorage subclass treat reconciliation as a full-snapshot rebuild — short transcripts re-layout for free.
- **TDD discipline.** Every story shipped red ATDD tests as a discrete commit before any implementation. `swiftc -typecheck -warnings-as-errors` was the gate at every step (`SWIFT_TREAT_WARNINGS_AS_ERRORS: YES` enforced by `project.yml` since Story 1.1).
- **Concurrency hygiene.** Actor isolation as the only concurrency primitive across the production code, with `@unchecked Sendable` boxes only at unavoidable boundaries (`UnsafeMutableRawPointer`, `AsyncStream.Continuation` captures inside Task bodies).

## What was harder than expected

- **XCTest deferral.** The CLT-only host has no XCTest module. Every runtime test (~110 across the 15 stories) is structurally complete and grep-validated but has never run. This is the single largest unverified risk in the cycle.
- **AVAudioEngine seams.** Story 3.4 needed two protocol seams (`AudioInputSource`, `MicPermissionGate`) instead of one because mocking `AVAudioEngine` directly is intractable (format negotiation depends on hardware) and the mic-permission dialog cannot run unattended.
- **`AttributedString.Index` range axis ambiguity in TranscriptModel.** The `TranscriptUpdate.range` had to be documented as per-field (provisional for commit/revise, committed for userEdit) because the actor stores two strings, not a merged view. NSTextStorage in Story 2.3 absorbs the mapping cost.
- **Sendable conformance gymnastics.** Three separate places (`OpaqueBox` in CactusRuntime, `SessionPtr` in WhisperSession, `ContinuationBox` in SileroVAD) needed `@unchecked Sendable` wrappers so that Task closures could carry non-Sendable payloads across actor boundaries cleanly.
- **Sole-public-from-internal compile failure.** `WhisperSession` actor + `init` had to drop from `public` to `internal` because `TranscriptModel` is internal — Swift forbids a public type depending on an internal one. The protocol (`WhisperSessionType`) + value types stay public for future external wiring.

## Recurring deviations from canonical BMAD / architecture (architecture-evolution signals)

These deviations recurred across multiple stories. Each is a signal that the architecture doc should adopt the deviation as canonical or invest in removing the constraint.

| Deviation | Stories affected | Root cause | Suggested arch action |
|---|---|---|---|
| `OSAllocatedUnfairLock` fallback in ring buffer | 2.1 | `swift-atomics` not on SPM graph; stdlib `Synchronization.UnsafeAtomic` is Swift 6 only (project is Swift 5.10) | Add swift-atomics SPM dep OR commit to Swift 6 toolchain; either way drop the lock |
| `KeyboardShortcuts.Name` persisted as `String?` via bridge file | 1.5 | SPM dep absent on CLT-only host; persistence layer typechecks Foundation-only | Add KeyboardShortcuts SPM dep so the bridge file collapses into Settings |
| All runtime tests deferred (XCTest absent) | 1.1, 1.2, 1.3, 1.4, 1.5, 2.1, 2.2, 2.3, 2.4, 2.5, 3.1, 3.2, 3.3, 3.4, 3.5 | Host has CLT only, no Xcode.app | Move primary dev/CI host to full Xcode; create build host doc (see User Guide) |
| VAD-finalization deferred from 3.2 to 3.4 | 3.2 → wired in 3.4 | No `.speechEnd` signal existed in 3.2 chronology | Architecture doc should note 3.2 wire-up depends on 3.3/3.4 ordering |
| Protocol seam at every FFI boundary (RuntimeFFI, WhisperFFI, VADInference, AudioInputSource, MicPermissionGate, ModelLoading) | 2.5, 3.1, 3.2, 3.3, 3.4 | Architecture doc named some seams but not all; testability drove the rest | Update architecture doc to list these as canonical FFI/IO seams (and consolidate where possible — e.g. RuntimeFFI vs ModelLoading are near-duplicates) |
| `WhisperSession` actor demoted from public to internal | 3.2 | Depends on internal `TranscriptModel` | Either elevate `TranscriptModel` to public or document the visibility rule |
| `FFIStub.c` returns `cactus_status_err_unimplemented` everywhere | 1.2, 2.5, 3.1+ all FFI consumers | No real `libcactus` linked yet | Story for real `libcactus` integration (mentioned in user-guide step 8) |
| Two `AsyncStream<Float>` instances (master + internal vadPcm) in AudioCapture | 3.4 | `AsyncStream` is single-consumer | Document multi-consumer pattern in architecture; consider Combine multicast or tee helper if pattern recurs |
| Grep-based boundary check instead of swift-syntax linter | 2.4 | Lightweight; no Swift-syntax tooling adopted yet | Replace with SwiftLint custom rule when linter is adopted (Story 1.4 deferred linter) |

## Action items for the development host

1. **Install full Xcode 15+ with the macOS 14 SDK** on the primary dev/CI machine. Without this, none of the runtime tests have actually executed.
2. **Run `xcodebuild test`** on the CactusVoice scheme. Expect ~110 test methods across the suite to execute; integration tests requiring real models or env vars will XCTSkip.
3. **Add SPM dependencies** to `apps/CactusVoice/project.yml`:
   - `swift-atomics` (so `BoundedSPSCBuffer` can drop `OSAllocatedUnfairLock`).
   - `KeyboardShortcuts` (so `SettingsHotkeyBridge.swift` collapses into `Settings.swift`).
4. **Wire real `libcactus`** to replace `FFIStub.c`. The TODO markers in `apps/CactusVoice/CactusCore/Sources/FFIStub.c` and `FFIShim.swift` are the insertion points.
5. **Execute the measurement spike** (`MeasurementSpikeTests`) with all four env vars set, populate `_bmad-output/implementation-artifacts/measurement-spike-results.csv`, and confirm NFR-001 tiered memory targets within the documented 20% divergence.
6. **Adopt the grep boundary script in CI** (`bash apps/CactusVoice/Scripts/check-permission-boundaries.sh`).

## Story-by-story commit summary

| Story | Title | Commits | KISS commit? |
|---|---|---|---|
| 1.1 | Workspace + two targets | `117bdea3`, `f8baf727` | no |
| 1.2 | cactus_c.h FFI surface | `9d125972`, `fd16cdf5` | no |
| 1.3 | Measurement spike | `36b116aa`, `dc230fa6` | no |
| 1.4 | AppError + Logger | `daafa0b3`, `fd2657e1`, `2b462d49` | yes (README trim) |
| 1.5 | Settings persistence | `2a9ddcc3`, `6694ead0` | no |
| 2.1 | BoundedSPSCBuffer | `c63806a2`, `9508aa7b`, `25dfe320` | yes (simplify write) |
| 2.2 | TranscriptModel actor | `3882af62`, `823631fa` | no |
| 2.3 | TranscriptTextStorage | `cccdc77b`, `6f5bf457` | no |
| 2.4 | PermissionsCoordinator | `39622913`, `309eec9b` | no |
| 2.5 | ModelCatalog | `a83f5e27`, `d7350a47` | no |
| 3.1 | CactusRuntime | `f130e948`, `2152bc62` | no |
| 3.2 | WhisperSession | `34475140`, `de71fdf9` | no |
| 3.3 | SileroVAD | `2d764e96`, `7812bc9e` | no |
| 3.4 | AudioCapture | `e1847e8f`, `e71d5500` | no |
| 3.5 | BaselinePipelineTests (E2E) | `50b060ac`, `417da2a1` | no |

Total: 32 feature/test/KISS commits + 14 trailing `chore(story-…): mark done` commits.
