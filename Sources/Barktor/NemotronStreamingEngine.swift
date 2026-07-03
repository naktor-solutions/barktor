import FluidAudio
import Foundation
import os.log

// NVIDIA Nemotron-3.5-ASR multilingual streaming via FluidAudio. Where
// ParakeetEngine juggles two model families (a batch `AsrManager` + the
// English-only EOU streaming model), this wraps a single
// `StreamingNemotronMultilingualAsrManager` that does BOTH batch and live
// streaming for 40 language-locales incl. Spanish. It is the first Barktor
// engine that streams a non-English language, so it's the only multilingual
// engine that supports Smart Typing.
//
// The multilingual model has NO auto-EOU (silence) detector — unlike the
// Parakeet EOU model. So a streaming session finalizes on hotkey release:
// one utterance per hold, append-only partials while speaking (verified in
// the spike), and PostProcessor runs once at the end.
//
// The ~612 MB INT8 CoreML weights (encoder on the ANE) download on demand
// from FluidInference's HuggingFace repo into Barktor's own models folder,
// so uninstalling reclaims them.
@MainActor
final class NemotronStreamingEngine: TranscriptionEngine {
    nonisolated let supportsStreaming = true

    // es-ES is fixed for this first cut (a language picker is a follow-up). The
    // model still auto-detects, but pinning the prompt_id improves recall.
    private let languageCode: String
    // 1120 ms is the model's trained chunk (balanced latency/throughput); the
    // spike measured ~14 ms compute per chunk and append-only partials here.
    private static let chunkMs = 1120

    init(languageCode: String = "es-ES") {
        self.languageCode = languageCode
    }

    private var manager: StreamingNemotronMultilingualAsrManager?
    // Single in-flight download+load so a warm-up and a Settings-button tap
    // coalesce onto one ~612 MB pull instead of racing two into the same dir.
    private var loadTask: Task<Void, Error>?
    // 0..1 while the model downloads, nil otherwise — wired to a @Published so
    // the Settings card shows a live bar for both warm-up and manual downloads.
    var onProgress: ((Double?) -> Void)?
    private var downloadActive = false
    private let log = Logger(subsystem: "com.naktor.barktor", category: "nemotron")

    func isWarm() async -> Bool { manager != nil }

    // Mirror ParakeetEngine's EOU policy: warm-up loads from disk if present but
    // NEVER downloads. The 612 MB pull happens only from the Settings card, so a
    // cold first dictation never stalls on a big download.
    func warmup() async {
        guard Self.isInstalled else { return }
        do {
            try await downloadAndLoad()
        } catch {
            log.error("Nemotron warmup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // Coalesced download + load. Concurrent callers (warm-up + Settings button)
    // share one in-flight task instead of pulling the model twice.
    func downloadAndLoad() async throws {
        if manager != nil { return }
        if let inFlight = loadTask {
            try await inFlight.value
            return
        }
        let task = Task { [weak self] () throws -> Void in
            try await self?.load()
        }
        loadTask = task
        defer { if loadTask == task { loadTask = nil } }
        try await task.value
    }

    private func load() async throws {
        let willDownload = !Self.isInstalled
        if willDownload {
            downloadActive = true
            onProgress?(0)
        }
        defer {
            if willDownload {
                downloadActive = false
                onProgress?(nil)
            }
        }
        let progressHandler: DownloadUtils.ProgressHandler? = { [weak self] progress in
            let fraction = progress.fractionCompleted
            Task { @MainActor in
                guard let self, self.downloadActive else { return }
                self.onProgress?(fraction)
            }
        }
        // downloadVariant nests <base>/<langDir>/<chunk>ms and returns that leaf.
        let dir = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
            languageCode: languageCode,
            chunkMs: Self.chunkMs,
            to: Self.baseModelDirectory,
            progressHandler: progressHandler)
        let m = StreamingNemotronMultilingualAsrManager()
        try await m.loadModels(from: dir)
        await m.setLanguage(languageCode)
        try Task.checkCancellation()
        manager = m
        log.info(
            "Nemotron multilingual (\(self.languageCode, privacy: .public)) downloaded and warmed up.")
    }

    // Drops the in-memory CoreML graphs (and cancels an in-flight load) so a
    // subsequent on-disk delete can't leave a stale mmap. MUST run before
    // ModelManager.deleteAllModels.
    func unload() {
        loadTask?.cancel()
        loadTask = nil
        manager = nil
        log.info("Nemotron multilingual unloaded.")
    }

    func transcribe(samples: [Float]) async throws -> String {
        let detailed = try await transcribeDetailed(samples: samples)
        return TranscriptCleaner.clean(detailed.text)
    }

    // Batch = feed the whole clip through the streaming manager, then finish().
    // finishWithTokenTimings carries per-token timings for meeting-mode
    // diarization alignment.
    func transcribeDetailed(samples: [Float]) async throws -> DetailedTranscription {
        if manager == nil { await warmup() }
        guard let m = manager else { throw EngineError.notLoaded }
        await m.reset()
        _ = try await m.process(samples: samples)
        let (text, timings) = try await m.finishWithTokenTimings()
        return DetailedTranscription(
            text: text,
            tokens: timings.map {
                DetailedTranscription.TimedToken(text: $0.token, start: $0.startTime, end: $0.endTime)
            },
            duration: Double(samples.count) / 16_000)
    }

    func makeStreamingSession() async throws -> any StreamingSession {
        // Load from disk if present; otherwise fetch (the streaming path is the
        // one place a download is acceptable, since the HUD shows "warming up").
        if manager == nil { await warmup() }
        if manager == nil { try await downloadAndLoad() }
        guard let m = manager else { throw EngineError.notLoaded }
        // Fresh decoder/cache state per session; the manager is reused across
        // sessions to keep the ~612 MB of CoreML graphs resident.
        await m.reset()
        let session = NemotronStreamingSession(manager: m)
        try await session.start()
        return session
    }

    // Weights live under Barktor's own models folder so uninstalling reclaims
    // them (FluidAudio's default cache would survive an uninstall).
    static var baseModelDirectory: URL {
        ModelManager.modelsDirectory.appendingPathComponent(
            "nemotron-multilingual", isDirectory: true)
    }

    // downloadVariant nests language/chunk subdirs under the base; any non-empty
    // subtree counts as installed (a corrupt partial re-downloads on load).
    static var isInstalled: Bool {
        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                atPath: baseModelDirectory.path)
        else { return false }
        return !contents.isEmpty
    }

    static func deleteAll() throws {
        let url = baseModelDirectory
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

// Streaming session backed by FluidAudio's StreamingNemotronMultilingualAsrManager.
// The multilingual model has no in-stream EOU detector, so — unlike
// StreamingEouAsrSession — we emit exactly one `.endOfUtterance` at `finish()`
// (hotkey release). Partials arrive via `setPartialCallback` with the full
// accumulated transcript; PartialDiff turns each into a clean append-only
// suffix (the decoder is append-only within a hold, verified in the spike).
@MainActor
final class NemotronStreamingSession: StreamingSession {
    nonisolated let events: AsyncStream<StreamingEvent>
    private let continuation: AsyncStream<StreamingEvent>.Continuation
    private let manager: StreamingNemotronMultilingualAsrManager
    private let diff = PartialDiff()
    private let log = Logger(subsystem: "com.naktor.barktor", category: "nemotron.stream")

    init(manager: StreamingNemotronMultilingualAsrManager) {
        self.manager = manager
        var continuation: AsyncStream<StreamingEvent>.Continuation!
        self.events = AsyncStream<StreamingEvent>(bufferingPolicy: .unbounded) { c in
            continuation = c
        }
        self.continuation = continuation
    }

    func start() async throws {
        // Synchronous handler — a Task hop would race finish()'s stream closure
        // and drop the last partial (same reason as StreamingEouAsrSession).
        let diff = self.diff
        let continuation = self.continuation
        await manager.setPartialCallback { full in
            if let suffix = diff.consume(full) {
                continuation.yield(.partial(suffix: suffix))
            }
        }
        log.info("Nemotron streaming session started.")
    }

    func feed(samples: [Float]) async throws {
        // Nemotron's manager takes [Float] directly (no AVAudioPCMBuffer hop).
        _ = try await manager.process(samples: samples)
    }

    func finish() async throws {
        // finish() flushes the padded final chunk (firing one last partial)
        // then returns the full transcript. There's no in-stream EOU, so this
        // trailing boundary is the ONE the consumer runs PostProcessor on.
        let final = try await manager.finish()
        continuation.yield(.endOfUtterance(rawAccumulated: final))
        continuation.finish()
        log.info("Nemotron streaming session finished.")
    }

    func cancel() async {
        continuation.finish()
        // reset() clears decoder + audio buffer state; the CoreML graphs stay
        // resident for the next session.
        await manager.reset()
    }
}
