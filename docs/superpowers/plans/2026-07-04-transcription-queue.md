# Background Transcription Queue (B9 + B1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** All batch ASR (meeting processing, dropped audio files, history retries) runs through one disk-backed serial queue with menu-bar progress and a system notification on completion, so stopping a long meeting never *feels* like a hang and any audio file can be transcribed by dropping it on History.

**Architecture:** A new `TranscriptionQueue` (@MainActor, ObservableObject) persists each job to `Application Support/Barktor/Queue/<jobID>/` (job.json + WAVs) before processing FIFO, one at a time. `MeetingPipeline.stop()` shrinks to persist-and-enqueue (its `.processing` state disappears — a new meeting can record immediately). Dropped files decode to 16 kHz mono via a new `AudioFileDecoder` and enter History as `.queued` entries. Whisper reports real progress (WhisperKit's per-call `Progress`); completion fires a `UNUserNotificationCenter` notification whose click reveals the transcript in Finder (meetings) or opens History (files).

**Tech Stack:** Swift 5 / SwiftPM, AppKit + SwiftUI islands, Swift Testing (NOT XCTest), WhisperKit, FluidAudio, AVFoundation (AVAudioConverter), UserNotifications.

**Spec:** `docs/superpowers/specs/2026-07-04-transcription-queue-design.md` — read it before starting any task.

## Global Constraints

- Base branch: `feature/transcription-queue` (already exists, tracks `origin/develop`). Final PR targets **develop**, never main.
- Tests: **Swift Testing** (`@Test`, `#expect`), never XCTest. Run with `make test` (CLT-only machine: it carries `-DNO_APPLE_FM` and framework search paths — plain `swift test` FAILS here).
- Build check: `make build` (or `swift build` via `make`); always verify compile before commit.
- Every new `DictationEntry` stored property MUST be optional or have a default — a decode failure renames history.json to .bak and silently wipes the user's history.
- The queue must NEVER borrow the live dictation engine (`AppCoordinator.engine`): WhisperKit does not serialize concurrent transcribes on one instance. Fresh `WhisperEngine` per job; shared `ParakeetEngine`/`NemotronStreamingEngine` are actors and safe.
- Background work runs at QoS `.utility` (`Task.detached(priority: .utility)`).
- No new package dependencies.
- All user-facing copy in English (matches the rest of the app).
- Engine choice is FROZEN into the job at enqueue time (rawValue of `SettingsStore.Engine` + whisper model name) — a relaunch must not change it.
- LLM polish only for file jobs with duration ≤ 300 s (5 min).
- File-drop duration cap: 3 hours.
- Match repo style: `.swift-format` config, comment density like existing files (comments explain *why*, not *what*).
- Commit messages: conventional prefix (`feat:`/`fix:`/`test:`/`refactor:`), plus the session trailer lines used by this repo's recent commits (Co-Authored-By + Claude-Session).
- `TranscriptionQueue` touches no global singletons except through injected closures/params — tests construct their own instance with a temp directory and a temp `HistoryStore`; ONLY the app wires `TranscriptionQueue.shared`.
- Unit tests must never construct the real `Notifier` (UNUserNotificationCenter traps outside an app bundle) — inject the `SpyNotifier` from Task 5.

---

### Task 1: DictationEntry — queue statuses, decode fallback, sourceFilename

**Files:**
- Modify: `Sources/Barktor/DictationEntry.swift`
- Modify: `Sources/Barktor/HistoryView.swift` (statusBadge switch gains 2 cases so the project still compiles)
- Create: `Tests/BarktorTests/DictationEntryStatusTests.swift`

**Interfaces:**
- Produces: `DictationEntry.Status.queued`, `.transcribing`; `DictationEntry.sourceFilename: String?` (default `nil`); `Status` decodes unknown raw values as `.failed`.
- Consumed by: Tasks 6, 9, 10.

- [ ] **Step 1: Write the failing tests**

Create `Tests/BarktorTests/DictationEntryStatusTests.swift`:

```swift
import Foundation
import Testing

@testable import Barktor

struct DictationEntryStatusTests {
    // Minimal JSON for a legacy entry (no sourceFilename, pre-queue status).
    // Dates use the default strategy (seconds since reference date, Double).
    private func entryJSON(status: String) -> Data {
        Data(
            """
            {"id":"11111111-2222-3333-4444-555555555555","date":0,"duration":1.5,
             "engineUsed":"parakeet","mode":"batch","status":"\(status)"}
            """.utf8)
    }

    @Test func unknownStatusDecodesAsFailedInsteadOfThrowing() throws {
        let entry = try JSONDecoder().decode(DictationEntry.self, from: entryJSON(status: "hologram"))
        #expect(entry.status == .failed)
    }

    @Test func queuedAndTranscribingRoundTrip() throws {
        for status in [DictationEntry.Status.queued, .transcribing] {
            let data = try JSONEncoder().encode(status)
            #expect(try JSONDecoder().decode(DictationEntry.Status.self, from: data) == status)
        }
    }

    @Test func legacyJSONWithoutSourceFilenameDecodesNil() throws {
        let entry = try JSONDecoder().decode(DictationEntry.self, from: entryJSON(status: "ok"))
        #expect(entry.sourceFilename == nil)
    }

    @Test func sourceFilenameRoundTrips() throws {
        var entry = try JSONDecoder().decode(DictationEntry.self, from: entryJSON(status: "ok"))
        entry.sourceFilename = "nota-voz.m4a"
        let data = try JSONEncoder().encode(entry)
        let back = try JSONDecoder().decode(DictationEntry.self, from: data)
        #expect(back.sourceFilename == "nota-voz.m4a")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test`
Expected: compile errors — `Status` has no member `queued`, `DictationEntry` has no `sourceFilename`.

- [ ] **Step 3: Implement**

In `Sources/Barktor/DictationEntry.swift`, replace the `Status` enum and add the field:

```swift
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
```

After `var audioFilename: String?` add:

```swift
    // Original filename for entries created from a dropped audio file (B1).
    // nil for dictations. Optional with default: see the decode-wipe warning
    // at the top of this file.
    var sourceFilename: String? = nil
```

In `Sources/Barktor/HistoryView.swift`, `statusBadge`'s switch gains the two new cases (before `case .cancelled` is fine — order doesn't matter, exhaustiveness does):

```swift
            case .queued:
                Label("Queued", systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
            case .transcribing:
                Label("Transcribing…", systemImage: "waveform")
                    .font(.caption).foregroundStyle(.secondary)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: PASS (all suites — HistoryStoreTests keep passing: the memberwise init still accepts the old argument list because `sourceFilename` has a default).

- [ ] **Step 5: Commit**

```bash
git add Sources/Barktor/DictationEntry.swift Sources/Barktor/HistoryView.swift Tests/BarktorTests/DictationEntryStatusTests.swift
git commit -m "feat: queue statuses + sourceFilename on DictationEntry, unknown-status decode fallback"
```

---

### Task 2: TranscriptionJob model

**Files:**
- Create: `Sources/Barktor/TranscriptionJob.swift`
- Create: `Tests/BarktorTests/TranscriptionJobTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct TranscriptionJob: Codable, Equatable, Identifiable {
      struct MeetingPayload: Codable, Equatable { let recordedAt: Date; let duration: TimeInterval; let hasSystemTrack: Bool }
      struct FilePayload: Codable, Equatable { let entryID: UUID; let sourceFilename: String; let duration: TimeInterval; let isRetry: Bool }
      enum Payload: Codable, Equatable { case meeting(MeetingPayload); case file(FilePayload) }
      let id: UUID; let createdAt: Date
      let engine: SettingsStore.Engine   // frozen at enqueue
      let whisperModel: String           // frozen at enqueue
      let payload: Payload
  }
  ```
- Consumed by: Tasks 6, 7.

- [ ] **Step 1: Write the failing test**

Create `Tests/BarktorTests/TranscriptionJobTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`
Expected: compile error — `TranscriptionJob` not defined.

- [ ] **Step 3: Implement**

Create `Sources/Barktor/TranscriptionJob.swift`:

```swift
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
```

Note: dates use the default Codable strategy (Double seconds since the reference date) — it round-trips `Date` bit-for-bit, same rationale as `HistoryStore.dateEncodingStrategy`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Barktor/TranscriptionJob.swift Tests/BarktorTests/TranscriptionJobTests.swift
git commit -m "feat: TranscriptionJob model with frozen engine choice"
```

---

### Task 3: AudioFileDecoder

**Files:**
- Create: `Sources/Barktor/AudioFileDecoder.swift`
- Create: `Tests/BarktorTests/AudioFileDecoderTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum AudioFileDecoderError: LocalizedError { case unreadable(String), tooLong(TimeInterval, limit: TimeInterval), empty }
  enum AudioFileDecoder {
      static let maxDuration: TimeInterval  // 3 * 3600
      static func decode16kMono(url: URL, maxDuration: TimeInterval = AudioFileDecoder.maxDuration) throws -> [Float]
  }
  ```
- Consumed by: Task 9 (`importAudioFiles`).

- [ ] **Step 1: Write the failing tests**

Create `Tests/BarktorTests/AudioFileDecoderTests.swift`. Fixtures are generated programmatically (no binary files in the repo):

```swift
import AVFoundation
import Foundation
import Testing

@testable import Barktor

struct AudioFileDecoderTests {
    private func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("decoder-\(UUID().uuidString).\(ext)")
    }

    // Writes `seconds` of a 440 Hz sine at the given format. AVAudioFile
    // handles the encode (PCM WAV or AAC m4a) via AudioToolbox.
    private func writeFixture(
        to url: URL, seconds: Double, sampleRate: Double, channels: AVAudioChannelCount,
        settings: [String: Any]
    ) throws {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                channels: channels, interleaved: false)
        else { throw AudioFileDecoderError.unreadable("fixture format") }
        let file = try AVAudioFile(
            forWriting: url, settings: settings,
            commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { throw AudioFileDecoderError.unreadable("fixture buffer") }
        buffer.frameLength = frames
        for ch in 0..<Int(channels) {
            let data = buffer.floatChannelData![ch]
            for i in 0..<Int(frames) {
                data[i] = sinf(2 * .pi * 440 * Float(i) / Float(sampleRate)) * 0.5
            }
        }
        try file.write(from: buffer)
    }

    @Test func decodesStereo44kWAVTo16kMono() throws {
        let url = tempURL("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeFixture(
            to: url, seconds: 1.0, sampleRate: 44_100, channels: 2,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
            ])
        let samples = try AudioFileDecoder.decode16kMono(url: url)
        // 1 s of audio → ~16 000 samples (resampler edges allow slack).
        #expect(abs(samples.count - 16_000) < 200)
        // A sine at half amplitude survives the downmix — not silence.
        #expect(samples.contains { abs($0) > 0.1 })
    }

    @Test func decodesM4A() throws {
        let url = tempURL("m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeFixture(
            to: url, seconds: 1.0, sampleRate: 44_100, channels: 1,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
            ])
        let samples = try AudioFileDecoder.decode16kMono(url: url)
        // AAC pads with priming/remainder frames; allow generous slack.
        #expect(abs(samples.count - 16_000) < 2_000)
    }

    @Test func corruptFileThrowsUnreadable() throws {
        let url = tempURL("mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data((0..<1024).map { _ in UInt8.random(in: 0...255) }).write(to: url)
        #expect(throws: (any Error).self) {
            try AudioFileDecoder.decode16kMono(url: url)
        }
    }

    @Test func overlongFileThrowsTooLong() throws {
        let url = tempURL("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeFixture(
            to: url, seconds: 2.0, sampleRate: 16_000, channels: 1,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
            ])
        #expect(throws: (any Error).self) {
            // 2 s fixture against a 1 s cap → .tooLong without a 3-hour fixture.
            try AudioFileDecoder.decode16kMono(url: url, maxDuration: 1.0)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test`
Expected: compile error — `AudioFileDecoder` not defined.

- [ ] **Step 3: Implement**

Create `Sources/Barktor/AudioFileDecoder.swift`:

```swift
import AVFoundation
import Foundation

enum AudioFileDecoderError: LocalizedError {
    case unreadable(String)
    case tooLong(TimeInterval, limit: TimeInterval)
    case empty

    var errorDescription: String? {
        switch self {
        case .unreadable(let detail):
            return "Could not read this audio file (\(detail))."
        case .tooLong(let duration, let limit):
            let hours = Int(duration / 3600)
            let limitHours = Int(limit / 3600)
            return "This file is ~\(hours)h long — the limit is \(limitHours)h."
        case .empty:
            return "This audio file contains no audio."
        }
    }
}

// Decodes any AVAudioFile-readable audio (m4a, mp3, wav, aiff, caf, flac…)
// to the 16 kHz mono Float32 samples every engine consumes. This is the one
// shape WAVFile deliberately refuses to produce (it round-trips exactly what
// Barktor records); dropped files (B1) arrive in arbitrary formats.
enum AudioFileDecoder {
    // ~690 MB of Float32 at 16 kHz — the in-RAM ceiling one job may claim.
    static let maxDuration: TimeInterval = 3 * 3600

    static func decode16kMono(
        url: URL, maxDuration: TimeInterval = AudioFileDecoder.maxDuration
    ) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioFileDecoderError.unreadable(error.localizedDescription)
        }
        let source = file.processingFormat
        guard file.length > 0, source.sampleRate > 0 else { throw AudioFileDecoderError.empty }
        let duration = Double(file.length) / source.sampleRate
        guard duration <= maxDuration else {
            throw AudioFileDecoderError.tooLong(duration, limit: maxDuration)
        }

        guard
            let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: source, to: target)
        else { throw AudioFileDecoderError.unreadable("unsupported audio format") }

        let inCapacity: AVAudioFrameCount = 65_536
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: inCapacity)
        else { throw AudioFileDecoderError.unreadable("could not allocate read buffer") }

        var samples: [Float] = []
        samples.reserveCapacity(Int(duration * 16_000) + 16_000)
        var readError: Error?

        while true {
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 65_536)
            else { throw AudioFileDecoderError.unreadable("could not allocate output buffer") }
            var convertError: NSError?
            let status = converter.convert(to: outBuffer, error: &convertError) { _, outStatus in
                do {
                    inBuffer.frameLength = 0
                    try file.read(into: inBuffer, frameCount: inCapacity)
                } catch {
                    readError = error
                    outStatus.pointee = .endOfStream
                    return nil
                }
                guard inBuffer.frameLength > 0 else {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inBuffer
            }
            if let convertError {
                throw AudioFileDecoderError.unreadable(convertError.localizedDescription)
            }
            if let readError {
                throw AudioFileDecoderError.unreadable(readError.localizedDescription)
            }
            if outBuffer.frameLength > 0 {
                samples.append(
                    contentsOf: UnsafeBufferPointer(
                        start: outBuffer.floatChannelData![0], count: Int(outBuffer.frameLength)))
            }
            switch status {
            case .haveData:
                continue
            case .endOfStream, .inputRanDry:
                guard !samples.isEmpty else { throw AudioFileDecoderError.empty }
                return samples
            case .error:
                throw AudioFileDecoderError.unreadable("conversion failed")
            @unknown default:
                throw AudioFileDecoderError.unreadable("conversion failed")
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: PASS (4 new tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/Barktor/AudioFileDecoder.swift Tests/BarktorTests/AudioFileDecoderTests.swift
git commit -m "feat: AudioFileDecoder - arbitrary audio to 16kHz mono Float32 with 3h cap"
```

---

### Task 4: Engine progress channel

**Files:**
- Modify: `Sources/Barktor/TranscriptionEngine.swift`
- Modify: `Sources/Barktor/WhisperEngine.swift`
- Create: `Tests/BarktorTests/EngineProgressTests.swift`

**Interfaces:**
- Produces (protocol extension, default forwards to the plain calls):
  ```swift
  func transcribe(samples: [Float], progress: @escaping @Sendable (Double) -> Void) async throws -> String
  func transcribeDetailed(samples: [Float], progress: @escaping @Sendable (Double) -> Void) async throws -> DetailedTranscription
  ```
- Consumed by: Tasks 6, 7 (queue calls the progress variants; FakeEngine overrides them).

- [ ] **Step 1: Write the failing test**

Create `Tests/BarktorTests/EngineProgressTests.swift`:

```swift
import Foundation
import Testing

@testable import Barktor

// An engine that implements ONLY the base protocol methods — proves the
// progress variants have working default implementations.
private final class MinimalEngine: TranscriptionEngine {
    let supportsStreaming = false
    func warmup() async {}
    func isWarm() async -> Bool { true }
    func transcribe(samples: [Float]) async throws -> String { "base" }
    func transcribeDetailed(samples: [Float]) async throws -> DetailedTranscription {
        DetailedTranscription(text: "base", tokens: [], duration: 1)
    }
    func makeStreamingSession() async throws -> any StreamingSession {
        throw EngineError.streamingNotSupported(engineName: "Minimal")
    }
}

struct EngineProgressTests {
    @Test func defaultProgressVariantsForwardToBaseCalls() async throws {
        let engine: any TranscriptionEngine = MinimalEngine()
        let text = try await engine.transcribe(samples: [0]) { _ in }
        #expect(text == "base")
        let detailed = try await engine.transcribeDetailed(samples: [0]) { _ in }
        #expect(detailed.text == "base")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`
Expected: compile error — no `transcribe(samples:progress:)` in the protocol.

- [ ] **Step 3: Implement the protocol extension**

In `Sources/Barktor/TranscriptionEngine.swift`, add to the protocol (after `transcribeDetailed`):

```swift
    // Progress-reporting variants for long batch runs (the background queue).
    // fraction ∈ [0, 1]. Engines with no real signal (Parakeet, Nemotron)
    // keep the defaults below, which never call the closure — the UI then
    // shows an indeterminate "Transcribing…" instead of a fake percentage.
    func transcribe(
        samples: [Float], progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String
    func transcribeDetailed(
        samples: [Float], progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DetailedTranscription
```

And below the protocol:

```swift
extension TranscriptionEngine {
    func transcribe(
        samples: [Float], progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        try await transcribe(samples: samples)
    }

    func transcribeDetailed(
        samples: [Float], progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DetailedTranscription {
        try await transcribeDetailed(samples: samples)
    }
}
```

- [ ] **Step 4: Implement WhisperEngine's real progress**

In `Sources/Barktor/WhisperEngine.swift`, add inside the class:

```swift
    // Real batch progress. WhisperKit tracks each transcribe call on
    // pipe.progress: runTranscribeTask adds one child Progress per call whose
    // units are SECONDS of audio seeked, and resets the parent when a call
    // finishes. Polling fractionCompleted is simpler and safer than the
    // per-token TranscriptionCallback (which fires off-actor) for the same
    // fidelity a progress bar needs. Verified against WhisperKit's
    // TranscribeTask.swift (progress.totalUnitCount = totalSeekDuration).
    private func pollingProgress<T>(
        progress: @escaping @Sendable (Double) -> Void,
        during operation: () async throws -> T
    ) async rethrows -> T {
        let poller = Task { [weak self] in
            while !Task.isCancelled {
                if let fraction = await self?.pipe?.progress.fractionCompleted, fraction > 0 {
                    progress(min(1, fraction))
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        defer { poller.cancel() }
        return try await operation()
    }

    func transcribe(
        samples: [Float], progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        try await pollingProgress(progress: progress) {
            try await transcribe(samples: samples)
        }
    }

    func transcribeDetailed(
        samples: [Float], progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DetailedTranscription {
        try await pollingProgress(progress: progress) {
            try await transcribeDetailed(samples: samples)
        }
    }
}
```

Note: `WhisperEngine` is `@MainActor`, so `await self?.pipe` hops correctly; the poller reads a `Foundation.Progress` (thread-safe). Whisper progress itself is validated manually in Task 12 — a unit test would need a downloaded model.

- [ ] **Step 5: Run tests to verify they pass**

Run: `make test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/Barktor/TranscriptionEngine.swift Sources/Barktor/WhisperEngine.swift Tests/BarktorTests/EngineProgressTests.swift
git commit -m "feat: progress-reporting transcribe variants, real fractions from WhisperKit"
```

---

### Task 5: Notifying protocol + Notifier

**Files:**
- Create: `Sources/Barktor/Notifier.swift`

**Interfaces:**
- Produces:
  ```swift
  @MainActor protocol Notifying: AnyObject {
      func requestPermissionIfNeeded()
      func notifyMeetingDone(title: String, revealURL: URL)
      func notifyFileDone(filename: String)
      func notifyFailure(message: String, revealURL: URL?)
  }
  final class Notifier: NSObject, Notifying, UNUserNotificationCenterDelegate  // var onOpenHistory: () -> Void
  final class NullNotifier: Notifying  // silent default so the queue works unwired
  ```
- Consumed by: Tasks 6, 7 (queue calls it; tests inject a spy), Task 11 (AppDelegate wires `onOpenHistory`).

No unit test: the real center traps outside an app bundle (see Global Constraints); behavior is validated in Task 12's manual UAT. This task must still compile cleanly.

- [ ] **Step 1: Implement**

Create `Sources/Barktor/Notifier.swift`:

```swift
import AppKit
import UserNotifications

// Completion/failure notifications for the background transcription queue.
// Injected as a protocol so unit tests can spy without touching
// UNUserNotificationCenter (which traps outside a real app bundle).
@MainActor
protocol Notifying: AnyObject {
    func requestPermissionIfNeeded()
    func notifyMeetingDone(title: String, revealURL: URL)
    func notifyFileDone(filename: String)
    func notifyFailure(message: String, revealURL: URL?)
}

// Default for an unwired queue (and a safe stand-in anywhere notifications
// must be off): swallows everything.
@MainActor
final class NullNotifier: Notifying {
    func requestPermissionIfNeeded() {}
    func notifyMeetingDone(title: String, revealURL: URL) {}
    func notifyFileDone(filename: String) {}
    func notifyFailure(message: String, revealURL: URL?) {}
}

// The real thing. Permission is requested lazily on the first enqueue —
// never at launch. A denial stays silent: the menu bar still tells the
// story, and nagging a user who said no is worse than no banner.
@MainActor
final class Notifier: NSObject, Notifying, UNUserNotificationCenterDelegate {
    // Opens the History window (file-job clicks). Wired by AppDelegate.
    var onOpenHistory: () -> Void = {}

    private var permissionRequested = false

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestPermissionIfNeeded() {
        guard !permissionRequested else { return }
        permissionRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
            _, _ in
        }
    }

    func notifyMeetingDone(title: String, revealURL: URL) {
        post(title: "Transcription ready", body: title, userInfo: ["reveal": revealURL.path])
    }

    func notifyFileDone(filename: String) {
        post(title: "Transcription ready", body: filename, userInfo: ["openHistory": true])
    }

    func notifyFailure(message: String, revealURL: URL?) {
        var info: [AnyHashable: Any] = [:]
        if let revealURL { info["reveal"] = revealURL.path }
        post(title: "Transcription failed", body: message, userInfo: info)
    }

    private func post(title: String, body: String, userInfo: [AnyHashable: Any]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = userInfo
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // Click routing: meetings reveal the transcript/summary in Finder, file
    // jobs open the History window (their result IS a History entry).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        Task { @MainActor [weak self] in
            if let path = info["reveal"] as? String {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } else if info["openHistory"] != nil {
                self?.onOpenHistory()
            }
            completionHandler()
        }
    }

    // Banners must show even while a Barktor window is frontmost (Settings /
    // History count as foreground for a menu-bar app).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
```

- [ ] **Step 2: Verify it builds and existing tests pass**

Run: `make test`
Expected: compiles, all suites PASS.

- [ ] **Step 3: Commit**

```bash
git add Sources/Barktor/Notifier.swift
git commit -m "feat: Notifier - UNUserNotificationCenter wrapper with click routing"
```

---

### Task 6: TranscriptionQueue — core + file jobs

**Files:**
- Create: `Sources/Barktor/TranscriptionQueue.swift`
- Modify: `Sources/Barktor/HistoryStore.swift` (orphan sweep helper)
- Create: `Tests/BarktorTests/TranscriptionQueueTests.swift` (includes `FakeEngine` + `SpyNotifier` used again in Task 7)

**Interfaces:**
- Produces:
  ```swift
  @MainActor final class TranscriptionQueue: ObservableObject {
      static let shared: TranscriptionQueue
      enum QueueState: Equatable { case idle; case processing(label: String, stage: String, fraction: Double?, queued: Int) }
      @Published private(set) var state: QueueState
      @Published private(set) var activeEntryIDs: Set<UUID>
      let directory: URL
      // injected: engineResolver, postProcess, diarize, summarize, writeDocument, salvageDirectory, notifier
      init(directory: URL = ..., history: HistoryStore? = nil)
      func jobDirectory(_ id: UUID) -> URL
      func enqueueMeeting(mic: [Float], system: [Float], recordedAt: Date, engine: SettingsStore.Engine, whisperModel: String) async throws
      func enqueueFile(jobID: UUID, entryID: UUID, sourceFilename: String, duration: TimeInterval, engine: SettingsStore.Engine, whisperModel: String, isRetry: Bool) throws
      func scanAndResume()
      func waitUntilIdle() async   // test/support helper
  }
  enum QueueError: LocalizedError { case audioMissing }
  ```
- Produces on HistoryStore: `func failOrphanedQueueEntries(activeIDs: Set<UUID>)`
- Consumes: `TranscriptionJob` (Task 2), progress variants (Task 4), `Notifying` (Task 5), `DictationEntry` statuses (Task 1), `WAVFile`, `AudioPreprocessor.normalize`, `AppCoordinator.engineUsedLabel` (existing, `nonisolated static`).

- [ ] **Step 1: Write the failing tests**

Create `Tests/BarktorTests/TranscriptionQueueTests.swift`:

```swift
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
    private(set) var calls = 0
    private var inFlight = 0
    private(set) var maxInFlight = 0

    func warmup() async {}
    func isWarm() async -> Bool { true }

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
    private(set) var failures: [(message: String, revealURL: URL?)] = []

    func requestPermissionIfNeeded() { permissionRequests += 1 }
    func notifyMeetingDone(title: String, revealURL: URL) {
        meetingDone.append((title, revealURL))
    }
    func notifyFileDone(filename: String) { fileDone.append(filename) }
    func notifyFailure(message: String, revealURL: URL?) {
        failures.append((message, revealURL))
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
}
```

Add `import Combine` at the top of the test file (for `.sink`).

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test`
Expected: compile error — `TranscriptionQueue` not defined.

- [ ] **Step 3: Add the HistoryStore helper**

In `Sources/Barktor/HistoryStore.swift`, after `sweepExpiredAudio`:

```swift
    // Queue-crash cleanup, called from TranscriptionQueue.scanAndResume():
    // entries left in .queued/.transcribing whose backing job no longer
    // exists can never complete — surface them as failed instead of leaving
    // zombie spinners in the list.
    func failOrphanedQueueEntries(activeIDs: Set<UUID>) {
        var changed = false
        for idx in entries.indices {
            let status = entries[idx].status
            guard status == .queued || status == .transcribing else { continue }
            guard !activeIDs.contains(entries[idx].id) else { continue }
            entries[idx].status = .failed
            entries[idx].errorMessage = "Interrupted before transcription finished."
            changed = true
        }
        if changed { save() }
    }
```

- [ ] **Step 4: Implement the queue (core + file jobs)**

Create `Sources/Barktor/TranscriptionQueue.swift`. Meeting processing arrives in Task 7 — for now `processMeeting` only salvages and notifies failure (so the switch is total and honest):

```swift
import Foundation
import os.log

enum QueueError: LocalizedError {
    case audioMissing

    var errorDescription: String? {
        switch self {
        case .audioMissing:
            return "The saved audio for this entry is no longer available."
        }
    }
}

// Serial background transcription queue — the single place ALL batch ASR
// runs (meeting processing, dropped files, history retries). Jobs persist to
// disk (job.json + WAVs) before processing, so a crash or quit never loses
// audio; scanAndResume() at startup re-enqueues whatever was pending. One
// job transcribes at a time: two concurrent Whisper pipes would double model
// memory for no wall-clock win.
//
// Everything external is injected (engine resolution, post-processing,
// diarization, summarization, document writing, notifications) so tests run
// the full job lifecycle against fakes over temp directories.
@MainActor
final class TranscriptionQueue: ObservableObject {
    static let shared = TranscriptionQueue()

    enum QueueState: Equatable {
        case idle
        // fraction nil = indeterminate (Parakeet/Nemotron report no signal).
        case processing(label: String, stage: String, fraction: Double?, queued: Int)
    }

    @Published private(set) var state: QueueState = .idle
    // Entry IDs of file jobs waiting or transcribing — HistoryView rows show
    // their spinner from this.
    @Published private(set) var activeEntryIDs: Set<UUID> = []

    // ------------------------------------------------------------------
    // Injected dependencies. Defaults work standalone; AppCoordinator.start()
    // overrides them with the app's shared engines and real pipelines.
    // ------------------------------------------------------------------

    // MUST return instances safe against the live dictation engine: fresh
    // WhisperEngine per job (WhisperKit doesn't serialize concurrent calls),
    // shared actor-based Parakeet/Nemotron.
    var engineResolver:
        (SettingsStore.Engine, String) -> (engine: any TranscriptionEngine, label: String) = {
            choice, model in
            switch choice {
            case .parakeet: return (ParakeetEngine(), "Parakeet TDT v2")
            case .parakeetV3: return (ParakeetEngine(version: .v3), "Parakeet TDT v3")
            case .nemotron: return (NemotronStreamingEngine(), "Multilingual (Nemotron)")
            case .whisper: return (WhisperEngine(modelName: model), "Whisper (\(model))")
            }
        }
    // Deterministic pass + optional LLM polish for file jobs; the duration
    // parameter lets the wiring skip polish on long audio (spec: ≤ 5 min).
    var postProcess: (String, TimeInterval) async -> String = { raw, _ in raw }
    var diarize: ([Float]) async throws -> [TimedSpeakerSegment] = { _ in [] }
    // Returns the summary sidecar URL, or nil when skipped or failed.
    var summarize: (URL) async -> URL? = { _ in nil }
    var writeDocument: (MeetingDocument.Output) throws -> URL = { try MeetingDocument.write($0) }
    var salvageDirectory: () -> URL = { MeetingDocument.meetingsDirectory() }
    var notifier: any Notifying = NullNotifier()

    let directory: URL
    private let history: HistoryStore
    private var jobs: [TranscriptionJob] = []
    private var worker: Task<Void, Never>?
    private let log = Logger(subsystem: "com.naktor.barktor", category: "queue")

    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Barktor/Queue", isDirectory: true)
    }

    init(directory: URL = TranscriptionQueue.defaultDirectory, history: HistoryStore? = nil) {
        self.directory = directory
        self.history = history ?? HistoryStore.shared
    }

    // ------------------------------------------------------------------
    // Disk layout
    // ------------------------------------------------------------------

    func jobDirectory(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func persist(_ job: TranscriptionJob) throws {
        try FileManager.default.createDirectory(
            at: jobDirectory(job.id), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(job)
        try data.write(
            to: jobDirectory(job.id).appendingPathComponent("job.json"), options: .atomic)
    }

    private func removeJobDir(_ id: UUID) {
        try? FileManager.default.removeItem(at: jobDirectory(id))
    }

    // ------------------------------------------------------------------
    // Enqueue
    // ------------------------------------------------------------------

    // Meeting stop path. The WAV write happens off-main at .utility (a
    // 90-minute meeting is ~330 MB per track); once this returns, the audio
    // is crash-safe on disk and MeetingPipeline can go back to .idle.
    func enqueueMeeting(
        mic: [Float], system: [Float], recordedAt: Date,
        engine: SettingsStore.Engine, whisperModel: String
    ) async throws {
        let job = TranscriptionJob(
            id: UUID(), createdAt: Date(), engine: engine, whisperModel: whisperModel,
            payload: .meeting(
                .init(
                    recordedAt: recordedAt,
                    duration: TimeInterval(mic.count) / 16_000.0,
                    hasSystemTrack: !system.isEmpty)))
        let dir = jobDirectory(job.id)
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try WAVFile.write(samples: mic, to: dir.appendingPathComponent("mic.wav"))
            if !system.isEmpty {
                try WAVFile.write(samples: system, to: dir.appendingPathComponent("system.wav"))
            }
        }.value
        try persist(job)
        notifier.requestPermissionIfNeeded()
        append(job)
    }

    // File jobs (drops and retries). For drops the caller has already
    // decoded audio.wav into jobDirectory(jobID) and created the .queued
    // History entry; retries reference the entry's existing History WAV.
    func enqueueFile(
        jobID: UUID, entryID: UUID, sourceFilename: String, duration: TimeInterval,
        engine: SettingsStore.Engine, whisperModel: String, isRetry: Bool
    ) throws {
        let job = TranscriptionJob(
            id: jobID, createdAt: Date(), engine: engine, whisperModel: whisperModel,
            payload: .file(
                .init(
                    entryID: entryID, sourceFilename: sourceFilename,
                    duration: duration, isRetry: isRetry)))
        try persist(job)
        notifier.requestPermissionIfNeeded()
        append(job)
    }

    // Startup: re-enqueue every job left on disk (crash/quit recovery),
    // oldest first, then fail History entries whose job vanished.
    func scanAndResume() {
        let fm = FileManager.default
        let dirs =
            (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var found: [TranscriptionJob] = []
        for dir in dirs {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("job.json")),
                let job = try? JSONDecoder().decode(TranscriptionJob.self, from: data)
            else {
                // Unreadable leftovers would fail forever on every launch.
                try? fm.removeItem(at: dir)
                continue
            }
            found.append(job)
        }
        found.sort { $0.createdAt < $1.createdAt }
        for job in found { append(job) }
        let active = Set(
            found.compactMap { job -> UUID? in
                if case .file(let p) = job.payload { return p.entryID }
                return nil
            })
        history.failOrphanedQueueEntries(activeIDs: active)
    }

    // ------------------------------------------------------------------
    // Worker
    // ------------------------------------------------------------------

    private func append(_ job: TranscriptionJob) {
        jobs.append(job)
        if case .file(let p) = job.payload { activeEntryIDs.insert(p.entryID) }
        refreshQueuedCount()
        startWorkerIfNeeded()
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.drain()
            guard let self else { return }
            self.worker = nil
            // An append that landed between drain()'s exit and this line saw
            // worker != nil and spawned nothing — pick its job up now.
            if !self.jobs.isEmpty { self.startWorkerIfNeeded() }
        }
    }

    private func drain() async {
        while let job = jobs.first {
            await process(job)
            jobs.removeFirst()
            if case .file(let p) = job.payload { activeEntryIDs.remove(p.entryID) }
        }
        state = .idle
    }

    // Test/support: suspends until the worker has drained everything.
    func waitUntilIdle() async {
        while let task = worker {
            await task.value
        }
    }

    private func process(_ job: TranscriptionJob) async {
        let resolved = engineResolver(job.engine, job.whisperModel)
        switch job.payload {
        case .meeting(let payload):
            await processMeeting(
                job, payload, engine: resolved.engine, engineLabel: resolved.label)
        case .file(let payload):
            await processFile(job, payload, engine: resolved.engine)
        }
    }

    // ------------------------------------------------------------------
    // File jobs
    // ------------------------------------------------------------------

    private func processFile(
        _ job: TranscriptionJob, _ payload: TranscriptionJob.FilePayload,
        engine: any TranscriptionEngine
    ) async {
        setProcessing(label: payload.sourceFilename, stage: "Transcribing", fraction: nil)
        // The retry gate (HistoryStore.beginRetry) is released here, not in
        // retryHistoryEntry — the job outlives that call by design.
        defer { if payload.isRetry { history.endRetry(payload.entryID) } }
        do {
            let audioURL: URL
            if payload.isRetry {
                guard let entry = history.entries.first(where: { $0.id == payload.entryID }),
                    let url = history.audioURL(for: entry)
                else { throw QueueError.audioMissing }
                audioURL = url
            } else {
                audioURL = jobDirectory(job.id).appendingPathComponent("audio.wav")
            }
            let samples = try WAVFile.read(url: audioURL)
            let prepared = AudioPreprocessor.normalize(samples).samples
            history.update(payload.entryID) { $0.status = .transcribing }
            let raw = try await engine.transcribe(samples: prepared) { [weak self] fraction in
                Task { @MainActor [weak self] in self?.setFraction(fraction) }
            }
            let processed = await postProcess(raw, payload.duration)
            history.update(payload.entryID) {
                $0.rawText = raw
                $0.processedText = processed
                $0.status = .ok
                $0.errorMessage = nil
                $0.engineUsed = AppCoordinator.engineUsedLabel(
                    engine: job.engine, modelName: job.whisperModel)
            }
            if !payload.isRetry { adoptAudioIntoHistory(from: audioURL, entryID: payload.entryID) }
            removeJobDir(job.id)
            notifier.notifyFileDone(filename: payload.sourceFilename)
        } catch {
            log.error(
                "File job failed (\(payload.sourceFilename, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
            history.update(payload.entryID) {
                $0.status = .failed
                $0.errorMessage = error.localizedDescription
            }
            if !payload.isRetry {
                // Keep the decoded audio when retention allows — Retry from
                // the entry stays possible after a transient failure.
                adoptAudioIntoHistory(
                    from: jobDirectory(job.id).appendingPathComponent("audio.wav"),
                    entryID: payload.entryID)
            }
            removeJobDir(job.id)
            notifier.notifyFailure(
                message: "Could not transcribe \(payload.sourceFilename).", revealURL: nil)
        }
    }

    // Moves the job's decoded WAV into History's audio directory when
    // retention keeps audio; otherwise it dies with the job dir (mirrors how
    // dictations behave under retention "Never").
    private func adoptAudioIntoHistory(from url: URL, entryID: UUID) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard history.retentionProvider().maxAge != nil else { return }
        let filename = "\(entryID.uuidString).wav"
        let dest = history.audioDirectory.appendingPathComponent(filename)
        do {
            try FileManager.default.createDirectory(
                at: history.audioDirectory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: url, to: dest)
            history.update(entryID) { $0.audioFilename = filename }
        } catch {
            log.warning(
                "Could not adopt job audio for \(entryID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public) — entry stays text-only"
            )
        }
    }

    // ------------------------------------------------------------------
    // Meeting jobs — full processing lands in the next task; failing
    // honestly (salvage + notify) keeps the switch total meanwhile.
    // ------------------------------------------------------------------

    private func processMeeting(
        _ job: TranscriptionJob, _ payload: TranscriptionJob.MeetingPayload,
        engine: any TranscriptionEngine, engineLabel: String
    ) async {
        let salvaged = salvageMeetingAudio(job, payload)
        removeJobDir(job.id)
        notifier.notifyFailure(
            message: "Meeting processing is not available yet.", revealURL: salvaged)
    }

    // Copies the job's WAVs into the Meetings folder so a failed job never
    // loses the recording. Returns the mic WAV's destination (nil when even
    // the salvage failed — logged, nothing more we can do).
    private func salvageMeetingAudio(
        _ job: TranscriptionJob, _ payload: TranscriptionJob.MeetingPayload
    ) -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let stamp = formatter.string(from: payload.recordedAt)
        let dir = salvageDirectory()
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let micDest = dir.appendingPathComponent("Meeting \(stamp) (audio only).wav")
            try? fm.removeItem(at: micDest)
            try fm.copyItem(
                at: jobDirectory(job.id).appendingPathComponent("mic.wav"), to: micDest)
            if payload.hasSystemTrack {
                let sysDest = dir.appendingPathComponent(
                    "Meeting \(stamp) (audio only, system).wav")
                try? fm.removeItem(at: sysDest)
                try fm.copyItem(
                    at: jobDirectory(job.id).appendingPathComponent("system.wav"), to: sysDest)
            }
            return micDest
        } catch {
            log.error(
                "Meeting audio salvage failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // ------------------------------------------------------------------
    // State publishing
    // ------------------------------------------------------------------

    private func setProcessing(label: String, stage: String, fraction: Double?) {
        state = .processing(
            label: label, stage: stage, fraction: fraction, queued: max(0, jobs.count - 1))
    }

    func setStage(_ stage: String, fraction: Double?) {
        guard case .processing(let label, _, _, let queued) = state else { return }
        state = .processing(label: label, stage: stage, fraction: fraction, queued: queued)
    }

    private func setFraction(_ fraction: Double) {
        guard case .processing(let label, let stage, _, let queued) = state else { return }
        state = .processing(
            label: label, stage: stage, fraction: min(1, max(0, fraction)), queued: queued)
    }

    private func refreshQueuedCount() {
        guard case .processing(let label, let stage, let fraction, _) = state else { return }
        state = .processing(
            label: label, stage: stage, fraction: fraction, queued: max(0, jobs.count - 1))
    }
}
```

Note: `setStage` is internal (not private) — Task 7's meeting processor uses it and it keeps the state enum manipulation in one place.

- [ ] **Step 5: Run tests to verify they pass**

Run: `make test`
Expected: PASS — all 9 new queue tests plus every existing suite.

- [ ] **Step 6: Commit**

```bash
git add Sources/Barktor/TranscriptionQueue.swift Sources/Barktor/HistoryStore.swift Tests/BarktorTests/TranscriptionQueueTests.swift
git commit -m "feat: TranscriptionQueue - disk-backed serial queue with file-job processing"
```

---

### Task 7: TranscriptionQueue — meeting jobs

**Files:**
- Modify: `Sources/Barktor/TranscriptionQueue.swift` (replace the placeholder `processMeeting`)
- Create: `Tests/BarktorTests/TranscriptionQueueMeetingTests.swift`

**Interfaces:**
- Consumes: `MeetingDocument.format(localOnly:duration:recordedAt:engineLabel:)`, `MeetingDocument.format(localASR:remoteASR:remoteSegments:duration:recordedAt:engineLabel:)`, `EchoCanceller.process(mic:reference:)`, injected `diarize`/`summarize`/`writeDocument`.
- Produces: complete meeting job lifecycle (mono + dual-track), sample-weighted progress, salvage-on-failure.

- [ ] **Step 1: Write the failing tests**

Create `Tests/BarktorTests/TranscriptionQueueMeetingTests.swift`:

```swift
import Combine
import Foundation
import Testing

@testable import Barktor

@MainActor
struct TranscriptionQueueMeetingTests {
    private func makeWorld() -> (
        queue: TranscriptionQueue, engine: FakeEngine, notifier: SpyNotifier, dir: URL
    ) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-meeting-\(UUID().uuidString)", isDirectory: true)
        let history = HistoryStore(
            directory: base.appendingPathComponent("history", isDirectory: true))
        history.retentionProvider = { .week }
        let queue = TranscriptionQueue(
            directory: base.appendingPathComponent("queue", isDirectory: true),
            history: history)
        let engine = FakeEngine()
        let notifier = SpyNotifier()
        queue.engineResolver = { _, _ in (engine, "Fake") }
        queue.notifier = notifier
        // Documents land in the temp dir, never the real Meetings folder.
        let docsDir = base.appendingPathComponent("meetings", isDirectory: true)
        queue.writeDocument = { output in
            try FileManager.default.createDirectory(
                at: docsDir, withIntermediateDirectories: true)
            let url = docsDir.appendingPathComponent("meeting-\(UUID().uuidString).md")
            try output.markdown.data(using: .utf8)!.write(to: url)
            return url
        }
        queue.salvageDirectory = { docsDir }
        return (queue, engine, notifier, base)
    }

    @Test func micOnlyMeetingWritesDocumentAndNotifies() async throws {
        let (queue, _, notifier, dir) = makeWorld()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await queue.enqueueMeeting(
            mic: [Float](repeating: 0.2, count: 16_000 * 3), system: [],
            recordedAt: Date(), engine: .parakeet, whisperModel: "")
        await queue.waitUntilIdle()
        #expect(notifier.meetingDone.count == 1)
        let url = try #require(notifier.meetingDone.first?.revealURL)
        let markdown = try String(contentsOf: url, encoding: .utf8)
        // FakeEngine returns no token timings → format falls back to raw text.
        #expect(markdown.contains("hola mundo"))
        #expect(queue.state == .idle)
    }

    @Test func dualTrackMeetingTranscribesBothAndWeightsProgress() async throws {
        let (queue, engine, notifier, dir) = makeWorld()
        defer { try? FileManager.default.removeItem(at: dir) }
        engine.progressSteps = [1.0]  // each pass reports "done"
        var fractions: [Double] = []
        let cancellable = queue.$state.sink { state in
            if case .processing(_, _, let fraction?, _) = state { fractions.append(fraction) }
        }
        defer { cancellable.cancel() }
        // System track 3× the mic → remote weight 0.75.
        try await queue.enqueueMeeting(
            mic: [Float](repeating: 0.2, count: 16_000),
            system: [Float](repeating: 0.2, count: 16_000 * 3),
            recordedAt: Date(), engine: .parakeet, whisperModel: "")
        await queue.waitUntilIdle()
        #expect(engine.calls == 2)  // remote pass + local pass
        #expect(notifier.meetingDone.count == 1)
        // Remote pass completion lands at its weight; local completes at 1.0.
        #expect(fractions.contains { abs($0 - 0.75) < 0.01 })
        #expect(fractions.contains { abs($0 - 1.0) < 0.01 })
    }

    @Test func summarySidecarWinsTheRevealURL() async throws {
        let (queue, _, notifier, dir) = makeWorld()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sidecar = dir.appendingPathComponent("summary.md")
        queue.summarize = { _ in sidecar }
        try await queue.enqueueMeeting(
            mic: [Float](repeating: 0.2, count: 16_000 * 3), system: [],
            recordedAt: Date(), engine: .parakeet, whisperModel: "")
        await queue.waitUntilIdle()
        #expect(notifier.meetingDone.first?.revealURL == sidecar)
    }

    @Test func failedMeetingSalvagesAudioAndNotifies() async throws {
        let (queue, engine, notifier, dir) = makeWorld()
        defer { try? FileManager.default.removeItem(at: dir) }
        engine.shouldThrow = true
        try await queue.enqueueMeeting(
            mic: [Float](repeating: 0.2, count: 16_000 * 3),
            system: [Float](repeating: 0.2, count: 16_000 * 3),
            recordedAt: Date(timeIntervalSince1970: 1_800_000_000),
            engine: .parakeet, whisperModel: "")
        await queue.waitUntilIdle()
        #expect(notifier.failures.count == 1)
        let salvaged = try #require(notifier.failures.first?.revealURL)
        #expect(FileManager.default.fileExists(atPath: salvaged.path))
        #expect(salvaged.lastPathComponent.contains("(audio only)"))
        // Both tracks salvaged; the job dir is gone.
        let names = try FileManager.default.contentsOfDirectory(atPath: salvaged.deletingLastPathComponent().path)
        #expect(names.contains { $0.contains("(audio only, system)") })
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test`
Expected: `micOnlyMeetingWritesDocumentAndNotifies` and the others FAIL — the placeholder `processMeeting` reports failure instead of transcribing.

- [ ] **Step 3: Implement meeting processing**

In `Sources/Barktor/TranscriptionQueue.swift`, replace the placeholder `processMeeting` with:

```swift
    // The former MeetingPipeline.stop() body, working from persisted WAVs.
    // Mic-only: single ASR pass, every utterance is "You". Dual-track: the
    // echo-cancelled mic is the local user; the system track carries remote
    // participants and is diarized concurrently with the two ASR passes.
    private func processMeeting(
        _ job: TranscriptionJob, _ payload: TranscriptionJob.MeetingPayload,
        engine: any TranscriptionEngine, engineLabel: String
    ) async {
        let title = "Meeting (\(max(1, Int(payload.duration / 60))) min)"
        setProcessing(label: title, stage: "Preparing", fraction: nil)
        do {
            let dir = jobDirectory(job.id)
            let mic = try WAVFile.read(url: dir.appendingPathComponent("mic.wav"))
            let system =
                payload.hasSystemTrack
                ? try WAVFile.read(url: dir.appendingPathComponent("system.wav")) : []
            let started = Date()
            let document: MeetingDocument.Output
            if system.isEmpty {
                setStage("Transcribing", fraction: nil)
                let asr = try await engine.transcribeDetailed(samples: mic) {
                    [weak self] fraction in
                    Task { @MainActor [weak self] in self?.setFraction(fraction) }
                }
                warnIfMissingTimings(asr, track: "mic")
                document = MeetingDocument.format(
                    localOnly: asr, duration: payload.duration,
                    recordedAt: payload.recordedAt, engineLabel: engineLabel)
            } else {
                // Echo cancellation is pure CPU work — keep it off the main
                // actor so the app stays responsive.
                let cleanedMic = await Task.detached(priority: .utility) {
                    EchoCanceller.process(mic: mic, reference: system)
                }.value
                async let remoteSegmentsTask = diarize(system)
                // Two sequential ASR passes share one progress bar, weighted
                // by how much audio each contributes.
                let remoteWeight = Double(system.count) / Double(system.count + cleanedMic.count)
                setStage("Transcribing", fraction: 0)
                let remoteASR = try await engine.transcribeDetailed(samples: system) {
                    [weak self] fraction in
                    Task { @MainActor [weak self] in self?.setFraction(fraction * remoteWeight) }
                }
                warnIfMissingTimings(remoteASR, track: "remote")
                let localASR = try await engine.transcribeDetailed(samples: cleanedMic) {
                    [weak self] fraction in
                    Task { @MainActor [weak self] in
                        self?.setFraction(remoteWeight + fraction * (1 - remoteWeight))
                    }
                }
                warnIfMissingTimings(localASR, track: "local")
                // A diarization failure (no remote speech, music, silence)
                // must not sink the meeting — transcripts survive unlabelled.
                let remoteSegments: [TimedSpeakerSegment]
                do {
                    remoteSegments = try await remoteSegmentsTask
                } catch {
                    log.error(
                        "Meeting diarization failed (\(error.localizedDescription, privacy: .public)) - saving without remote speaker labels."
                    )
                    remoteSegments = []
                }
                document = MeetingDocument.format(
                    localASR: localASR, remoteASR: remoteASR, remoteSegments: remoteSegments,
                    duration: payload.duration, recordedAt: payload.recordedAt,
                    engineLabel: engineLabel)
            }
            let url = try writeDocument(document)
            log.info(
                "Meeting job done in \(String(format: "%.2f", Date().timeIntervalSince(started)), privacy: .public)s → \(url.path, privacy: .public)"
            )
            setStage("Summarizing", fraction: nil)
            let summaryURL = await summarize(url)
            removeJobDir(job.id)
            notifier.notifyMeetingDone(title: title, revealURL: summaryURL ?? url)
        } catch {
            log.error(
                "Meeting job failed: \(error.localizedDescription, privacy: .public)")
            let salvaged = salvageMeetingAudio(job, payload)
            removeJobDir(job.id)
            notifier.notifyFailure(
                message:
                    "Meeting transcription failed. The audio was saved to your Meetings folder.",
                revealURL: salvaged)
        }
    }

    // Non-empty text with zero token timings silently loses speaker
    // attribution (some Whisper models lack an alignment head) — this is the
    // only trace of that degradation.
    private func warnIfMissingTimings(_ result: DetailedTranscription, track: String) {
        guard result.tokens.isEmpty else { return }
        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        log.warning(
            "ASR[\(track, privacy: .public)]: non-empty text with no token timings - speaker attribution disabled for this track."
        )
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: PASS (4 new meeting tests + everything else).

- [ ] **Step 5: Commit**

```bash
git add Sources/Barktor/TranscriptionQueue.swift Tests/BarktorTests/TranscriptionQueueMeetingTests.swift
git commit -m "feat: meeting job processing in the queue - dual-track, weighted progress, salvage"
```

---

### Task 8: MeetingPipeline slims to persist-and-enqueue

**Files:**
- Modify: `Sources/Barktor/MeetingPipeline.swift`
- Modify: `Sources/Barktor/AppCoordinator.swift` (diarizer ownership, meeting init, observers, voice-edit gate, canQuitSafely)

**Interfaces:**
- `MeetingPipeline.State` loses `.processing` (now `idle` / `recording(startedAt:)` / `error(String)`).
- `MeetingPipeline.init(hud:queue:)` — `summarizer`, `engineProvider` and the diarizer move out.
- `AppCoordinator` gains `private let diarizer = Diarizer()`; call sites `meeting.unloadDiarizer()` → `diarizer.unload()`, `try await meeting.downloadDiarizer()` → `try await diarizer.downloadAndWarmup()` (three sites: ~lines 305, 319, 437).
- Consumed by: Task 11 wires the queue's closures.

No new unit tests: MeetingPipeline drives AudioRecorder/HUD (device-bound); the moved logic is already covered by Task 7's tests. The compile + full suite must stay green.

- [ ] **Step 1: Rewrite MeetingPipeline**

Replace the class contents so it reads (complete new file body — keep the header comment about in-memory recording, `startSystemCapture`, `stopSystemCapture`, `maybeShowSystemAudioNotice`, `startElapsedTimer`, `startLevelTask`, `startSystemLevelTask` EXACTLY as they are today; what changes is listed here):

State enum and stop-path:

```swift
    enum State: Equatable {
        case idle
        case recording(startedAt: Date)
        case error(String)
    }
```

Remove: `private let engineProvider`, `private let summarizer`, `private let diarizer = Diarizer()`, `unloadDiarizer()`, `downloadDiarizer()`, `meetingBusy`, `runSummaryIfEnabled`, `SummaryOutcome`, `summaryFailureMessage`, `logASRResult`, `warnIfMissingTimings`.

New init and toggle:

```swift
    private let hud: RecordingHUD
    private let queue: TranscriptionQueue

    init(hud: RecordingHUD, queue: TranscriptionQueue) {
        self.hud = hud
        self.queue = queue
    }

    func toggle() {
        if hud.shouldIgnorePress(whileBusy: false) { return }
        switch state {
        case .idle, .error:
            start()
        case .recording:
            Task { await stop() }
        }
    }
```

New stop():

```swift
    // Stop is now persist-and-enqueue: the WAVs land in the queue's job
    // directory (crash-safe), the pipeline returns to .idle immediately —
    // a new meeting can start while the previous one transcribes — and the
    // queue owns everything that used to run inline here (echo cancel,
    // diarization, ASR, document, summary).
    private func stop() async {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        levelTask?.cancel()
        levelTask = nil
        systemLevelTask?.cancel()
        systemLevelTask = nil
        latestSystemLevel = 0
        let samples = recorder.stop()
        // Align the tap to the mic's continuous timeline; the tap omits silent
        // gaps, so its raw timestamps don't share the mic's clock origin.
        let systemCaptureResult = stopSystemCapture(micStartHostTime: recorder.captureStartHostTime)
        guard samples.count >= 16_000 * 2 else {
            // Less than 2 s of audio is almost always an accidental tap.
            state = .idle
            hud.hide()
            return
        }
        state = .idle
        do {
            try await queue.enqueueMeeting(
                mic: samples, system: systemCaptureResult.samples, recordedAt: Date(),
                engine: SettingsStore.shared.meetingEngine,
                whisperModel: SettingsStore.shared.modelName)
            hud.showMessage("Transcribing in the background…", autoHideAfter: 3)
        } catch {
            // Disk full or unwritable queue dir: salvage straight to the
            // Meetings folder before giving up — the recording must survive.
            log.error(
                "Meeting enqueue failed: \(error.localizedDescription, privacy: .public)")
            let saved = salvageDirectly(
                mic: samples, system: systemCaptureResult.samples)
            hud.showMessage(
                saved
                    ? "Couldn't queue the transcription — audio saved to your Meetings folder."
                    : "Couldn't save the meeting audio. Check free disk space.",
                autoHideAfter: 5)
        }
        maybeShowSystemAudioNotice(silentButActive: systemCaptureResult.silentButActive)
    }

    // Last-resort persistence when even the queue directory is unwritable.
    private func salvageDirectly(mic: [Float], system: [Float]) -> Bool {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let stamp = formatter.string(from: Date())
        let dir = MeetingDocument.meetingsDirectory()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try WAVFile.write(
                samples: mic, to: dir.appendingPathComponent("Meeting \(stamp) (audio only).wav"))
            if !system.isEmpty {
                try WAVFile.write(
                    samples: system,
                    to: dir.appendingPathComponent("Meeting \(stamp) (audio only, system).wav"))
            }
            return true
        } catch {
            log.error(
                "Meeting direct salvage failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
```

- [ ] **Step 2: Update AppCoordinator**

1. Add near the other engines (`private var nemotron = ...`):

```swift
    // Owned here (not by MeetingPipeline) since the queue is what diarizes
    // now; Settings' download/unload flows reach it through the coordinator.
    private let diarizer = Diarizer()
```

2. Meeting construction in `start()` becomes:

```swift
        meeting = MeetingPipeline(hud: hud, queue: TranscriptionQueue.shared)
```

3. The three diarizer call sites: `meeting.unloadDiarizer()` → `diarizer.unload()` (2×) and `try await meeting.downloadDiarizer()` → `try await diarizer.downloadAndWarmup()`.

4. `meetingObserver` sink — `.processing` no longer exists:

```swift
            switch state {
            case .recording:
                self.hotkey.suspendDictation(true)
                self.meetingActive = true
            case .idle, .error:
                self.hotkey.suspendDictation(false)
                self.meetingActive = false
            }
```

5. `handleVoiceEditPress()` — delete the meeting-state gate entirely (the queue never borrows the live engine, so the old shared-pipe hazard is gone):

```swift
    private func handleVoiceEditPress() {
        voiceEditor.handlePress()
    }
```

6. `canQuitSafely()` — recording still blocks, queue work doesn't:

```swift
    private func canQuitSafely() -> Bool {
        switch state {
        case .recording, .transcribing: return false
        case .idle, .error: break
        }
        if let meeting = meeting {
            switch meeting.state {
            case .recording: return false
            case .idle, .error: break
            }
        }
        return true
    }
```

- [ ] **Step 3: Build and run the full suite**

Run: `make test`
Expected: compiles clean, all suites PASS (no meeting-pipeline unit tests exist; the queue tests cover the moved logic).

- [ ] **Step 4: Commit**

```bash
git add Sources/Barktor/MeetingPipeline.swift Sources/Barktor/AppCoordinator.swift
git commit -m "refactor: MeetingPipeline persists and enqueues - processing moves to the queue"
```

---

### Task 9: Retry through the queue + importAudioFiles

**Files:**
- Modify: `Sources/Barktor/AppCoordinator.swift` (`retryHistoryEntry` rewrite + new `importAudioFiles`)

**Interfaces:**
- Produces: `func importAudioFiles(_ urls: [URL]) async` (consumed by Task 10's drop UI).
- `retryHistoryEntry(_:using:)` keeps its signature — HistoryView's call site doesn't change.
- Consumes: `TranscriptionQueue.shared.enqueueFile`, `AudioFileDecoder`, `queue.jobDirectory`.

The queue-side behavior is already tested (Task 6: retry reads History audio, releases the gate, vanished-audio fails clean). These coordinator methods are thin wiring over the real singletons, so this task is compile + suite green + Task 12 manual UAT.

- [ ] **Step 1: Rewrite retryHistoryEntry**

```swift
    // Re-runs transcription + post-processing over a history entry's saved
    // WAV, now via the background queue: retries serialize with meetings and
    // drops, so two Whisper pipes never load at once. beginRetry() survives
    // purely as a double-enqueue guard; the queue calls endRetry() when the
    // job finishes (see TranscriptionQueue.processFile).
    func retryHistoryEntry(_ id: UUID, using choice: SettingsStore.Engine) async {
        guard let entry = HistoryStore.shared.entries.first(where: { $0.id == id }),
            HistoryStore.shared.audioURL(for: entry) != nil
        else { return }
        guard HistoryStore.shared.beginRetry(id) else { return }
        do {
            try TranscriptionQueue.shared.enqueueFile(
                jobID: UUID(), entryID: id,
                sourceFilename: entry.sourceFilename ?? "dictation",
                duration: entry.duration,
                engine: choice, whisperModel: SettingsStore.shared.modelName,
                isRetry: true)
        } catch {
            log.error(
                "Retry enqueue failed: \(error.localizedDescription, privacy: .public)")
            HistoryStore.shared.endRetry(id)
        }
    }
```

- [ ] **Step 2: Add importAudioFiles**

Add below `retryHistoryEntry`:

```swift
    // B1: audio files dropped on the History window. One .queued entry + one
    // queue job per file; decode runs off-main (a podcast-sized file takes a
    // moment). The engine is the MEETING engine at drop time — an external
    // audio is closer to a meeting than to a dictation, and Retry can rerun
    // it with any other engine.
    func importAudioFiles(_ urls: [URL]) async {
        let queue = TranscriptionQueue.shared
        for url in urls {
            let entryID = UUID()
            let jobID = UUID()
            let filename = url.lastPathComponent
            let engineChoice = SettingsStore.shared.meetingEngine
            let model = SettingsStore.shared.modelName
            do {
                let samples = try await Task.detached(priority: .utility) {
                    try AudioFileDecoder.decode16kMono(url: url)
                }.value
                let duration = TimeInterval(samples.count) / 16_000.0
                let jobDir = queue.jobDirectory(jobID)
                try await Task.detached(priority: .utility) {
                    try FileManager.default.createDirectory(
                        at: jobDir, withIntermediateDirectories: true)
                    try WAVFile.write(
                        samples: samples, to: jobDir.appendingPathComponent("audio.wav"))
                }.value
                HistoryStore.shared.add(
                    DictationEntry(
                        id: entryID, date: Date(), duration: duration, rawText: nil,
                        processedText: nil,
                        engineUsed: Self.engineUsedLabel(engine: engineChoice, modelName: model),
                        mode: .batch, status: .queued, errorMessage: nil, audioFilename: nil,
                        sourceFilename: filename))
                try queue.enqueueFile(
                    jobID: jobID, entryID: entryID, sourceFilename: filename,
                    duration: duration, engine: engineChoice, whisperModel: model,
                    isRetry: false)
            } catch {
                log.error(
                    "Audio import failed for \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                // A failed decode still leaves a visible, explainable row.
                HistoryStore.shared.add(
                    DictationEntry(
                        id: entryID, date: Date(), duration: 0, rawText: nil, processedText: nil,
                        engineUsed: Self.engineUsedLabel(engine: engineChoice, modelName: model),
                        mode: .batch, status: .failed, errorMessage: error.localizedDescription,
                        audioFilename: nil, sourceFilename: filename))
            }
        }
    }
```

- [ ] **Step 3: Build and run the full suite**

Run: `make test`
Expected: compiles clean, all suites PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/Barktor/AppCoordinator.swift
git commit -m "feat: history retries route through the queue; importAudioFiles for drops"
```

---

### Task 10: HistoryView — drop target + queue-aware rows

**Files:**
- Modify: `Sources/Barktor/HistoryView.swift`
- Create: `Tests/BarktorTests/HistoryDropFilterTests.swift`

**Interfaces:**
- Produces: `HistoryView.audioURLs(from:)` (static, pure — the testable part of the drop).
- Consumes: `coordinator.importAudioFiles` (Task 9), `TranscriptionQueue.shared.activeEntryIDs`, entry statuses (Task 1).

- [ ] **Step 1: Write the failing test**

Create `Tests/BarktorTests/HistoryDropFilterTests.swift`:

```swift
import Foundation
import Testing

@testable import Barktor

struct HistoryDropFilterTests {
    @Test func keepsAudioExtensionsDropsTheRest() {
        let urls = [
            URL(fileURLWithPath: "/tmp/nota.m4a"),
            URL(fileURLWithPath: "/tmp/cancion.mp3"),
            URL(fileURLWithPath: "/tmp/grabacion.wav"),
            URL(fileURLWithPath: "/tmp/documento.pdf"),
            URL(fileURLWithPath: "/tmp/video.mp4"),
            URL(fileURLWithPath: "/tmp/sin-extension"),
        ]
        let audio = HistoryView.audioURLs(from: urls)
        #expect(audio.map(\.lastPathComponent) == ["nota.m4a", "cancion.mp3", "grabacion.wav"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`
Expected: compile error — `HistoryView.audioURLs` not defined.

- [ ] **Step 3: Implement**

In `Sources/Barktor/HistoryView.swift`:

1. Add to the view struct:

```swift
    @ObservedObject private var queue = TranscriptionQueue.shared
    @State private var isDropTargeted = false
```

2. Add the pure filter (near the private helpers):

```swift
    // The testable half of the drop: keep only files whose type conforms to
    // audio. Video containers (.mp4/.mov) are out of scope — their audio
    // track would need AVAsset extraction, not AVAudioFile.
    static func audioURLs(from urls: [URL]) -> [URL] {
        urls.filter { url in
            guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
            return type.conforms(to: .audio)
        }
    }
```

3. Attach the drop to the outer `VStack` (after `.frame(minWidth: 480, minHeight: 420)`):

```swift
        .dropDestination(for: URL.self) { urls, _ in
            let audio = Self.audioURLs(from: urls)
            guard !audio.isEmpty else { return false }
            Task { await coordinator.importAudioFiles(audio) }
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.12))
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    Label("Drop audio files to transcribe", systemImage: "waveform.badge.plus")
                        .font(.title3)
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(8)
                .allowsHitTesting(false)
            }
        }
```

4. The row's `isRetrying` argument becomes queue-aware (a queued/transcribing drop shows the same spinner a retry does):

```swift
                            HistoryRow(
                                entry: entry,
                                isRetrying: store.retryingEntryIDs.contains(entry.id)
                                    || queue.activeEntryIDs.contains(entry.id),
                                ...
```

5. In `HistoryRow`, show the source filename in the meta line (after the engine name):

```swift
                if let source = entry.sourceFilename {
                    metaDot
                    Text(source)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
```

6. In `HistoryRow`'s body-text fallbacks, give in-flight entries honest copy — before the `errorMessage` branch:

```swift
            } else if entry.status == .queued {
                Text("Waiting to transcribe…").foregroundStyle(.secondary).font(.callout)
            } else if entry.status == .transcribing {
                Text("Transcribing…").foregroundStyle(.secondary).font(.callout)
```

7. The empty-state copy mentions the new capability:

```swift
                Text("No dictations yet. Hold your hotkey and speak - every dictation lands here. You can also drop audio files to transcribe them.")
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Barktor/HistoryView.swift Tests/BarktorTests/HistoryDropFilterTests.swift
git commit -m "feat: drop audio files on History to transcribe them (B1)"
```

---

### Task 11: Menu bar progress + app wiring

**Files:**
- Modify: `Sources/Barktor/AppCoordinator.swift` (queue wiring in `start()`, `MenuBarStatus.queueProcessing`)
- Modify: `Sources/Barktor/MenuBarController.swift` (queue menu item + icon)
- Modify: `Sources/Barktor/AppDelegate.swift` (Notifier ownership)

**Interfaces:**
- Produces: `AppCoordinator.MenuBarStatus.queueProcessing`; live progress item at the top of the status menu.
- Consumes: `queue.$state`, `Notifier.onOpenHistory` (Task 5).

UI-only behavior — no unit tests. Compile + suite green here; behavior verified in Task 12.

- [ ] **Step 1: Wire the queue in AppCoordinator.start()**

At the end of `start()` (after `installHotkeys()`), add:

```swift
        // Background transcription queue: the coordinator supplies real
        // engines and pipelines; the queue never touches globals itself.
        let queue = TranscriptionQueue.shared
        queue.engineResolver = { [weak self] choice, model in
            switch choice {
            case .parakeet:
                return (self?.parakeet ?? ParakeetEngine(), "Parakeet TDT v2")
            case .parakeetV3:
                return (self?.parakeetV3 ?? ParakeetEngine(version: .v3), "Parakeet TDT v3")
            case .nemotron:
                return (self?.nemotron ?? NemotronStreamingEngine(), "Multilingual (Nemotron)")
            case .whisper:
                // ALWAYS a fresh pipe: the live dictation engine must never
                // share WhisperKit decoder state with a queue job.
                return (WhisperEngine(modelName: model), "Whisper (\(model))")
            }
        }
        queue.postProcess = { [weak self] raw, duration in
            guard let self else { return raw }
            let processed = self.makePostProcessor().apply(raw).text
            // LLM polish only for dictation-sized audio; on an hour-long
            // file it would just burn its 15 s watchdog for nothing.
            guard duration <= 300 else { return processed }
            return await LLMPostProcessor.polish(processed)
        }
        queue.diarize = { [weak self] samples in
            guard let self else { return [] }
            return try await self.diarizer.diarize(samples: samples)
        }
        queue.summarize = { url in
            guard SettingsStore.shared.summarizeMeetings, MeetingSummarizer.canSummarizeNow
            else { return nil }
            return try? await MeetingSummarizer.shared.summarize(transcriptURL: url)
        }
        queueObserver = queue.$state.sink { [weak self] state in
            self?.queueActive = state != .idle
            self?.refreshMenuBarStatus()
        }
        queue.scanAndResume()
```

Add the supporting members next to `meetingObserver`:

```swift
    private var queueObserver: AnyCancellable?
    // True while the queue is processing or has jobs waiting; feeds the
    // menu-bar glyph when nothing foreground is active.
    private var queueActive = false
```

- [ ] **Step 2: Extend MenuBarStatus**

```swift
    enum MenuBarStatus: Equatable {
        case idle
        case recording
        case transcribing
        case meeting
        case queueProcessing
        case error(String)
    }
```

`computeMenuBarStatus()` — background work is the lowest-priority signal:

```swift
    private func computeMenuBarStatus() -> MenuBarStatus {
        if meetingActive { return .meeting }
        switch state {
        case .error(let message): return .error(message)
        case .transcribing: return .transcribing
        case .recording: return .recording
        case .idle:
            switch voiceEditState {
            case .transcribing: return .transcribing
            case .recording: return .recording
            case .idle: return queueActive ? .queueProcessing : .idle
            }
        }
    }
```

- [ ] **Step 3: MenuBarController — icon + live progress item**

1. Init gains the queue reference (AppDelegate passes `TranscriptionQueue.shared`):

```swift
    init(
        coordinator: AppCoordinator,
        queue: TranscriptionQueue,
        onShowAbout: @escaping () -> Void,
        ...
```

Store it (`private let queue: TranscriptionQueue`) and assign in init before `rebuildMenu()`.

2. New icon + members:

```swift
    // Queue processing runs for minutes with nothing else on screen — worth
    // a glyph, unlike the seconds-long dictation transcribe.
    private lazy var iconQueue = templateComposite(["mic", "waveform"])

    private var queueCancellable: AnyCancellable?
    private let queueItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let queueSeparator = NSMenuItem.separator()
    // NSMenu tracking runs the main loop in event-tracking mode, where
    // Combine's default scheduling stalls — a .common-modes timer keeps the
    // progress line moving while the menu is open (same trick as the
    // meeting pill's elapsed timer).
    private var queueTimer: Timer?
```

3. In `init`, after the existing `stateCancellable` sink:

```swift
        queueCancellable = queue.$state.sink { [weak self] state in
            self?.applyQueueState(state)
        }
```

4. In `rebuildMenu()`, insert at the very top (before "About Barktor"):

```swift
        queueItem.isEnabled = false
        queueItem.isHidden = true
        queueSeparator.isHidden = true
        menu.addItem(queueItem)
        menu.addItem(queueSeparator)
```

5. New methods:

```swift
    private func applyQueueState(_ state: TranscriptionQueue.QueueState) {
        switch state {
        case .idle:
            queueItem.isHidden = true
            queueSeparator.isHidden = true
            queueTimer?.invalidate()
            queueTimer = nil
        case .processing:
            queueItem.title = Self.queueTitle(state) ?? ""
            queueItem.isHidden = false
            queueSeparator.isHidden = false
            startQueueTimerIfNeeded()
        }
    }

    private func startQueueTimerIfNeeded() {
        guard queueTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let title = Self.queueTitle(self.queue.state) {
                    self.queueItem.title = title
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        queueTimer = timer
    }

    // "Transcribing Meeting (42 min) — 43%  (2 queued)"
    static func queueTitle(_ state: TranscriptionQueue.QueueState) -> String? {
        guard case .processing(let label, let stage, let fraction, let queued) = state
        else { return nil }
        var text = "\(stage) \(label)"
        if let fraction { text += " — \(Int(fraction * 100))%" }
        if queued > 0 { text += "  (\(queued) queued)" }
        return text
    }
```

6. `applyStatus` gains the case:

```swift
        case .queueProcessing:
            button.image = iconQueue
            button.toolTip = "Barktor - transcribing in background…"
```

- [ ] **Step 4: AppDelegate wiring**

```swift
    private let notifier = Notifier()
```

In `applicationDidFinishLaunching`, BEFORE `coordinator.start()` (the startup scan may complete jobs immediately, and their notifications need the real notifier):

```swift
        notifier.onOpenHistory = { [weak self] in self?.showHistory() }
        TranscriptionQueue.shared.notifier = notifier
```

And the MenuBarController construction gains the queue argument:

```swift
        menuBar = MenuBarController(
            coordinator: coordinator,
            queue: TranscriptionQueue.shared,
            ...
```

- [ ] **Step 5: Build and run the full suite**

Run: `make test`
Expected: compiles clean, all suites PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/Barktor/AppCoordinator.swift Sources/Barktor/MenuBarController.swift Sources/Barktor/AppDelegate.swift
git commit -m "feat: menu-bar queue progress, notification wiring, startup resume"
```

---

### Task 12: Install, smoke-test, push, PR

**Files:** none (verification + delivery).

- [ ] **Step 1: Full suite + app build**

```bash
make test && make build
```
Expected: everything green.

- [ ] **Step 2: Install the app locally**

Use the repo's install path (check `Makefile` for the `install`/`app` target; it signs with the "Barktor Local Dev" identity — see RELEASING.md). Launch Barktor.

- [ ] **Step 3: Manual smoke checklist** (what unit tests can't reach)

1. Record a short meeting (~1 min, Whisper as meeting engine) → on stop: pill shows "Transcribing in the background…" and hides in ~3 s; menu-bar glyph flips to mic+waveform; the dropdown's first item shows "Transcribing Meeting (1 min) — N%" with a LIVE percentage while the menu stays open.
2. Completion → system notification "Transcription ready" (grant the permission prompt on first run); click reveals the transcript in Finder; NO Finder window opens on its own.
3. Record meeting B while A still transcribes → allowed; B queues ("(1 queued)" in the menu item).
4. Quit Barktor mid-transcription (⌃⌥Q must work now) → relaunch → the job resumes from the persisted WAVs and completes with a notification.
5. Drop a real `.m4a` voice note on the History window → overlay appears while dragging; a "Queued"/"Transcribing…" row appears, then fills with text; notification click opens the History window.
6. Retry any entry from its ⋯ menu → spinner shows, entry re-transcribes (now through the queue).
7. Drop a `.pdf` → nothing happens (filtered).

If any check fails: STOP, fix, re-run `make test`, amend/commit the fix before proceeding.

- [ ] **Step 4: Push and open the PR against develop**

```bash
git push -u origin feature/transcription-queue
gh pr create --repo naktor-solutions/barktor --base develop \
  --title "Background transcription queue: B9 (meetings) + B1 (dropped audio files)" \
  --body "$(cat <<'EOF'
## Summary
- All batch ASR now flows through a disk-backed serial TranscriptionQueue (one Whisper pipe at a time, crash/quit-safe jobs, resume on launch)
- B9: stopping a meeting enqueues and returns to idle — record the next meeting immediately; live progress (real % on Whisper) in the menu bar; system notification on completion (click reveals in Finder); quit no longer blocked by processing
- B1: drop audio files (m4a/mp3/wav/…) on History to transcribe them with the meeting engine; retries also route through the queue
- Spec: docs/superpowers/specs/2026-07-04-transcription-queue-design.md

## Test plan
- [ ] make test (unit suites incl. queue lifecycle, decoder, job model)
- [ ] Manual UAT checklist in docs/superpowers/plans/2026-07-04-transcription-queue.md Task 12

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: PR created against `develop`.

---

## Self-review (done at plan-writing time)

- **Spec coverage:** decisions 1–9 of the spec map to: queue serial FIFO (T6), disk persistence (T2/T6), menu+pill progress (T8/T11), notification with click routing (T5/T11), meeting engine for drops (T9), quit unblocked + resume (T8/T6/T11), polish ≤ 5 min (T11 wiring), 3 h cap (T3), QoS utility (T6/T8/T9). Error cases: meeting salvage (T7), file-failure entry + audio kept (T6), decode failure row (T9), orphaned entries (T6), vanished retry WAV (T6), enqueue-failure direct salvage (T8). Out-of-scope items in the spec stay out.
- **Deviation from spec (deliberate, minor):** the system-audio-silent notice stays at `stop()` time (the spec's architecture section said "from the job") — the data is known at stop and the alert is tied to the user's action; the spec's own error section already implied this. The summary-failure HUD copy is replaced by the transcript-reveal notification + log (the HUD may be long gone when a queued summary fails).
- **Type consistency:** `enqueueFile(jobID:entryID:sourceFilename:duration:engine:whisperModel:isRetry:)`, `QueueState.processing(label:stage:fraction:queued:)`, `Notifying`'s four methods, and `FakeEngine`/`SpyNotifier` names are used identically across Tasks 5–11.
- **Placeholders:** none — every step carries complete code or an exact command.
