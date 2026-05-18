# Developer User Guide — Epic 1-3

Absolute path: `/Users/Z/projects/cactus/_bmad-output/implementation-artifacts/user-guide-epic-1-3.md`

For a developer with a full-Xcode Apple Silicon Mac who has cloned `https://github.com/zye3776/cactus` and wants to bring the CactusVoice baseline pipeline up to a runnable, testable state.

## 1. Prerequisites

- Apple Silicon Mac (arm64), macOS 14+.
- Xcode 15+ with the macOS 14 SDK installed (Command Line Tools alone are not enough — `xcodebuild` + XCTest module are required).
- `brew install xcodegen` (version 2.45+ confirmed working).
- Optional but recommended: a real Whisper model file, a Silero VAD ONNX model, a Gemma-3 LLM file, and a 10 s baseline WAV + matching reference transcript for the integration test. See step 5.

## 2. Generate the Xcode project

```sh
cd apps/CactusVoice
xcodegen generate
open CactusVoice.xcworkspace
```

This regenerates `CactusVoice.xcodeproj` from `project.yml`. The `.xcodeproj` is git-ignored — always regenerate after pulling. Source/test folders are picked up by globs in `project.yml`; you should not need to edit it to add new files under `CactusVoice/` or `CactusVoiceTests/`.

## 3. Build the app target

Cmd+B in Xcode (or `xcodebuild -workspace CactusVoice.xcworkspace -scheme CactusVoice build`). Expected: warning-clean build. `project.yml` sets `SWIFT_TREAT_WARNINGS_AS_ERRORS: YES`, so any warning fails the build.

Two SPM dependencies are **declared in the source but not yet resolved** on a CLT-only host:

- `swift-atomics` — when added to `project.yml`, you can drop `OSAllocatedUnfairLock` from `BoundedSPSCBuffer.swift` (Story 2.1 deviation).
- `KeyboardShortcuts` — when added to `project.yml`, `SettingsHotkeyBridge.swift` (22 LOC) collapses into `Settings.swift` (Story 1.5 deviation).

Add them under the `packages:` section in `apps/CactusVoice/project.yml` and run `xcodegen generate` again before building.

## 4. Run the XCTest suite

Cmd+U in Xcode (or `xcodebuild test -workspace CactusVoice.xcworkspace -scheme CactusVoice -destination 'platform=macOS,arch=arm64' -only-testing:CactusVoiceTests`). About 110 test methods will execute across stories 1.1-3.5. Tests that require model files, env vars, or special entitlements will `XCTSkip` cleanly without failing.

## 5. Run the integration tests

To make integration tests do real work, set these scheme env vars (Product → Scheme → Edit Scheme → Test → Arguments → Environment Variables):

- `CACTUSVOICE_WHISPER_PATH` — absolute path to a Whisper model file (`.gguf` or whatever the cactus runtime accepts).
- `CACTUSVOICE_VAD_PATH` — absolute path to the Silero VAD ONNX file.
- `CACTUSVOICE_BASELINE_WAV` — absolute path to a 10 s baseline WAV (defaults to `Fixtures/baseline_10s.wav`).

Also ensure a matching reference transcript exists at `Fixtures/baseline_10s.transcript.txt` (UTF-8, lowercase, punctuation stripped, single-space separated). See `apps/CactusVoice/CactusVoiceTests/Fixtures/README.md` for format details.

With those set, `BaselinePipelineTests.testEndToEndBaselinePipeline` will read the WAV, feed it through the AudioCapture → SileroVAD → WhisperSession → TranscriptModel pipeline, and assert WER ≤ 0.15.

## 6. Run the measurement spike

Set the additional env vars:

- `CACTUSVOICE_GEMMA_PATH` — absolute path to a Gemma-3 LLM model file.
- `CACTUSVOICE_APP_BUNDLE_PATH` — absolute path to a built `.app` bundle whose total size you want measured.

Then run `MeasurementSpikeTests` (a single test method, ~30 s wall-clock). It appends one row to `_bmad-output/implementation-artifacts/measurement-spike-results.csv` containing baseline / minimal-mode / full-mode peak resident bytes + bundle size. NFR-001 targets are ~600 MB minimal / ~2.5 GB full; the spike header documents the 20% divergence procedure (file a PRD-revision PR if measured deviates more than that).

## 7. Boundary check

```sh
bash apps/CactusVoice/Scripts/check-permission-boundaries.sh
```

Should exit 0. The script greps for `AVCaptureDevice.requestAccess` and `startAccessingSecurityScopedResource` across `apps/CactusVoice/CactusVoice/`, filters out `Permissions/PermissionsCoordinator.swift`, and exits 1 with offending lines on stderr if any other file owns those APIs. Wire this into CI as a pre-build step.

## 8. Wire real `libcactus`

Currently `apps/CactusVoice/CactusCore/Sources/FFIStub.c` provides weak `cactus_*` symbols that all return `cactus_status_err_unimplemented`. To run anything for real, replace `FFIStub.c` with a binding to the actual `libcactus`:

1. Build / locate a `libcactus.dylib` (or `.a`) for `arm64-apple-macos14.0`.
2. In `apps/CactusVoice/project.yml`, replace the `FFIStub.c` source entry with a link against `libcactus` (`OTHER_LDFLAGS: -lcactus` plus a library search path).
3. Remove `FFIStub.c` from the build phase (or keep it as a fallback under `#ifdef CACTUS_STUB`).
4. Search the tree for `TODO(real-cactus)` markers in `FFIShim.swift` — those are the insertion points where the shim's `loadModel` / `freeModel` / `whisper*` / `onnxRun` calls expect real runtime behaviour.

Once `libcactus` is wired, the default `FFIShim*` adapters in `CactusRuntime`, `WhisperSession`, `SileroVAD`, and `ModelCatalog` start producing real values instead of error statuses; injected test stubs continue to work as before since the protocol seams are unchanged.

## Notes

- Push target is the fork `origin → zye3776/cactus`. Never push to `upstream`.
- `chmod +x` on shell scripts is intentionally not done (per project convention); always invoke with `bash <path>`.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` is the canonical per-story status; `traces/epic-1-3-events.yaml` is the orchestrator trace; `traces/reports/epic-1-3-sequence.md` is the Mermaid summary.
