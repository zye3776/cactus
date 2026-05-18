import Foundation
import KeyboardShortcuts

/// Bridges the persistence layer (`Settings.hotkey: String?`) to the typed
/// `KeyboardShortcuts.Name?` consumed by the HotkeyManager.
///
/// Kept out of `Settings.swift` so that the persistence file can typecheck
/// against Foundation alone (no SPM dependency), per the Story 1.5 deviation
/// rationale. `KeyboardShortcuts.Name` is `RawRepresentable<String>`, so the
/// raw-name round-trip is lossless.
extension Settings {
    /// Typed hotkey name, derived from / written to the persisted raw `hotkey`.
    public var hotkeyName: KeyboardShortcuts.Name? {
        get {
            guard let raw = hotkey else { return nil }
            return KeyboardShortcuts.Name(raw)
        }
        set {
            hotkey = newValue?.rawValue
        }
    }
}
