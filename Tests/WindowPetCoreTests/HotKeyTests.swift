import XCTest
@testable import WindowPetCore

final class HotKeyTests: XCTestCase {

    func testDefaultIsOptionSpace() {
        let binding = HotKeyBinding.default
        XCTAssertEqual(binding.keyCode, KeyCodes.byName["space"])
        XCTAssertEqual(binding.modifiers, .option)
        XCTAssertTrue(binding.isValid)
        XCTAssertEqual(binding.displayName, "Option-Space")
    }

    func testDisplayNameOrdersModifiersLikeMacOS() {
        let binding = HotKeyBinding(keyCode: KeyCodes.byName["r"]!,
                                    modifiers: [.command, .shift, .control, .option])
        XCTAssertEqual(binding.displayName, "Control-Option-Shift-Command-R")
    }

    func testNamedKeysReadBackNicely() {
        XCTAssertEqual(KeyCodes.name(for: 49), "Space")
        XCTAssertEqual(KeyCodes.name(for: 36), "Return")
        XCTAssertEqual(KeyCodes.name(for: 53), "Escape")
        XCTAssertEqual(KeyCodes.name(for: KeyCodes.byName["r"]!), "R")
        XCTAssertEqual(KeyCodes.name(for: KeyCodes.byName["f5"]!), "F5")
        XCTAssertNil(KeyCodes.name(for: 250))
    }

    func testAModifierIsRequired() {
        // A global shortcut with no modifier would swallow that key
        // everywhere on the system.
        let bare = HotKeyBinding(keyCode: KeyCodes.byName["space"]!, modifiers: [])
        XCTAssertFalse(bare.isValid)
    }

    func testSystemShortcutsAreReserved() {
        let quit = HotKeyBinding(keyCode: KeyCodes.byName["q"]!, modifiers: .command)
        let close = HotKeyBinding(keyCode: KeyCodes.byName["w"]!, modifiers: .command)
        let switcher = HotKeyBinding(keyCode: KeyCodes.byName["tab"]!, modifiers: .command)
        XCTAssertFalse(quit.isValid)
        XCTAssertFalse(close.isValid)
        XCTAssertFalse(switcher.isValid)
        // The same keys are fine with a different modifier set.
        XCTAssertTrue(HotKeyBinding(keyCode: KeyCodes.byName["q"]!,
                                    modifiers: [.command, .shift]).isValid)
    }

    func testUnknownKeyCodeIsRejected() {
        XCTAssertFalse(HotKeyBinding(keyCode: 250, modifiers: .command).isValid)
    }

    func testCommonAlternativesAreValid() {
        // The combos someone would actually pick to dodge a conflict.
        for (name, mods) in [("r", HotKeyModifiers([.control, .option])),
                             ("space", [.control]),
                             ("j", [.command, .shift])] {
            let binding = HotKeyBinding(keyCode: KeyCodes.byName[name]!, modifiers: mods)
            XCTAssertTrue(binding.isValid, "\(binding.displayName) should be bindable")
        }
    }

    func testKeyTableIsSharedWithPressKeys() {
        // The press_keys tool and the summon shortcut read the same table, so
        // a code fixed in one place is fixed in both.
        XCTAssertEqual(KeyCodes.byName["cmd"], nil)  // modifiers aren't keys
        XCTAssertEqual(KeyCodes.byName["t"], 17)
        XCTAssertEqual(KeyCodes.byName["4"], 21)
    }
}
