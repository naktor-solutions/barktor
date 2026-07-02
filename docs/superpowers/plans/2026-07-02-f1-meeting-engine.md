# F1: Selectable Meeting Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Meeting mode transcribes with a user-selectable engine (Parakeet or Whisper) instead of hardcoded Parakeet, enabling Spanish (and 100+ language) meeting transcripts with speaker attribution.

**Architecture:** Add an engine-agnostic `DetailedTranscription` (text + timed tokens) to the `TranscriptionEngine` protocol; Parakeet maps its `ASRResult`, Whisper turns on word timestamps. `MeetingPipeline` stops holding a concrete `ParakeetEngine` and instead resolves the engine from a coordinator-injected provider (same pattern `VoiceEditor` already uses), driven by a new `meeting.engine` setting with its own picker in Settings > Features.

**Tech Stack:** Swift 5.9 / SwiftPM, FluidAudio (Parakeet + diarizer), WhisperKit, XCTest (new test target).

**Spec:** `docs/superpowers/specs/2026-07-02-history-engines-postprocessing-design.md` (section F1).

## Global Constraints

- Target: macOS 14+, Apple Silicon only (`--arch arm64`). No new package dependencies.
- **Every build/test command on a machine without Xcode (Command Line Tools only) needs `-Xswiftc -DNO_APPLE_FM`** (Task 1 introduces the flag). On a machine with Xcode, omit it — both variants must stay green.
- Build: `swift build -Xswiftc -DNO_APPLE_FM` · Test: `swift test -Xswiftc -DNO_APPLE_FM`.
- Follow existing conventions: settings = `Keys` constant + `@Published` with `didSet` persisting to UserDefaults + seed in `init()` + entry in `resetToDefaults()` (`SettingsStore.swift`); UI copy in English; comment style matches surrounding files (explain constraints, not mechanics).
- Default behavior must not change: `meeting.engine` defaults to Parakeet.
- Branch: `feature/f1-meeting-engine` off `main`. Remote `origin` = fork `AlejandroMarchan/purr`.

---

### Task 1: `NO_APPLE_FM` build flag (dev enabler for CLT-only machines)

The standalone Command Line Tools toolchain lacks Xcode's `FoundationModelsMacros` compiler plugin, so the 10 `#if canImport(FoundationModels)` blocks fail to build (`external macro implementation type 'FoundationModelsMacros.GenerableMacro' could not be found`). Guard them with an opt-out flag so CLT machines can build/test; Xcode builds are unaffected because the flag is simply never defined there.

**Files:**
- Modify: `Sources/Purr/EditInterpreter.swift` (4 guards: lines 4, 77, 112, 124)
- Modify: `Sources/Purr/MeetingSummarizer.swift` (6 guards: lines 4, 151, 195, 295, 346, 622)

**Interfaces:**
- Produces: compile condition `NO_APPLE_FM`. All later tasks' build/test commands rely on it.

- [ ] **Step 1: Create the branch**

```bash
git checkout main && git pull origin main && git checkout -b feature/f1-meeting-engine
```

- [ ] **Step 2: Rewrite the guards**

```bash
sed -i '' 's|#if canImport(FoundationModels)|#if canImport(FoundationModels) \&\& !NO_APPLE_FM|' \
  Sources/Purr/EditInterpreter.swift Sources/Purr/MeetingSummarizer.swift
grep -c 'canImport(FoundationModels) && !NO_APPLE_FM' \
  Sources/Purr/EditInterpreter.swift Sources/Purr/MeetingSummarizer.swift
```

Expected: `4` and `6`.

- [ ] **Step 3: Verify the CLT build now succeeds**

Run: `swift build -Xswiftc -DNO_APPLE_FM 2>&1 | tail -3`
Expected: `Build complete!` (first run compiles all dependencies; several minutes).

- [ ] **Step 4: Commit**

```bash
git add Sources/Purr/EditInterpreter.swift Sources/Purr/MeetingSummarizer.swift
git commit -m "build: allow opting out of FoundationModels with -DNO_APPLE_FM

The CLT-only toolchain lacks the FoundationModelsMacros plugin, so
canImport-guarded @Generable code fails to compile without Xcode.
Defining NO_APPLE_FM compiles those blocks out; every call site
already has a Gemma fallback. Xcode builds are unaffected."
```

---

### Task 2: Test target scaffold

The package has no test target. Add one; SwiftPM supports `@testable import` of executable targets on macOS since Swift 5.5.

**Files:**
- Modify: `Package.swift` (add `.testTarget` to `targets`)
- Create: `Tests/PurrTests/SmokeTests.swift`

**Interfaces:**
- Produces: test target `PurrTests`; later tasks add test files under `Tests/PurrTests/`.

- [ ] **Step 1: Add the test target to `Package.swift`**

Append to the `targets:` array (after the `.executableTarget` entry):

```swift
        .testTarget(
            name: "PurrTests",
            dependencies: ["Purr"],
            path: "Tests/PurrTests"
        ),
```

- [ ] **Step 2: Write a smoke test**

`Tests/PurrTests/SmokeTests.swift`:

```swift
import XCTest

@testable import Purr

final class SmokeTests: XCTestCase {
    func testTestTargetLinksAgainstApp() {
        // PostProcessor is a pure value type - constructing one proves the
        // executable target links into the test bundle.
        XCTAssertNotNil(SettingsStore.Engine.parakeet)
    }
}
```

- [ ] **Step 3: Run the tests, verify pass**

Run: `swift test -Xswiftc -DNO_APPLE_FM 2>&1 | tail -3`
Expected: `Test Suite 'All tests' passed` with 1 test.

- [ ] **Step 4: Commit**

```bash
git add Package.swift Tests/
git commit -m "test: add PurrTests target"
```

---

### Task 3: `DetailedTranscription` + protocol requirement + Parakeet conformance

**Files:**
- Create: `Sources/Purr/DetailedTranscription.swift`
- Modify: `Sources/Purr/TranscriptionEngine.swift:9-15` (protocol)
- Modify: `Sources/Purr/ParakeetEngine.swift:244-269` (rename existing method, add conformance)
- Test: `Tests/PurrTests/DetailedTranscriptionTests.swift`

**Interfaces:**
- Produces:
  - `struct DetailedTranscription { let text: String; let tokens: [TimedToken]; let duration: TimeInterval }` with `struct TimedToken: Equatable { let text: String; let start: TimeInterval; let end: TimeInterval }` and `init(asrResult: ASRResult)`.
  - Protocol requirement `func transcribeDetailed(samples: [Float]) async throws -> DetailedTranscription` on `TranscriptionEngine`.
  - `ParakeetEngine.transcribeASR(samples:) -> ASRResult` (the renamed old `transcribeDetailed`; still used internally).
- Consumes: `ASRResult`/`TokenTiming` from FluidAudio (public inits).

- [ ] **Step 1: Write the failing test**

`Tests/PurrTests/DetailedTranscriptionTests.swift`:

```swift
import FluidAudio
import XCTest

@testable import Purr

final class DetailedTranscriptionTests: XCTestCase {
    func testMapsParakeetTokenTimings() {
        let asr = ASRResult(
            text: "hola mundo", confidence: 0.9, duration: 2.0, processingTime: 0.1,
            tokenTimings: [
                TokenTiming(token: "hola", tokenId: 1, startTime: 0.0, endTime: 0.5, confidence: 0.9),
                TokenTiming(token: " mundo", tokenId: 2, startTime: 0.6, endTime: 1.1, confidence: 0.9),
            ])
        let detailed = DetailedTranscription(asrResult: asr)
        XCTAssertEqual(detailed.text, "hola mundo")
        XCTAssertEqual(
            detailed.tokens,
            [
                DetailedTranscription.TimedToken(text: "hola", start: 0.0, end: 0.5),
                DetailedTranscription.TimedToken(text: " mundo", start: 0.6, end: 1.1),
            ])
        XCTAssertEqual(detailed.duration, 2.0)
    }

    func testNilTimingsBecomeEmptyTokens() {
        let asr = ASRResult(text: "x", confidence: 1, duration: 1, processingTime: 0)
        XCTAssertTrue(DetailedTranscription(asrResult: asr).tokens.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test -Xswiftc -DNO_APPLE_FM 2>&1 | tail -5`
Expected: FAIL to compile — `cannot find 'DetailedTranscription' in scope`.

- [ ] **Step 3: Create the type**

`Sources/Purr/DetailedTranscription.swift`:

```swift
import FluidAudio
import Foundation

// Engine-agnostic batch transcription result with per-token timings.
// Meeting mode uses `tokens` to align text with diarized speaker segments;
// an engine that can't produce timings returns an empty array and the
// meeting transcript falls back to unattributed text instead of failing.
struct DetailedTranscription {
    struct TimedToken: Equatable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
    }

    let text: String
    let tokens: [TimedToken]
    let duration: TimeInterval
}

extension DetailedTranscription {
    // FluidAudio's ASRResult (Parakeet) mapped to the engine-agnostic shape.
    init(asrResult: ASRResult) {
        self.init(
            text: asrResult.text,
            tokens: (asrResult.tokenTimings ?? []).map {
                TimedToken(text: $0.token, start: $0.startTime, end: $0.endTime)
            },
            duration: asrResult.duration
        )
    }
}
```

- [ ] **Step 4: Add the protocol requirement**

In `Sources/Purr/TranscriptionEngine.swift`, replace the protocol with:

```swift
protocol TranscriptionEngine: AnyObject {
    var supportsStreaming: Bool { get }

    func warmup() async
    func transcribe(samples: [Float]) async throws -> String
    // Batch transcription that also carries per-token timings, for callers
    // (meeting mode) that align text against diarized speaker segments.
    func transcribeDetailed(samples: [Float]) async throws -> DetailedTranscription
    func makeStreamingSession() async throws -> any StreamingSession
}
```

- [ ] **Step 5: Rename Parakeet's ASRResult method and conform**

In `Sources/Purr/ParakeetEngine.swift`, rename the existing `func transcribeDetailed(samples: [Float]) async throws -> ASRResult` to `func transcribeASR(samples: [Float]) async throws -> ASRResult` (keep its body and doc comment; overloading `transcribeDetailed` purely on return type would make the meeting call sites ambiguous). Update the one internal caller:

```swift
    func transcribe(samples: [Float]) async throws -> String {
        let detailed = try await transcribeASR(samples: samples)
        return TranscriptCleaner.clean(detailed.text)
    }
```

Then add the protocol method next to it:

```swift
    func transcribeDetailed(samples: [Float]) async throws -> DetailedTranscription {
        DetailedTranscription(asrResult: try await transcribeASR(samples: samples))
    }
```

Note: `MeetingPipeline` still calls the old signature at lines 204/226/227 — it now resolves to the new protocol method returning `DetailedTranscription`, so `MeetingPipeline` will NOT compile until Task 5. To keep this task's test cycle green, Task 5's `MeetingPipeline`/`MeetingDocument` changes are staged in the same PR; for THIS task, verify compilation of the two touched files only via the full build in Task 5. To keep commits bisectable, do Steps 1-5 of this task and all of Task 5 before running the full test suite — commit boundaries below reflect that.

**Correction for bisectability:** to keep every commit green, this task and Task 5 are committed together at the end of Task 5. Continue directly into Task 4 and 5 before committing.

- [ ] **Step 6: (deferred)** — commit happens at Task 5 Step 6.

---

### Task 4: `WhisperEngine.transcribeDetailed` with word timestamps

**Files:**
- Modify: `Sources/Purr/WhisperEngine.swift` (add static mapper + protocol method)
- Test: `Tests/PurrTests/WhisperTimedTokenTests.swift`

**Interfaces:**
- Produces: `WhisperEngine.timedTokens(from: [WordTiming]) -> [DetailedTranscription.TimedToken]` (nonisolated static) and `transcribeDetailed(samples:)` conformance.
- Consumes: `DetailedTranscription` (Task 3), WhisperKit `WordTiming` (`word: String`, `start: Float`, `end: Float`, public init).

- [ ] **Step 1: Write the failing test**

`Tests/PurrTests/WhisperTimedTokenTests.swift`:

```swift
import WhisperKit
import XCTest

@testable import Purr

final class WhisperTimedTokenTests: XCTestCase {
    func testWordsKeepTheirTimings() {
        let words = [
            WordTiming(word: " hola", tokens: [1], start: 0.0, end: 0.4, probability: 1),
            WordTiming(word: " mundo", tokens: [2], start: 0.5, end: 0.9, probability: 1),
        ]
        XCTAssertEqual(
            WhisperEngine.timedTokens(from: words),
            [
                DetailedTranscription.TimedToken(text: " hola", start: 0.0, end: 0.4),
                DetailedTranscription.TimedToken(text: " mundo", start: 0.5, end: 0.9),
            ])
    }

    func testMissingLeadingSpaceIsAdded() {
        // MeetingDocument concatenates tokens verbatim (Parakeet BPE tokens
        // carry their own leading spaces), so Whisper words must too.
        let words = [WordTiming(word: "hola", tokens: [1], start: 0, end: 1, probability: 1)]
        XCTAssertEqual(WhisperEngine.timedTokens(from: words).first?.text, " hola")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test -Xswiftc -DNO_APPLE_FM 2>&1 | tail -5`
Expected: FAIL to compile — `type 'WhisperEngine' has no member 'timedTokens'`.

- [ ] **Step 3: Implement mapper + conformance**

Add inside `WhisperEngine` (after `transcribe(samples:)`):

```swift
    // WhisperKit's DTW word timings mapped to the engine-agnostic shape.
    // MeetingDocument concatenates token text verbatim, so every word must
    // carry its leading space (WhisperKit usually includes it; normalize
    // the ones that don't so words never run together).
    nonisolated static func timedTokens(from words: [WordTiming]) -> [DetailedTranscription.TimedToken] {
        words.map { timing in
            let text = timing.word.hasPrefix(" ") ? timing.word : " " + timing.word
            return DetailedTranscription.TimedToken(
                text: text,
                start: TimeInterval(timing.start),
                end: TimeInterval(timing.end)
            )
        }
    }

    // Detailed variant for meeting mode. Always the plain transcribe task
    // with auto-detected language: the translate-to-English toggle is a
    // dictation-only affordance, and a Spanish meeting must stay Spanish.
    func transcribeDetailed(samples: [Float]) async throws -> DetailedTranscription {
        if loadedModel != modelIdentifier { await warmup() }
        guard let pipe = pipe else { throw EngineError.notLoaded }
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: nil,
            temperature: 0.0,
            sampleLength: 224,
            usePrefillPrompt: true,
            withoutTimestamps: false,
            wordTimestamps: true
        )
        let started = Date()
        let results: [TranscriptionResult] = try await pipe.transcribe(
            audioArray: samples,
            decodeOptions: options
        )
        let elapsed = Date().timeIntervalSince(started)
        let words = results.flatMap(\.segments).flatMap { $0.words ?? [] }
        let text = TranscriptCleaner.clean(results.map(\.text).joined(separator: " "))
        log.info(
            "Whisper detailed transcribe: \(samples.count, privacy: .public) samples in \(String(format: "%.2f", elapsed), privacy: .public)s, \(words.count, privacy: .public) word timings"
        )
        return DetailedTranscription(
            text: text,
            tokens: Self.timedTokens(from: words),
            duration: TimeInterval(samples.count) / 16_000.0
        )
    }
```

- [ ] **Step 4: (deferred)** — the suite still can't compile until Task 5 fixes `MeetingPipeline`; run and commit there.

---

### Task 5: Engine-agnostic `MeetingPipeline` + `MeetingDocument`

**Files:**
- Modify: `Sources/Purr/MeetingPipeline.swift` (engine provider instead of concrete Parakeet)
- Modify: `Sources/Purr/MeetingDocument.swift` (consume `DetailedTranscription`, dynamic engine label)
- Modify: `Sources/Purr/AppCoordinator.swift:181` (construction — final wiring lands in Task 7; here just keep it compiling with a provider that returns `(parakeet, "Parakeet TDT v2")`)
- Test: `Tests/PurrTests/MeetingDocumentTests.swift`

**Interfaces:**
- Consumes: `DetailedTranscription` (Task 3).
- Produces:
  - `MeetingPipeline.init(hud: RecordingHUD, summarizer: MeetingSummarizer, engineProvider: @escaping () -> (engine: any TranscriptionEngine, label: String))`
  - `MeetingDocument.format(localOnly: DetailedTranscription, duration: TimeInterval, recordedAt: Date, engineLabel: String) -> Output`
  - `MeetingDocument.format(localASR: DetailedTranscription, remoteASR: DetailedTranscription, remoteSegments: [TimedSpeakerSegment], duration: TimeInterval, recordedAt: Date, engineLabel: String) -> Output`

- [ ] **Step 1: Write the failing tests**

`Tests/PurrTests/MeetingDocumentTests.swift`:

```swift
import FluidAudio
import XCTest

@testable import Purr

final class MeetingDocumentTests: XCTestCase {
    private func token(_ text: String, _ start: Double, _ end: Double)
        -> DetailedTranscription.TimedToken
    {
        .init(text: text, start: start, end: end)
    }

    func testLocalOnlyLabelsEverythingYouAndShowsEngine() {
        let asr = DetailedTranscription(
            text: "hola mundo",
            tokens: [token("hola", 0, 0.5), token(" mundo", 0.6, 1.0)],
            duration: 2)
        let out = MeetingDocument.format(
            localOnly: asr, duration: 2, recordedAt: Date(timeIntervalSince1970: 0),
            engineLabel: "Whisper (large-v3)")
        XCTAssertTrue(out.markdown.contains("**You:** hola mundo"))
        XCTAssertTrue(out.markdown.contains("_Engine: Whisper (large-v3)_"))
        XCTAssertFalse(out.markdown.contains("Parakeet TDT v2"))
    }

    func testEmptyTokensFallBackToRawText() {
        let asr = DetailedTranscription(text: "sin timings", tokens: [], duration: 2)
        let out = MeetingDocument.format(
            localOnly: asr, duration: 2, recordedAt: Date(timeIntervalSince1970: 0),
            engineLabel: "Whisper (tiny)")
        XCTAssertTrue(out.markdown.contains("sin timings"))
        XCTAssertFalse(out.markdown.contains("**You:**"))
    }

    func testDualTrackAttributesRemoteSpeakers() {
        let local = DetailedTranscription(
            text: "vale", tokens: [token("vale", 2.0, 2.4)], duration: 5)
        let remote = DetailedTranscription(
            text: "buenos dias", tokens: [token("buenos", 0, 0.4), token(" dias", 0.5, 0.9)],
            duration: 5)
        let segments = [
            TimedSpeakerSegment(
                speakerId: "speaker_0001", embedding: [], startTimeSeconds: 0.0,
                endTimeSeconds: 1.0, qualityScore: 1.0)
        ]
        let out = MeetingDocument.format(
            localASR: local, remoteASR: remote, remoteSegments: segments,
            duration: 5, recordedAt: Date(timeIntervalSince1970: 0),
            engineLabel: "Whisper (large-v3)")
        XCTAssertTrue(out.markdown.contains("**Speaker 1:** buenos dias"))
        XCTAssertTrue(out.markdown.contains("**You:** vale"))
        XCTAssertTrue(out.markdown.contains("_Engine: Whisper (large-v3) + FluidAudio Diarizer_"))
    }
}
```

- [ ] **Step 2: Rework `MeetingDocument`**

In `Sources/Purr/MeetingDocument.swift`:

1. `format(localOnly:duration:recordedAt:)` → signature becomes `format(localOnly asr: DetailedTranscription, duration: TimeInterval, recordedAt: Date, engineLabel: String)`; the header line `body += "_Engine: Parakeet TDT v2_\n\n"` becomes `body += "_Engine: \(engineLabel)_\n\n"`.
2. `format(localASR:remoteASR:remoteSegments:duration:recordedAt:)` → gains `engineLabel: String`; the header line becomes `body += "_Engine: \(engineLabel) + FluidAudio Diarizer_\n\n"`.
3. All merge helpers swap `ASRResult` → `DetailedTranscription` and the optional `tokenTimings` unwrap for the non-optional `tokens` array:

```swift
    private static func remoteUtterances(
        asr: DetailedTranscription,
        segments: [TimedSpeakerSegment],
        labelMap: [String: String]
    ) -> [TimedUtterance] {
        let timings = asr.tokens
        guard !timings.isEmpty else {
            return rawUtterance(asr: asr, speaker: remoteFallbackSpeaker)
        }
        guard !segments.isEmpty else {
            var result: [TimedUtterance] = []
            for timing in timings {
                let token = timing.text
                if token.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                appendToken(
                    token, speaker: remoteFallbackSpeaker, start: timing.start,
                    end: timing.end, into: &result)
            }
            return result.isEmpty
                ? rawUtterance(asr: asr, speaker: remoteFallbackSpeaker) : result
        }
        let sorted = segments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds })

        var result: [TimedUtterance] = []
        for timing in timings {
            let token = timing.text
            if token.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let midpoint = (timing.start + timing.end) / 2.0
            let speakerId = speakerAt(time: midpoint, segments: sorted)
            let label = labelMap[speakerId] ?? speakerId
            appendToken(
                token, speaker: label, start: timing.start, end: timing.end,
                into: &result)
        }
        return result.isEmpty ? rawUtterance(asr: asr, speaker: remoteFallbackSpeaker) : result
    }

    private static func localUtterances(asr: DetailedTranscription) -> [TimedUtterance] {
        let timings = asr.tokens
        guard !timings.isEmpty else { return [] }
        var result: [TimedUtterance] = []
        for timing in timings {
            let token = timing.text
            if token.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            appendToken(
                token, speaker: "You", start: timing.start, end: timing.end,
                into: &result)
        }
        return result
    }

    private static func rawUtterance(asr: DetailedTranscription, speaker: String) -> [TimedUtterance] {
        let cleaned = TranscriptCleaner.clean(asr.text)
        guard !cleaned.isEmpty else { return [] }
        return [
            TimedUtterance(
                speaker: speaker,
                text: cleaned,
                startTime: 0,
                endTime: asr.duration
            )
        ]
    }
```

(`buildLabelMap`, `speakerAt`, `appendToken`, `isPunctuationOnly` and both `format` bodies are otherwise unchanged.)

- [ ] **Step 3: Rework `MeetingPipeline`**

In `Sources/Purr/MeetingPipeline.swift`:

1. Replace the stored engine and init:

```swift
    // Resolved at stop() time so a Settings change between meetings takes
    // effect without rebuilding the pipeline. The label feeds the transcript
    // header ("_Engine: ..._").
    private let engineProvider: () -> (engine: any TranscriptionEngine, label: String)
```

```swift
    init(
        hud: RecordingHUD,
        summarizer: MeetingSummarizer,
        engineProvider: @escaping () -> (engine: any TranscriptionEngine, label: String)
    ) {
        self.hud = hud
        self.summarizer = summarizer
        self.engineProvider = engineProvider
    }
```

2. In `stop()`, right after `state = .processing` / `hud.show(.transcribing)`, resolve once:

```swift
        let (engine, engineLabel) = engineProvider()
```

3. Replace the three transcription calls and the two format calls:

```swift
                let asr = try await engine.transcribeDetailed(samples: samples)
                logASRResult(asr, track: "mic")
                log.info(
                    "Meeting transcribe complete in \(String(format: "%.2f", Date().timeIntervalSince(processingStarted)), privacy: .public)s: \(asr.tokens.count, privacy: .public) tokens, single local speaker (You)"
                )
                document = MeetingDocument.format(
                    localOnly: asr,
                    duration: duration,
                    recordedAt: Date(),
                    engineLabel: engineLabel
                )
```

and in the dual-track branch:

```swift
                let remoteASR = try await engine.transcribeDetailed(samples: systemSamples)
                let localASR = try await engine.transcribeDetailed(samples: cleanedMic)
```

```swift
                log.info(
                    "Meeting dual-track complete in \(String(format: "%.2f", Date().timeIntervalSince(processingStarted)), privacy: .public)s: local \(localASR.tokens.count, privacy: .public) tokens, remote \(remoteASR.tokens.count, privacy: .public) tokens, \(remoteSegments.count, privacy: .public) speaker segments"
                )
                document = MeetingDocument.format(
                    localASR: localASR,
                    remoteASR: remoteASR,
                    remoteSegments: remoteSegments,
                    duration: duration,
                    recordedAt: Date(),
                    engineLabel: engineLabel
                )
```

(The dual-track comment "The two Parakeet passes share one AsrManager" becomes "The two ASR passes run sequentially on the same engine".)

4. Adapt the diagnostics helper:

```swift
    private func logASRResult(_ result: DetailedTranscription, track: String) {
        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        log.info(
            "ASR[\(track, privacy: .public)]: \(result.text.count, privacy: .public) chars, \(result.tokens.count, privacy: .public) tokens, audio \(String(format: "%.2f", result.duration), privacy: .public)s, empty \(trimmed.isEmpty, privacy: .public)"
        )
    }
```

- [ ] **Step 4: Keep `AppCoordinator` compiling (interim wiring)**

In `Sources/Purr/AppCoordinator.swift` (inside `start()`, line ~181), replace:

```swift
        meeting = MeetingPipeline(parakeet: parakeet, hud: hud, summarizer: summarizer)
```

with:

```swift
        meeting = MeetingPipeline(
            hud: hud,
            summarizer: summarizer,
            engineProvider: { [weak self] in
                // Interim: always Parakeet. Task 7 switches this on the
                // meeting.engine setting.
                (self?.parakeet ?? ParakeetEngine(), "Parakeet TDT v2")
            }
        )
```

- [ ] **Step 5: Run the full suite, verify all tests pass**

Run: `swift test -Xswiftc -DNO_APPLE_FM 2>&1 | tail -5`
Expected: `Test Suite 'All tests' passed` — SmokeTests (1) + DetailedTranscriptionTests (2) + WhisperTimedTokenTests (2) + MeetingDocumentTests (3).

- [ ] **Step 6: Commit Tasks 3+4+5 together**

```bash
git add Sources/Purr/DetailedTranscription.swift Sources/Purr/TranscriptionEngine.swift \
  Sources/Purr/ParakeetEngine.swift Sources/Purr/WhisperEngine.swift \
  Sources/Purr/MeetingPipeline.swift Sources/Purr/MeetingDocument.swift \
  Sources/Purr/AppCoordinator.swift Tests/PurrTests/
git commit -m "feat: engine-agnostic detailed transcription for meeting mode

Adds DetailedTranscription (text + timed tokens) to the
TranscriptionEngine protocol. Parakeet maps its ASRResult; Whisper
turns on word timestamps. MeetingPipeline resolves its engine from an
injected provider and MeetingDocument renders the real engine label."
```

---

### Task 6: `meeting.engine` setting

**Files:**
- Modify: `Sources/Purr/SettingsStore.swift` (key + property + seed + reset)

**Interfaces:**
- Produces: `SettingsStore.shared.meetingEngine: SettingsStore.Engine` (persisted, default `.parakeet`).

No unit test: `SettingsStore.shared` is a singleton over live UserDefaults; exercising it in tests would mutate the developer's real preferences. Covered by build + UAT.

- [ ] **Step 1: Add the key**

In `enum Keys` (after `static let engine = "stt.engine"`):

```swift
        static let meetingEngine = "meeting.engine"
```

- [ ] **Step 2: Add the property**

After the `@Published var engine` property:

```swift
    // Engine used to transcribe meeting recordings, independent of the
    // dictation engine: Parakeet v2 is English-only, so a Spanish meeting
    // needs Whisper without forcing every dictation onto it. Meetings are
    // batch-only, so Whisper's lack of streaming doesn't matter here.
    @Published var meetingEngine: Engine {
        didSet { defaults.set(meetingEngine.rawValue, forKey: Keys.meetingEngine) }
    }
```

- [ ] **Step 3: Seed in `init()`**

After the `self.engine = ...` seed lines:

```swift
        let storedMeetingEngine =
            defaults.string(forKey: Keys.meetingEngine) ?? Engine.parakeet.rawValue
        self.meetingEngine = Engine(rawValue: storedMeetingEngine) ?? .parakeet
```

- [ ] **Step 4: Add to `resetToDefaults()`**

After `engine = .parakeet`:

```swift
        meetingEngine = .parakeet
```

- [ ] **Step 5: Build to verify**

Run: `swift build -Xswiftc -DNO_APPLE_FM 2>&1 | tail -2`
Expected: `Build complete!`

- [ ] **Step 6: Commit**

```bash
git add Sources/Purr/SettingsStore.swift
git commit -m "feat: add meeting.engine setting (default Parakeet)"
```

---

### Task 7: Coordinator wiring + Settings UI picker

**Files:**
- Modify: `Sources/Purr/AppCoordinator.swift` (real `currentMeetingEngine()`)
- Modify: `Sources/Purr/SettingsView.swift:261-316` (picker in the Meeting Mode section)

**Interfaces:**
- Consumes: `SettingsStore.shared.meetingEngine` (Task 6), `MeetingPipeline.init(hud:summarizer:engineProvider:)` (Task 5), `WhisperEngine.modelIdentifier` (existing `nonisolated let`).

- [ ] **Step 1: Add the resolver to `AppCoordinator`**

Next to `rebuildEngine(initial:)`:

```swift
    // Resolves the meeting-transcription engine from Settings at the moment
    // a meeting stops. Parakeet reuses the shared instance (its CoreML pipes
    // are expensive to duplicate). Whisper reuses the dictation engine when
    // it's already a matching WhisperEngine; otherwise a fresh instance
    // lazy-loads on first use - meetings are infrequent enough that keeping
    // a second pipe resident isn't worth it.
    private func currentMeetingEngine() -> (engine: any TranscriptionEngine, label: String) {
        switch SettingsStore.shared.meetingEngine {
        case .parakeet:
            return (parakeet, "Parakeet TDT v2")
        case .whisper:
            let model = SettingsStore.shared.modelName
            if let existing = engine as? WhisperEngine, existing.modelIdentifier == model {
                return (existing, "Whisper (\(model))")
            }
            return (WhisperEngine(modelName: model), "Whisper (\(model))")
        }
    }
```

- [ ] **Step 2: Point the provider at it**

Replace the interim closure from Task 5 Step 4 with:

```swift
        meeting = MeetingPipeline(
            hud: hud,
            summarizer: summarizer,
            engineProvider: { [weak self] in
                self?.currentMeetingEngine() ?? (ParakeetEngine(), "Parakeet TDT v2")
            }
        )
```

- [ ] **Step 3: Add the picker to Settings > Features > Meeting Mode**

In `Sources/Purr/SettingsView.swift`, inside `Section("Meeting Mode")`, right after the `Toggle("Show Meeting Indicator", ...)` block:

```swift
                Picker("Meeting engine", selection: $settings.meetingEngine) {
                    ForEach(SettingsStore.Engine.allCases) { engine in
                        Text(engine.label).tag(engine)
                    }
                }
                .disabled(!settings.meetingEnabled)
                .help(
                    "Engine used to transcribe meetings, independent of the dictation engine. Parakeet is English-only; Whisper covers 100+ languages."
                )
                if settings.meetingEngine == .whisper {
                    Text(
                        "Whisper uses the model selected in the Engine tab — make sure it's downloaded there before your meeting."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
```

- [ ] **Step 4: Build + run tests**

Run: `swift test -Xswiftc -DNO_APPLE_FM 2>&1 | tail -3`
Expected: all 8 tests pass, build clean.

- [ ] **Step 5: Commit**

```bash
git add Sources/Purr/AppCoordinator.swift Sources/Purr/SettingsView.swift
git commit -m "feat: meeting engine picker in Settings > Features"
```

---

### Task 8: Spike — Parakeet TDT v3 multilingual (timeboxed, report only)

`Package.swift:12-14` says FluidAudio 0.8 ships "Parakeet TDT v3 batch (multilingual)". If `ParakeetEngine` can load v3, it would give Spanish meetings Parakeet speed WITH timings. **Do not implement in this branch** — the deliverable is a findings note for the PR description and, if viable, a backlog entry.

**Files:**
- Create: `docs/superpowers/specs/2026-07-02-parakeet-v3-spike.md` (findings note)

- [ ] **Step 1: Investigate FluidAudio's model-version API**

```bash
grep -rn "v3\|version" .build/checkouts/FluidAudio/Sources/FluidAudio/ASR/Parakeet/AsrModels.swift | head -20
grep -rn "language:" Sources/Purr/ParakeetEngine.swift
grep -rn "downloadAndLoad\|modelVersion\|ModelVersion" .build/checkouts/FluidAudio/Sources/FluidAudio/ASR/ | head -20
```

Questions to answer in the note: (a) does `AsrManager`/`AsrModels` accept a v2/v3 choice, (b) does v3 emit `tokenTimings`, (c) model download size, (d) does the `language:` parameter in `ParakeetEngine.transcribeDetailed`'s existing call select Spanish on v3.

- [ ] **Step 2: Write the findings note**

`docs/superpowers/specs/2026-07-02-parakeet-v3-spike.md` — answers to (a)-(d), a go/no-go recommendation, and if "go", the estimated change surface (files + rough LOC).

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-07-02-parakeet-v3-spike.md
git commit -m "docs: Parakeet v3 multilingual spike findings"
```

---

### Task 9: App build, manual UAT, PR

**Files:** none (build + validation + PR).

- [ ] **Step 1: Build the app bundle (ad-hoc signed, CLT machine)**

```bash
swift build -c release --arch arm64 -Xswiftc -DNO_APPLE_FM
APP=dist/Purr.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp .build/arm64-apple-macosx/release/Purr "$APP/Contents/MacOS/Purr"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/purr_menubar_glyph.pdf "$APP/Contents/Resources/purr_menubar_glyph.pdf"
cp -Rp .build/arm64-apple-macosx/release/llama.framework "$APP/Contents/Frameworks/llama.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Purr" 2>/dev/null || true
codesign --force --sign - "$APP/Contents/Frameworks/llama.framework"
codesign --force --sign - --entitlements Resources/Purr.entitlements "$APP"
touch "$APP"
rm -rf /Applications/Purr.app && cp -Rp "$APP" /Applications/Purr.app && open /Applications/Purr.app
```

Expected: app launches in the menu bar. (Ad-hoc signature: macOS re-asks for Accessibility/Input Monitoring after each rebuild — re-grant via menu bar > Onboarding Setup.)

- [ ] **Step 2: Manual UAT checklist**

1. Settings > Engine: download a multilingual Whisper model (e.g. `large-v3-turbo` or `small`) if not present.
2. Settings > Features > Meeting Mode: picker visible, disabled until "Enable meeting recording" is on; select **Whisper**; caption about the Engine-tab model appears.
3. Record a short meeting (⌃⌥M) speaking **Spanish** with some system audio playing (e.g. a YouTube video with speech) → stop → transcript opens in Finder: Spanish text, `**You:**`/`**Speaker N:**` attribution present, header shows `_Engine: Whisper (<model>)_ + FluidAudio Diarizer`.
4. Switch picker back to **Parakeet**, record a short English meeting → header shows `_Engine: Parakeet TDT v2_`, attribution intact (no regression).
5. Quit and relaunch Purr → picker still shows the last selection.
6. Error path: select Whisper with its model deleted (Settings > Customization > Delete Models) → record a short meeting → HUD shows "Speech model is not loaded..." and the app returns to idle without crashing.

- [ ] **Step 3: Push and open the PR against the fork**

```bash
git push -u origin feature/f1-meeting-engine
gh pr create --repo AlejandroMarchan/purr --base main \
  --title "F1: selectable meeting engine (Spanish meetings via Whisper)" \
  --body "$(cat <<'EOF'
Implements F1 of docs/superpowers/specs/2026-07-02-history-engines-postprocessing-design.md.

- Engine-agnostic DetailedTranscription in the TranscriptionEngine protocol
- Whisper word timestamps feed the diarization merge
- New meeting.engine setting + picker (default Parakeet, no behavior change)
- NO_APPLE_FM build flag for CLT-only machines
- New PurrTests target (8 tests)
- Parakeet v3 multilingual spike findings in docs/

UAT: Spanish meeting via Whisper with speaker attribution; English meeting via Parakeet unchanged.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: PR URL printed. Paste the spike findings summary as a PR comment if relevant.

---

## Self-review notes

- **Spec coverage:** protocol extension ✔ (T3), Whisper timings ✔ (T4), injection + label ✔ (T5), setting ✔ (T6), picker + degradación ✔ (T5 rawUtterance fallback + T7), spike v3 ✔ (T8), validación ✔ (T9). Spec's "degradación a mic-only sin timings" is covered by the existing `rawUtterance` fallback now driven by `tokens.isEmpty`.
- **Type consistency:** `transcribeASR` (Parakeet, internal) vs protocol `transcribeDetailed` — call sites checked; `TimedToken(text:start:end:)` used consistently; `engineProvider` tuple `(engine:label:)` consistent between T5 and T7.
- **Known compile-order caveat:** Tasks 3-5 land as one commit (protocol change breaks MeetingPipeline until reworked); documented inline.
