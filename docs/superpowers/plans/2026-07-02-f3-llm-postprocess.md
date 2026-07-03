# F3: Configurable LLM Post-Processing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Optional local-LLM cleanup/rewrite of batch dictations with user-defined instructions (e.g. "spoken enumerations become line-broken lists"), defaulting to Off so nothing changes for anyone who doesn't opt in.

**Architecture:** A new `LLMPostProcessor` (static, stateless) builds a level-specific Gemma prompt (chat template + watchdog pattern copied from `EditInterpreter`), runs it through the existing `LlamaRuntime` actor, and falls back silently to the deterministic text on timeout (15 s), failure, or missing model. It intercepts the batch flow only, after `PostProcessor.apply` and before insertion (same order as Voice Edit: deterministic first, LLM second), and the same polish is applied in history retry. `rawText` in history stays the unedited ASR stream (F2's shipped contract); `processedText` becomes the LLM output when the level ≠ Off — F2's raw↔processed toggle is the "Undo AI edit" view for free.

**Tech Stack:** Swift 5.9 / SwiftPM, llama.cpp via existing `LlamaRuntime`/`LlamaSession` (Gemma 3 4B), SwiftUI settings section, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-07-02-history-engines-postprocessing-design.md` (section F3).

## Global Constraints

- Target: macOS 14+, Apple Silicon only. No new package dependencies.
- Canonical test command: `make test` (Swift Testing; currently 23 tests). Build check: `swift build -Xswiftc -DNO_APPLE_FM` → `Build complete!`.
- Settings conventions: `Keys` constant + `@Published` with `didSet` + seed in `init()` + `resetToDefaults()`. UI copy in English; comments explain constraints.
- **Default behavior must not change:** `postprocess.llmLevel` defaults to `Off` → the batch pipeline is byte-identical to today. The dictation must never be lost or indefinitely delayed: every LLM failure path returns the deterministic text.
- Engine: Gemma only via `LlamaRuntime.shared.generate` (F3 never uses Apple FoundationModels; this machine compiles it out anyway). Watchdog 15 s. `temperature: 0.2`, `maxTokens = max(256, min(2000, text.count / 2))` (≈2× input tokens at ~4 chars/token).
- Batch mode only. Smart Typing (streaming) is untouched; Settings shows a note when both are enabled.
- Spec deviation (controller-resolved): the spec's "Historial: rawText = salida determinista" is superseded by F2's shipped contract (`rawText` = full unedited ASR stream, enforced by review). `processedText` = final inserted text (LLM when on). The intermediate deterministic text is not persisted — "Undo AI edit" = the raw view, or a Retry with level Off.
- Branch: `feature/f3-llm-postprocess` off `feature/f2-history` (stacked). Remote `origin` = `naktor-solutions/naktor-purr`.

---

### Task 1: `LLMPostProcessLevel` + settings

**Files:**
- Create: `Sources/Purr/LLMPostProcessor.swift` (the enum only; Task 2 adds the processor to the same file)
- Modify: `Sources/Purr/SettingsStore.swift` (2 keys + 2 properties + seeds + resets)

**Interfaces:**
- Produces:

```swift
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
```

- `SettingsStore.shared.llmPostProcessLevel: LLMPostProcessLevel` (key `postprocess.llmLevel`, default `.off`)
- `SettingsStore.shared.llmCustomInstructions: String` (key `postprocess.customInstructions`, default `""`)

- [ ] **Step 1: Create the enum file**

`Sources/Purr/LLMPostProcessor.swift` with a file header comment:

```swift
import Foundation

// Optional LLM pass over batch dictations, applied AFTER the deterministic
// PostProcessor (fillers, voice commands, dictionary) and BEFORE insertion -
// the same order Voice Edit uses. Off by default; every failure path falls
// back to the deterministic text so a dictation is never lost or stalled.
```

followed by the `LLMPostProcessLevel` enum from the Interfaces block, verbatim.

- [ ] **Step 2: SettingsStore additions**

In `enum Keys` (after `historyAudioRetention`):

```swift
        static let llmPostProcessLevel = "postprocess.llmLevel"
        static let llmCustomInstructions = "postprocess.customInstructions"
```

After the `historyAudioRetention` property:

```swift
    // Optional LLM cleanup/rewrite of batch dictations. Off preserves the
    // deterministic-only pipeline byte for byte; Smart Typing streams are
    // never LLM-processed (the text is already typed sentence by sentence).
    @Published var llmPostProcessLevel: LLMPostProcessLevel {
        didSet { defaults.set(llmPostProcessLevel.rawValue, forKey: Keys.llmPostProcessLevel) }
    }

    // Free-form user guidance appended to the active level's prompt (e.g.
    // "format enumerations as bullet lists").
    @Published var llmCustomInstructions: String {
        didSet { defaults.set(llmCustomInstructions, forKey: Keys.llmCustomInstructions) }
    }
```

Seeds in `init()` (after the `historyAudioRetention` seed):

```swift
        let storedLLMLevel =
            defaults.string(forKey: Keys.llmPostProcessLevel) ?? LLMPostProcessLevel.off.rawValue
        self.llmPostProcessLevel = LLMPostProcessLevel(rawValue: storedLLMLevel) ?? .off
        self.llmCustomInstructions = defaults.string(forKey: Keys.llmCustomInstructions) ?? ""
```

In `resetToDefaults()` (after `historyAudioRetention = .week`):

```swift
        llmPostProcessLevel = .off
        llmCustomInstructions = ""
```

- [ ] **Step 3: Build to verify** — `swift build -Xswiftc -DNO_APPLE_FM 2>&1 | tail -2` → `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/Purr/LLMPostProcessor.swift Sources/Purr/SettingsStore.swift
git commit -m "feat: LLM post-processing level and instructions settings (default Off)"
```

---

### Task 2: `LLMPostProcessor` (prompt, watchdog, fallback)

**Files:**
- Modify: `Sources/Purr/LLMPostProcessor.swift` (add the processor below the enum)
- Test: `Tests/PurrTests/LLMPostProcessorTests.swift`

**Interfaces:**
- Consumes: `LlamaRuntime.shared.generate(prompt:parameters:)` (actor func, throws), `LlamaSession.Parameters(maxTokens:temperature:)` (other fields defaulted), `LLMModelManager.isInstalled()`, `SettingsStore.shared.llmPostProcessLevel/.llmCustomInstructions` (Task 1).
- Produces (all on `enum LLMPostProcessor`):
  - `static func polish(_ text: String) async -> String` (reads settings; convenience for callers)
  - `static func polish(_ text: String, level: LLMPostProcessLevel, customInstructions: String) async -> String` (explicit, testable)
  - `static func prompt(for text: String, level: LLMPostProcessLevel, customInstructions: String) -> String` (internal, tested via @testable)
  - `static func sanitize(_ raw: String) -> String` (internal, tested)
  - `static func maxTokens(forInputLength count: Int) -> Int` (internal, tested)

- [ ] **Step 1: Write the failing tests**

`Tests/PurrTests/LLMPostProcessorTests.swift`:

```swift
import Testing

@testable import Purr

struct LLMPostProcessorTests {
    @Test func promptCarriesLevelRulesAndText() {
        let p = LLMPostProcessor.prompt(
            for: "hola mundo", level: .cleanup, customInstructions: "")
        // Gemma chat template wrapping (same as EditInterpreter).
        #expect(p.hasPrefix("<start_of_turn>user\n"))
        #expect(p.contains("<end_of_turn>\n<start_of_turn>model"))
        // The one non-negotiable cleanup rule and the payload.
        #expect(p.contains("Never change the user's words"))
        #expect(p.contains("hola mundo"))
        // No custom-instructions block when empty.
        #expect(!p.contains("Additional instructions"))
    }

    @Test func promptAppendsCustomInstructions() {
        let p = LLMPostProcessor.prompt(
            for: "x", level: .rewrite, customInstructions: "bullet lists please")
        #expect(p.contains("Additional instructions from the user"))
        #expect(p.contains("bullet lists please"))
        #expect(p.contains("Rewrite"))
    }

    @Test func sanitizeStripsFencesAndWhitespace() {
        #expect(LLMPostProcessor.sanitize("\n```\nhola\n```\n") == "hola")
        #expect(LLMPostProcessor.sanitize("```text\nhola\n```") == "hola")
        #expect(LLMPostProcessor.sanitize("  hola  \n") == "hola")
        #expect(LLMPostProcessor.sanitize("hola\nmundo") == "hola\nmundo")
    }

    @Test func maxTokensScalesWithInputAndClamps() {
        #expect(LLMPostProcessor.maxTokens(forInputLength: 10) == 256)
        #expect(LLMPostProcessor.maxTokens(forInputLength: 1000) == 500)
        #expect(LLMPostProcessor.maxTokens(forInputLength: 100_000) == 2000)
    }

    @Test func offLevelPassesThroughUntouched() async {
        let text = "  raw text with, weird punctuation  "
        let out = await LLMPostProcessor.polish(text, level: .off, customInstructions: "")
        #expect(out == text)
    }

    @Test func missingModelFallsBackToInput() async {
        // This CLT machine has no Gemma GGUF installed, so the guard path is
        // exercised for real: polish must return the input unchanged, fast.
        guard !LLMModelManager.isInstalled() else { return }
        let out = await LLMPostProcessor.polish(
            "hola mundo", level: .cleanup, customInstructions: "")
        #expect(out == "hola mundo")
    }
}
```

- [ ] **Step 2: Run to verify failure** — `make test 2>&1 | tail -5` → compile FAIL (`no member 'prompt'`).

- [ ] **Step 3: Implement**

Append to `Sources/Purr/LLMPostProcessor.swift`:

```swift
import os.log

enum LLMPostProcessor {
    private static let log = Logger(subsystem: "com.arunbrahma.purr", category: "llm-postprocess")

    // 15 s watchdog: LlamaRuntime serializes generations, so a meeting
    // summary in flight can queue this call - past the deadline the dictation
    // ships deterministic rather than waiting.
    private static let timeout: Duration = .seconds(15)

    static func polish(_ text: String) async -> String {
        await polish(
            text,
            level: SettingsStore.shared.llmPostProcessLevel,
            customInstructions: SettingsStore.shared.llmCustomInstructions)
    }

    static func polish(
        _ text: String, level: LLMPostProcessLevel, customInstructions: String
    ) async -> String {
        guard level != .off,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return text }
        guard LLMModelManager.isInstalled() else {
            log.info("LLM level active but Gemma not installed - shipping deterministic text")
            return text
        }
        let parameters = LlamaSession.Parameters(
            maxTokens: maxTokens(forInputLength: text.count), temperature: 0.2)
        let work = Task {
            try await LlamaRuntime.shared.generate(
                prompt: prompt(for: text, level: level, customInstructions: customInstructions),
                parameters: parameters)
        }
        let watchdog = Task<Void, Error> {
            try await Task.sleep(for: timeout)
            work.cancel()
        }
        do {
            let raw = try await work.value
            watchdog.cancel()
            let cleaned = sanitize(raw)
            guard !cleaned.isEmpty else {
                log.warning("LLM returned empty output - shipping deterministic text")
                return text
            }
            return cleaned
        } catch {
            watchdog.cancel()
            log.warning(
                "LLM post-processing failed or timed out (\(error.localizedDescription, privacy: .public)) - shipping deterministic text"
            )
            return text
        }
    }

    // MARK: - Prompt

    static func prompt(
        for text: String, level: LLMPostProcessLevel, customInstructions: String
    ) -> String {
        let task: String
        switch level {
        case .off:
            task = ""  // never reached by polish(); kept total for the type
        case .cleanup:
            task = """
                Clean up this dictated text. Fix punctuation and capitalization, remove \
                false starts, hesitations and immediate repetitions, and format spoken \
                enumerations (like "first... second..." or "one... two...") as a list with \
                line breaks. Never change the user's words beyond those repairs, never add \
                content, and never translate - keep the original language exactly.
                """
        case .rewrite:
            task = """
                Rewrite this dictated text so it reads clearly and naturally. Keep the \
                meaning, tone and language of the original - never translate. Fix grammar, \
                punctuation and structure, and format spoken enumerations as a list with \
                line breaks.
                """
        }
        let custom = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let customBlock =
            custom.isEmpty
            ? ""
            : """


                Additional instructions from the user:
                \(custom)
                """
        let body = """
            \(task)\(customBlock)

            Reply with ONLY the resulting text - no preamble, no quotes, no code fences.

            Text:
            \(text)
            """
        // Gemma chat template, same shape EditInterpreter uses.
        return """
            <start_of_turn>user
            \(body)<end_of_turn>
            <start_of_turn>model

            """
    }

    // MARK: - Output hygiene

    // Models occasionally wrap output in code fences or stray whitespace
    // despite instructions; strip the wrappers, never the content.
    static func sanitize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            if !lines.isEmpty { lines.removeFirst() }  // ``` or ```lang
            if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    // ~2x the input tokens at the ~4 chars/token rule of thumb, clamped so a
    // one-liner still has room and a monologue can't run the context out.
    static func maxTokens(forInputLength count: Int) -> Int {
        max(256, min(2000, count / 2))
    }
}
```

- [ ] **Step 4: Run tests** — `make test 2>&1 | tail -5` → all pass (23 + 6 = 29).

- [ ] **Step 5: Commit**

```bash
git add Sources/Purr/LLMPostProcessor.swift Tests/PurrTests/LLMPostProcessorTests.swift
git commit -m "feat: LLM post-processor with Gemma watchdog and silent fallback"
```

---

### Task 3: Batch integration + HUD "Polishing…" + warm-up + retry parity

**Files:**
- Modify: `Sources/Purr/AppCoordinator.swift` (`finishBatchRecording` success path; `retryHistoryEntry`; `handleTranscribePress`)
- Modify: `Sources/Purr/RecordingHUD.swift` (new `Mode` case + its label, mirroring `summarizing`)

**Interfaces:**
- Consumes: `LLMPostProcessor.polish(_:)` (Task 2), `SettingsStore.shared.llmPostProcessLevel/.smartTyping`, `LLMModelManager.isInstalled()`, `LlamaRuntime.shared.warmUp()`.

- [ ] **Step 1: HUD case**

In `Sources/Purr/RecordingHUD.swift`, add `case polishing` to `enum Mode` (after `transcribing`). Find where each `Mode` maps to its pill label/icon (the same switch that renders `summarizing`) and add the `polishing` branch with the label `"Polishing…"`, styled like `transcribing`/`summarizing`.

- [ ] **Step 2: Batch intercept**

In `finishBatchRecording`'s `do` block, right after `let processed = makePostProcessor().apply(raw)`, insert:

```swift
            // Optional LLM pass, after the deterministic pipeline ("scratch
            // that" and dropPreviousChunks are already resolved) and before
            // any insertion. polish() returns the input untouched when the
            // level is Off, the model is missing, or generation fails/times
            // out - the dictation always ships.
            var finalText = processed.text
            if !finalText.isEmpty, SettingsStore.shared.llmPostProcessLevel != .off {
                hud.show(.polishing)
                finalText = await LLMPostProcessor.polish(finalText)
            }
```

Then replace every use of `processed.text` in the branch chain below (the `if processed.text.isEmpty` / autoPaste insert / clipboard copy) and in the history update with `finalText`. Note: `processed.dropPreviousChunks` stays read from `processed`.

- [ ] **Step 3: Retry parity**

In `retryHistoryEntry`, after `let processed = makePostProcessor().apply(raw)`, add `let polished = await LLMPostProcessor.polish(processed.text)` and store `$0.processedText = polished` (raw stays the ASR output). One short comment: retry produces what a fresh dictation would, under the current settings.

- [ ] **Step 4: Warm-up on hotkey press**

Read `handleTranscribePress()` (~AppCoordinator.swift:549). At its start (alongside whatever early gating exists, without disturbing it), add:

```swift
        // Overlap a cold Gemma load with the user speaking (EditInterpreter
        // does the same for voice edit). Only for batch dictations - Smart
        // Typing never LLM-processes.
        if SettingsStore.shared.llmPostProcessLevel != .off,
            !SettingsStore.shared.smartTyping,
            LLMModelManager.isInstalled()
        {
            Task { await LlamaRuntime.shared.warmUp() }
        }
```

(If `warmUp()` is not `async`, drop the `await` — match the real signature; `EditInterpreter.warmUp` wraps it as `Task { await LlamaRuntime.shared.warmUp() }`.)

- [ ] **Step 5: Run tests + build** — `make test 2>&1 | tail -5` → 29 pass; `swift build -Xswiftc -DNO_APPLE_FM` → `Build complete!`.

- [ ] **Step 6: Commit**

```bash
git add Sources/Purr/AppCoordinator.swift Sources/Purr/RecordingHUD.swift
git commit -m "feat: LLM polish pass in batch dictation with Polishing HUD state"
```

---

### Task 4: Settings UI — Section("AI cleanup")

**Files:**
- Modify: `Sources/Purr/SettingsView.swift` (featuresTab: new section between `Section("Meeting summary")` and `Section("Voice Editing Mode")`)

**Interfaces:**
- Consumes: `$settings.llmPostProcessLevel`, `$settings.llmCustomInstructions`, `settings.smartTyping`, `voiceEditLLM.isInstalled` (the existing shared Gemma view-model `LLMSummaryViewModel`).

- [ ] **Step 1: Add the section**

In `featuresTab`, after `Section("Meeting summary") { MeetingSummarySection(vm: voiceEditLLM) }` and before `Section("Voice Editing Mode")`:

```swift
            Section("AI cleanup") {
                Picker("Level", selection: $settings.llmPostProcessLevel) {
                    ForEach(LLMPostProcessLevel.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                Text(settings.llmPostProcessLevel.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.llmPostProcessLevel != .off {
                    if settings.smartTyping {
                        Text(
                            "AI cleanup applies only when Smart Typing is off - streamed text is already typed sentence by sentence."
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                    if !voiceEditLLM.isInstalled {
                        Text(
                            "Uses the same local Gemma model as Meeting summary - download it there first. Until then, dictations get the standard cleanup."
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Custom instructions")
                        TextEditor(text: $settings.llmCustomInstructions)
                            .font(.body)
                            .frame(height: 60)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.secondary.opacity(0.3))
                            )
                        Text("Added to the prompt, e.g. \"format enumerations as bullet lists\".")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
```

(If `voiceEditLLM.isInstalled` is not the property's real name, read `LLMSummaryViewModel` and use its actual installed-state property; `SettingsView.swift:395` references it.)

- [ ] **Step 2: Run tests + build** — `make test 2>&1 | tail -5` → 29 pass; build `Build complete!`.

- [ ] **Step 3: Commit**

```bash
git add Sources/Purr/SettingsView.swift
git commit -m "feat: AI cleanup section in Settings > Features"
```

---

### Task 5: App build, validation, PR

**Files:** none (build + validation + PR).

- [ ] **Step 1: Validation scope note**

Gemma is NOT installed on this machine, so the LLM-output path cannot be validated autonomously (no 2.5 GB download without the user). What IS validated: Off-level passthrough and missing-model fallback are unit-tested against the real installed-state check; the prompt/sanitizer/token-budget logic is unit-tested; everything else is code-reviewed. UAT (user, with Gemma downloaded from Settings > Features > Meeting summary): dictate an enumeration with level "Clean up" → line-broken list; level Off → identical to today; custom instruction respected; model missing → silent deterministic fallback.

- [ ] **Step 2: Build + install** (same recipe as F1/F2: release build with `-DNO_APPLE_FM`, assemble `dist/Purr.app`, ad-hoc sign, quit + replace `/Applications/Purr.app`, relaunch).

- [ ] **Step 3: Push + PR (stacked on F2)**

```bash
git push -u origin feature/f3-llm-postprocess
gh pr create --repo naktor-solutions/naktor-purr --base feature/f2-history --head feature/f3-llm-postprocess \
  --title "F3: configurable LLM post-processing (cleanup/rewrite + custom instructions)" \
  --body "<summary: levels Off/Clean up/Rewrite, custom instructions, Gemma+watchdog+silent fallback, batch-only, Polishing HUD, retry parity; stacked on #2; UAT needs Gemma downloaded>"
```

---

## Self-review notes

- **Spec coverage:** levels + default Off ✔ (T1), custom instructions ✔ (T1/T2/T4), Gemma + chat template + watchdog + 15 s + fallback ✔ (T2), temperature/maxTokens ✔ (T2), order deterministic→LLM ✔ (T3), batch-only + HUD ✔ (T3), warm-up reuse ✔ (T3 Step 4), Smart Typing note ✔ (T4), history raw/processed as "Undo AI edit" ✔ (T3 + documented deviation in Global Constraints), Settings section next to the other Gemma consumers ✔ (T4), actor contention covered by watchdog ✔ (T2 comment). Validation ✔ (T5, scoped to what's possible without Gemma).
- **Type consistency:** `LLMPostProcessLevel` cases/labels consistent T1→T4; `polish(_:)`/`polish(_:level:customInstructions:)` consistent T2→T3; `finalText` only inside `finishBatchRecording`.
- **Placeholder scan:** clean; T5's PR body is written at PR time from executed reality.
- **Known softness:** RecordingHUD's label-mapping location is described, not quoted (the file wasn't fully read while planning) — the implementer mirrors the `summarizing` case; if the mapping is structured differently, NEEDS_CONTEXT is the right escalation.
