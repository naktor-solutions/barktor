import Combine
import Foundation
import Testing

@testable import Barktor

// Deterministic engine for queue tests. Tracks concurrency so the
// one-job-at-a-time guarantee is provable, and replays scripted progress.
@MainActor
final class FakeEngine: TranscriptionEngine {
    nonisolated let supportsStreaming = false
    var transcript = "hola mundo"
    var shouldThrow = false
    var delay: Duration = .zero
    var progressSteps: [Double] = []
    // Configurable so tests can exercise the "Warming up" → "Transcribing"
    // stage transition (Fix E) without a real cold engine.
    var warm = true
    private(set) var calls = 0
    private var inFlight = 0
    private(set) var maxInFlight = 0

    func warmup() async {}
    func isWarm() async -> Bool { warm }

    func transcribe(samples: [Float]) async throws -> String {
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        defer { inFlight -= 1 }
        calls += 1
        if delay > .zero { try? await Task.sleep(for: delay) }
        if shouldThrow { throw EngineError.notLoaded }
        return transcript
    }

    func transcribe(
        samples: [Float], progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        for step in progressSteps { progress(step) }
        return try await transcribe(samples: samples)
    }

    func transcribeDetailed(samples: [Float]) async throws -> DetailedTranscription {
        let text = try await transcribe(samples: samples)
        return DetailedTranscription(
            text: text, tokens: [], duration: Double(samples.count) / 16_000)
    }

    func transcribeDetailed(
        samples: [Float], progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DetailedTranscription {
        for step in progressSteps { progress(step) }
        return try await transcribeDetailed(samples: samples)
    }

    func makeStreamingSession() async throws -> any StreamingSession {
        throw EngineError.streamingNotSupported(engineName: "Fake")
    }
}

@MainActor
final class SpyNotifier: Notifying {
    private(set) var permissionRequests = 0
    private(set) var meetingDone: [(title: String, revealURL: URL)] = []
    private(set) var fileDone: [String] = []
    private(set) var failures: [(message: String, revealURL: URL?, opensHistory: Bool)] = []

    func requestPermissionIfNeeded() { permissionRequests += 1 }
    func notifyMeetingDone(title: String, revealURL: URL) {
        meetingDone.append((title, revealURL))
    }
    func notifyFileDone(filename: String) { fileDone.append(filename) }
    func notifyFailure(message: String, revealURL: URL?, opensHistory: Bool) {
        failures.append((message, revealURL, opensHistory))
    }
}

@MainActor
struct TranscriptionQueueTests {
    // Fresh queue + history over temp dirs; retention pinned to .week.
    private func makeWorld() -> (
        queue: TranscriptionQueue, history: HistoryStore, engine: FakeEngine,
        notifier: SpyNotifier, dir: URL
    ) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-\(UUID().uuidString)", isDirectory: true)
        let history = HistoryStore(
            directory: base.appendingPathComponent("history", isDirectory: true))
        history.retentionProvider = { .week }
        let queue = TranscriptionQueue(
            directory: base.appendingPathComponent("queue", isDirectory: true),
            history: history)
        let engine = FakeEngine()
        let notifier = SpyNotifier()
        queue.engineResolver = { _, _ in (engine, "Fake") }
        queue.postProcess = { raw, _ in raw.uppercased() }
        queue.notifier = notifier
        return (queue, history, engine, notifier, base)
    }

    private func queuedEntry(_ history: HistoryStore, id: UUID = UUID()) -> DictationEntry {
        let entry = DictationEntry(
            id: id, date: Date(), duration: 2.0, rawText: nil, processedText: nil,
            engineUsed: "parakeet", mode: .batch, status: .queued, errorMessage: nil,
            audioFilename: nil, sourceFilename: "drop.m4a")
        history.add(entry)
        return entry
    }

    // Writes the decoded WAV a drop would have produced into the job dir.
    private func stageAudio(_ queue: TranscriptionQueue, jobID: UUID) throws {
        let dir = queue.jobDirectory(jobID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try WAVFile.write(
            samples: [Float](repeating: 0.2, count: 16_000),
            to: dir.appendingPathComponent("audio.wav"))
    }

    @Test func fileJobCompletesEntryAndAdoptsAudio() async throws {
        let (queue, history, _, notifier, dir) = makeWorld()
        defer { try? FileManager.default.removeItem(at: dir) }
        let entry = queuedEntry(history)
        let jobID = UUID()
        try stageAudio(queue, jobID: jobID)
        try queue.enqueueFile(
            jobID: jobID, entryID: entry.id, sourceFilename: "drop.m4a", duration: 1,
            engine: .parakeet, whisperModel: "", isRetry: false)
        await queue.waitUntilIdle()

        let updated = history.entries.first { $0.id == entry.id }
        #expect(updated?.status == .ok)
        #expect(updated?.rawText == "hola mundo")
        #expect(updated?.processedText == "HOLA MUNDO")
        #expect(updated?.engineUsed == "parakeet")
        // Retention .week → the WAV moved into History's audio dir.
        #expect(updated?.audioFilename == "\(entry.id.uuidString).wav")
        #expect(history.audioURL(for: updated!) != nil)
        // Job dir cleaned up; completion notified; queue idle again.
        #expect(!FileManager.default.fileExists(atPath: queue.jobDirectory(jobID).path))
        #expect(notifier.fileDone == ["drop.m4a"])
        #expect(queue.state == .idle)
        #expect(queue.activeEntryIDs.isEmpty)
    }

    @Test func retentionNeverDropsAudioInsteadOfAdopting() async throws {
        let (queue, history, _, _, dir) = makeWorld()
        defer { try? FileManager.default.removeItem(at: dir) }
        history.retentionProvider = { .never }
        let entry = queuedEntry(history)
        let jobID = UUID()
        try stageAudio(queue, jobID: jobID)
        try queue.enqueueFile(
            jobID: jobID, entryID: entry.id, sourceFilename: "drop.m4a", duration: 1,
            engine: .parakeet, whisperModel: "", isRetry: false)
        await queue.waitUntilIdle()
        let updated = history.entries.first { $0.id == entry.id }
        #expect(updated?.status == .ok)
        #expect(updated?.audioFilename == nil)
    }

    @Test func jobsRunFIFOAndNeverConcurrently() async throws {
        let (queue, history, engine, _, dir) = makeWorld()
        defer { try? FileManager.default.removeItem(at: dir) }
        engine.delay = .milliseconds(30)
        var ids: [UUID] = []
        for _ in 0..<3 {
            let entry = queuedEntry(history)
            let jobID = UUID()
            try stageAudio(queue, jobID: jobID)
            try queue.enqueueFile(
                jobID: jobID, entryID: entry.id, sourceFilename: "f.wav", duration: 1,
                engine: .parakeet, whisperModel: "", isRetry: false)
            ids.append(entry.id)
        }
        #expect(queue.activeEntryIDs == Set(ids))
        await queue.waitUntilIdle()
        #expect(engine.calls == 3)
        #expect(engine.maxInFlight == 1)  // serial, always
    }

    @Test func failedJobMarksEntryFailedAndNotifies() async throws {
        let (queue, history, engine, notifier, dir) = makeWorld()
        defer { try? FileManager.default.removeItem(at: dir) }
        engine.shouldThrow = true
        let entry = queuedEntry(history)
        let jobID = UUID()
        try stageAudio(queue, jobID: jobID)
        try queue.enqueueFile(
            jobID: jobID, entryID: entry.id, sourceFilename: "drop.m4a", duration: 1,
            engine: .parakeet, whisperModel: "", isRetry: false)
        await queue.waitUntilIdle()
        let updated = history.entries.first { $0.id == entry.id }
        #expect(updated?.status == .failed)
        #expect(updated?.errorMessage?.isEmpty == false)
        // Audio still adopted so Retry stays possible after a failure.
        #expect(updated?.audioFilename != nil)
        #expect(notifier.failures.count == 1)
        // A failed drop's natural landing spot is its .failed row in History.
        #expect(notifier.failures.first?.opensHistory == true)
        #expect(!FileManager.default.fileExists(atPath: queue.jobDirectory(jobID).path))
    }

    @Test func retryJobReadsHistoryAudioAndEndsRetry() async throws {
        let (queue, history, _, _, dir) = makeWorld()
        defer { try? FileManager.default.removeItem(at: dir) }
        // An existing OK entry with saved audio, like a real dictation.
        let id = UUID()
        history.add(
            DictationEntry(
                id: id, date: Date(), duration: 2.0, rawText: "old", processedText: "old",
                engineUsed: "parakeet", mode: .batch, status: .ok, errorMessage: nil,
                audioFilename: "\(id.uuidString).wav"))
        try FileManager.default.createDirectory(
            at: history.audioDirectory, withIntermediateDirectories: true)
        try WAVFile.write(
            samples: [Float](repeating: 0.2, count: 16_000),
            to: history.audioDirectory.appendingPathComponent("\(id.uuidString).wav"))
        #expect(history.beginRetry(id))
        try queue.enqueueFile(
            jobID: UUID(), entryID: id, sourceFilename: "retry", duration: 2,
            engine: .parakeet, whisperModel: "", isRetry: true)
        await queue.waitUntilIdle()
        let updated = history.entries.first { $0.id == id }
        #expect(updated?.rawText == "hola mundo")
        #expect(updated?.status == .ok)
        // The queue released the retry gate when the job finished.
        #expect(history.retryingEntryIDs.isEmpty)
        // Retry audio stays where it was — still exportable.
        #expect(updated?.audioFilename == "\(id.uuidString).wav")
    }

    @Test func retryWithVanishedAudioFailsClean() async throws {
        let (queue, history, engine, _, dir) = makeWorld()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        history.add(
            DictationEntry(
                id: id, date: Date(), duration: 2.0, rawText: "old", processedText: "old",
                engineUsed: "parakeet", mode: .batch, status: .ok, errorMessage: nil,
                audioFilename: "\(id.uuidString).wav"))  // file never written
        #expect(history.beginRetry(id))
        try queue.enqueueFile(
            jobID: UUID(), entryID: id, sourceFilename: "retry", duration: 2,
            engine: .parakeet, whisperModel: "", isRetry: true)
        await queue.waitUntilIdle()
        #expect(engine.calls == 0)
        #expect(history.entries.first { $0.id == id }?.status == .failed)
        #expect(history.retryingEntryIDs.isEmpty)
    }

    @Test func scanResumesPersistedJobsOldestFirst() async throws {
        let (queue, history, engine, _, dir) = makeWorld()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Two entries + jobs persisted, then a "relaunch": a second queue over
        // the same directory picks both up in createdAt order.
        var entryIDs: [UUID] = []
        for _ in 0..<2 {
            let entry = queuedEntry(history)
            let jobID = UUID()
            try stageAudio(queue, jobID: jobID)
            try queue.enqueueFile(
                jobID: jobID, entryID: entry.id, sourceFilename: "f.wav", duration: 1,
                engine: .parakeet, whisperModel: "", isRetry: false)
            entryIDs.append(entry.id)
        }
        // Simulate crash-before-processing: fresh queue, same disk.
        let revived = TranscriptionQueue(directory: queue.directory, history: history)
        revived.engineResolver = { _, _ in (engine, "Fake") }
        revived.postProcess = { raw, _ in raw }
        revived.notifier = SpyNotifier()
        // Note: the first queue is still draining; wait for it so the fake
        // engine's counters only reflect the revived queue.
        await queue.waitUntilIdle()
        let callsAfterFirst = engine.calls
        revived.scanAndResume()
        await revived.waitUntilIdle()
        // Jobs were already processed and their dirs removed by the first
        // queue, so the revived scan found nothing — now test the real case:
        // persist a job WITHOUT letting a worker touch it.
        #expect(engine.calls == callsAfterFirst)

        let entry = queuedEntry(history)
        let jobID = UUID()
        try stageAudio(revived, jobID: jobID)
        // Write job.json by hand — enqueueFile would start the worker.
        let job = TranscriptionJob(
            id: jobID, createdAt: Date(), engine: .parakeet, whisperModel: "",
            payload: .file(
                .init(entryID: entry.id, sourceFilename: "f.wav", duration: 1, isRetry: false)))
        try JSONEncoder().encode(job).write(
            to: revived.jobDirectory(jobID).appendingPathComponent("job.json"))
        let cold = TranscriptionQueue(directory: revived.directory, history: history)
        cold.engineResolver = { _, _ in (engine, "Fake") }
        cold.postProcess = { raw, _ in raw }
        cold.notifier = SpyNotifier()
        cold.scanAndResume()
        await cold.waitUntilIdle()
        #expect(engine.calls == callsAfterFirst + 1)
        #expect(history.entries.first { $0.id == entry.id }?.status == .ok)
    }

    @Test func scanFailsOrphanedEntries() async throws {
        let (queue, history, _, _, dir) = makeWorld()
        defer { try? FileManager.default.removeItem(at: dir) }
        let orphan = queuedEntry(history)  // .queued but no job on disk
        queue.scanAndResume()
        await queue.waitUntilIdle()
        let updated = history.entries.first { $0.id == orphan.id }
        #expect(updated?.status == .failed)
        #expect(updated?.errorMessage?.isEmpty == false)
    }

    @Test func progressUpdatesStateFraction() async throws {
        let (queue, history, engine, _, dir) = makeWorld()
        defer { try? FileManager.default.removeItem(at: dir) }
        engine.progressSteps = [0.5]
        engine.delay = .milliseconds(50)
        var fractions: [Double] = []
        let cancellable = queue.$state.sink { state in
            if case .processing(_, _, let fraction?, _) = state { fractions.append(fraction) }
        }
        defer { cancellable.cancel() }
        let entry = queuedEntry(history)
        let jobID = UUID()
        try stageAudio(queue, jobID: jobID)
        try queue.enqueueFile(
            jobID: jobID, entryID: entry.id, sourceFilename: "f.wav", duration: 1,
            engine: .parakeet, whisperModel: "", isRetry: false)
        await queue.waitUntilIdle()
        #expect(fractions.contains(0.5))
        #expect(queue.state == .idle)
    }

    // Fix E: a cold engine should show "Warming up" until its first real
    // progress signal, then flip to "Transcribing" — never a misleading
    // "Transcribing" while the model is still loading.
    @Test func coldEngineWarmsUpThenTranscribes() async throws {
        let (queue, history, engine, _, dir) = makeWorld()
        defer { try? FileManager.default.removeItem(at: dir) }
        engine.warm = false
        engine.progressSteps = [0.5]
        engine.delay = .milliseconds(30)
        var stages: [String] = []
        let cancellable = queue.$state.sink { state in
            if case .processing(_, let stage, _, _) = state { stages.append(stage) }
        }
        defer { cancellable.cancel() }
        let entry = queuedEntry(history)
        let jobID = UUID()
        try stageAudio(queue, jobID: jobID)
        try queue.enqueueFile(
            jobID: jobID, entryID: entry.id, sourceFilename: "f.wav", duration: 1,
            engine: .parakeet, whisperModel: "", isRetry: false)
        await queue.waitUntilIdle()
        let warmingUpIndex = stages.firstIndex(of: "Warming up")
        let transcribingIndex = stages.lastIndex(of: "Transcribing")
        #expect(warmingUpIndex != nil)
        #expect(transcribingIndex != nil)
        if let w = warmingUpIndex, let t = transcribingIndex {
            #expect(w < t)
        }
    }

    // Fix F: HistoryStore.deleteAll() mid-job must not resurrect a WAV for an
    // entry that no longer exists — adoptAudioIntoHistory guards on the entry
    // still being present.
    @Test func deleteAllMidJobLeavesNoOrphanWAV() async throws {
        let (queue, history, engine, _, dir) = makeWorld()
        defer { try? FileManager.default.removeItem(at: dir) }
        engine.delay = .milliseconds(30)
        let entry = queuedEntry(history)
        let jobID = UUID()
        try stageAudio(queue, jobID: jobID)
        try queue.enqueueFile(
            jobID: jobID, entryID: entry.id, sourceFilename: "drop.m4a", duration: 1,
            engine: .parakeet, whisperModel: "", isRetry: false)
        history.deleteAll()
        await queue.waitUntilIdle()
        let audioDir = history.audioDirectory
        let names =
            (try? FileManager.default.contentsOfDirectory(atPath: audioDir.path)) ?? []
        #expect(names.isEmpty)
        #expect(history.entries.isEmpty)
    }
}
