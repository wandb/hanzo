import Testing
@testable import HanzoCore

@Suite("HotkeyService.displayString")
struct HotkeyServiceDisplayStringTests {

    @Test("Control modifier produces ⌃")
    func controlModifier() {
        let result = HotkeyService.displayString(keyCode: 49, modifiers: 4096)
        #expect(result.contains("⌃"))
    }

    @Test("Option modifier produces ⌥")
    func optionModifier() {
        let result = HotkeyService.displayString(keyCode: 49, modifiers: 2048)
        #expect(result.contains("⌥"))
    }

    @Test("Shift modifier produces ⇧")
    func shiftModifier() {
        let result = HotkeyService.displayString(keyCode: 49, modifiers: 512)
        #expect(result.contains("⇧"))
    }

    @Test("Command modifier produces ⌘")
    func commandModifier() {
        let result = HotkeyService.displayString(keyCode: 49, modifiers: 256)
        #expect(result.contains("⌘"))
    }

    @Test("Multiple modifiers produce multiple symbols")
    func multipleModifiers() {
        // Control (4096) + Command (256)
        let result = HotkeyService.displayString(keyCode: 49, modifiers: 4352)
        #expect(result.contains("⌃"))
        #expect(result.contains("⌘"))
    }

    @Test("Space key (keyCode 49) produces Space")
    func spaceKey() {
        let result = HotkeyService.displayString(keyCode: 49, modifiers: 0)
        #expect(result.contains("Space"))
    }

    @Test("No modifiers produces only key name")
    func noModifiers() {
        let result = HotkeyService.displayString(keyCode: 49, modifiers: 0)
        #expect(!result.contains("⌃"))
        #expect(!result.contains("⌥"))
        #expect(!result.contains("⇧"))
        #expect(!result.contains("⌘"))
    }

    @Test("Default hotkey is Option+Space")
    func defaultHotkey() {
        let result = HotkeyService.displayString(
            keyCode: Constants.defaultHotkeyCode,
            modifiers: Constants.defaultHotkeyModifiers
        )
        #expect(result.contains("⌥"))
        #expect(result.contains("Space"))
    }

    @Test("Letter key A (keyCode 0) produces A")
    func letterKeyA() {
        let result = HotkeyService.displayString(keyCode: 0, modifiers: 0)
        #expect(result == "A")
    }
}
