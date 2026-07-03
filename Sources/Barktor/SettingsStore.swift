import Combine
import CoreGraphics
import Foundation

// Persistent user settings, backed by UserDefaults.
//
// Hotkey is stored as two scalars - keyCode + modifierMask - because that's
// the granularity CGEventTap reports. A bare-modifier hotkey (no normal key,
// e.g. "hold Right Option") is represented by keyCode == nil and a single
// bit set in modifierMask.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    enum Keys {
        // Legacy hotkey keys, read once to migrate into dictationTrigger:
        // the pre-0.4 single hotkey+mode, and the short-lived 0.4-dev two-trigger array.
        static let hotkeyKeyCode = "hotkey.keyCode"
        static let hotkeyModifiers = "hotkey.modifiers"
        static let hotkeyMode = "hotkey.mode"
        static let dictationTriggersArray = "hotkey.dictationTriggers"
        static let dictationTrigger = "hotkey.dictationTrigger"
        static let inputDeviceUID = "audio.inputDeviceUID"
        static let meetingHotkeyKey = "hotkey.meeting.keyCode"
        static let meetingHotkeyMod = "hotkey.meeting.modifiers"
        static let voiceEditKey = "hotkey.edit.keyCode"
        static let voiceEditMod = "hotkey.edit.modifiers"
        static let meetingEnabled = "feature.meeting"
        static let showMeetingHUD = "feature.showMeetingHUD"
        static let voiceEditEnabled = "feature.voiceEdit"
        static let modelName = "stt.modelName"
        static let autoPaste = "stt.autoPaste"
        static let onboardingDone = "onboarding.done"
        static let engine = "stt.engine"
        static let meetingEngine = "meeting.engine"
        static let translateToEnglish = "stt.translateToEnglish"
        static let translationSourceLanguage = "stt.translationSourceLanguage"
        static let dictationLanguage = "stt.dictationLanguage"
        static let smartTyping = "ui.smartTyping"
        static let voiceCommands = "ui.voiceCommands"
        static let dictionary = "post.dictionary"
        static let customVoiceCommands = "post.customVoiceCommands"
        static let customFillerWords = "post.customFillerWords"
        static let trimFillers = "post.trimFillers"
        static let summarizeMeetings = "feature.summarizeMeetings"
        static let summaryBackend = "feature.summaryBackend"
        static let meetingsFolderPath = "meetings.folderPath"
        static let systemAudioNoticeShown = "meetings.systemAudioNoticeShown"
        static let historyAudioRetention = "history.audioRetention"
        static let showHistoryOriginals = "history.showOriginals"
        static let llmPostProcessLevel = "postprocess.llmLevel"
        static let llmCustomInstructions = "postprocess.customInstructions"
        static let soundCues = "sound.cues"
        static let recordingAudio = "recording.audioAction"
    }

    // What to do with other apps' audio while a dictation records. Mute
    // silences the default output device and restores its prior state on stop.
    // (No "pause" mode: the Play/Pause key is a directionless toggle and macOS
    // exposes no reliable play-state since MediaRemote was gated in 15.4+, so it
    // would start music that was merely paused.) See MediaController.
    enum RecordingAudio: String, Codable, CaseIterable, Identifiable {
        case nothing
        case mute
        var id: String { rawValue }
        var label: String {
            switch self {
            case .nothing: return "Do nothing"
            case .mute: return "Mute audio"
            }
        }
    }

    // Which on-device LLM produces the meeting summary. Apple FM is the
    // default on macOS 26+; older systems coerce to .llamaCpp at use time.
    enum SummaryBackend: String, Codable, CaseIterable, Identifiable {
        case appleFoundation
        case llamaCpp
        var id: String { rawValue }
    }

    // Ordered Live-first so the streaming engines (the app's flagship Smart
    // Typing) lead: English-live → multilingual-live → multilingual-fast →
    // widest-coverage. This order drives every picker (dictation + meeting) and
    // the history retry menu. rawValue is unchanged, so persistence is safe.
    enum Engine: String, Codable, CaseIterable, Identifiable {
        case parakeet
        case nemotron
        case parakeetV3
        case whisper
        var id: String { rawValue }

        // Model codename, shown as the row title in the selector and as the
        // plain label in the meeting-engine picker and history retry menu.
        var label: String {
            switch self {
            case .parakeet: return "Parakeet TDT v2"
            case .nemotron: return "Nemotron"
            case .parakeetV3: return "Parakeet TDT v3"
            case .whisper: return "Whisper"
            }
        }

        // One honest benefit line under the selector row. Positioning grounded
        // in the measured es/en WER bake-off: v2 is English-only (es unusable),
        // v3 is the fastest accurate multilingual batch, Nemotron trades a hair
        // of accuracy for the only live multilingual typing, Whisper is the most
        // accurate + widest and can translate to English.
        var summary: String {
            switch self {
            case .parakeet:
                return "Fastest and most accurate English. Types live as you speak. English only."
            case .nemotron:
                return
                    "Spanish, English, French, Italian, Portuguese, German — typed live as you speak. The only multilingual engine with Smart Typing."
            case .parakeetV3:
                return
                    "25 European languages incl. Spanish. The fastest multilingual option; inserts when you finish speaking."
            case .whisper:
                return
                    "100+ languages incl. Chinese, Japanese, and Arabic. Our most accurate engine; can translate speech to English."
            }
        }

        // Compact language-scope badge for the selector row.
        var languageBadge: String {
            switch self {
            case .parakeet: return "English"
            case .nemotron: return "6 languages"
            case .parakeetV3: return "25 languages"
            case .whisper: return "100+ languages"
            }
        }

        // Decision-helping stats on the selector row, from the FLEURS es/en WER
        // bake-off (8 clips, M5 Pro — approximate, small sample; see the
        // barktor-asr-engine-bakeoff note). Word accuracy ≈ 100 − WER, rounded,
        // shown in the engine's dominant language. All cluster at 95-98%, which
        // is the honest takeaway: pick by language + Smart Typing, not decimals.
        var accuracyStat: String {
            switch self {
            case .parakeet: return "≈95% English"
            case .nemotron: return "≈96% Spanish"
            case .parakeetV3: return "≈97% Spanish"
            case .whisper: return "≈98% Spanish"
            }
        }

        // Speed as latency for the live engines (throughput is the wrong lens
        // when it types as you speak) and as ×real-time for the batch engines.
        var speedStat: String {
            switch self {
            case .parakeet: return "Fastest · types live"
            case .nemotron: return "Live · 60 ms to first word"
            case .parakeetV3: return "~110× real-time"
            case .whisper: return "~45× real-time"
            }
        }

        // Engines that can stream partials for Smart Typing (live preview +
        // insert as you speak): Parakeet v2 via its separate EOU model,
        // Nemotron intrinsically. Whisper and Parakeet v3 are batch-only.
        // Doubles as the "Live" badge flag in the selector.
        var supportsSmartTyping: Bool {
            switch self {
            case .parakeet, .nemotron: return true
            case .parakeetV3, .whisper: return false
            }
        }

        // ISO 639-1 codes this engine can be pinned to (besides Auto). Empty =
        // the engine ignores language (Parakeet v2 is English-only). Nemotron
        // runs the 6-language latin variant; v3 covers ~28 European; Whisper the
        // full 100. Drives the per-engine Language picker and clamps a shared
        // choice the engine can't honor back to auto-detect.
        var languageCodes: [String] {
            switch self {
            case .parakeet: return []
            case .nemotron: return ["es", "en", "fr", "it", "pt", "de"]
            case .parakeetV3:
                return [
                    "en", "es", "fr", "de", "it", "pt", "ro", "nl", "da", "sv", "fi", "hu", "et",
                    "lv", "lt", "mt", "pl", "cs", "sk", "sl", "hr", "bs", "ru", "uk", "be", "bg",
                    "sr", "el",
                ]
            case .whisper: return WhisperLanguage.all.dropFirst().map(\.code)
            }
        }

        var offersLanguagePicker: Bool { !languageCodes.isEmpty }

        // The shared dictation language clamped to what this engine supports;
        // "" = auto-detect. A code the engine can't do falls back to auto.
        func clampedLanguage(_ code: String) -> String {
            code.isEmpty || languageCodes.contains(code) ? code : ""
        }
    }

    // How a dictation trigger is activated. Replaces the old single global
    // "hold vs toggle" mode: each trigger now carries its own gesture, so the
    // user can bind e.g. Right Option to hold-to-talk and a second key to
    // double-tap toggle.
    enum Gesture: String, Codable, CaseIterable, Identifiable {
        case hold
        case tapToggle
        case doubleTapToggle
        var id: String { rawValue }
        var label: String {
            switch self {
            case .hold: return "Hold to talk"
            case .tapToggle: return "Tap to toggle"
            case .doubleTapToggle: return "Double-tap to toggle"
            }
        }
    }

    // The dictation triggers (max 2). Each is a key + a gesture, both routed to
    // the same dictation state machine. Persisted as JSON; migrated from the
    // legacy single `hotkey` + `hotkeyMode` on first launch after upgrade.
    @Published var dictationTrigger: DictationTrigger {
        didSet { persistDictationTrigger() }
    }

    // Stable UID of the input device to record from; "" means the system default.
    // A UID (not an AudioDeviceID) so the choice survives reconnects and reboots.
    // AudioRecorder resolves it at open time and falls back to the default when
    // the pinned device isn't currently present.
    @Published var inputDeviceUID: String {
        didSet { defaults.set(inputDeviceUID, forKey: Keys.inputDeviceUID) }
    }

    @Published var meetingHotkey: Hotkey {
        didSet { persistMeetingHotkey() }
    }

    @Published var voiceEditHotkey: Hotkey {
        didSet { persistVoiceEditHotkey() }
    }

    @Published var meetingEnabled: Bool {
        didSet { defaults.set(meetingEnabled, forKey: Keys.meetingEnabled) }
    }

    // Whether the floating "Meeting · 0:00" recording pill (with its live
    // waveform) is shown while a meeting records. When off, the meeting still
    // records and the menu bar shows a recording indicator - only the
    // on-screen pill is suppressed; transcribing/summary/error HUDs still show.
    @Published var showMeetingHUD: Bool {
        didSet { defaults.set(showMeetingHUD, forKey: Keys.showMeetingHUD) }
    }

    @Published var voiceEditEnabled: Bool {
        didSet { defaults.set(voiceEditEnabled, forKey: Keys.voiceEditEnabled) }
    }

    @Published var modelName: String {
        didSet { defaults.set(modelName, forKey: Keys.modelName) }
    }

    @Published var autoPaste: Bool {
        didSet { defaults.set(autoPaste, forKey: Keys.autoPaste) }
    }

    @Published var onboardingDone: Bool {
        didSet { defaults.set(onboardingDone, forKey: Keys.onboardingDone) }
    }

    // Set once after we warn the user that a meeting captured silent system
    // audio (output was active but the System Audio Recording permission is
    // off). Persisted so the one-time notice never nags on later meetings.
    var systemAudioNoticeShown: Bool {
        get { defaults.bool(forKey: Keys.systemAudioNoticeShown) }
        set { defaults.set(newValue, forKey: Keys.systemAudioNoticeShown) }
    }

    @Published var engine: Engine {
        didSet { defaults.set(engine.rawValue, forKey: Keys.engine) }
    }

    // Engine used to transcribe meeting recordings, independent of the
    // dictation engine: Parakeet v2 is English-only, so a Spanish meeting
    // needs Whisper without forcing every dictation onto it. Meetings are
    // batch-only, so Whisper's lack of streaming doesn't matter here.
    @Published var meetingEngine: Engine {
        didSet { defaults.set(meetingEngine.rawValue, forKey: Keys.meetingEngine) }
    }

    // How long dictation audio is kept for retry/recover. Text stays until
    // manually deleted; only the WAVs expire. "Never" keeps no audio at all.
    @Published var historyAudioRetention: AudioRetention {
        didSet { defaults.set(historyAudioRetention.rawValue, forKey: Keys.historyAudioRetention) }
    }

    // Reveal the raw transcript + red-strikethrough diff in history rows that
    // the LLM post-processed. Off by default to keep the list compact.
    @Published var showHistoryOriginals: Bool {
        didSet { defaults.set(showHistoryOriginals, forKey: Keys.showHistoryOriginals) }
    }

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

    // Audible confirmation that a recording actually started/stopped -
    // dictation is eyes-free, so the HUD alone is easy to miss.
    @Published var soundCues: Bool {
        didSet { defaults.set(soundCues, forKey: Keys.soundCues) }
    }

    // Pause / mute other apps' audio while recording a dictation. Off by
    // default. Applies to dictation only - meeting mode captures system audio
    // on purpose, so it's never touched.
    @Published var recordingAudio: RecordingAudio {
        didSet { defaults.set(recordingAudio.rawValue, forKey: Keys.recordingAudio) }
    }

    // Whisper-only: when on, transcription runs the X→English translate task
    // instead of plain same-language transcription. Inert on Parakeet and on
    // Whisper models that can't translate (turbo / English-only) — the
    // toggle is gated in Settings and WhisperEngine re-checks
    // ModelManager.supportsTranslation before honouring it.
    @Published var translateToEnglish: Bool {
        didSet { defaults.set(translateToEnglish, forKey: Keys.translateToEnglish) }
    }

    // Source language for Whisper translation. Empty string = auto-detect.
    // Pinning a language skips Whisper's audio-based detection, which is
    // unreliable on short utterances. Consulted only when translateToEnglish
    // is on; valid values are WhisperLanguage codes.
    @Published var translationSourceLanguage: String {
        didSet { defaults.set(translationSourceLanguage, forKey: Keys.translationSourceLanguage) }
    }

    // The language you dictate in, shared across engines (ISO 639-1 code; ""
    // = auto-detect). Each engine clamps it to what it supports: Whisper 100+,
    // Nemotron 6 (latin), Parakeet v3 ~28 European; Parakeet v2 ignores it
    // (English-only). Whisper uses it for both transcription and the translate
    // source language.
    @Published var dictationLanguage: String {
        didSet { defaults.set(dictationLanguage, forKey: Keys.dictationLanguage) }
    }

    // Smart typing = real-time streaming + word-by-word insertion at the
    // cursor as the user speaks. Only meaningful with a streaming-capable
    // engine (Parakeet). When the active engine doesn't support streaming
    // and this is on, the coordinator transparently falls back to batch
    // and surfaces a hint in the HUD.
    @Published var smartTyping: Bool {
        didSet { defaults.set(smartTyping, forKey: Keys.smartTyping) }
    }

    @Published var voiceCommands: Bool {
        didSet { defaults.set(voiceCommands, forKey: Keys.voiceCommands) }
    }

    @Published var trimFillers: Bool {
        didSet { defaults.set(trimFillers, forKey: Keys.trimFillers) }
    }

    // Off until the user has explicitly downloaded the GGUF model AND
    // opted in (macOS < 26), or until Apple Intelligence is available on
    // macOS 26+. We never run a 2.5 GB download by surprise.
    @Published var summarizeMeetings: Bool {
        didSet { defaults.set(summarizeMeetings, forKey: Keys.summarizeMeetings) }
    }

    @Published var summaryBackend: SummaryBackend {
        didSet { defaults.set(summaryBackend.rawValue, forKey: Keys.summaryBackend) }
    }

    // Where meeting transcripts (and their .summary.md sidecars) are saved.
    // Empty string = unset, which resolves to `defaultMeetingsDirectory` -
    // a folder under ~/Library/Application Support that needs no TCC consent,
    // so a save never trips a permission prompt. A non-empty path is a
    // user-chosen folder; if it ever becomes unwritable, MeetingDocument
    // falls back to the default so a transcript is never lost.
    @Published var meetingsFolderPath: String {
        didSet { defaults.set(meetingsFolderPath, forKey: Keys.meetingsFolderPath) }
    }

    // Default save location: ~/Library/Application Support/Barktor/Meetings.
    // Matches the App Support convention already used for models, and unlike
    // ~/Documents it is not TCC-protected, so the app can always create and
    // write here without a consent prompt.
    static var defaultMeetingsDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Barktor/Meetings", isDirectory: true)
    }

    // Custom dictionary maps spoken-form → preferred-form, applied as a
    // case-insensitive whole-word post-process on every transcript.
    // Useful for proper nouns and brand spellings the model gets wrong.
    @Published var dictionary: [DictionaryEntry] {
        didSet {
            if let data = try? JSONEncoder().encode(dictionary) {
                defaults.set(data, forKey: Keys.dictionary)
            }
        }
    }

    // Custom voice commands map a spoken phrase → literal replacement text,
    // applied in the voice-command post-processing pass alongside the
    // built-in commands and gated by the same `voiceCommands` toggle.
    @Published var customVoiceCommands: [VoiceCommandEntry] {
        didSet {
            if let data = try? JSONEncoder().encode(customVoiceCommands) {
                defaults.set(data, forKey: Keys.customVoiceCommands)
            }
        }
    }

    // Custom filler words the user wants stripped, applied in the filler-trim
    // pass after the built-in hesitations and gated by the same `trimFillers`
    // toggle. Lets the user opt into removing words the built-in pass leaves
    // alone ("like", "you know", "basically", …).
    @Published var customFillerWords: [FillerWordEntry] {
        didSet {
            if let data = try? JSONEncoder().encode(customFillerWords) {
                defaults.set(data, forKey: Keys.customFillerWords)
            }
        }
    }

    private let defaults = UserDefaults.standard

    private init() {
        if let data = defaults.data(forKey: Keys.dictationTrigger),
            let decoded = try? JSONDecoder().decode(DictationTrigger.self, from: data)
        {
            self.dictationTrigger = decoded
        } else if let data = defaults.data(forKey: Keys.dictationTriggersArray),
            let first = (try? JSONDecoder().decode([DictationTrigger].self, from: data))?.first
        {
            // Migrate from the short-lived two-trigger array: keep the first.
            self.dictationTrigger = first
        } else {
            // First launch after upgrade (or a clean install): fold the legacy
            // single hotkey + mode into one trigger. `nil`/`nil` means nothing
            // was ever stored -> seed the documented Right Option default.
            let legacyKey = defaults.object(forKey: Keys.hotkeyKeyCode) as? Int
            let legacyMods = defaults.object(forKey: Keys.hotkeyModifiers) as? UInt
            self.dictationTrigger = DictationTrigger.migrate(
                legacyKeyCode: legacyKey.map { Int64($0) },
                legacyModifiers: legacyMods.map { UInt64($0) },
                legacyMode: defaults.string(forKey: Keys.hotkeyMode)
            )
        }
        self.inputDeviceUID = defaults.string(forKey: Keys.inputDeviceUID) ?? ""
        self.modelName = defaults.string(forKey: Keys.modelName) ?? ModelManager.defaultModel
        self.autoPaste = defaults.object(forKey: Keys.autoPaste) as? Bool ?? true
        self.onboardingDone = defaults.bool(forKey: Keys.onboardingDone)
        let storedEngine = defaults.string(forKey: Keys.engine) ?? Engine.parakeet.rawValue
        self.engine = Engine(rawValue: storedEngine) ?? .parakeet
        let storedMeetingEngine =
            defaults.string(forKey: Keys.meetingEngine) ?? Engine.parakeet.rawValue
        self.meetingEngine = Engine(rawValue: storedMeetingEngine) ?? .parakeet
        let storedRetention =
            defaults.string(forKey: Keys.historyAudioRetention) ?? AudioRetention.week.rawValue
        self.historyAudioRetention = AudioRetention(rawValue: storedRetention) ?? .week
        self.showHistoryOriginals = defaults.bool(forKey: Keys.showHistoryOriginals)
        let storedLLMLevel =
            defaults.string(forKey: Keys.llmPostProcessLevel) ?? LLMPostProcessLevel.off.rawValue
        self.llmPostProcessLevel = LLMPostProcessLevel(rawValue: storedLLMLevel) ?? .off
        self.llmCustomInstructions = defaults.string(forKey: Keys.llmCustomInstructions) ?? ""
        self.soundCues = defaults.object(forKey: Keys.soundCues) as? Bool ?? true
        let storedRecordingAudio =
            defaults.string(forKey: Keys.recordingAudio) ?? RecordingAudio.nothing.rawValue
        self.recordingAudio = RecordingAudio(rawValue: storedRecordingAudio) ?? .nothing
        self.translateToEnglish = defaults.object(forKey: Keys.translateToEnglish) as? Bool ?? false
        self.translationSourceLanguage = defaults.string(forKey: Keys.translationSourceLanguage) ?? ""
        // Seed from the legacy Whisper source-language pin so an existing choice
        // carries over the first time this shared setting appears.
        self.dictationLanguage =
            defaults.string(forKey: Keys.dictationLanguage)
            ?? defaults.string(forKey: Keys.translationSourceLanguage) ?? ""
        self.smartTyping = defaults.object(forKey: Keys.smartTyping) as? Bool ?? false
        self.voiceCommands = defaults.object(forKey: Keys.voiceCommands) as? Bool ?? true
        self.trimFillers = defaults.object(forKey: Keys.trimFillers) as? Bool ?? true
        self.summarizeMeetings = defaults.object(forKey: Keys.summarizeMeetings) as? Bool ?? false
        let storedBackend =
            defaults.string(forKey: Keys.summaryBackend) ?? SummaryBackend.appleFoundation.rawValue
        self.summaryBackend = SummaryBackend(rawValue: storedBackend) ?? .appleFoundation
        self.meetingsFolderPath = defaults.string(forKey: Keys.meetingsFolderPath) ?? ""
        if let data = defaults.data(forKey: Keys.dictionary),
            let entries = try? JSONDecoder().decode([DictionaryEntry].self, from: data)
        {
            self.dictionary = entries
        } else {
            self.dictionary = []
        }
        if let data = defaults.data(forKey: Keys.customVoiceCommands),
            let entries = try? JSONDecoder().decode([VoiceCommandEntry].self, from: data)
        {
            self.customVoiceCommands = entries
        } else {
            self.customVoiceCommands = []
        }
        if let data = defaults.data(forKey: Keys.customFillerWords),
            let entries = try? JSONDecoder().decode([FillerWordEntry].self, from: data)
        {
            self.customFillerWords = entries
        } else {
            self.customFillerWords = []
        }

        let mKey = defaults.object(forKey: Keys.meetingHotkeyKey) as? Int
        let mMods = defaults.object(forKey: Keys.meetingHotkeyMod) as? UInt
        self.meetingHotkey = Hotkey(
            keyCode: mKey.map { Int64($0) } ?? Hotkey.defaultMeeting.keyCode,
            modifiers: mMods.map { CGEventFlags(rawValue: UInt64($0)) } ?? Hotkey.defaultMeeting.modifiers
        )
        let eKey = defaults.object(forKey: Keys.voiceEditKey) as? Int
        let eMods = defaults.object(forKey: Keys.voiceEditMod) as? UInt
        self.voiceEditHotkey = Hotkey(
            keyCode: eKey.map { Int64($0) } ?? Hotkey.defaultVoiceEdit.keyCode,
            modifiers: eMods.map { CGEventFlags(rawValue: UInt64($0)) }
                ?? Hotkey.defaultVoiceEdit.modifiers
        )
        self.meetingEnabled = defaults.object(forKey: Keys.meetingEnabled) as? Bool ?? false
        self.showMeetingHUD = defaults.object(forKey: Keys.showMeetingHUD) as? Bool ?? true
        self.voiceEditEnabled = defaults.object(forKey: Keys.voiceEditEnabled) as? Bool ?? false
    }

    // Returns every user-facing preference to its first-launch defaults.
    // Leaves transitional state (onboardingDone) and disk artifacts
    // (downloaded models) alone - the user can clear those explicitly via
    // the model rows. didSet on each @Published var handles persistence.
    func resetToDefaults() {
        dictationTrigger = DictationTrigger(hotkey: .defaultRightOption, gesture: .hold)
        inputDeviceUID = ""
        meetingHotkey = .defaultMeeting
        voiceEditHotkey = .defaultVoiceEdit
        meetingEnabled = false
        showMeetingHUD = true
        voiceEditEnabled = false
        engine = .parakeet
        meetingEngine = .parakeet
        historyAudioRetention = .week
        llmPostProcessLevel = .off
        llmCustomInstructions = ""
        soundCues = true
        recordingAudio = .nothing
        modelName = ModelManager.defaultModel
        translateToEnglish = false
        translationSourceLanguage = ""
        dictationLanguage = ""
        autoPaste = true
        smartTyping = false
        voiceCommands = true
        trimFillers = true
        summarizeMeetings = false
        summaryBackend = .appleFoundation
        meetingsFolderPath = ""
        dictionary = []
        customVoiceCommands = []
        customFillerWords = []
    }

    private func persistDictationTrigger() {
        guard let data = try? JSONEncoder().encode(dictationTrigger) else { return }
        defaults.set(data, forKey: Keys.dictationTrigger)
    }

    private func persistMeetingHotkey() {
        if let keyCode = meetingHotkey.keyCode {
            defaults.set(Int(keyCode), forKey: Keys.meetingHotkeyKey)
        } else {
            defaults.removeObject(forKey: Keys.meetingHotkeyKey)
        }
        defaults.set(UInt(meetingHotkey.modifiers.rawValue), forKey: Keys.meetingHotkeyMod)
    }

    private func persistVoiceEditHotkey() {
        if let keyCode = voiceEditHotkey.keyCode {
            defaults.set(Int(keyCode), forKey: Keys.voiceEditKey)
        } else {
            defaults.removeObject(forKey: Keys.voiceEditKey)
        }
        defaults.set(UInt(voiceEditHotkey.modifiers.rawValue), forKey: Keys.voiceEditMod)
    }
}

// The dictation trigger: a key + the gesture that activates it (see AppCoordinator).
struct DictationTrigger: Codable, Equatable {
    var hotkey: Hotkey
    var gesture: SettingsStore.Gesture

    // Fold the pre-0.4 single hotkey + global mode into a trigger.
    // `legacyKeyCode`/`legacyModifiers` are nil when nothing was stored, which
    // means a clean install -> seed the documented Right Option default. Pure
    // and total so it can be unit-tested without the UserDefaults singleton.
    static func migrate(
        legacyKeyCode: Int64?, legacyModifiers: UInt64?, legacyMode: String?
    ) -> DictationTrigger {
        let hotkey: Hotkey
        if legacyKeyCode == nil && legacyModifiers == nil {
            hotkey = .defaultRightOption
        } else {
            hotkey = Hotkey(
                keyCode: legacyKeyCode,
                modifiers: legacyModifiers.map { CGEventFlags(rawValue: $0) }
                    ?? Hotkey.defaultRightOption.modifiers
            )
        }
        let gesture: SettingsStore.Gesture = (legacyMode == "toggle") ? .tapToggle : .hold
        return DictationTrigger(hotkey: hotkey, gesture: gesture)
    }
}

// A hotkey is either:
//   - bare modifiers (keyCode == nil, modifiers != 0)            e.g. hold Right Option
//   - modifiers + key (both present)                              e.g. ⌃⌥ Space
//   - bare key (keyCode != nil, modifiers == 0)                   e.g. F5
struct Hotkey: Equatable, Codable {
    var keyCode: Int64?
    var modifiers: CGEventFlags

    var isBareModifier: Bool { keyCode == nil && !modifiers.isEmpty }

    // CGEventFlags is an OptionSet, not Codable; round-trip it via its rawValue.
    private enum CodingKeys: String, CodingKey { case keyCode, modifiers }
    init(keyCode: Int64?, modifiers: CGEventFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try c.decodeIfPresent(Int64.self, forKey: .keyCode)
        modifiers = CGEventFlags(rawValue: try c.decode(UInt64.self, forKey: .modifiers))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(keyCode, forKey: .keyCode)
        try c.encode(modifiers.rawValue, forKey: .modifiers)
    }

    static let defaultRightOption = Hotkey(
        keyCode: nil,
        // CGEventFlags doesn't distinguish left/right out of the box;
        // HotkeyManager checks the device-side bit (NX_DEVICERALTKEYMASK)
        // to gate "right" specifically. We store .maskAlternate as a logical
        // hint; the manager interprets bare-modifier hotkeys as side-aware.
        modifiers: .maskAlternate
    )

    // Meeting toggle defaults to ⌃⌥M. M (kVK_ANSI_M) = 46. Picked because
    // (a) it doesn't collide with any default macOS shortcut, (b) the M
    // mnemonic is easy to remember, and (c) Control+Option together
    // require an intentional press, avoiding accidental meeting starts.
    static let defaultMeeting = Hotkey(
        keyCode: 46,
        modifiers: [.maskControl, .maskAlternate]
    )

    // Voice-edit defaults to ⌃⌥E. E (kVK_ANSI_E) = 14. "E" for Edit.
    static let defaultVoiceEdit = Hotkey(
        keyCode: 14,
        modifiers: [.maskControl, .maskAlternate]
    )

    // Quit shortcut. Hardcoded (not user-configurable) - shadows the status-
    // bar Quit item so power users never have to reach for the mouse, and so
    // the app can be terminated when no Barktor window is frontmost (the standard
    // ⌘Q only fires when a window is key). Lives on ⌃⌥ to stay clear of any
    // focused-app ⌘ shortcuts. kVK_ANSI_Q = 12.
    static let quitApp = Hotkey(
        keyCode: 12,
        modifiers: [.maskControl, .maskAlternate]
    )

    var displayName: String {
        var parts: [String] = []
        if modifiers.contains(CGEventFlags.maskControl) { parts.append("⌃") }
        if modifiers.contains(CGEventFlags.maskAlternate) { parts.append("⌥") }
        if modifiers.contains(CGEventFlags.maskShift) { parts.append("⇧") }
        if modifiers.contains(CGEventFlags.maskCommand) { parts.append("⌘") }
        if let code = keyCode {
            parts.append(KeyCodes.name(for: code))
        } else if isBareModifier {
            // Bare modifier hotkey: clarify that it's the right-side key
            // (which is the whole point of bare-modifier mode - the left
            // ones get used as actual modifiers in everyday typing).
            return "Right \(parts.joined())"
        }
        return parts.joined()
    }
}

// One row in the custom dictionary. `from` and `to` are matched
// case-insensitively as whole words; replacement preserves the surrounding
// whitespace.
struct DictionaryEntry: Codable, Equatable, Identifiable, Hashable {
    var id: UUID = UUID()
    var from: String
    var to: String
}

// One custom voice command. `phrase` is matched case-insensitively as a whole
// word; `replacement` is inserted in its place, with \n and \t escapes
// expanded so a command can produce whitespace.
struct VoiceCommandEntry: Codable, Equatable, Identifiable, Hashable {
    var id: UUID = UUID()
    var phrase: String
    var replacement: String
}

// One custom filler word or phrase. Matched case-insensitively as a whole
// word and removed during the filler-trim pass.
struct FillerWordEntry: Codable, Equatable, Identifiable, Hashable {
    var id: UUID = UUID()
    var word: String
}

enum KeyCodes {
    static func name(for code: Int64) -> String {
        // Unlisted codes fall through to "Key <n>".
        switch code {
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 49: return "Space"
        case 36: return "Return"
        case 46: return "M"
        case 14: return "E"
        case 15: return "R"
        case 9: return "V"
        case 43: return ","
        case 31: return "O"
        case 12: return "Q"
        default: return "Key \(code)"
        }
    }
}
