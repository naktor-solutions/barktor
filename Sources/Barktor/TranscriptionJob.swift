import Foundation

// One unit of background ASR work, persisted to disk before processing so a
// crash or quit never loses audio. On-disk layout (owned by
// TranscriptionQueue): Queue/<id>/job.json plus the job's audio — mic.wav
// (+ system.wav) for meetings, audio.wav for dropped files. History retries
// own no audio: they read the entry's WAV from History's audio directory.
//
// The engine choice is FROZEN here at enqueue time. Resolving it lazily
// would silently switch the engine when the app relaunches mid-queue with
// different Settings.
struct TranscriptionJob: Codable, Equatable, Identifiable {
    struct MeetingPayload: Codable, Equatable {
        let recordedAt: Date
        let duration: TimeInterval
        let hasSystemTrack: Bool
    }

    struct FilePayload: Codable, Equatable {
        let entryID: UUID
        let sourceFilename: String
        let duration: TimeInterval
        let isRetry: Bool
    }

    enum Payload: Codable, Equatable {
        case meeting(MeetingPayload)
        case file(FilePayload)
    }

    let id: UUID
    let createdAt: Date
    let engine: SettingsStore.Engine
    let whisperModel: String
    let payload: Payload
}
