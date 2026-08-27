import XCTest
@testable import WindowPetCore

private let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)

final class LayoutSlotTests: XCTestCase {

    func testHalvesSplitTheScreen() {
        XCTAssertEqual(LayoutSlot.left.rect(in: screen), CGRect(x: 0, y: 0, width: 800, height: 1000))
        XCTAssertEqual(LayoutSlot.right.rect(in: screen), CGRect(x: 800, y: 0, width: 800, height: 1000))
    }

    /// AppKit's origin is bottom-left, so the top half is the high half of y.
    /// If this inverts, every "top right" lands bottom right.
    func testTopIsTheHighHalf() {
        XCTAssertEqual(LayoutSlot.top.rect(in: screen), CGRect(x: 0, y: 500, width: 1600, height: 500))
        XCTAssertEqual(LayoutSlot.bottom.rect(in: screen), CGRect(x: 0, y: 0, width: 1600, height: 500))
        XCTAssertEqual(LayoutSlot.topRight.rect(in: screen),
                       CGRect(x: 800, y: 500, width: 800, height: 500))
    }

    func testThirdsTileTheScreenExactly() {
        let slots: [LayoutSlot] = [.leftThird, .middleThird, .rightThird]
        let widths = slots.map { $0.rect(in: screen).width }
        XCTAssertEqual(widths.reduce(0, +), screen.width, accuracy: 0.001)
        XCTAssertEqual(LayoutSlot.rightThird.rect(in: screen).maxX, screen.maxX, accuracy: 0.001)
    }

    func testFullIsTheWholeVisibleArea() {
        XCTAssertEqual(LayoutSlot.full.rect(in: screen), screen)
    }

    /// Slots are relative, so a second display with a different origin and
    /// size gets the same arrangement rather than the same coordinates.
    func testSlotsAreRelativeToTheirDisplay() {
        let external = CGRect(x: 1600, y: 200, width: 2560, height: 1440)
        let right = LayoutSlot.right.rect(in: external)
        XCTAssertEqual(right.minX, 1600 + 1280)
        XCTAssertEqual(right.height, 1440)
    }

    // MARK: parsing what a person says

    func testParsesTheOrdinarySpellings() {
        XCTAssertEqual(LayoutSlot.parse("left"), .left)
        XCTAssertEqual(LayoutSlot.parse("  RIGHT "), .right)
        XCTAssertEqual(LayoutSlot.parse("bottom right"), .bottomRight)
        XCTAssertEqual(LayoutSlot.parse("upper left"), .topLeft)
        XCTAssertEqual(LayoutSlot.parse("full screen"), .full)
        XCTAssertEqual(LayoutSlot.parse("centre"), .center)
    }

    /// Word order is not fixed in speech, and both readings mean the corner.
    func testWordOrderDoesNotMatter() {
        XCTAssertEqual(LayoutSlot.parse("left top"), .topLeft)
        XCTAssertEqual(LayoutSlot.parse("top left"), .topLeft)
    }

    /// "left third" must not be read as "left", which is twice the width.
    func testThirdsBeatHalves() {
        XCTAssertEqual(LayoutSlot.parse("left third"), .leftThird)
        XCTAssertEqual(LayoutSlot.parse("middle third"), .middleThird)
    }

    func testNonsenseIsRejected() {
        XCTAssertNil(LayoutSlot.parse(""))
        XCTAssertNil(LayoutSlot.parse("sideways"))
    }

    // MARK: reading the screen back

    func testNearestRecognizesAnExactHalf() {
        let left = LayoutSlot.left.rect(in: screen)
        XCTAssertEqual(LayoutSlot.nearest(to: left, in: screen), .left)
    }

    func testNearestRecognizesAnExactCorner() {
        let corner = LayoutSlot.bottomRight.rect(in: screen)
        XCTAssertEqual(LayoutSlot.nearest(to: corner, in: screen), .bottomRight)
    }

    func testNearestRecognizesFullScreen() {
        XCTAssertEqual(LayoutSlot.nearest(to: screen, in: screen), .full)
    }

    /// Windows are never placed perfectly by hand, so a near miss still reads
    /// as the slot the person meant.
    func testNearestToleratesANudge() {
        let nudged = CGRect(x: 12, y: 8, width: 790, height: 980)
        XCTAssertEqual(LayoutSlot.nearest(to: nudged, in: screen), .left)
    }

    func testEverySlotRoundTripsThroughNearest() {
        for slot in LayoutSlot.allCases {
            XCTAssertEqual(LayoutSlot.nearest(to: slot.rect(in: screen), in: screen), slot,
                           "\(slot.rawValue) did not survive a round trip")
        }
    }
}

final class LayoutParserTests: XCTestCase {

    func testReadsOnePlacement() {
        XCTAssertEqual(LayoutParser.placement(from: "Safari left"),
                       WindowPlacement(app: "Safari", slot: .left))
    }

    func testReadsATwoWordSlot() {
        XCTAssertEqual(LayoutParser.placement(from: "Terminal bottom right"),
                       WindowPlacement(app: "Terminal", slot: .bottomRight))
    }

    /// An app name with spaces survives, because the slot is taken off the end
    /// rather than the app being taken off the front.
    func testAppNamesWithSpacesSurvive() {
        XCTAssertEqual(LayoutParser.placement(from: "Visual Studio Code left"),
                       WindowPlacement(app: "Visual Studio Code", slot: .left))
    }

    /// The colon form is the escape hatch for an app whose name ends in a slot
    /// word, which would otherwise lose it.
    func testColonFormProtectsAwkwardNames() {
        XCTAssertEqual(LayoutParser.placement(from: "Left Field: right"),
                       WindowPlacement(app: "Left Field", slot: .right))
    }

    func testReadsAWholeArrangement() {
        let placements = LayoutParser.placements(
            from: "Safari left, Terminal bottom right and Notes top right")
        XCTAssertEqual(placements, [
            WindowPlacement(app: "Safari", slot: .left),
            WindowPlacement(app: "Terminal", slot: .bottomRight),
            WindowPlacement(app: "Notes", slot: .topRight),
        ])
    }

    /// A piece that names no slot is dropped rather than guessed at, so a
    /// half-understood instruction moves fewer windows rather than wrong ones.
    func testUnreadablePiecesAreDropped() {
        let placements = LayoutParser.placements(from: "Safari left, Terminal sideways")
        XCTAssertEqual(placements, [WindowPlacement(app: "Safari", slot: .left)])
    }

    func testBareAppNameIsNotAPlacement() {
        XCTAssertNil(LayoutParser.placement(from: "Safari"))
        XCTAssertNil(LayoutParser.placement(from: "left"))
    }

    func testLayoutNamesMatchLoosely() {
        XCTAssertEqual(WindowLayout.normalize("  Writing "), "writing")
    }

    func testLayoutSummaryNamesEveryApp() {
        let layout = WindowLayout(name: "writing", placements: [
            WindowPlacement(app: "iA Writer", slot: .left),
            WindowPlacement(app: "Safari", slot: .right),
        ])
        XCTAssertEqual(layout.summary, "writing: iA Writer left, Safari right")
    }
}

// MARK: - Watching

final class WatchPolicyTests: XCTestCase {

    private func watch(startedAt: TimeInterval = 100) -> WatchPolicy.Watch {
        WatchPolicy.Watch(id: 1, app: "Xcode", reason: "the build", startedAt: startedAt)
    }

    func testStillBusyKeepsWaiting() {
        let outcome = WatchPolicy.evaluate(watch(), lastActivityAt: 150,
                                           appRunning: true, now: 160)
        XCTAssertEqual(outcome, .waiting)
    }

    func testQuietForLongEnoughSettles() {
        let outcome = WatchPolicy.evaluate(watch(), lastActivityAt: 150,
                                           appRunning: true, now: 150 + WatchPolicy.defaultQuiet)
        XCTAssertEqual(outcome, .settled)
    }

    /// An app that was already idle when the watch started must still wait a
    /// full quiet stretch, or every watch fires instantly and means nothing.
    func testAnAlreadyIdleAppDoesNotSettleImmediately() {
        let outcome = WatchPolicy.evaluate(watch(startedAt: 100), lastActivityAt: 0,
                                           appRunning: true, now: 101)
        XCTAssertEqual(outcome, .waiting)
    }

    func testQuittingCountsAsFinishing() {
        let outcome = WatchPolicy.evaluate(watch(), lastActivityAt: 100,
                                           appRunning: false, now: 101)
        XCTAssertEqual(outcome, .quit)
    }

    /// Quitting wins over the timeout: an app that quit at the one hour mark
    /// quit, it did not expire.
    func testQuitBeatsExpiry() {
        let outcome = WatchPolicy.evaluate(watch(), lastActivityAt: 100, appRunning: false,
                                           now: 100 + WatchPolicy.defaultTimeout + 1)
        XCTAssertEqual(outcome, .quit)
    }

    func testAnEndlessWatchExpires() {
        // Busy right up to the deadline, so it never settles on its own.
        let now = 100 + WatchPolicy.defaultTimeout
        let outcome = WatchPolicy.evaluate(watch(), lastActivityAt: now,
                                           appRunning: true, now: now)
        XCTAssertEqual(outcome, .expired)
    }

    func testWaitingSaysNothing() {
        XCTAssertNil(WatchPolicy.message(for: .waiting, watch: watch()))
    }

    func testFiringMessagesNameTheAppAndTheReason() {
        for outcome in [WatchPolicy.Outcome.settled, .quit, .expired] {
            let message = WatchPolicy.message(for: outcome, watch: watch())
            XCTAssertNotNil(message)
            XCTAssertTrue(message!.contains("Xcode"), message!)
            XCTAssertTrue(message!.contains("the build"), message!)
            XCTAssertFalse(message!.contains("\u{2014}"), message!)
        }
    }

    func testAcknowledgementPromisesSomethingSpecific() {
        let text = WatchPolicy.acknowledgement(watch())
        XCTAssertTrue(text.contains("Xcode"))
        XCTAssertTrue(text.contains("\(Int(WatchPolicy.defaultQuiet))"))
    }

    func testEmptyListingSaysSo() {
        XCTAssertEqual(WatchPolicy.listing([]), "I am not watching anything right now.")
    }
}

// MARK: - Splitting "watch X until Y"

final class SplitReasonTests: XCTestCase {

    func testSplitsOnUntil() {
        let (app, reason) = AssistantRouting.splitReason("Xcode until the build finishes")
        XCTAssertEqual(app, "Xcode")
        XCTAssertEqual(reason, "the build finishes")
    }

    func testAppNamesWithSpacesSurvive() {
        let (app, reason) = AssistantRouting.splitReason("Visual Studio Code until it stops")
        XCTAssertEqual(app, "Visual Studio Code")
        XCTAssertEqual(reason, "it stops")
    }

    func testBareAppNameHasNoReason() {
        let (app, reason) = AssistantRouting.splitReason("Xcode")
        XCTAssertEqual(app, "Xcode")
        XCTAssertEqual(reason, "")
    }

    func testSplitIsCaseInsensitive() {
        let (app, _) = AssistantRouting.splitReason("Mail Until the sync ends")
        XCTAssertEqual(app, "Mail")
    }
}
