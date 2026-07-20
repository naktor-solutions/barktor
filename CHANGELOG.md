# Changelog

All notable changes to Barktor are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org).

## [0.4.0] - 2026-07-20

### Fixed
- The first transcription after switching to a Whisper engine could hang for many minutes. Loading a Whisper model runs a one-time Apple Neural Engine compile; a missing guard let the background warm-up and the first dictation compile the same model at once, thrashing the Neural Engine. Warm-ups are now coalesced so the model compiles exactly once.
- Parakeet transcription could hang indefinitely on some Macs, pinning the status pill on "Transcribing" with no way to recover. A watchdog now bounds the CoreML inference (generous and audio-proportional, so it only trips on a genuine hang) and aborts a stuck decode into a recoverable error.
- The menu-bar icon could end up orphaned (never drawn) on macOS Tahoe. The app now registers a proper main menu so the status item always appears, and remembers its position in the bar.
- Updating from a 0.2.x Purr install now migrates your old settings, history and models even when an empty Barktor scaffold already exists.

### Added
- **Copy a dictation with one click.** Click anywhere on a history row to copy its text — a "Copied" check confirms it, no aiming for the small copy button.
- **See what AI cleanup changed, in History.** A new **Show originals** checkbox (History footer) reveals the raw transcript above the polished result for dictations the LLM post-processed, with the words the AI dropped or replaced struck through in red. Off by default; replaces the old per-entry raw-vs-processed toggle.
- **Multilingual live dictation (new engine).** A new **Multilingual** engine (NVIDIA Nemotron, on the Apple Neural Engine) dictates in 6 languages — Spanish, English, French, Italian, Portuguese, and German — **with live Smart Typing**, so the words appear as you speak, not only when you finish. It's the only multilingual engine that streams; Parakeet v3 and Whisper stay batch-only. Downloads ~600 MB on first use from Settings › Engine.
- **Pick your dictation language.** Settings › Engine has a Language control (default Auto-detect), shared across engines: Whisper covers 100+ languages, Parakeet v3 ~28 European, and the Multilingual engine its 6. Pinning a language improves accuracy on short phrases and skips misdetection; each engine falls back to auto-detect for a language it can't do. (For Whisper this also sets the translate-from language.)
- Choose which microphone to record from in Settings › General. The pick is remembered by device (so it survives reconnects and reboots) and falls back to the system default when that device isn't plugged in; "System Default" keeps the previous behavior of following whatever macOS selects.
- Whisper models now warm up as soon as they finish downloading, so the one-time Neural Engine compile happens under the download's own progress instead of on your first dictation.
- The status pill shows "Warming up…" instead of "Transcribing" while a cold model is still loading, so a slow first run is no longer mistaken for a stuck transcription.
- **Mute audio while you dictate.** Settings › General can mute other apps' audio (music, video) while a dictation records and restore its prior state the moment you stop — so you're not talking over your music. Off by default; enable it under "While recording."

### Changed
- **Dictation trigger reworked: pick the gesture and record any key.** The fixed "Hold to talk / Tap to toggle" mode is replaced by one trigger where you choose the gesture — **Hold** (hold to talk; double-tap to lock hands-free, press once to stop), **Tap to toggle**, or **Double-tap to toggle** — and set the key by clicking the field and pressing any key or combination (bare Right Option, ⌃⌥Space, F5, …) instead of picking from a short preset list. Your existing hotkey and mode carry over automatically.
- **Settings › Engine, reworked.** Smart Typing moved here from General and now lives with the engine that provides it, shown only for engines that can stream — so it's no longer offered where it can't run. The engine picker was redesigned: each option shows its language coverage, a Smart Typing badge, and at-a-glance accuracy and speed, so it's clear which one to pick. On the Multilingual engine, Smart Typing no longer needs the separate Parakeet EOU download.
- The menu-bar glyph is now a dog-only silhouette, legible at the 18 pt status-item size.

## [0.3.0] - 2026-07-03

### Changed
- **Purr is now Barktor.** New app name, bundle identifier (`com.naktor.barktor`), repository (`naktor-solutions/barktor`), and release asset names (`Barktor.dmg`). Because the bundle identifier changed, macOS asks you to re-grant the three permissions once after updating.
- Default meetings folder is now `~/Library/Application Support/Barktor/Meetings`.
- The DMG install window was redrawn for Barktor and is now sharp on Retina displays.

### Fixed
- The menu bar icon could fail to appear at all on macOS Tahoe (the app had
  no main menu, which can orphan the status item). Ported from upstream Purr.
- A hung transcription (CoreML never returning) no longer pins the HUD on
  "Transcribing" forever; it now stops with a clear error after a generous,
  audio-proportional timeout. Ported from upstream Purr.

### Added
- New Barktor app icon and menu-bar glyph.
- One-time migration from a 0.2.x Purr install: settings, dictation history, downloaded models, and meeting transcripts all move to the new identity automatically on first launch. If you update in place from 0.2.0, the bundle in /Applications keeps its old `Purr.app` file name - installing fresh from the DMG (and deleting `Purr.app`) is recommended.

## [0.2.0] - 2026-07-03

First Naktor release, forked from [iamarunbrahma/purr](https://github.com/iamarunbrahma/purr) at 0.0.1.

### Added
- **Meeting engine picker**: meetings can now transcribe with Whisper (any language, word-level timings for speaker attribution) or Parakeet, instead of always forcing Parakeet (English-only).
- **Dictation history** (Settings > History, and a History window in the menu): every dictation is kept with its text, audio, engine, duration and status. Audio is saved *before* transcription, so failed, interrupted or cancelled dictations can be **retried** with any engine. Includes copy, raw-vs-processed toggle, WAV export, per-entry and delete-all, configurable audio retention, and a stats header (words, average WPM, day streak).
- **AI cleanup** (Settings > Features): optional local LLM post-processing of batch dictations with Gemma 3 4B - "Clean up" (punctuation, false starts, spoken lists; never changes your words) or "Rewrite" (clarity, same meaning and language), plus free-form custom instructions. Every failure path falls back to the standard deterministic cleanup; a dictation is never lost.
- **Esc cancels** an in-flight dictation. The audio still lands in History as a cancelled entry, so a mistaken Esc loses nothing.
- **Hands-free lock**: in hold-to-talk, a quick double-press locks the recording on with no key held; the next press stops it.
- **Open at login** and **sound cues** toggles (Settings > General).
- **Reopening Purr.app** (Finder, Spotlight, Launchpad) now surfaces Settings - or Onboarding while setup is incomplete - so a crowded menu bar or the notch can no longer strand you with no way into the app.
- **What's New in About**: the About window shows the installed version and this changelog.

### Changed
- History rows redesigned: cards with hover-revealed actions, a prominent Copy button with the rest behind an ellipsis menu, and readable model names ("Whisper · Large V3 Turbo" instead of the model filename).
- App identity: bundle identifier is now `com.naktor.purr` and the in-app updater follows releases of `naktor-solutions/naktor-purr`. Updating from an upstream 0.0.x install requires re-granting permissions once.

### Security
- LLM prompts hardened against prompt injection: dictated text is delimited and treated strictly as data (the model no longer answers or auto-completes what you dictate), and Gemma chat-template control tokens are neutralized in all interpolated content (dictations, voice-edit selections, meeting transcripts, custom instructions).
