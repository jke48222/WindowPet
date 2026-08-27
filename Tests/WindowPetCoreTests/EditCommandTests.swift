import XCTest
@testable import WindowPetCore

final class EditCommandTests: XCTestCase {

    func testStandardShortcuts() {
        XCTAssertEqual(EditCommand.forKey("c", shift: false), .copy)
        XCTAssertEqual(EditCommand.forKey("v", shift: false), .paste)
        XCTAssertEqual(EditCommand.forKey("x", shift: false), .cut)
        XCTAssertEqual(EditCommand.forKey("a", shift: false), .selectAll)
    }

    func testUndoAndRedoShareAKey() {
        XCTAssertEqual(EditCommand.forKey("z", shift: false), .undo)
        XCTAssertEqual(EditCommand.forKey("z", shift: true), .redo)
    }

    func testUnrelatedKeysAreIgnored() {
        // Command-Q, Command-W and friends must fall through to the system
        // rather than being swallowed by the panel.
        for key in ["q", "w", "s", "n", "1", " "] {
            XCTAssertNil(EditCommand.forKey(key, shift: false), "\(key) should pass through")
        }
    }

    func testShiftOnlyMattersForZ() {
        XCTAssertEqual(EditCommand.forKey("c", shift: true), .copy)
        XCTAssertEqual(EditCommand.forKey("v", shift: true), .paste)
    }

    func testSelectorNamesMatchAppKit() {
        // These strings are turned into selectors at runtime, so a typo here
        // would silently do nothing instead of failing to compile.
        XCTAssertEqual(EditCommand.cut.rawValue, "cut:")
        XCTAssertEqual(EditCommand.copy.rawValue, "copy:")
        XCTAssertEqual(EditCommand.paste.rawValue, "paste:")
        XCTAssertEqual(EditCommand.selectAll.rawValue, "selectAll:")
        XCTAssertEqual(EditCommand.undo.rawValue, "undo:")
        XCTAssertEqual(EditCommand.redo.rawValue, "redo:")
    }
}
