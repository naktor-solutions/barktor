import Foundation

// Optional LLM pass over batch dictations, applied AFTER the deterministic
// PostProcessor (fillers, voice commands, dictionary) and BEFORE insertion -
// the same order Voice Edit uses. Off by default; every failure path falls
// back to the deterministic text so a dictation is never lost or stalled.

enum LLMPostProcessLevel: String, Codable, CaseIterable, Identifiable {
    case off, cleanup, rewrite
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .cleanup: return "Clean up"
        case .rewrite: return "Rewrite"
        }
    }
    var summary: String {
        switch self {
        case .off: return "Standard cleanup only - fillers, voice commands and dictionary."
        case .cleanup:
            return "Fixes punctuation and false starts and formats spoken lists. Never changes your words."
        case .rewrite: return "Rewrites for clarity, keeping your meaning and language."
        }
    }
}
