import XCTest
@testable import WindowPetCore

// MARK: - Dictation

final class DictationPolicyTests: XCTestCase {

    func testFirstBreathIsCapitalized() {
        XCTAssertEqual(DictationPolicy.text(from: "the meeting is at four"),
                       "The meeting is at four")
    }

    /// A second breath joins the sentence rather than starting a new one, so
    /// it keeps its case and brings its own leading space.
    func testContinuingBreathJoinsTheSentence() {
        XCTAssertEqual(DictationPolicy.text(from: "and bring the notes", continuing: true),
                       " and bring the notes")
    }

    func testSpokenPunctuationBecomesPunctuation() {
        XCTAssertEqual(DictationPolicy.text(from: "hello comma world period"),
                       "Hello, world.")
    }

    func testNewLineAndParagraph() {
        XCTAssertEqual(DictationPolicy.text(from: "one new line two"), "One\ntwo")
        XCTAssertEqual(DictationPolicy.text(from: "one new paragraph two"), "One\n\ntwo")
    }

    /// The trap in spoken punctuation: the words are also ordinary words.
    /// Only a standalone "comma" is a comma.
    func testPunctuationWordsInsideOtherWordsSurvive() {
        XCTAssertEqual(DictationPolicy.text(from: "watch the commas in that period piece"),
                       "Watch the commas in that period piece")
    }

    func testFillersAreDropped() {
        XCTAssertEqual(DictationPolicy.text(from: "um the uh meeting"), "The meeting")
    }

    func testPunctuationHugsTheWordBefore() {
        XCTAssertEqual(DictationPolicy.text(from: "yes comma really question mark"),
                       "Yes, really?")
    }

    func testEmptyInputTypesNothing() {
        XCTAssertEqual(DictationPolicy.text(from: "   "), "")
        XCTAssertEqual(DictationPolicy.text(from: "um uh"), "")
    }

    func testStatusSaysWhereTheWordsAreGoing() {
        XCTAssertEqual(DictationPolicy.statusLine(app: "Notes"), "Dictating into Notes")
        XCTAssertEqual(DictationPolicy.statusLine(app: nil), "Dictating")
    }
}

// MARK: - Standing asks

final class SchedulePolicyTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: iso)!
    }

    // MARK: reading times

    func testReadsPlainAndMeridiemTimes() {
        XCTAssertEqual(SchedulePolicy.timeOfDay(in: "at 9"), 9 * 60)
        XCTAssertEqual(SchedulePolicy.timeOfDay(in: "at 9am"), 9 * 60)
        XCTAssertEqual(SchedulePolicy.timeOfDay(in: "at 6:15pm"), 18 * 60 + 15)
        XCTAssertEqual(SchedulePolicy.timeOfDay(in: "at 09:30"), 9 * 60 + 30)
    }

    /// Midnight and noon are the two the twelve-hour clock gets wrong.
    func testMidnightAndNoon() {
        XCTAssertEqual(SchedulePolicy.timeOfDay(in: "12am"), 0)
        XCTAssertEqual(SchedulePolicy.timeOfDay(in: "12pm"), 12 * 60)
    }

    func testNonsenseTimesAreRejected() {
        XCTAssertNil(SchedulePolicy.timeOfDay(in: "at teatime"))
        XCTAssertNil(SchedulePolicy.timeOfDay(in: "at 99"))
    }

    // MARK: parsing whole asks

    func testParsesEveryWeekday() {
        let entry = SchedulePolicy.parse("every weekday at 9: tell me my first meeting", id: 1)
        XCTAssertEqual(entry?.cadence, .weekdays)
        XCTAssertEqual(entry?.minuteOfDay, 9 * 60)
        XCTAssertEqual(entry?.request, "tell me my first meeting")
    }

    func testParsesANamedDay() {
        let entry = SchedulePolicy.parse("every Friday at 5pm: start the backup", id: 1)
        XCTAssertEqual(entry?.cadence, .weekly)
        XCTAssertEqual(entry?.weekday, 6)  // Calendar numbers Sunday as 1
    }

    func testParsesDailyAndWeekend() {
        XCTAssertEqual(SchedulePolicy.parse("every day at 8: x", id: 1)?.cadence, .daily)
        XCTAssertEqual(SchedulePolicy.parse("every weekend at 10: x", id: 1)?.cadence, .weekends)
    }

    func testParsesRelativeReminders() {
        let now = date("2026-08-27T10:00:00Z")
        let entry = SchedulePolicy.parse("in 20 minutes: check the oven", id: 1, now: now,
                                         calendar: calendar)
        XCTAssertEqual(entry?.cadence, .once)
        XCTAssertEqual(entry?.fireAt, now.addingTimeInterval(20 * 60))
        XCTAssertEqual(SchedulePolicy.parse("in an hour: x", id: 1, now: now,
                                            calendar: calendar)?.fireAt,
                       now.addingTimeInterval(3600))
    }

    /// A request with no time, or a time with no request, is a miss rather
    /// than a guess: a schedule that half-understood is worse than none.
    func testIncompleteAsksAreRejected() {
        XCTAssertNil(SchedulePolicy.parse("every weekday at 9", id: 1))
        XCTAssertNil(SchedulePolicy.parse("tell me my meetings", id: 1))
        XCTAssertNil(SchedulePolicy.parse("at teatime: tell me something", id: 1))
    }

    // MARK: firing

    private func entry(_ cadence: SchedulePolicy.Cadence, minute: Int, weekday: Int? = nil,
                       lastFired: Date? = nil) -> SchedulePolicy.Entry {
        SchedulePolicy.Entry(id: 1, request: "x", cadence: cadence, minuteOfDay: minute,
                             weekday: weekday, lastFiredAt: lastFired)
    }

    func testDailyFiresInsideItsWindow() {
        // A Thursday at 09:05, five minutes into a 9am slot.
        let now = date("2026-08-27T09:05:00Z")
        XCTAssertTrue(SchedulePolicy.isDue(entry(.daily, minute: 9 * 60), now: now,
                                           calendar: calendar))
    }

    func testDailyDoesNotFireBeforeItsTime() {
        let now = date("2026-08-27T08:59:00Z")
        XCTAssertFalse(SchedulePolicy.isDue(entry(.daily, minute: 9 * 60), now: now,
                                            calendar: calendar))
    }

    /// The one that matters for a laptop: waking at 3pm must not replay the
    /// morning it slept through.
    func testAMissedSlotIsNotReplayedLater() {
        let now = date("2026-08-27T15:00:00Z")
        XCTAssertFalse(SchedulePolicy.isDue(entry(.daily, minute: 9 * 60), now: now,
                                            calendar: calendar))
    }

    func testFiresOncePerDayHoweverOftenItIsChecked() {
        let now = date("2026-08-27T09:05:00Z")
        let alreadyFired = entry(.daily, minute: 9 * 60,
                                 lastFired: date("2026-08-27T09:01:00Z"))
        XCTAssertFalse(SchedulePolicy.isDue(alreadyFired, now: now, calendar: calendar))
    }

    func testYesterdaysFiringDoesNotBlockToday() {
        let now = date("2026-08-27T09:05:00Z")
        let firedYesterday = entry(.daily, minute: 9 * 60,
                                   lastFired: date("2026-08-26T09:01:00Z"))
        XCTAssertTrue(SchedulePolicy.isDue(firedYesterday, now: now, calendar: calendar))
    }

    /// 2026-08-27 is a Thursday and 2026-08-29 a Saturday.
    func testWeekdaysAndWeekendsRespectTheDay() {
        let thursday = date("2026-08-27T09:05:00Z")
        let saturday = date("2026-08-29T09:05:00Z")
        XCTAssertTrue(SchedulePolicy.isDue(entry(.weekdays, minute: 9 * 60), now: thursday,
                                           calendar: calendar))
        XCTAssertFalse(SchedulePolicy.isDue(entry(.weekdays, minute: 9 * 60), now: saturday,
                                            calendar: calendar))
        XCTAssertTrue(SchedulePolicy.isDue(entry(.weekends, minute: 9 * 60), now: saturday,
                                           calendar: calendar))
    }

    func testOneOffFiresOnceAndNeverAgain() {
        let fireAt = date("2026-08-27T10:00:00Z")
        let once = SchedulePolicy.Entry(id: 1, request: "x", cadence: .once,
                                        minuteOfDay: 600, fireAt: fireAt)
        XCTAssertTrue(SchedulePolicy.isDue(once, now: fireAt.addingTimeInterval(60),
                                           calendar: calendar))
        var fired = once
        fired.markFired(at: fireAt)
        XCTAssertFalse(SchedulePolicy.isDue(fired, now: fireAt.addingTimeInterval(60),
                                            calendar: calendar))
    }

    func testOneOffLongPastIsNotFired() {
        let fireAt = date("2026-08-27T10:00:00Z")
        let once = SchedulePolicy.Entry(id: 1, request: "x", cadence: .once,
                                        minuteOfDay: 600, fireAt: fireAt)
        XCTAssertFalse(SchedulePolicy.isDue(once, now: fireAt.addingTimeInterval(3600),
                                            calendar: calendar))
    }

    // MARK: how it reads

    func testDescriptionsReadLikeSentences() {
        XCTAssertEqual(entry(.weekdays, minute: 9 * 60).description
                        .replacingOccurrences(of: ": x", with: ""),
                       "every weekday at 9am")
        XCTAssertEqual(entry(.weekly, minute: 17 * 60 + 30, weekday: 6).description
                        .replacingOccurrences(of: ": x", with: ""),
                       "every Friday at 5:30pm")
    }

    func testEmptyListingExplainsHowToAddOne() {
        XCTAssertTrue(SchedulePolicy.listing([]).contains("every weekday at 9"))
    }
}

// MARK: - Quiet hours

final class QuietPolicyTests: XCTestCase {

    func testAnOrdinaryMomentSpeaks() {
        XCTAssertEqual(QuietPolicy.verdict(.init()), .speak)
    }

    /// The three that mean "there is a person listening to something else".
    func testFocusMicAndLockAllHold() {
        XCTAssertEqual(QuietPolicy.verdict(.init(focusOn: true)), .hold(reason: "Focus was on"))
        XCTAssertEqual(QuietPolicy.verdict(.init(micInUse: true)),
                       .hold(reason: "your microphone was in use"))
        XCTAssertEqual(QuietPolicy.verdict(.init(suspended: true)),
                       .hold(reason: "the screen was locked"))
    }

    /// Full screen and mid-sentence are different: the user is right there and
    /// can read, they just should not be talked over.
    func testImmersionAndSpeakingShowWithoutSpeaking() {
        guard case .showSilently = QuietPolicy.verdict(.init(immersion: true)) else {
            return XCTFail("a full-screen video should still show the message")
        }
        guard case .showSilently = QuietPolicy.verdict(.init(speaking: true)) else {
            return XCTFail("mid-sentence should still show the message")
        }
    }

    /// A locked screen outranks everything: nobody is there to read it either.
    func testLockedScreenOutranksTheRest() {
        XCTAssertEqual(QuietPolicy.verdict(.init(focusOn: true, immersion: true, suspended: true)),
                       .hold(reason: "the screen was locked"))
    }

    func testOnlyHoldsCountAsHolding() {
        XCTAssertTrue(QuietPolicy.shouldHold(.init(focusOn: true)))
        XCTAssertFalse(QuietPolicy.shouldHold(.init(immersion: true)))
        XCTAssertFalse(QuietPolicy.shouldHold(.init()))
    }

    /// A message that waited says so, or it looks like a bug.
    func testHeldMessagesExplainTheDelay() {
        let preamble = QuietPolicy.heldPreamble(reason: "Focus was on", waited: 12 * 60)
        XCTAssertTrue(preamble.contains("12 minutes ago"))
        XCTAssertTrue(preamble.contains("Focus was on"))
    }

    func testABriefHoldNeedsNoExplanation() {
        XCTAssertEqual(QuietPolicy.heldPreamble(reason: "Focus was on", waited: 20), "")
    }

    /// Two hours later it is not news, and saying it is worse than silence.
    func testVeryOldMessagesGoStale() {
        XCTAssertFalse(QuietPolicy.isStale(waited: 3600))
        XCTAssertTrue(QuietPolicy.isStale(waited: 3 * 3600))
    }
}

// MARK: - Learned routines

final class TrickPolicyTests: XCTestCase {

    func testOrdinaryVerbsRecord() {
        XCTAssertTrue(TrickPolicy.isRecordable(verb: "open"))
        XCTAssertTrue(TrickPolicy.isRecordable(verb: "place_windows"))
    }

    /// A privileged command saved under a friendly name and replayed by saying
    /// one word is exactly the shape of thing that should not exist.
    func testAdminIsNeverRecorded() {
        XCTAssertFalse(TrickPolicy.isRecordable(verb: "run_admin"))
    }

    /// Questions answer something about right now and mean nothing on replay.
    func testReportingVerbsAreNotRecorded() {
        for verb in ["windows", "clips", "layouts", "look", "read_file"] {
            XCTAssertFalse(TrickPolicy.isRecordable(verb: verb), verb)
        }
    }

    /// The recorder's own verbs must never end up inside a recording, or a
    /// trick would re-arm the recorder every time it ran.
    func testTheRecorderDoesNotRecordItself() {
        for verb in ["record_trick", "save_trick", "trick", "forget_trick"] {
            XCTAssertFalse(TrickPolicy.isRecordable(verb: verb), verb)
        }
    }

    func testStepsAppendUntilTheRoutineIsFull() {
        var steps: [TrickStep] = []
        for index in 0..<TrickPolicy.maxSteps {
            let appended = TrickPolicy.appending(TrickStep(verb: "open", argument: "\(index)"),
                                                 to: steps)
            steps = try! XCTUnwrap(appended)
        }
        XCTAssertNil(TrickPolicy.appending(TrickStep(verb: "open", argument: "one too many"),
                                           to: steps))
    }

    func testUnrecordableStepsAreRefusedNotSilentlyDropped() {
        XCTAssertNil(TrickPolicy.appending(TrickStep(verb: "run_admin", argument: "whoami"),
                                           to: []))
    }

    func testSummaryNamesEveryStep() {
        let trick = Trick(name: "morning", steps: [
            TrickStep(verb: "open", argument: "Mail"),
            TrickStep(verb: "place_windows", argument: "Mail left"),
        ])
        XCTAssertEqual(trick.summary, "morning: open Mail, place_windows Mail left")
    }

    func testAnEmptyRecordingSaysSoRatherThanSavingNothing() {
        let message = TrickPolicy.recordingSaved(Trick(name: "empty", steps: []))
        XCTAssertTrue(message.contains("nothing to save"))
    }

    func testNamesMatchLoosely() {
        XCTAssertEqual(TrickPolicy.normalize("  Morning "), "morning")
    }
}

// MARK: - Putting the windows back

final class ArrangementHistoryTests: XCTestCase {

    private func frame(_ app: String) -> RememberedFrame {
        RememberedFrame(app: app, frame: CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    func testNothingToUndoAtFirst() {
        var history = ArrangementHistory()
        XCTAssertFalse(history.canUndo)
        XCTAssertNil(history.popLast())
    }

    func testUndoReturnsTheMostRecentArrangement() {
        var history = ArrangementHistory()
        history.record([frame("Safari")])
        history.record([frame("Terminal")])
        XCTAssertEqual(history.popLast()?.first?.app, "Terminal")
        XCTAssertEqual(history.popLast()?.first?.app, "Safari")
        XCTAssertFalse(history.canUndo)
    }

    /// An arrangement that moved nothing is not an undo step. Recording it
    /// would make the first undo silently do nothing at all.
    func testEmptyArrangementsAreNotRecorded() {
        var history = ArrangementHistory()
        history.record([])
        XCTAssertFalse(history.canUndo)
    }

    func testHistoryIsBounded() {
        var history = ArrangementHistory()
        for index in 0..<(ArrangementHistory.maxDepth + 5) {
            history.record([frame("App \(index)")])
        }
        XCTAssertEqual(history.steps.count, ArrangementHistory.maxDepth)
        // The oldest fell off the bottom, not the newest off the top.
        XCTAssertEqual(history.steps.first?.first?.app, "App 5")
    }

    /// Windows that could not be put back are named rather than glossed over.
    func testPartialUndoReportsWhatFailed() {
        let message = ArrangementHistory.undone([frame("Safari")], failed: ["Terminal"])
        XCTAssertTrue(message.contains("Put Safari back"))
        XCTAssertTrue(message.contains("Terminal"))
    }

    func testFullyFailedUndoSaysNothingHappened()  {
        XCTAssertEqual(ArrangementHistory.undone([], failed: []),
                       ArrangementHistory.nothingToUndo())
    }
}

// MARK: - Per-app memory

final class ScopedMemoryTests: XCTestCase {

    func testUnscopedFactsAlwaysApply() {
        let fact = PetMemory.Fact(text: "prefers Safari")
        XCTAssertTrue(fact.applies(inApp: "Xcode"))
        XCTAssertTrue(fact.applies(inApp: nil))
    }

    func testScopedFactsOnlyApplyInTheirApp() {
        let fact = PetMemory.Fact(text: "keep the left half", scope: "Xcode")
        XCTAssertTrue(fact.applies(inApp: "Xcode"))
        XCTAssertTrue(fact.applies(inApp: "xcode"))
        XCTAssertFalse(fact.applies(inApp: "Safari"))
        XCTAssertFalse(fact.applies(inApp: nil))
    }

    func testPromptOnlyCarriesFactsForTheAppInFront() {
        var memory = PetMemory()
        memory.remember("prefers dark mode")
        memory.remember("keep the left half", scope: "Xcode")
        memory.remember("open the reader view", scope: "Safari")

        let inXcode = memory.promptBlock(inApp: "Xcode")
        XCTAssertTrue(inXcode.contains("prefers dark mode"))
        XCTAssertTrue(inXcode.contains("keep the left half"))
        XCTAssertFalse(inXcode.contains("reader view"))

        let nowhere = memory.promptBlock(inApp: nil)
        XCTAssertTrue(nowhere.contains("prefers dark mode"))
        XCTAssertFalse(nowhere.contains("keep the left half"))
    }

    /// The same words in two apps are two facts, not one overwriting the other.
    func testSameTextInTwoAppsIsTwoFacts() {
        var memory = PetMemory()
        memory.remember("keep the left half", scope: "Xcode")
        memory.remember("keep the left half", scope: "Safari")
        XCTAssertEqual(memory.facts.count, 2)
    }

    func testRememberingTheSameScopedFactRefreshesIt() {
        var memory = PetMemory()
        memory.remember("keep the left half", scope: "Xcode")
        memory.remember("keep the left half", scope: "Xcode")
        XCTAssertEqual(memory.facts.count, 1)
    }

    // MARK: the "in App:" spelling

    func testScopePrefixIsRead() {
        let (scope, text) = PetMemory.splitScope("in Xcode: keep the left half")
        XCTAssertEqual(scope, "Xcode")
        XCTAssertEqual(text, "keep the left half")
    }

    func testOtherSpellingsAreRead() {
        XCTAssertEqual(PetMemory.splitScope("for Safari: use reader view").scope, "Safari")
        XCTAssertEqual(PetMemory.splitScope("when in Mail: archive on read").scope, "Mail")
    }

    /// Without a colon there is no way to tell an app name from the sentence,
    /// so the fact stays global rather than being guessed at.
    func testASentenceStartingWithInIsNotAScope() {
        let (scope, text) = PetMemory.splitScope("in the mornings they read email first")
        XCTAssertNil(scope)
        XCTAssertEqual(text, "in the mornings they read email first")
    }

    func testUnprefixedFactsStayGlobal() {
        let (scope, text) = PetMemory.splitScope("prefers dark mode")
        XCTAssertNil(scope)
        XCTAssertEqual(text, "prefers dark mode")
    }

    /// Memory files written before scopes existed must still decode.
    func testOldMemoryFilesStillDecode() throws {
        let json = #"{"facts":[{"text":"prefers Safari","savedAt":0}],"recent":[]}"#
        let memory = try JSONDecoder().decode(PetMemory.self, from: Data(json.utf8))
        XCTAssertEqual(memory.facts.count, 1)
        XCTAssertNil(memory.facts[0].scope)
        XCTAssertTrue(memory.promptBlock(inApp: "Anything").contains("prefers Safari"))
    }
}
