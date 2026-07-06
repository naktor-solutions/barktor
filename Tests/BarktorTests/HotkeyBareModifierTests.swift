import CoreGraphics
import Foundation
import Testing

@testable import Barktor

// Covers the side-aware / fn-aware bare-modifier hotkeys added so users can bind
// the fn (globe) key and left-side modifiers, not just right-side ones.
struct HotkeyBareModifierTests {
    // MARK: displayName

    @Test func fnBareModifierDisplaysAsFn() {
        let hotkey = Hotkey(
            keyCode: nil, modifiers: .maskSecondaryFn, deviceKeyCode: KeyCodes.fnKeyCode)
        #expect(hotkey.displayName == "fn")
        #expect(hotkey.isBareModifier)
    }

    @Test func leftControlNamesTheLeftSide() {
        let hotkey = Hotkey(keyCode: nil, modifiers: .maskControl, deviceKeyCode: 59)
        #expect(hotkey.displayName == "Left ⌃")
    }

    @Test func rightControlNamesTheRightSide() {
        let hotkey = Hotkey(keyCode: nil, modifiers: .maskControl, deviceKeyCode: 62)
        #expect(hotkey.displayName == "Right ⌃")
    }

    @Test func legacyBareModifierWithoutDeviceCodeDefaultsToRight() {
        // Hotkeys stored before deviceKeyCode existed have it nil and must keep
        // reading as the right-side key so the binding doesn't change meaning.
        #expect(Hotkey.defaultRightOption.deviceKeyCode == nil)
        #expect(Hotkey.defaultRightOption.displayName == "Right ⌥")
    }

    // MARK: Codable

    @Test func deviceKeyCodeSurvivesRoundTrip() throws {
        let cases: [Hotkey] = [
            Hotkey(keyCode: nil, modifiers: .maskControl, deviceKeyCode: 59),
            Hotkey(keyCode: nil, modifiers: .maskSecondaryFn, deviceKeyCode: KeyCodes.fnKeyCode),
            .defaultRightOption,  // deviceKeyCode nil must stay nil
        ]
        for hotkey in cases {
            let data = try JSONEncoder().encode(hotkey)
            let decoded = try JSONDecoder().decode(Hotkey.self, from: data)
            #expect(decoded == hotkey)
            #expect(decoded.deviceKeyCode == hotkey.deviceKeyCode)
        }
    }
}
