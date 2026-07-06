import AppKit
import SwiftUI

// WisprFlow-style hotkey field: shows the current key and, on click, listens
// for the next keypress to rebind it. Captures real combinations (⌃⌥ + key),
// bare single modifiers on *either* side (hold Left Control, hold Right Option),
// and the bare fn/globe key - the shapes HotkeyManager actually watches for.
// Multi-modifier bare chords can't be watched at runtime, so instead of
// silently ignoring them the field shows a short hint explaining why.
struct HotkeyRecorderField: View {
    let hotkey: Hotkey
    let onChange: (Hotkey) -> Void
    // Fired true when this field starts listening and false when it stops (by
    // any path: commit, Esc-cancel, tapping away, or the view disappearing).
    // The owner uses it to mute the global hotkey tap during capture.
    var onCapturingChange: (Bool) -> Void = { _ in }

    @State private var listening = false
    // Non-nil while listening after the user tried something we can't bind;
    // explains why instead of leaving the field looking dead.
    @State private var hint: String?
    @State private var recorder = HotkeyRecorder()

    private var label: String {
        if let hint { return hint }
        return listening ? "Press a key…" : hotkey.displayName
    }

    private var labelColor: Color {
        if hint != nil { return .orange }
        return listening ? Color.accentColor : .primary
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .foregroundStyle(labelColor)
                .lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "pencil")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: 190, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    listening ? Color.accentColor : Color(nsColor: .separatorColor),
                    lineWidth: listening ? 2 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
        .help("Click, then press the key or combination to use. Works with fn, "
            + "single modifiers (either side), or a modifier + key.")
        .onDisappear { stop() }
    }

    private func toggle() {
        if listening {
            stop()
        } else {
            listening = true
            hint = nil
            // Mute the global tap *before* arming the monitor so no keypress
            // slips through and fires dictation mid-capture.
            onCapturingChange(true)
            recorder.start { captured in
                finishListening()
                onChange(captured)
            } onCancel: {
                finishListening()
            } onReject: { message in
                // Keep listening; just tell the user why that didn't take.
                hint = message
            }
        }
    }

    private func stop() {
        recorder.stop()
        if listening { finishListening() }
    }

    private func finishListening() {
        listening = false
        hint = nil
        onCapturingChange(false)
    }
}

// Owns the local event monitor for one recording session. A reference type so
// the monitor closure and the field's @State don't fight over value copies.
final class HotkeyRecorder {
    private var monitor: Any?
    private var onCapture: ((Hotkey) -> Void)?
    private var onCancel: (() -> Void)?
    private var onReject: ((String) -> Void)?
    // Highest modifier combination seen while no normal key was pressed; a
    // bare-modifier hotkey is committed from it once every key is released.
    private var candidateBareModifiers: CGEventFlags = []
    // Device keyCode of the modifier establishing the candidate, valid only
    // while exactly one modifier is held. Tells us which physical key (left vs
    // right, or fn) to bind, rather than assuming a side.
    private var candidateDeviceCode: Int64?
    // Deferred commit of a lone bare modifier. macOS doesn't reliably deliver a
    // modifier's key-UP flagsChanged to a local monitor, so we can't wait for
    // "everything released" to commit - instead we commit after the modifier has
    // been held briefly with nothing following. A key or a second modifier
    // cancels it (that's a combo/chord, not a bare modifier).
    private var pendingBareCommit: DispatchWorkItem?
    // How long a lone modifier must sit alone before it commits as bare. Long
    // enough that pressing modifier+key for a combo lands the key first.
    private static let bareCommitDelay: TimeInterval = 0.4

    func start(
        onCapture: @escaping (Hotkey) -> Void,
        onCancel: @escaping () -> Void,
        onReject: @escaping (String) -> Void
    ) {
        stop()
        self.onCapture = onCapture
        self.onCancel = onCancel
        self.onReject = onReject
        candidateBareModifiers = []
        candidateDeviceCode = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) {
            [weak self] event in
            guard let self else { return event }
            let consumed = self.handle(event)
            // Swallow only key-down presses, so letters/Space don't leak into
            // the UI. Let flagsChanged (modifier press/release) pass through:
            // it's harmless (a bare modifier types nothing) and consuming it can
            // desync AppKit's modifier state.
            return (event.type == .keyDown && consumed) ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        onCapture = nil
        onCancel = nil
        onReject = nil
        candidateBareModifiers = []
        candidateDeviceCode = nil
        pendingBareCommit?.cancel()
        pendingBareCommit = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .keyDown:
            let mods = Self.cgFlags(from: event.modifierFlags)
            // Esc alone cancels the recording without changing the binding.
            if event.keyCode == 53 && mods.isEmpty {
                let cancel = onCancel
                stop()
                cancel?()
                return true
            }
            // A normal key means this is a combo, not a bare modifier - drop any
            // pending bare-modifier commit and take the key+modifiers.
            commit(Hotkey(keyCode: Int64(event.keyCode), modifiers: mods))
            return true
        case .flagsChanged:
            return handleFlagsChanged(event)
        default:
            return false
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) -> Bool {
        let code = Int64(event.keyCode)
        // The fn/globe key is special: it arrives with keyCode 63 but WITHOUT a
        // device-independent .function flag, and pressing it can pull up system
        // UI (emoji/input switcher) that swallows the key-up. So bind it right
        // on its own event instead of tracking a flag or waiting for release.
        if code == KeyCodes.fnKeyCode {
            commit(Hotkey(keyCode: nil, modifiers: .maskSecondaryFn, deviceKeyCode: code))
            return true
        }
        let mods = Self.cgFlags(from: event.modifierFlags)

        // Any modifier change supersedes a queued bare commit; we re-decide below.
        pendingBareCommit?.cancel()
        pendingBareCommit = nil

        if mods.isEmpty {
            // The OS *did* deliver a release-to-empty (not guaranteed, but when it
            // does it's the fast path). A lone modifier commits; a chord is dropped.
            if Self.isSingleModifier(candidateBareModifiers), let dev = candidateDeviceCode {
                commit(Hotkey(keyCode: nil, modifiers: candidateBareModifiers, deviceKeyCode: dev))
            } else if !candidateBareModifiers.isEmpty {
                onReject?("Use one modifier, or add a key")
            }
            candidateBareModifiers = []
            candidateDeviceCode = nil
        } else {
            candidateBareModifiers = mods
            // Remember the physical key only while exactly one modifier is held.
            candidateDeviceCode = Self.isSingleModifier(mods) ? code : nil
            if candidateDeviceCode != nil {
                // A lone modifier: commit it shortly unless a key or a second
                // modifier arrives first (which cancels this above).
                scheduleBareCommit()
            }
        }
        return true
    }

    // Commit the current lone-modifier candidate after a short hold, since the
    // key-up that would otherwise trigger the commit isn't reliably delivered.
    private func scheduleBareCommit() {
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                Self.isSingleModifier(self.candidateBareModifiers),
                let dev = self.candidateDeviceCode
            else { return }
            self.commit(
                Hotkey(keyCode: nil, modifiers: self.candidateBareModifiers, deviceKeyCode: dev))
        }
        pendingBareCommit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.bareCommitDelay, execute: work)
    }

    private func commit(_ hotkey: Hotkey) {
        let capture = onCapture
        stop()
        capture?(hotkey)
    }

    private static func cgFlags(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var result: CGEventFlags = []
        if flags.contains(.command) { result.insert(.maskCommand) }
        if flags.contains(.option) { result.insert(.maskAlternate) }
        if flags.contains(.shift) { result.insert(.maskShift) }
        if flags.contains(.control) { result.insert(.maskControl) }
        return result
    }

    private static func isSingleModifier(_ flags: CGEventFlags) -> Bool {
        let bits: [CGEventFlags] = [
            .maskCommand, .maskAlternate, .maskShift, .maskControl, .maskSecondaryFn,
        ]
        return bits.filter { flags.contains($0) }.count == 1
    }
}
