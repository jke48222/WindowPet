import CoreGraphics
import XCTest
@testable import WindowPetCore

/// Multi-display geometry. The layout under test is a common one: a MacBook
/// (1512x982, Dock 70 high at the bottom) with a 2560x1440 external display
/// arranged directly above it, overhanging on both sides.
final class DisplayGeometryTests: XCTestCase {

    let laptopFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let laptopVisible = CGRect(x: 0, y: 70, width: 1512, height: 982 - 70 - 38)
    let externalFrame = CGRect(x: -524, y: 982, width: 2560, height: 1440)
    let externalVisible = CGRect(x: -524, y: 982, width: 2560, height: 1440 - 25)
    /// A display beside the laptop, at the same height.
    let right = CGRect(x: 1512, y: 0, width: 1920, height: 1080)

    var stackedFloors: [CGRect] { [laptopVisible, externalVisible] }

    // MARK: floors

    /// Standing on the upper display's floor must resolve to that floor, not
    /// the laptop's, even though both span the same x.
    func testStackedFloorIsChosenByHeight() {
        XCTAssertEqual(DisplayGeometry.floorIndex(under: CGPoint(x: 500, y: 982),
                                                  floors: stackedFloors), 1)
        XCTAssertEqual(DisplayGeometry.floorIndex(under: CGPoint(x: 500, y: 70),
                                                  floors: stackedFloors), 0)
        XCTAssertEqual(DisplayGeometry.floorIndex(under: CGPoint(x: 500, y: 600),
                                                  floors: stackedFloors), 0)
    }

    func testFloorOnlyTheUpperDisplaySpans() {
        XCTAssertEqual(DisplayGeometry.floorIndex(under: CGPoint(x: 1800, y: 1500),
                                                  floors: stackedFloors), 1)
    }

    func testFloorFallbacks() {
        // Below every floor (a failsafe case): the lowest one that spans x.
        XCTAssertEqual(DisplayGeometry.floorIndex(under: CGPoint(x: 500, y: -100),
                                                  floors: stackedFloors), 0)
        // Off to the side of everything: the horizontally nearest floor.
        XCTAssertEqual(DisplayGeometry.floorIndex(under: CGPoint(x: 5000, y: 100),
                                                  floors: stackedFloors), 1)
        XCTAssertNil(DisplayGeometry.floorIndex(under: .zero, floors: []))
    }

    // MARK: ceiling

    /// With a display above, the laptop's menu bar is not a ceiling; the
    /// external display's is.
    func testCeilingFollowsTheStack() {
        let ceiling = DisplayGeometry.ceiling(above: CGPoint(x: 500, y: 300),
                                              regions: [laptopFrame, externalFrame],
                                              clampTops: [944, 982 + 1415])
        XCTAssertEqual(ceiling, 2397)
    }

    func testSideBySideCeilingIsEachDisplaysOwn() {
        let regions = [laptopFrame, right]
        let tops: [CGFloat] = [944, 1055]
        XCTAssertEqual(DisplayGeometry.ceiling(above: CGPoint(x: 500, y: 300),
                                               regions: regions, clampTops: tops), 944)
        XCTAssertEqual(DisplayGeometry.ceiling(above: CGPoint(x: 2000, y: 300),
                                               regions: regions, clampTops: tops), 1055)
    }

    // MARK: airborne walls

    func testLeapCrossesASharedEdge() {
        let step = DisplayGeometry.airborneX(from: 1480, to: 1490, atY: 400, margin: 19,
                                             regions: [laptopFrame, right],
                                             walls: [laptopVisible, right])
        XCTAssertEqual(step.x, 1490)
        XCTAssertFalse(step.hitWall)
    }

    func testLeapThudsAtOuterWalls() {
        let regions = [laptopFrame, right]
        let walls = [laptopVisible, right]
        let left = DisplayGeometry.airborneX(from: 20, to: 10, atY: 400, margin: 19,
                                             regions: regions, walls: walls)
        XCTAssertEqual(left.x, 19)
        XCTAssertTrue(left.hitWall)
        let far = DisplayGeometry.airborneX(from: 3400, to: 3420, atY: 400, margin: 19,
                                            regions: regions, walls: walls)
        XCTAssertEqual(far.x, 3432 - 19)
        XCTAssertTrue(far.hitWall)
    }

    /// Above the top of a shorter neighbour there is nothing to fly into.
    func testNoCrossingAboveAShorterNeighbour() {
        let tall = CGRect(x: 0, y: 0, width: 1512, height: 1200)
        let step = DisplayGeometry.airborneX(from: 1490, to: 1500, atY: 1100, margin: 19,
                                             regions: [tall, right], walls: nil)
        XCTAssertTrue(step.hitWall)
        XCTAssertEqual(step.x, 1512 - 19)
    }

    func testSideDockIsAWall() {
        let dockVisible = CGRect(x: 80, y: 0, width: 1432, height: 944)
        let step = DisplayGeometry.airborneX(from: 110, to: 90, atY: 400, margin: 19,
                                             regions: [laptopFrame], walls: [dockVisible])
        XCTAssertTrue(step.hitWall)
        XCTAssertEqual(step.x, 99)
    }

    // MARK: mouse hole

    func testOnlyRustysPanelTakesTheMouse() {
        XCTAssertEqual(HolePolicy.ignoresMouseEvents(open: true, currentIndex: 1, count: 3),
                       [true, false, true])
        XCTAssertEqual(HolePolicy.ignoresMouseEvents(open: false, currentIndex: 1, count: 2),
                       [true, true])
    }

    func testHoleFlagsFollowRustyExceptMidGrab() {
        XCTAssertTrue(HolePolicy.needsReapply(open: true, appliedOpen: true, currentIndex: 1,
                                              appliedIndex: 0, grabInFlight: false))
        XCTAssertFalse(HolePolicy.needsReapply(open: true, appliedOpen: true, currentIndex: 1,
                                               appliedIndex: 0, grabInFlight: true))
        XCTAssertFalse(HolePolicy.needsReapply(open: false, appliedOpen: false, currentIndex: 0,
                                               appliedIndex: 0, grabInFlight: false))
        // After the panels are rebuilt nothing has been written yet.
        XCTAssertTrue(HolePolicy.needsReapply(open: false, appliedOpen: false, currentIndex: 0,
                                              appliedIndex: nil, grabInFlight: false))
    }

    // MARK: presence

    func testPresenceFromTheIdleClock() {
        XCTAssertTrue(ReactionPolicy.isAway(idleSeconds: ReactionPolicy.awayThreshold))
        XCTAssertFalse(ReactionPolicy.isAway(idleSeconds: 60))
        XCTAssertTrue(ReactionPolicy.inputResumed(previousIdle: 130, idle: 0.2))
        XCTAssertFalse(ReactionPolicy.inputResumed(previousIdle: 130, idle: 130.5))
    }

    // MARK: reduce motion

    func testReduceMotionStopsSelfInitiatedMovement() {
        for whim: MotionPolicy.Whim in [.stroll, .stepOff, .travel, .climb] {
            XCTAssertFalse(MotionPolicy.allows(whim, reduceMotion: true), "\(whim)")
            XCTAssertTrue(MotionPolicy.allows(whim, reduceMotion: false), "\(whim)")
        }
        for whim: MotionPolicy.Whim in [.sit, .sleep, .wake] {
            XCTAssertTrue(MotionPolicy.allows(whim, reduceMotion: true), "\(whim)")
        }
    }

    // MARK: speech bubble

    /// A fake measure: 16 pt per line of 40 characters.
    private let measure: (String) -> CGFloat = { CGFloat(($0.count + 39) / 40) * 16 }

    func testShortTextIsUnchanged() {
        XCTAssertEqual(BubbleFit.tail(of: "hello there", maxHeight: 208, height: measure),
                       "hello there")
    }

    /// A growing transcript keeps its newest words, fits, and does not open
    /// on half a word.
    func testLongTextKeepsTheTail() {
        let words = (1...300).map { "w\($0)" }.joined(separator: " ")
        let fit = BubbleFit.tail(of: words, maxHeight: 208, height: measure)
        XCTAssertTrue(fit.hasSuffix("w300"))
        XCTAssertTrue(fit.hasPrefix(BubbleFit.ellipsis))
        XCTAssertLessThanOrEqual(measure(fit), 208)
        XCTAssertEqual(fit.dropFirst().first, "w")
    }
}
