import Foundation
import Observation
import os

/// Activation mode for the global hotkey.
///
/// - `hold`: capture while the hotkey is held down.
/// - `toggle`: first tap starts capture, second tap (or silence-VAD timeout) stops it.
public enum ActivationMode: String, Codable, Sendable, Equatable {
    case hold
    case toggle
}

/// Persisted application settings.
///
/// One `Codable` blob, encoded as JSON and stored under a single versioned
/// UserDefaults key (`com.cactusvoice.settings.v1`). The struct itself has no
/// dependency on `UserDefaults` — all I/O lives in `SettingsStore`.
///
/// Architecture refs: §A line 174 (UserDefaults via small Codable-backed
/// struct, single accessor); line 175 (security-scoped bookmark Data alongside
/// paths).
///
/// Note on `hotkey`: persisted as the raw shortcut name (`String?`) rather
/// than `KeyboardShortcuts.Name?`. Rationale documented in
/// `_bmad-output/implementation-artifacts/stories/story-1.5.md` (Deviation
/// section). The typed value is available via `Settings.hotkeyName` in
/// `SettingsHotkeyBridge.swift`.
public struct Settings: Codable, Sendable, Equatable {
    /// Raw name of the registered KeyboardShortcuts.Name, or nil if unbound.
    public var hotkey: String?
    public var activationMode: ActivationMode
    public var whisperModelPath: String?
    public var llmModelPath: String?
    public var whisperBookmark: Data?
    public var llmBookmark: Data?

    public init(
        hotkey: String? = nil,
        activationMode: ActivationMode = .hold,
        whisperModelPath: String? = nil,
        llmModelPath: String? = nil,
        whisperBookmark: Data? = nil,
        llmBookmark: Data? = nil
    ) {
        self.hotkey = hotkey
        self.activationMode = activationMode
        self.whisperModelPath = whisperModelPath
        self.llmModelPath = llmModelPath
        self.whisperBookmark = whisperBookmark
        self.llmBookmark = llmBookmark
    }
}

/// UserDefaults key namespace. One JSON blob, versioned suffix.
///
/// A migration scaffold is intentionally deferred — a future story will
/// introduce v2 only when a real schema change appears (KISS).
public enum SettingsKeys {
    public static let blob = "com.cactusvoice.settings.v1"
}

/// The single read/write owner of `Settings` in UserDefaults.
///
/// This is the *only* file in the project that imports / references
/// `Foundation.UserDefaults` — Story 1.5 AC3. Other modules read settings via
/// this `@Observable` mirror so SwiftUI views re-render automatically.
@MainActor
@Observable
public final class SettingsStore {
    /// The current settings. Setter writes through to the underlying defaults
    /// store synchronously.
    public var current: Settings {
        didSet { persist(current) }
    }

    @ObservationIgnored
    private let defaults: UserDefaults

    @ObservationIgnored
    private let log = Logger(subsystem: "com.cactusvoice", category: "SettingsStore")

    /// - Parameter defaults: injection seam for tests. Pass
    ///   `UserDefaults(suiteName:)` in tests to isolate from the user store.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.current = Self.load(from: defaults, log: log)
    }

    private static func load(from defaults: UserDefaults, log: Logger) -> Settings {
        guard let data = defaults.data(forKey: SettingsKeys.blob) else {
            return Settings()
        }
        do {
            return try JSONDecoder().decode(Settings.self, from: data)
        } catch {
            // Log once at creation site (Story 1.4 convention) and fall back.
            // User content (the corrupted blob) is not interpolated.
            log.error("settings decode failed; falling back to defaults")
            return Settings()
        }
    }

    private func persist(_ value: Settings) {
        do {
            let data = try JSONEncoder().encode(value)
            defaults.set(data, forKey: SettingsKeys.blob)
        } catch {
            log.error("settings encode failed; in-memory value retained")
        }
    }
}
