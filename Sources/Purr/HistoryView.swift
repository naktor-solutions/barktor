import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Dictation history: stats header, newest-first list with per-entry actions,
// retention + delete-all footer. Shared verbatim by the dedicated History
// window and the Settings > History tab.
struct HistoryView: View {
    @ObservedObject private var store = HistoryStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    let coordinator: AppCoordinator

    @State private var showDeleteAllConfirmation = false

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    var body: some View {
        VStack(spacing: 0) {
            statsHeader
            Divider()
            if store.entries.isEmpty {
                Spacer()
                Text("No dictations yet. Hold your hotkey and speak - every dictation lands here.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                Spacer()
            } else {
                List {
                    ForEach(store.entries) { entry in
                        let hasAudio = store.audioURL(for: entry) != nil
                        HistoryRow(
                            entry: entry,
                            isRetrying: store.retryingEntryIDs.contains(entry.id),
                            canRetry: hasAudio && store.retryingEntryIDs.isEmpty, // One retry at a time: each Whisper retry loads its own model instance.
                            canExport: hasAudio,
                            onCopy: { copy($0) },
                            onRetry: { engine in retry(entry, engine: engine) },
                            onExport: { export(entry) },
                            onDelete: { store.delete(entry.id) }
                        )
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            footer
        }
        .frame(minWidth: 480, minHeight: 420)
    }

    private var statsHeader: some View {
        let stats = store.stats()
        return HStack(spacing: 24) {
            statCell(value: "\(stats.totalWords)", label: "words dictated")
            statCell(value: String(format: "%.0f", stats.averageWPM), label: "avg WPM")
            statCell(value: "\(stats.streakDays)", label: "day streak")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    private func statCell(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2).fontWeight(.semibold).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Picker("Keep audio", selection: $settings.historyAudioRetention) {
                ForEach(AudioRetention.allCases) { retention in
                    Text(retention.label).tag(retention)
                }
            }
            .fixedSize()
            .help("How long dictation audio is kept for Retry. Text stays until you delete it.")
            .onChange(of: settings.historyAudioRetention) {
                store.sweepExpiredAudio()
            }
            Spacer()
            Button("Delete All History", role: .destructive) {
                showDeleteAllConfirmation = true
            }
            .disabled(store.entries.isEmpty || !store.retryingEntryIDs.isEmpty) // A retry in flight targets an entry by id - don't yank the rug.
            .confirmationDialog(
                "Delete all history?", isPresented: $showDeleteAllConfirmation
            ) {
                Button("Delete Everything", role: .destructive) { store.deleteAll() }
            } message: {
                Text("Removes every entry and all saved audio. This cannot be undone.")
            }
        }
        .padding(10)
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func retry(_ entry: DictationEntry, engine: SettingsStore.Engine) {
        Task { await coordinator.retryHistoryEntry(entry.id, using: engine) }
    }

    private func export(_ entry: DictationEntry) {
        guard let source = store.audioURL(for: entry) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = "Dictation \(entry.date.formatted(.iso8601.year().month().day())).wav"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let dest = panel.url {
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: source, to: dest)
        }
    }
}

private struct HistoryRow: View {
    let entry: DictationEntry
    let isRetrying: Bool
    let canRetry: Bool
    let canExport: Bool
    let onCopy: (String) -> Void
    let onRetry: (SettingsStore.Engine) -> Void
    let onExport: () -> Void
    let onDelete: () -> Void

    @State private var showRaw = false
    @State private var showDeleteConfirmation = false

    private var needsAttention: Bool {
        entry.status == .failed || entry.status == .interrupted
    }

    private var shownText: String? { showRaw ? entry.rawText : entry.displayText }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                statusBadge
                Text(entry.date, format: .relative(presentation: .named))
                    .font(.caption).foregroundStyle(.secondary)
                Text(String(format: "%.0fs", entry.duration))
                    .font(.caption).foregroundStyle(.secondary)
                Text(engineDisplayName)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                actions
            }
            if let text = shownText, !text.isEmpty {
                Text(text)
                    .lineLimit(3)
                    .textSelection(.enabled)
            } else if let message = entry.errorMessage {
                Text(message).foregroundStyle(.orange).font(.callout)
            } else if canExport {
                Text("No text - use Retry to transcribe the saved audio.")
                    .foregroundStyle(.secondary).font(.callout)
            } else {
                Text("No text - the audio wasn't saved, so this entry can't be retried.")
                    .foregroundStyle(.secondary).font(.callout)
            }
        }
        .padding(.vertical, 4)
        .overlay(alignment: .leading) {
            if needsAttention {
                Rectangle().fill(.orange).frame(width: 3).offset(x: -8)
            }
        }
    }

    private var statusBadge: some View {
        Group {
            switch entry.status {
            case .ok:
                EmptyView()
            case .failed:
                Label("Failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            case .interrupted:
                Label("Interrupted", systemImage: "bolt.horizontal.fill")
                    .font(.caption).foregroundStyle(.orange)
            case .cancelled:
                Label("Cancelled", systemImage: "xmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var engineDisplayName: String {
        if entry.engineUsed == "parakeet" { return "Parakeet" }
        if entry.engineUsed.hasPrefix("whisper:") {
            return "Whisper (\(entry.engineUsed.dropFirst("whisper:".count)))"
        }
        return entry.engineUsed
    }

    private var actions: some View {
        HStack(spacing: 6) {
            if isRetrying {
                ProgressView().controlSize(.small)
            } else if canRetry {
                Menu("Retry") {
                    ForEach(SettingsStore.Engine.allCases) { engine in
                        Button(engine.label) { onRetry(engine) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Button("Copy") { shownText.map(onCopy) }
                .disabled(shownText?.isEmpty != false)
            if entry.rawText != nil, entry.processedText != nil, entry.rawText != entry.processedText {
                Toggle("Raw", isOn: $showRaw).toggleStyle(.button).controlSize(.small)
            }
            Button(action: onExport) { Image(systemName: "square.and.arrow.up") }
                .help("Export audio as WAV")
                .disabled(!canExport)
            Button(role: .destructive, action: { showDeleteConfirmation = true }) {
                Image(systemName: "trash")
            }
            .disabled(isRetrying)
            .confirmationDialog("Delete this entry?", isPresented: $showDeleteConfirmation) {
                Button("Delete", role: .destructive, action: onDelete)
            }
        }
        .controlSize(.small)
        .buttonStyle(.borderless)
    }
}
