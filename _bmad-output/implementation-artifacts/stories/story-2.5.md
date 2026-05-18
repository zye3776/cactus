# Story 2.5: ModelCatalog (bookmark store + can-open probe)

**Epic:** 2 — Headless Core
**Status:** in_progress
**Owner:** story-executor-2.5

## User Story

As the **Settings UI later**,
I want **an actor that validates a chosen model file via a cheap "can-open" probe and persists its security-scoped bookmark**,
So that **invalid file selections fail synchronously in Settings, not at first-hotkey time**.

## Acceptance Criteria

1. `apps/CactusVoice/CactusVoice/Permissions/ModelCatalog.swift` declares `actor ModelCatalog`.
2. The actor exposes a top-level `enum ModelKind { case whisper, llm, vad }`.
3. The actor exposes a top-level `enum ValidationResult { case ok(bookmark: Data); case failed(reason: String) }`.
4. The actor exposes:
   `func validate(_ url: URL, kind: ModelKind) async -> ValidationResult`
   - First checks `FileManager.default.fileExists(atPath:)` → on miss returns `.failed(reason: "file not found")`.
   - Calls `PermissionsCoordinator.makeBookmark(for: url)` → on throw returns `.failed(reason: "load failed")`.
   - Calls the injected `ModelLoading.load(path:kind:)` → on success immediately calls `ModelLoading.free(_:)` and returns `.ok(bookmark:)`.
   - On a load failure status indicating an unsupported model format
     (`cactus_status_err_unsupported = 4`) returns `.failed(reason: "unsupported format")`.
   - On any other load failure returns `.failed(reason: "load failed")`.
5. Failure reasons are **exactly one of**:
   `"file not found"`, `"unsupported format"`, `"load failed"` (matches UX-DR8).
6. The probe never holds a model handle in memory longer than the probe call —
   `ModelLoading.free(_:)` is called before `validate` returns, on every success path.
7. The FFI seam is a Swift `protocol ModelLoading` declared inside `ModelCatalog.swift`,
   with a default `FFIShimModelLoader` actor/struct that wraps `FFIShim.loadModel` +
   `FFIShim.freeModel`. `ModelCatalog.init` takes
   `(permissions: PermissionsCoordinator, loader: ModelLoading = FFIShimModelLoader())`.
8. Tests:
   - `apps/CactusVoice/CactusVoiceTests/Permissions/ModelCatalogTests.swift` — runtime
     XCTest (deferred to a host with XCTest). Covers (a) ok path via a stub
     `ModelLoading` returning success, (b) file-not-found path with no FFI call,
     (c) malformed-bytes failure via stub returning load failure → `"load failed"`,
     (d) unsupported-format stub failure → `"unsupported format"`, (e) handle-leak
     check via a stub that counts allocate/free invocations, asserting balance.
   - `apps/CactusVoice/CactusVoiceTests/StoryAcceptance/Story2_5Tests.swift` —
     static grep checks for actor declaration, ModelKind + three cases,
     ValidationResult + `.ok(bookmark:)` + `.failed(reason:)`, the three exact
     failure-reason string literals, `protocol ModelLoading`, init signature.

## Deviation: FFIStub returns `unimplemented` on CLT-only hosts

`FFIShim.loadModel` is wired through `FFIStub.c` (Story 1.2) which returns
`cactus_status_err_unimplemented = 3` until Story 3.1 wires the real cactus
runtime. The default `FFIShimModelLoader` therefore always reports failure on
this host. That is exactly why the protocol seam (`ModelLoading`) exists — the
unit tests inject stub loaders to exercise the ok / unsupported / malformed
paths deterministically without depending on real model files.

## Deviation: status-code mapping for "unsupported format"

`cactus_status_t` is currently
`{ok=0, err_invalid_arg=1, err_io=2, err_unimplemented=3, err_unsupported=4, err_internal=5}`
(from `cactus_c.h`, Story 1.2). `ModelLoading.load` reports a typed `FFIError`
that the catalog inspects: `.unsupportedFormat` maps to
`"unsupported format"`, every other failure maps to `"load failed"`. This
keeps the catalog ignorant of raw C status integers — the protocol layer owns
the translation. `FFIShimModelLoader` reads `CactusStatus.raw` and maps
`4 → .unsupportedFormat`, anything else non-zero → `.loadFailed`.

## Tasks

- [x] T1 — Author this story file.
- [ ] T2 — Acceptance tests (red): `CactusVoiceTests/StoryAcceptance/Story2_5Tests.swift`.
- [ ] T3 — Implement `Permissions/ModelCatalog.swift` (~120-160 LOC) and
       `CactusVoiceTests/Permissions/ModelCatalogTests.swift` (~120 LOC).
- [ ] T4 — `swiftc -typecheck ModelCatalog.swift`: pass (exit 0).
- [ ] T5 — Regenerate `.xcodeproj` via `xcodegen generate`.
- [ ] T6 — KISS pass.

## Dev Notes

- `PermissionsCoordinator` (Story 2.4) already exposes `makeBookmark(for:)`. The
  catalog does **not** call `resolveBookmark` during validation — the freshly
  picked URL is already accessible; the bookmark is for persistence in
  Settings, not for round-trip during the probe.
- The catalog does **not** cache bookmarks (`Data` flows straight back to the
  caller). Caching would duplicate Settings' job and add an eviction policy
  with no testable benefit.
- No FFIShim modification needed; this story uses `FFIShim.loadModel` /
  `FFIShim.freeModel` as-is (Story 1.2 surface).
- `ModelKind` deliberately mirrors `FFIShim.ModelType` but is the
  Catalog-layer-facing name. The default loader maps
  `.whisper → .whisper`, `.llm → .llm`, `.vad → .onnx` (Silero VAD is an
  ONNX model — see architecture §C accuracy revision).
