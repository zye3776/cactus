# Story 1.1: Initialize Xcode workspace and two targets

**Epic:** 1 — Project Foundation & FFI Seam
**Status:** done
**Owner:** story-executor-1.1

## User Story

As the **author**,
I want **a CactusVoice Xcode workspace with the app target, CactusCore static lib, and KeyboardShortcuts SPM dep wired in**,
So that **every subsequent story has a buildable home and the C++/Swift seam is physically real from day one**.

## Acceptance Criteria

1. Workspace at `apps/CactusVoice/CactusVoice.xcworkspace` opens cleanly.
2. Two targets exist: `CactusVoice.app` (SwiftUI lifecycle, macOS 14+, Apple Silicon only) and `CactusCore` (static library); `CactusCore` is linked into `CactusVoice.app`.
3. `KeyboardShortcuts` (~v2.4+) is the *only* SPM dependency.
4. `CactusVoice.entitlements` contains exactly: `com.apple.security.app-sandbox`, `com.apple.security.device.audio-input`, `com.apple.security.files.user-selected.read-only`, `com.apple.security.files.bookmarks.app-scope` — **no network entitlement**.
5. `Info.plist` declares bundle id `com.cactusvoice` and `LSMinimumSystemVersion` ≥ 14.0.
6. Folder layout matches `architecture.md §Project Structure` exactly (App/, Audio/, Hotkey/, Inference/, Transcript/, UI/, Permissions/, Persistence/, Errors/, Resources/ + sibling CactusCore/ + CactusVoiceTests/).
7. `xcodebuild -workspace CactusVoice.xcworkspace -scheme CactusVoice build` succeeds with zero warnings.
8. The produced `.app` launches, shows nothing, exits cleanly.

## Tasks

- [x] T1 — Author `project.yml` declaring app + static-lib targets, KeyboardShortcuts SPM dep, deploy target macOS 14, arch arm64.
- [x] T2 — Create `CactusVoice.xcworkspace/contents.xcworkspacedata` pointing at the generated `.xcodeproj`.
- [x] T3 — Write `Info.plist` with bundle id `com.cactusvoice`, `LSMinimumSystemVersion = 14.0`.
- [x] T4 — Write `CactusVoice.entitlements` with the four required keys and no network capability.
- [x] T5 — Create minimal SwiftUI `CactusVoiceApp.swift` (empty Scene, exits cleanly).
- [x] T6 — Lay out folders per architecture §Project Structure with `.gitkeep` placeholders.
- [x] T7 — Create `CactusCore` static-lib sources (`cactus_c.h` umbrella, `module.modulemap`, stub `cactus_c.cpp`).
- [x] T8 — Add `.gitignore` for xcuserdata and generated `.xcodeproj` (XcodeGen regenerates).
- [x] T9 — Write acceptance tests (`Story1_1Tests.swift`) that mechanically check ACs 1–6.
- [x] T10 — README explaining XcodeGen regeneration + build/run.
- [x] T11 — Run xcodegen + xcodebuild if available; capture status.

## Dev Notes

- Architecture refs: `architecture.md §A` (persistence/state shape — informs Settings folder existing even though empty here), `§B` (FFI seam — informs CactusCore target separation), `§G` (logging conventions — folder created, content deferred to story 1.4), §Project Structure (lines 373-470).
- Headless constraint: no Xcode GUI available; use **XcodeGen** to materialize `.xcodeproj` from `project.yml`. Workspace is hand-rolled XML referencing the generated `.xcodeproj`.
- This story builds the *skeleton only*. Real code lands in stories 1.2–1.5 and beyond. `.gitkeep` files are deliberate.
- `CactusCore` is exposed to Swift via `module.modulemap`. The `cactus_c.h` header is an empty umbrella for now; the actual FFI surface is story 1.2's job.
- KeyboardShortcuts pinned to `from: 2.4.0` per architecture decision (sole third-party dep).
- Tests use `XCTSkipUnless` for any check requiring tools that aren't available in this environment (e.g., a built `.app` bundle when `xcodebuild` is missing).

## Validation

| AC | Covered by |
|----|------------|
| 1 (workspace opens) | `Story1_1Tests.testWorkspaceFileExists` + manual `xcodebuild` invocation |
| 2 (two targets) | `Story1_1Tests.testProjectYmlDeclaresBothTargets` |
| 3 (only KeyboardShortcuts SPM dep) | `Story1_1Tests.testOnlyKeyboardShortcutsDependency` |
| 4 (entitlements) | `Story1_1Tests.testEntitlementsContents` |
| 5 (Info.plist) | `Story1_1Tests.testInfoPlistContents` |
| 6 (folder layout) | `Story1_1Tests.testFolderLayoutMatchesArchitecture` |
| 7 (xcodebuild zero warnings) | Story-executor runs `xcodebuild` if available; otherwise flagged as skipped. |
| 8 (.app launches & exits) | Manual / CI step; not unit-testable. |

## Change Log

- 2026-05-18 — Initial story file authored by story-executor-1.1.
