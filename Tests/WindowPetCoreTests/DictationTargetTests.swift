import XCTest
@testable import WindowPetCore

/// Dictation types only into the app the hold started in, and never behind
/// the lock screen.
final class DictationTargetTests: XCTestCase {
    func testSameAppWhileUnlockedTypes() {
        XCTAssertTrue(DictationPolicy.mayType(targetPID: 412, frontPID: 412, suspended: false))
    }

    func testAnotherAppInFrontStopsTyping() {
        XCTAssertFalse(DictationPolicy.mayType(targetPID: 412, frontPID: 977, suspended: false))
    }

    func testUnknownTargetOrFrontNeverTypes() {
        XCTAssertFalse(DictationPolicy.mayType(targetPID: nil, frontPID: 412, suspended: false))
        XCTAssertFalse(DictationPolicy.mayType(targetPID: 412, frontPID: nil, suspended: false))
        XCTAssertFalse(DictationPolicy.mayType(targetPID: nil, frontPID: nil, suspended: false))
    }

    func testLockedMacNeverTypes() {
        XCTAssertFalse(DictationPolicy.mayType(targetPID: 412, frontPID: 412, suspended: true))
    }
}
