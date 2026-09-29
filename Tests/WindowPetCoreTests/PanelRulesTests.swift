import XCTest
@testable import WindowPetCore

/// The assistant panel's safety check answers only a fresh, deliberate
/// Return.
final class ConfirmationGateTests: XCTestCase {
    private let shown = Date(timeIntervalSince1970: 1_000)

    private func decide(armedAt: Date?, after seconds: TimeInterval,
                        isRepeat: Bool = false) -> ConfirmationGate.Verdict {
        ConfirmationGate.decide(shownAt: shown, armedAt: armedAt,
                                now: shown.addingTimeInterval(seconds), isRepeat: isRepeat,
                                delay: 0.6, lifetime: 120)
    }

    func testAHeldReturnNeverApproves() {
        // Auto-repeat keeps firing past any delay; it is not a press.
        XCTAssertEqual(decide(armedAt: shown, after: 0.65, isRepeat: true), .ignore)
        XCTAssertEqual(decide(armedAt: shown, after: 30, isRepeat: true), .ignore)
    }

    func testANewPressAfterTheDelayApproves() {
        XCTAssertEqual(decide(armedAt: shown, after: 0.65), .approve)
    }

    func testAnUnarmedCheckIsRefused() {
        XCTAssertEqual(decide(armedAt: nil, after: 5), .notArmed)
    }

    func testTheDelayCountsFromArming() {
        let armed = shown.addingTimeInterval(3)
        XCTAssertEqual(decide(armedAt: armed, after: 3.2), .tooSoon)
        XCTAssertEqual(decide(armedAt: armed, after: 3.7), .approve)
    }

    func testAStaleCheckExpires() {
        XCTAssertEqual(decide(armedAt: shown, after: 121), .expired)
    }
}

final class AutoHidePolicyTests: XCTestCase {
    func testEachReasonToWait() {
        XCTAssertEqual(AutoHidePolicy.decide(isKey: false, busy: true, pointerOver: true), .busy)
        XCTAssertEqual(AutoHidePolicy.decide(isKey: true, busy: false, pointerOver: true),
                       .waitForFocus)
        XCTAssertEqual(AutoHidePolicy.decide(isKey: false, busy: false, pointerOver: true),
                       .pauseForHover)
        XCTAssertEqual(AutoHidePolicy.decide(isKey: false, busy: false, pointerOver: false), .hide)
    }
}

/// Outside content keeps gating side effects for as long as the model can
/// still see it, and no longer.
final class ConversationHistoryTests: XCTestCase {
    func testAFollowUpToADroppedFileStartsTainted() {
        var history = ConversationHistory(capacity: 24)
        history.append(role: "user", text: "notes.md", tainted: true)
        history.append(role: "assistant", text: "summary", tainted: true)
        history.append(role: "user", text: "summarise it again", tainted: false)
        XCTAssertTrue(history.priorTurnsTainted)
        XCTAssertEqual(history.plain.map(\.role), ["user", "assistant", "user"])
    }

    func testTaintClearsOnceTheTaintedTurnsLeaveTheWindow() {
        var history = ConversationHistory(capacity: 24)
        history.append(role: "user", text: "notes.md", tainted: true)
        history.append(role: "assistant", text: "summary", tainted: true)
        for i in 0..<22 {
            history.append(role: i % 2 == 0 ? "user" : "assistant", text: "t\(i)", tainted: false)
            XCTAssertTrue(history.priorTurnsTainted, "still replayed after \(i + 1) turns")
        }
        // The window holds 24 turns: the drop falls out first, then its answer.
        history.append(role: "user", text: "later", tainted: false)
        XCTAssertEqual(history.turns.count, 24)
        XCTAssertTrue(history.priorTurnsTainted)
        history.append(role: "assistant", text: "sure", tainted: false)
        XCTAssertEqual(history.turns.count, 24)
        XCTAssertFalse(history.priorTurnsTainted)
    }

    func testTheNewestTurnIsNotCountedAsPrior() {
        var history = ConversationHistory(capacity: 24)
        history.append(role: "user", text: "open safari", tainted: false)
        XCTAssertFalse(history.priorTurnsTainted)
        history.append(role: "assistant", text: "Opening", tainted: false)
        history.append(role: "user", text: "dropped file", tainted: true)
        XCTAssertFalse(history.priorTurnsTainted)
    }

    func testAFollowUpToAWakeWordRequestStartsTainted() {
        var history = ConversationHistory(capacity: 24)
        history.append(role: "user", text: "remember my code is 4412",
                       tainted: RequestSource.wakeWord.isUntrusted)
        history.append(role: "assistant", text: "Noted", tainted: true)
        history.append(role: "user", text: "what is my code", tainted: RequestSource.typed.isUntrusted)
        XCTAssertTrue(history.priorTurnsTainted)
    }
}

/// Only what the user typed or said while holding the key is theirs; a
/// dropped file, a standing ask and anything the wake word heard count as
/// outside content.
final class RequestSourceTests: XCTestCase {
    func testOnlyTypingAndPushToTalkAreTheUsersOwnWords() {
        let own = RequestSource.allCases.filter { !$0.isUntrusted }
        XCTAssertEqual(Set(own), [.typed, .voice])
    }

    func testTheWakeWordIsOutsideContentAndHeard() {
        XCTAssertTrue(RequestSource.wakeWord.isUntrusted)
        XCTAssertTrue(RequestSource.wakeWord.isHeard)
        XCTAssertTrue(RequestSource.wakeWord.isVoice)
    }

    func testPushToTalkIsVoiceButNotHeard() {
        XCTAssertTrue(RequestSource.voice.isVoice)
        XCTAssertFalse(RequestSource.voice.isHeard)
        XCTAssertFalse(RequestSource.voice.isUntrusted)
    }
}
