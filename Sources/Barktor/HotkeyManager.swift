import AppKit
import Carbon.HIToolbox
import os.log

// Global hotkey via `CGEvent.tapCreate`. We deliberately do not use the
// Carbon `RegisterEventHotKey` API because:
//
//   - It can't fire on bare modifiers (e.g. hold Right Option alone). The
//     "press Right Option" interaction that WisprFlow popularised is the
//     interaction users want from a dictation app, and it requires watching
//     the raw event stream.
//   - It can't distinguish left vs right modifier keys, only the logical
//     "any option/command/etc."
//
// CGEventTap sees the device-side codes for each right modifier
// separately and gives us the resolution we need.
final class HotkeyManager {
    typealias Callback = () -> Void

    enum Action: Hashable {
        case transcribe
        case meetingToggle
        case voiceEdit
        case quit
    }

    struct Binding {
        let action: Action
        let hotkey: Hotkey
        let onPress: Callback
        let onRelease: Callback
    }

    private var bindings: [Binding] = []
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    // Per-binding press state, keyed by binding index (parallel to `bindings`),
    // so every binding is observed independently. Index rather than Action
    // because the two dictation triggers share `action == .transcribe` yet
    // must track their own held state.
    private var heldDown: [Bool] = []
    private var dictationSuspended = false
    // While true the tap is disabled and every event is ignored (see setPaused).
    private var paused = false

    private let log = Logger(subsystem: "com.naktor.barktor", category: "hotkey")

    // Right-side modifier device codes (NSEvent.keyCode for modifier-only
    // flagsChanged events). Carbon's kVK_* constants don't distinguish
    // sides, so we hardcode these from IOHIDFamily.
    private static let kRightCommand: Int64 = 54
    private static let kRightShift: Int64 = 60
    private static let kRightOption: Int64 = 61
    private static let kRightControl: Int64 = 62
    private static let kEscape: Int64 = 53

    // F4: Esc cancels an in-flight dictation. Observed, not swallowed - the
    // tap is listen-only, so the frontmost app still receives the key. All
    // gating (are we even recording?) lives in the handler on the main
    // actor; dispatching an occasional no-op closure is cheaper than
    // reading coordinator state from the tap thread.
    var onEscape: (() -> Void)?

    init() {}

    deinit { uninstall() }

    func setBindings(_ new: [Binding]) {
        self.bindings = new
        self.heldDown = Array(repeating: false, count: new.count)
    }

    // Silences the dictation hotkey only (meeting + voice-edit still
    // fire). Used while a meeting is recording so the user can't
    // accidentally insert a batch transcript into a window.
    func suspendDictation(_ suspend: Bool) {
        dictationSuspended = suspend
        if suspend {
            for i in bindings.indices where bindings[i].action == .transcribe { heldDown[i] = false }
        }
    }

    // Fully mutes every binding by disabling the tap outright. Used while the
    // user is recording a *new* hotkey in Settings, so pressing keys to bind
    // one doesn't also fire dictation/meeting/quit through the live tap. The
    // Settings recorder listens via a separate local NSEvent monitor, which is
    // unaffected by this.
    func setPaused(_ paused: Bool) {
        self.paused = paused
        if let tap { CGEvent.tapEnable(tap: tap, enable: !paused) }
        if paused { for i in heldDown.indices { heldDown[i] = false } }
    }

    func install() {
        uninstall()
        // A fresh tap is always live; a reinstall (e.g. after a hotkey was just
        // recorded) clears any leftover paused state.
        paused = false

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: { _, type, event, refcon in
                    guard let refcon else { return Unmanaged.passUnretained(event) }
                    let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                    manager.handle(type: type, event: event)
                    return Unmanaged.passUnretained(event)
                },
                userInfo: userInfo
            )
        else {
            log.error("CGEvent.tapCreate failed - Input Monitoring permission probably not granted yet.")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
        log.info("Hotkey tap installed with \(self.bindings.count, privacy: .public) bindings.")
    }

    func uninstall() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        tap = nil
        runLoopSource = nil
        for i in heldDown.indices { heldDown[i] = false }
    }

    // ------------------------------------------------------------------
    // Event handling
    // ------------------------------------------------------------------

    private func handle(type: CGEventType, event: CGEvent) {
        // Paused for hotkey capture: ignore everything, and don't fight the
        // deliberate disable by re-enabling on the disabled-callback.
        if paused { return }

        // The OS occasionally disables our tap (timeout, backgrounded
        // dispatch, system sleep). Re-enable and move on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        if type == .keyDown,
            event.getIntegerValueField(.keyboardEventKeycode) == Self.kEscape,
            event.flags.intersection([.maskCommand, .maskAlternate, .maskShift, .maskControl]).isEmpty
        {
            DispatchQueue.main.async { [weak self] in self?.onEscape?() }
        }

        for (index, binding) in bindings.enumerated() {
            if dictationSuspended, binding.action == .transcribe { continue }
            if binding.hotkey.isBareModifier {
                handleBareModifier(type: type, event: event, index: index, binding: binding)
            } else {
                handleKeyCombination(type: type, event: event, index: index, binding: binding)
            }
        }
    }

    private func handleBareModifier(
        type: CGEventType, event: CGEvent, index: Int, binding: Binding
    ) {
        // Only flagsChanged events carry meaningful info for bare modifiers.
        guard type == .flagsChanged else { return }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let targetKeyCode = bareModifierTargetKeyCode(binding.hotkey)
        guard keyCode == targetKeyCode else { return }

        let modifierBit = bareModifierBit(binding.hotkey)
        let isDown = event.flags.contains(modifierBit)
        let wasDown = heldDown[index]

        if isDown && !wasDown {
            heldDown[index] = true
            log.debug(
                "Bare-modifier press: action=\(String(describing: binding.action), privacy: .public)")
            DispatchQueue.main.async { binding.onPress() }
        } else if !isDown && wasDown {
            heldDown[index] = false
            log.debug(
                "Bare-modifier release: action=\(String(describing: binding.action), privacy: .public)"
            )
            DispatchQueue.main.async { binding.onRelease() }
        }
    }

    private func handleKeyCombination(
        type: CGEventType, event: CGEvent, index: Int, binding: Binding
    ) {
        guard let targetKeyCode = binding.hotkey.keyCode else { return }
        guard type == .keyDown || type == .keyUp else { return }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == targetKeyCode else { return }

        let wasDown = heldDown[index]

        if type == .keyUp {
            // A keyUp ends the hold whenever this binding is currently
            // held - the modifier state at release time is irrelevant.
            // Users routinely lift the modifiers a few ms before the
            // letter, so the keyUp arrives with different (often empty)
            // flags; an exact modifier match here would strand the binding
            // permanently "held" and never call onRelease.
            guard wasDown else { return }
            heldDown[index] = false
            log.debug(
                "Combo release: action=\(String(describing: binding.action), privacy: .public)")
            DispatchQueue.main.async { binding.onRelease() }
            return
        }

        // keyDown: only START the hold on the exact modifier combination.
        let relevantMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift, .maskControl]
        let active = event.flags.intersection(relevantMask)
        let required = binding.hotkey.modifiers.intersection(relevantMask)
        guard active == required else { return }

        if wasDown { return }
        heldDown[index] = true
        log.debug("Combo press: action=\(String(describing: binding.action), privacy: .public)")
        DispatchQueue.main.async { binding.onPress() }
    }

    private func bareModifierTargetKeyCode(_ hotkey: Hotkey) -> Int64 {
        // The recorder captures the exact physical key (left/right side, or fn),
        // so prefer it. nil means a pre-side-aware stored hotkey, which assumed
        // the right-side key - keep that behavior.
        if let code = hotkey.deviceKeyCode { return code }
        let mods = hotkey.modifiers
        if mods.contains(CGEventFlags.maskAlternate) { return Self.kRightOption }
        if mods.contains(CGEventFlags.maskCommand) { return Self.kRightCommand }
        if mods.contains(CGEventFlags.maskShift) { return Self.kRightShift }
        if mods.contains(CGEventFlags.maskControl) { return Self.kRightControl }
        return Self.kRightOption
    }

    private func bareModifierBit(_ hotkey: Hotkey) -> CGEventFlags {
        let mods = hotkey.modifiers
        // fn is gated on its device keyCode in handleBareModifier, so the
        // secondary-fn flag here is unambiguous (arrow/function keys can't reach
        // this path).
        if mods.contains(CGEventFlags.maskSecondaryFn) { return CGEventFlags.maskSecondaryFn }
        if mods.contains(CGEventFlags.maskAlternate) { return CGEventFlags.maskAlternate }
        if mods.contains(CGEventFlags.maskCommand) { return CGEventFlags.maskCommand }
        if mods.contains(CGEventFlags.maskShift) { return CGEventFlags.maskShift }
        if mods.contains(CGEventFlags.maskControl) { return CGEventFlags.maskControl }
        return CGEventFlags.maskAlternate
    }
}
