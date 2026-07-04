import Foundation

// Persisted as JSON. Every field added later MUST be optional (or decoded with a default): a decode failure renames history.json to .bak and starts empty, which silently wipes the user's history on upgrade.
struct DictationEntry: Codable, Identifiable, Equatable {
    enum Mode: String, Codable { case batch, streaming }
    enum Status: String, Codable {
        case ok, failed, interrupted, cancelled, queued, transcribing

        // Forward-compat: an unknown raw value (history.json written by a
        // NEWER Barktor) must not fail the decode — one unknown status would
        // otherwise wipe the whole history to .bak. Unknown maps to .failed:
        // visible and actionable, never silently dropped.
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .failed
        }
    }
    let id: UUID
    let date: Date
    // var, not let: a dropped file's placeholder .queued row is created with
    // duration 0 before decode runs (so the row shows up immediately), then
    // updated to the real value once decode finishes. See
    // AppCoordinator.importAudioFiles.
    var duration: TimeInterval
    var rawText: String?
    var processedText: String?
    var engineUsed: String  // "parakeet" | "parakeet-v3" | "nemotron" | "whisper:<model>"
    let mode: Mode
    var status: Status
    var errorMessage: String?  // set when status == .failed
    var audioFilename: String?  // nil once expired / never written
    // Original filename for entries created from a dropped audio file (B1).
    // nil for dictations. Optional with default: see the decode-wipe warning
    // at the top of this file.
    var sourceFilename: String? = nil

    // Best text available for display/copy: processed wins over raw.
    var displayText: String? { processedText?.isEmpty == false ? processedText : rawText }
}

struct HistoryStats: Equatable {
    let totalWords: Int
    let averageWPM: Double  // words over spoken duration, entries with text only
    let streakDays: Int  // consecutive calendar days with >= 1 entry, ending today
}

enum AudioRetention: String, Codable, CaseIterable, Identifiable {
    case never, day, week, month
    var id: String { rawValue }
    var label: String {
        switch self {
        case .never: return "Never"
        case .day: return "24 hours"
        case .week: return "7 days"
        case .month: return "30 days"
        }
    }
    // nil = keep no audio at all.
    var maxAge: TimeInterval? {
        switch self {
        case .never: return nil
        case .day: return 24 * 3600
        case .week: return 7 * 24 * 3600
        case .month: return 30 * 24 * 3600
        }
    }
}
