import XCTest
@testable import WindowPetCore

/// Waking is not unlocking. Anything that listens, speaks or animates stops
/// when the Mac locks or sleeps and resumes only once it is awake and
/// unlocked.
final class ScreenLockStateTests: XCTestCase {

    func testWakingToTheLockScreenDoesNotResume() {
        var state = ScreenLockState(isLocked: false)
        XCTAssertEqual(state.apply(.locked), .suspend)
        XCTAssertEqual(state.apply(.willSleep), .suspend)
        XCTAssertEqual(state.apply(.didWake(sessionLocked: true)), .suspend)
        XCTAssertTrue(state.isSuspended)
        XCTAssertEqual(state.apply(.unlocked), .resume)
        XCTAssertFalse(state.isSuspended)
    }

    /// No lock notification arrives when the lock happened during sleep; the
    /// session state at wake is the authority.
    func testALockDuringSleepIsCaughtAtWake() {
        var state = ScreenLockState(isLocked: false)
        _ = state.apply(.willSleep)
        XCTAssertEqual(state.apply(.didWake(sessionLocked: true)), .suspend)
        XCTAssertEqual(state.apply(.unlocked), .resume)
    }

    func testWakeWithoutAPasswordResumes() {
        var state = ScreenLockState(isLocked: false)
        _ = state.apply(.willSleep)
        XCTAssertEqual(state.apply(.didWake(sessionLocked: false)), .resume)
    }

    func testUnlockWhileStillAsleepDoesNotResume() {
        var state = ScreenLockState(isLocked: false)
        _ = state.apply(.locked)
        _ = state.apply(.willSleep)
        XCTAssertEqual(state.apply(.unlocked), .suspend)
        XCTAssertTrue(state.isSuspended)
    }

    func testLaunchWhileLockedStartsSuspended() {
        XCTAssertTrue(ScreenLockState(isLocked: true).isSuspended)
    }

    func testUnlockWhenAlreadyActiveIsANoOp() {
        var state = ScreenLockState(isLocked: false)
        XCTAssertNil(state.apply(.unlocked))
    }
}
