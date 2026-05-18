# P1 Gap Remediation — Epic 1-3

Absolute path: `/Users/Z/projects/cactus/_bmad-output/implementation-artifacts/p1-gap-remediation-epic-1-3.md`

## Acknowledgement

The cycle was executed on a host with Command Line Tools only — no Xcode.app, therefore no XCTest module and no `xcodebuild`. Every Swift production file typechecks clean (`swiftc -typecheck -warnings-as-errors`, target `arm64-apple-macos14.0`), but **no runtime test from this epic has actually executed**. Expanding the "automate" remediation column for these P1 gaps requires moving to a host with a full Xcode 15+ install. This document catalogues which test files need to run, what they need to run with, and which are most load-bearing.

## Per-story P1 test execution gaps

| Story | Test file (absolute path) | Status | Required env / setup |
|---|---|---|---|
| 1.1 | `apps/CactusVoice/CactusVoiceTests/StoryAcceptance/Story1_1Tests.swift` | static greps pass; xcodebuild clean + .app launch (ACs 7-8) require Xcode | full Xcode 15+; `xcodebuild -workspace CactusVoice.xcworkspace -scheme CactusVoice build` |
| 1.2 | `apps/CactusVoice/CactusVoiceTests/StoryAcceptance/Story1_2Tests.swift` | static greps pass; need full -typecheck via XCTest | XCTest module |
| 1.3 | `apps/CactusVoice/CactusVoiceTests/Spike/MeasurementSpikeTests.swift` | -parse passes; runtime requires real models | `CACTUSVOICE_WHISPER_PATH`, `CACTUSVOICE_VAD_PATH`, `CACTUSVOICE_GEMMA_PATH`, `CACTUSVOICE_APP_BUNDLE_PATH` |
| 1.4 | `apps/CactusVoice/CactusVoiceTests/Errors/AppErrorMappingTests.swift` | -parse passes | XCTest module |
| 1.5 | `apps/CactusVoice/CactusVoiceTests/Persistence/SettingsCodecTests.swift` | -parse blocked on `@testable import CactusVoice` + KeyboardShortcuts SPM | XCTest + KeyboardShortcuts SPM resolution |
| 2.1 | `apps/CactusVoice/CactusVoiceTests/Audio/BoundedSPSCBufferTests.swift` | -parse passes; 10 000-op fuzz needs runtime | XCTest module |
| 2.2 | `apps/CactusVoice/CactusVoiceTests/Transcript/TranscriptModelTests.swift` | static greps pass | XCTest module |
| 2.3 | `apps/CactusVoice/CactusVoiceTests/Transcript/TranscriptTextStorageTests.swift` | static greps pass; needs `NSLayoutManager` attached at runtime | XCTest module + AppKit (macOS host) |
| 2.4 | `apps/CactusVoice/CactusVoiceTests/Permissions/PermissionsCoordinatorTests.swift` | static greps pass; bookmark round-trip needs entitlement, XCTSkip otherwise | XCTest + `com.apple.security.files.bookmarks.app-scope` entitlement on app test host |
| 2.5 | `apps/CactusVoice/CactusVoiceTests/Permissions/ModelCatalogTests.swift` | static greps pass | XCTest module |
| 3.1 | `apps/CactusVoice/CactusVoiceTests/Inference/CactusRuntimeTests.swift` | static greps pass; concurrent-load collapse needs runtime + 20 ms artificial delay | XCTest module |
| 3.2 | `apps/CactusVoice/CactusVoiceTests/Inference/WhisperSessionTests.swift` | static greps pass | XCTest module |
| 3.3 | `apps/CactusVoice/CactusVoiceTests/Inference/SileroVADTests.swift` | static greps pass | XCTest module |
| 3.4 | `apps/CactusVoice/CactusVoiceTests/Audio/AudioCaptureTests.swift` | static greps pass; NFR-009 stop ≤ 100 ms p95 needs runtime | XCTest module |
| 3.5 | `apps/CactusVoice/CactusVoiceTests/Inference/BaselinePipelineTests.swift` | -parse passes; full run requires models + WAV fixture | `CACTUSVOICE_WHISPER_PATH`, `CACTUSVOICE_VAD_PATH`, `CACTUSVOICE_BASELINE_WAV` (default `Fixtures/baseline_10s.wav`), + reference transcript `Fixtures/baseline_10s.transcript.txt` |

## Prioritisation — most load-bearing first

1. **`BaselinePipelineTests` (Story 3.5).** The keystone. Wires AudioCapture → SileroVAD → WhisperSession → TranscriptModel + CactusRuntime end-to-end and asserts WER ≤ 0.15. If this passes, every downstream Epic-4 story can assume the baseline path works. Required env: all three above + the WAV fixture + reference transcript on disk. **Run this first on the build host.**
2. **`MeasurementSpikeTests` (Story 1.3).** Produces the actual NFR-001 tiered memory numbers (~600 MB minimal / ~2.5 GB full ± 20%) plus bundle size. Until this runs, every NFR-001 claim is unverified. Required env: all four model env vars + `CACTUSVOICE_APP_BUNDLE_PATH`.
3. **`AudioCaptureTests` (Story 3.4).** Includes the NFR-009 stop-under-100 ms test and the overrun-forwarding test. Both gate audio reliability claims.
4. **`CactusRuntimeTests` (Story 3.1).** Includes the eight-concurrent-acquire-collapse-to-one-load test. Slot ownership semantics gate every downstream consumer (WhisperSession, the eventual LLM, future correction pipeline).
5. **`BoundedSPSCBufferTests` (Story 2.1).** 10 000-op DispatchQueue producer/consumer fuzz. Validates the SPSC contract before it carries real audio.
6. **`WhisperSessionTests` + `SileroVADTests` + `TranscriptModelTests` + `TranscriptTextStorageTests`.** Per-component contract tests; less load-bearing than the integration / spike tests but they pin per-actor behaviour.
7. **`PermissionsCoordinatorTests` + `ModelCatalogTests` + `AppErrorMappingTests` + `SettingsCodecTests` + per-story `StoryAcceptance/Story*Tests.swift`.** Mostly static structural greps that already passed on the CLT-only host; running them under XCTest is confirmatory rather than load-bearing.

## What "automate" means once the build host exists

`xcodebuild test -workspace CactusVoice.xcworkspace -scheme CactusVoice -destination 'platform=macOS,arch=arm64' -only-testing:CactusVoiceTests` will execute everything in the table above. Integration / spike tests will `XCTSkipUnless` cleanly when env vars / fixtures / entitlements are absent — those should be added to a scheme that sets them explicitly, and the boundary script `bash apps/CactusVoice/Scripts/check-permission-boundaries.sh` should be a pre-build CI step.
