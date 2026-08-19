import XCTest
@testable import WindowPetCore

final class GeometryTests: XCTestCase {

    // Primary display 1512x982 (14" MBP default scaled). A window whose CG
    // bounds put it 100pt from the top must land 100pt from the top in AppKit
    // space too: akY = 982 - 100 - 400 = 482.
    func testCGToAppKitOnPrimaryDisplay() {
        let cg = CGRect(x: 300, y: 100, width: 600, height: 400)
        let ak = Geometry.appKitRect(fromCGGlobal: cg, primaryScreenHeight: 982)
        XCTAssertEqual(ak, CGRect(x: 300, y: 482, width: 600, height: 400))
        XCTAssertEqual(ak.maxY, 882) // top edge of window, where the pet stands
    }

    // Display above the primary: CG y is negative there; the flip must still
    // round-trip. cg.y = -800 (800pt above primary top), h = 500
    // → akY = 982 - (-800) - 500 = 1282.
    func testCGToAppKitOnSecondaryDisplayAbove() {
        let cg = CGRect(x: -1000, y: -800, width: 700, height: 500)
        let ak = Geometry.appKitRect(fromCGGlobal: cg, primaryScreenHeight: 982)
        XCTAssertEqual(ak, CGRect(x: -1000, y: 1282, width: 700, height: 500))
    }

    func testRoundTripIsIdentity() {
        let cg = CGRect(x: 123.5, y: 456.25, width: 640, height: 480)
        let there = Geometry.appKitRect(fromCGGlobal: cg, primaryScreenHeight: 1080)
        let back = Geometry.appKitRect(fromCGGlobal: there, primaryScreenHeight: 1080)
        XCTAssertEqual(back, cg) // the flip is an involution
    }

    func testInitialPerchSitsRightOfCenterAndInsideWindow() {
        let perch = Geometry.initialPerch(windowWidth: 1000, petWidth: 64)
        XCTAssertEqual(perch, 1000 * 0.62 - 32, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(perch, 8)
        XCTAssertLessThanOrEqual(perch, 1000 - 64 - 8)
    }

    func testPerchClampsOnNarrowWindow() {
        // Window narrower than pet + margins: pet pins to the left margin.
        XCTAssertEqual(Geometry.clampPerch(200, windowWidth: 60, petWidth: 64), 8)
        // Window resized down under the pet: perch slides left to stay on it.
        XCTAssertEqual(Geometry.clampPerch(500, windowWidth: 300, petWidth: 64), 300 - 64 - 8)
    }

    func testPetOriginStandsOnTopEdgeWithFootOverlap() {
        let win = CGRect(x: 100, y: 200, width: 800, height: 600) // AppKit space
        let origin = Geometry.petOrigin(windowFrame: win, perchOffsetX: 400,
                                        petSize: CGSize(width: 64, height: 64), footOverlap: 5)
        XCTAssertEqual(origin.x, 500)
        XCTAssertEqual(origin.y, win.maxY - 5) // feet sunk 5pt into the title bar
    }

    func testRatePolicyBands() {
        XCTAssertEqual(RatePolicy.interval(hasTarget: false, sinceMotion: 99), 0.5)
        XCTAssertEqual(RatePolicy.interval(hasTarget: true, sinceMotion: 0.1), 1.0 / 60.0, accuracy: 1e-9)
        XCTAssertEqual(RatePolicy.interval(hasTarget: true, sinceMotion: 5.0), 0.1)
        XCTAssertEqual(RatePolicy.interval(hasTarget: true, sinceMotion: 30.0), 0.25)
    }
}
