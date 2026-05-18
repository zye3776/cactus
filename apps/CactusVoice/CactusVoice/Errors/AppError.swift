import Foundation

/// The stage of the inference pipeline an `inferenceFailed` originated in.
public enum InferenceStage: String, Sendable, Equatable {
    case audio
    case whisper
    case vad
    case llm
    case correction
}

/// The single error type for every UI-visible failure in CactusVoice.
///
/// Per architecture §G and §4: errors are mapped to `AppError` at the seam
/// where they leave their owning actor, logged at `.error` exactly once at
/// the creation site (never re-logged on re-throw), and rendered by
/// `ErrorBanner` via an exhaustive switch on the case.
///
/// `errorDescription` returns a declarative, ≤ 8-word banner string per
/// UX-DR6 / ux-design-specification.md §11 ("Error sentences: declarative,
/// action-oriented, ≤ 8 words. No exclamation marks.").
public enum AppError: Error, LocalizedError, Equatable, Sendable {
    case micDenied
    case modelLoadFailed(path: String, reason: String)
    case inferenceFailed(stage: InferenceStage, reason: String)
    case clipboardWriteFailed
    case hotkeyConflict(existing: String)
    case vadLoadFailed(reason: String)
    case correctionFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .micDenied:
            return "Microphone access required."
        case .modelLoadFailed:
            return "Couldn't load model file."
        case .inferenceFailed(let stage, _):
            switch stage {
            case .audio:      return "Audio capture failed."
            case .whisper:    return "Transcription failed."
            case .vad:        return "Voice detection failed."
            case .llm:        return "Rewrite failed."
            case .correction: return "Correction failed."
            }
        case .clipboardWriteFailed:
            return "Couldn't copy to clipboard."
        case .hotkeyConflict:
            return "Hotkey already in use."
        case .vadLoadFailed:
            return "Couldn't load VAD model."
        case .correctionFailed:
            return "Correction step failed."
        }
    }
}
