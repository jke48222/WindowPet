import XCTest
@testable import WindowPetCore

/// Two-display rig used throughout: a 1512x982 laptop screen at the origin
/// and a 1920x1080 external sitting to its right. AppKit coordinates, so y
/// grows upward and the primary display's origin is (0, 0).
private let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
private let external = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
private let both = [laptop, external]

final class DisplayChoiceTests: XCTestCase {

    // MARK: which display holds a point

    func testPointOnSecondaryPicksSecondary() {
        XCTAssertEqual(DisplayChoice.index(containing: CGPoint(x: 2000, y: 500), in: both), 1)
    }

    func testPointOnPrimaryPicksPrimary() {
        XCTAssertEqual(DisplayChoice.index(containing: CGPoint(x: 700, y: 500), in: both), 0)
    }

    /// The shared edge belongs to exactly one display, never both.
    func testSharedEdgeBelongsToSecondaryOnly() {
        XCTAssertEqual(DisplayChoice.index(containing: CGPoint(x: 1512, y: 500), in: both), 1)
    }

    func testPointOnNoDisplayIsNil() {
        XCTAssertNil(DisplayChoice.index(containing: CGPoint(x: -900, y: 500), in: both))
    }

    // MARK: preference order

    /// A panel pinned to the external display reopens there even while the
    /// pointer and the key window are back on the laptop.
    func testPinnedOriginWinsOverPointer() {
        let index = DisplayChoice.index(preferred: CGPoint(x: 2000, y: 400),
                                        mouse: CGPoint(x: 100, y: 100),
                                        fallback: 0, in: both)
        XCTAssertEqual(index, 1)
    }

    /// With nothing pinned, UI follows the pointer rather than NSScreen.main.
    func testPointerWinsWhenNothingPinned() {
        let index = DisplayChoice.index(preferred: nil,
                                        mouse: CGPoint(x: 2500, y: 900),
                                        fallback: 0, in: both)
        XCTAssertEqual(index, 1)
    }

    /// The regression this exists for: the external display is unplugged, so
    /// the remembered origin is on no display. UI must land somewhere real.
    func testPinnedOriginOnUnpluggedDisplayFallsBackToPointer() {
        let index = DisplayChoice.index(preferred: CGPoint(x: 2000, y: 400),
                                        mouse: CGPoint(x: 300, y: 300),
                                        fallback: nil, in: [laptop])
        XCTAssertEqual(index, 0)
    }

    /// Pointer between displays (it happens during a drag across the seam):
    /// fall through to the key screen.
    func testFallbackUsedWhenPointerIsNowhere() {
        let index = DisplayChoice.index(preferred: nil,
                                        mouse: CGPoint(x: -50, y: -50),
                                        fallback: 1, in: both)
        XCTAssertEqual(index, 1)
    }

    func testPrimaryUsedWhenEverythingElseMisses() {
        let index = DisplayChoice.index(preferred: nil,
                                        mouse: CGPoint(x: -50, y: -50),
                                        fallback: nil, in: both)
        XCTAssertEqual(index, 0)
    }

    func testNoDisplaysAtAllIsNil() {
        XCTAssertNil(DisplayChoice.index(preferred: nil, mouse: .zero, fallback: 0, in: []))
    }

    // MARK: which display a window is on

    func testWindowFullyOnSecondary() {
        let window = CGRect(x: 1700, y: 200, width: 800, height: 600)
        XCTAssertEqual(DisplayChoice.index(overlapping: window, in: both), 1)
    }

    /// A window straddling the seam goes to whichever display holds more of
    /// it, so "snap left" snaps where the window visually lives.
    func testStraddlingWindowGoesToGreaterOverlap() {
        let mostlyExternal = CGRect(x: 1400, y: 200, width: 800, height: 600)
        XCTAssertEqual(DisplayChoice.index(overlapping: mostlyExternal, in: both), 1)
        let mostlyLaptop = CGRect(x: 1000, y: 200, width: 800, height: 600)
        XCTAssertEqual(DisplayChoice.index(overlapping: mostlyLaptop, in: both), 0)
    }

    func testWindowOffEveryDisplayIsNil() {
        XCTAssertNil(DisplayChoice.index(overlapping: CGRect(x: -4000, y: 0, width: 100, height: 100),
                                         in: both))
    }

    /// Touching edges share no area, so an adjacent window is not "on" a
    /// display it merely borders.
    func testZeroAreaTouchDoesNotCount() {
        let touching = CGRect(x: 1512, y: 0, width: 0, height: 400)
        XCTAssertNil(DisplayChoice.index(overlapping: touching, in: [laptop]))
    }

    // MARK: clamping

    func testOriginInsideIsLeftAlone() {
        let origin = CGPoint(x: 400, y: 400)
        XCTAssertEqual(DisplayChoice.clamp(origin: origin, size: CGSize(width: 380, height: 200),
                                           into: laptop, inset: 12), origin)
    }

    func testOriginPastRightEdgeIsPulledIn() {
        let clamped = DisplayChoice.clamp(origin: CGPoint(x: 1400, y: 400),
                                          size: CGSize(width: 380, height: 200),
                                          into: laptop, inset: 12)
        XCTAssertEqual(clamped.x, 1512 - 12 - 380)
        XCTAssertEqual(clamped.y, 400)
    }

    func testOriginBelowBottomIsPulledUp() {
        let clamped = DisplayChoice.clamp(origin: CGPoint(x: 400, y: -300),
                                          size: CGSize(width: 380, height: 200),
                                          into: laptop, inset: 12)
        XCTAssertEqual(clamped.y, 12)
    }

    /// A panel taller than the display pins to the bottom-left corner instead
    /// of inverting the clamp and landing off the far edge.
    func testOversizePanelPinsToNearCorner() {
        let clamped = DisplayChoice.clamp(origin: CGPoint(x: 900, y: 900),
                                          size: CGSize(width: 4000, height: 4000),
                                          into: laptop, inset: 12)
        XCTAssertEqual(clamped, CGPoint(x: 12, y: 12))
    }

    /// Clamping into the external display keeps the panel there, negative or
    /// large coordinates included.
    func testClampRespectsSecondaryDisplayOrigin() {
        let clamped = DisplayChoice.clamp(origin: CGPoint(x: 1520, y: 5000),
                                          size: CGSize(width: 380, height: 200),
                                          into: external, inset: 8)
        XCTAssertEqual(clamped.x, 1520)
        XCTAssertEqual(clamped.y, 1080 - 8 - 200)
    }
}
