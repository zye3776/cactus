//
//  PermissionsCoordinator.swift
//  CactusVoice
//
//  Single actor that owns:
//    1. macOS microphone authorization (AVFoundation) — request, re-check,
//       and mid-session revoke surfacing.
//    2. Security-scoped bookmark mechanics — `makeBookmark`, `resolveBookmark`
//       (with `startAccessingSecurityScopedResource()` already called), and
//       paired `release(_:)` that calls `stopAccessingSecurityScopedResource()`.
//
//  Architecture §E: this file is the ONLY file in the project allowed to
//  call `AVCaptureDevice.requestAccess` or `URL.startAccessingSecurityScopedResource()`.
//  Enforced by `Scripts/check-permission-boundaries.sh` — grep-based,
//  exits 1 on any offending hit elsewhere in `CactusVoice/`.
//
//  No cache: `ensureMicPermission` re-reads `authorizationStatus(for: .audio)`
//  on every call so a user-initiated revoke in System Settings surfaces as
//  `AppError.micDenied` on the next call (AC5 of Story 2.4).
//
//  Error mapping: bookmark resolution failure raises
//  `AppError.modelLoadFailed(path: "", reason: "bookmark resolution failed")`
//  — chosen over extending AppError to keep the surface minimal (Story 1.4).
//
import AVFoundation
import Foundation
import os

public actor PermissionsCoordinator {

    private let log = Logger(subsystem: "com.cactusvoice", category: "permissions")

    public init() {}

    // MARK: - Microphone

    /// Ensure the process holds a granted microphone authorization.
    ///
    /// - `.authorized`     → return.
    /// - `.notDetermined`  → request access (suspends until user responds), then re-read status.
    /// - `.denied` / `.restricted` → throw `AppError.micDenied`.
    ///
    /// Calls re-read status freshly every invocation so a mid-session revoke
    /// surfaces as `.micDenied` on the next call.
    public func ensureMicPermission() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return
        case .notDetermined:
            // Suspends until the user responds to the OS dialog.
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            // Re-read after the dialog resolves.
            let post = AVCaptureDevice.authorizationStatus(for: .audio)
            if post != .authorized {
                log.error("Mic permission denied after request (post-status=\(post.rawValue, privacy: .public))")
                throw AppError.micDenied
            }
        case .denied, .restricted:
            log.error("Mic permission denied (status=\(status.rawValue, privacy: .public))")
            throw AppError.micDenied
        @unknown default:
            log.error("Mic permission unknown status (\(status.rawValue, privacy: .public)); treating as denied")
            throw AppError.micDenied
        }
    }

    // MARK: - Bookmarks

    /// Resolve a security-scoped bookmark blob produced by `makeBookmark(for:)`.
    ///
    /// On success: calls `startAccessingSecurityScopedResource()` on the
    /// resolved URL and returns it. Callers MUST eventually call
    /// `release(_:)` with the same URL to balance the start.
    ///
    /// On failure: throws `AppError.modelLoadFailed(path: "", reason: "bookmark resolution failed")`.
    public func resolveBookmark(_ data: Data) async throws -> URL {
        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            log.error("Bookmark resolve failed: \(error.localizedDescription, privacy: .public)")
            throw AppError.modelLoadFailed(path: "", reason: "bookmark resolution failed")
        }
        if isStale {
            // Non-fatal in v1; Settings UI in a later story can detect staleness
            // and re-prompt the user. We still hand back the URL with access started.
            log.info("Bookmark resolved as stale for path=\(url.path, privacy: .private(mask: .hash))")
        }
        let started = url.startAccessingSecurityScopedResource()
        if !started {
            // Some bookmarks (e.g. files inside the app's own container) return
            // `false` from start-accessing yet are still readable. We log and proceed.
            log.info("startAccessingSecurityScopedResource returned false for path=\(url.path, privacy: .private(mask: .hash))")
        }
        return url
    }

    /// Balance a previous `resolveBookmark` start. Safe to call on a URL whose
    /// access was not actually started — `stopAccessingSecurityScopedResource`
    /// is a no-op in that case.
    public func release(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }

    /// Produce a security-scoped bookmark blob for `url`. Used by Settings's
    /// path-picker flow (Story 2.5 / Settings scene) — the blob is persisted
    /// via SettingsStore (Story 1.5) and round-tripped through
    /// `resolveBookmark` at runtime.
    ///
    /// Requires the `com.apple.security.files.bookmarks.app-scope` entitlement
    /// on the calling process; the CactusVoice app target sets this in
    /// `CactusVoice.entitlements`.
    public func makeBookmark(for url: URL) async throws -> Data {
        return try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }
}
