# Story 2.4: PermissionsCoordinator (mic + security-scoped bookmarks)

**Epic:** 2 — Headless Core
**Status:** done
**Owner:** story-executor-2.4

## User Story

As **any component needing mic or file access**,
I want **one actor that owns mic permission state and security-scoped bookmark resolution**,
So that **the OS dialog and the bookmark plumbing don't sprawl across components**.

## Acceptance Criteria

1. `apps/CactusVoice/CactusVoice/Permissions/PermissionsCoordinator.swift` declares `actor PermissionsCoordinator`.
2. `func ensureMicPermission() async throws -> Void`:
   - Reads `AVCaptureDevice.authorizationStatus(for: .audio)`.
   - If `.notDetermined` → `await AVCaptureDevice.requestAccess(for: .audio)` and re-reads status.
   - If `.denied` or `.restricted` → throws `AppError.micDenied`.
   - Mid-session revoke: the next call re-reads status freshly (no cache) and throws `.micDenied` accordingly.
3. `func resolveBookmark(_ data: Data) async throws -> URL`:
   - Resolves via `URL(resolvingBookmarkData:options:.withSecurityScope, relativeTo:nil, bookmarkDataIsStale: &stale)`.
   - Calls `url.startAccessingSecurityScopedResource()` before returning.
   - On resolution failure throws `AppError.modelLoadFailed(path:, reason:)` with `reason = "bookmark resolution failed"` (path = empty string when URL is unavailable).
4. `func release(_ url: URL)` calls `url.stopAccessingSecurityScopedResource()`.
5. `func makeBookmark(for url: URL) async throws -> Data` returns `url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)`.
6. **No other file in the project may call** `AVCaptureDevice.requestAccess` or `URL.startAccessingSecurityScopedResource`. Enforced by a grep-based script `apps/CactusVoice/Scripts/check-permission-boundaries.sh` that:
   - Scans `apps/CactusVoice/CactusVoice/` for the two forbidden identifiers.
   - Allows hits only inside `Permissions/PermissionsCoordinator.swift`.
   - Exits 1 on any offending match, 0 otherwise.
   - Per global rule the script is **not** chmod +x — it must be invoked as `bash apps/CactusVoice/Scripts/check-permission-boundaries.sh`. This is the CI-check stub for the rule in architecture §E.
7. Tests:
   - `apps/CactusVoice/CactusVoiceTests/Permissions/PermissionsCoordinatorTests.swift` — runtime XCTest (deferred to host with XCTest, same as other stories). Covers `makeBookmark` + `resolveBookmark` round-trip on a real file in `NSTemporaryDirectory()`; `release` no-crash on a URL whose accessing was never started; `ensureMicPermission` no-crash when current authorization is `.authorized` (otherwise the test is skipped — requires the user-facing OS dialog).
   - `apps/CactusVoice/CactusVoiceTests/StoryAcceptance/Story2_4Tests.swift` — static grep checks (actor declaration, four async funcs, boundary script existence + content, `AppError.micDenied` reference, exclusive ownership of the two forbidden identifiers).

## Deviation: bookmark round-trip requires sandboxing

`url.bookmarkData(options: .withSecurityScope, ...)` is a privileged form of bookmark — it succeeds only in a process that has the `com.apple.security.files.bookmarks.app-scope` entitlement (the CactusVoice app target sets this in `CactusVoice.entitlements`). When the unit-test bundle runs unsandboxed under `xcodebuild test` (the common case), the security-scoped bookmark API still works on `NSTemporaryDirectory()` files because the test host inherits the app's entitlements; outside that host (e.g. running the source file with `swift test` without the project) the API would fail.

The `PermissionsCoordinatorTests.makeBookmark + resolveBookmark round-trip` test therefore documents this requirement and falls back to `XCTSkip` if `makeBookmark` raises a "user lacks permission to access the file" error so the test does not falsely fail outside the proper test host.

## Deviation: grep-based check, not a true linter

The CI-check stub is intentionally a grep — not a swift-syntax or SwiftLint custom rule — because (a) the rule is a single textual identifier match (b) we have no other lint config in the repo yet (c) a developer can run it in two seconds with `bash apps/CactusVoice/Scripts/check-permission-boundaries.sh`. When Story 1.4's deferred linter lands (`Errors/README.md`), this rule can be folded into it.

## Tasks

- [x] T1 — Author this story file.
- [x] T2 — Acceptance tests (red): `CactusVoiceTests/StoryAcceptance/Story2_4Tests.swift`.
- [x] T3 — Implement `Permissions/PermissionsCoordinator.swift` (127 LOC) + `Scripts/check-permission-boundaries.sh` (37 LOC) + `CactusVoiceTests/Permissions/PermissionsCoordinatorTests.swift` (75 LOC).
- [x] T4 — `swiftc -typecheck` PermissionsCoordinator.swift: pass (exit 0).
- [x] T5 — Run boundary script: exits 0.
- [x] T6 — Regenerate `.xcodeproj` via `xcodegen generate`.
- [x] T7 — KISS pass: no refactor commit needed.

## Dev Notes

- AppError.micDenied already exists (Story 1.4) → no AppError changes needed.
- AppError.modelLoadFailed(path:, reason:) is the closest match for bookmark-resolve failure; using `reason = "bookmark resolution failed"` keeps the error surface minimal (no AppError extension).
- The actor does **not** cache `authorizationStatus` per AC2 ("re-reads every call"). This is required to surface mid-session revoke.
- `resolveBookmark` ignores `stale = true` for v1 — Settings UI in a later story can detect staleness and re-prompt the user; the coordinator just resolves and returns the URL.
