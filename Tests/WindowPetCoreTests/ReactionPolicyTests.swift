import XCTest
@testable import WindowPetCore

final class ReactionPolicyTests: XCTestCase {

    func testDecayingRateRisesWithBurstsAndDecaysToQuiet() {
        var r = DecayingRate(tau: 3)
        XCTAssertEqual(r.rate(at: 100), 0)
        // Three quick hits — a build spamming its title.
        r.hit(at: 100.0)
        r.hit(at: 100.3)
        r.hit(at: 100.6)
        XCTAssertGreaterThan(r.rate(at: 100.6), 2.5)
        XCTAssertTrue(ReactionPolicy.isAgitated(titleRate: r.rate(at: 100.6)))
        // Ten quiet seconds later the excitement is gone.
        XCTAssertLessThan(r.rate(at: 110.6), 0.2)
        XCTAssertFalse(ReactionPolicy.isAgitated(titleRate: r.rate(at: 110.6)))
    }

    func testImmersionExcludesMaximizedButNotFullscreen() {
        XCTAssertTrue(ReactionPolicy.isImmersive(coverage: 1.0))
        XCTAssertTrue(ReactionPolicy.isImmersive(coverage: 0.99))
        // Maximized Chrome under a visible menu bar: ~96.6%.
        XCTAssertFalse(ReactionPolicy.isImmersive(coverage: 0.966))
    }

    func testGreetingRequiresRealAbsence() {
        XCTAssertFalse(ReactionPolicy.isReturnGreeting(awaySeconds: 30))
        XCTAssertTrue(ReactionPolicy.isReturnGreeting(awaySeconds: 120))
    }

    func testLockTimeCountsTowardBeingAway() {
        // 30 s idle, then a 2 minute lock: away, so the unlock greets.
        let away = ReactionPolicy.awayAcrossSuspend(idleAtSuspend: 30, suspendedFor: 120)
        XCTAssertEqual(away, 150)
        XCTAssertTrue(ReactionPolicy.isAway(idleSeconds: away))
        // A short lock right after typing is not an absence.
        XCTAssertFalse(ReactionPolicy.isAway(
            idleSeconds: ReactionPolicy.awayAcrossSuspend(idleAtSuspend: 2, suspendedFor: 20)))
        // A wall clock that went backwards adds nothing.
        XCTAssertEqual(ReactionPolicy.awayAcrossSuspend(idleAtSuspend: 10, suspendedFor: -500), 10)
    }

    func testDistractionSetMembership() {
        XCTAssertTrue(ReactionPolicy.isDistraction(bundleID: "com.hnc.Discord"))
        XCTAssertFalse(ReactionPolicy.isDistraction(bundleID: "com.apple.dt.Xcode"))
        XCTAssertFalse(ReactionPolicy.isDistraction(bundleID: nil))
    }
}
