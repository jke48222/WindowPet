import XCTest
@testable import WindowPetCore

final class Tier2PolicyTests: XCTestCase {

    func testHealthyAppIsLeftAlone() {
        XCTAssertEqual(Tier2Policy.probe(attachedFor: 60, eventsSeen: 12, sawTier1Motion: true,
                                         alreadyForced: false, alreadyDegraded: false), .none)
    }

    func testSilenceWithoutMotionIsNotEvidence() {
        // An idle app produces no events AND no motion — nothing to conclude.
        XCTAssertEqual(Tier2Policy.probe(attachedFor: 300, eventsSeen: 0, sawTier1Motion: false,
                                         alreadyForced: false, alreadyDegraded: false), .none)
    }

    func testProbationMustElapseBeforeActing() {
        XCTAssertEqual(Tier2Policy.probe(attachedFor: 2, eventsSeen: 0, sawTier1Motion: true,
                                         alreadyForced: false, alreadyDegraded: false), .none)
    }

    func testContradictionForcesElectronHookFirst() {
        XCTAssertEqual(Tier2Policy.probe(attachedFor: 5, eventsSeen: 0, sawTier1Motion: true,
                                         alreadyForced: false, alreadyDegraded: false),
                       .forceManualAccessibility)
    }

    func testSecondContradictionDegrades() {
        XCTAssertEqual(Tier2Policy.probe(attachedFor: 10, eventsSeen: 0, sawTier1Motion: true,
                                         alreadyForced: true, alreadyDegraded: false), .markDegraded)
    }

    func testDegradedStaysQuiet() {
        XCTAssertEqual(Tier2Policy.probe(attachedFor: 99, eventsSeen: 0, sawTier1Motion: true,
                                         alreadyForced: true, alreadyDegraded: true), .none)
    }
}
