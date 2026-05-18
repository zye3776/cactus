# Story 1.5: Settings persistence (UserDefaults + Codable + @Observable mirror)

**Epic:** 1 — Project Foundation & FFI Seam
**Status:** done
**Owner:** story-executor-1.5

## User Story

As the **Settings UI later**,
I want **a single `Settings` Codable struct persisted to `UserDefaults` with an `@Observable` mirror on the main actor**,
So that **all four (later, more) configuration fields have one canonical writer and SwiftUI views bind cleanly**.

## Acceptance Criteria

1. `apps/CactusVoice/CactusVoice/Persistence/Settings.swift` declares a `Codable` struct `Settings` with fields: `hotkey`, `activationMode: ActivationMode (.hold | .toggle, default .hold)`, `whisperModelPath: String?`, `llmModelPath: String?`, `whisperBookmark: Data?`, `llmBookmark: Data?`.
2. `ActivationMode` is an `enum ActivationMode: String, Codable { case hold, toggle }`.
3. `SettingsStore` is `@MainActor @Observable final class` owning the read/write through `UserDefaults`; it is the *only* file in the project that imports `Foundation.UserDefaults`.
4. UserDefaults keys are prefixed `com.cactusvoice.` — one JSON blob key `com.cactusvoice.settings.v1`.
5. `SettingsStore.init` reads UserDefaults on init; missing key → default `Settings`. `current` setter writes through.
6. `CactusVoiceTests/Persistence/SettingsCodecTests.swift` round-trips `Settings` through JSONEncoder/JSONDecoder with both nil paths and populated 1 KB bookmark blobs; round-trips through a `UserDefaults(suiteName:)` instance (cleared in setUp/tearDown); asserts default `activationMode == .hold`; asserts observability fires on mutation.
7. File ≤ 200 LOC (Settings + SettingsStore in one file).

## Tasks

- [x] T1 — Acceptance tests (red): static greps on Settings.swift / SettingsStore shape and UserDefaults import isolation.
- [x] T2 — Implement `Persistence/Settings.swift` (Settings struct + ActivationMode + SettingsStore).
- [x] T3 — Implement `Persistence/SettingsHotkeyBridge.swift` (KeyboardShortcuts.Name <-> String bridge).
- [x] T4 — Implement `CactusVoiceTests/Persistence/SettingsCodecTests.swift`.
- [x] T5 — `swiftc -typecheck Settings.swift` (Foundation-only) passes.
- [x] T6 — Regenerate `.xcodeproj` via `xcodegen generate`.

## Deviation: KeyboardShortcuts.Name decoupling

The story brief explicitly authorizes this deviation. The core `Settings` struct stores the hotkey as a `String?` (raw shortcut name), not `KeyboardShortcuts.Name?`. Rationale:

- **KISS / testability on host:** Settings.swift typechecks with `Foundation` alone — no SPM resolution needed on this CLT-only host or in `swiftc -typecheck` quick gates.
- **Decoupled types:** Persistence layer does not depend on the hotkey package's public surface.
- **No information loss:** `KeyboardShortcuts.Name` is `RawRepresentable<String>`; round-tripping through its raw value is lossless. The bridge in `SettingsHotkeyBridge.swift` provides `Settings.hotkeyName: KeyboardShortcuts.Name?` (computed) for the consumers that need the typed value.

This satisfies AC1's intent (one hotkey field, persisted) without making the persistence file itself depend on the third-party package. Documented in story brief and here.

## Dev Notes

- Architecture refs: §A line 174 (UserDefaults + Codable Settings struct, single accessor), line 175 (bookmark Data alongside paths).
- No migration scaffold in v1 — key is suffixed `.v1` to leave the door open. A future story will introduce v2 only when a real schema change appears.
- `SettingsStore` is `@MainActor` because SwiftUI bindings read it; `@Observable` (Observation framework, macOS 14+) gives change tracking without `@Published`.
- `SettingsStore` deliberately decodes-or-defaults silently; corrupted JSON in UserDefaults logs once via the standard `os.Logger` (per Story 1.4 convention) and falls back to a default `Settings`. The file is the only `import Foundation` consumer of `UserDefaults` in the project.
- Tests run under XCTest; on this CLT-only host the test target won't build (no XCTest module), same constraint as 1.1–1.4. Greps in `Story1_5Tests.swift` enforce the on-disk contract statically.

## Validation

| AC | Covered by |
|----|------------|
| 1 (fields)         | `Story1_5Tests.testSettingsHasRequiredFields` |
| 2 (ActivationMode) | `Story1_5Tests.testActivationModeEnum` |
| 3 (SettingsStore)  | `Story1_5Tests.testSettingsStoreShape`, `testUserDefaultsImportIsolated` |
| 4 (key prefix)     | `Story1_5Tests.testKeyPrefix` |
| 5 (init + setter)  | runtime `SettingsCodecTests.testStoreReadsAndWritesUserDefaults` |
| 6 (round-trips)    | runtime `SettingsCodecTests.*` (JSON, UserDefaults, default mode, observability) |
| 7 (≤ 200 LOC)      | `Story1_5Tests.testFileSizeUnder200LOC` |

## Change Log

- 2026-05-18 — Initial story file authored by story-executor-1.5.
