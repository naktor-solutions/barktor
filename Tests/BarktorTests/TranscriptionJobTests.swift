import Foundation
import Testing

@testable import Barktor

struct TranscriptionJobTests {
    @Test func meetingJobRoundTrips() throws {
        let job = TranscriptionJob(
            id: UUID(), createdAt: Date(),
            engine: .whisper, whisperModel: "openai_whisper-large-v3-v20240930_turbo",
            payload: .meeting(.init(recordedAt: Date(), duration: 3600, hasSystemTrack: true)))
        let data = try JSONEncoder().encode(job)
        let back = try JSONDecoder().decode(TranscriptionJob.self, from: data)
        #expect(back == job)
    }

    @Test func fileJobRoundTrips() throws {
        let job = TranscriptionJob(
            id: UUID(), createdAt: Date(),
            engine: .parakeet, whisperModel: "",
            payload: .file(.init(
                entryID: UUID(), sourceFilename: "nota.m4a", duration: 42, isRetry: true)))
        let data = try JSONEncoder().encode(job)
        let back = try JSONDecoder().decode(TranscriptionJob.self, from: data)
        #expect(back == job)
    }
}
