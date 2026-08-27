import XCTest
@testable import WindowPetCore

private let laptop = CGRect(x: 0, y: 0, width: 1512, height: 944)

// MARK: - Seeing the windows

final class WindowReportTests: XCTestCase {

    private func window(_ app: String, _ frame: CGRect, front: Bool = false) -> WindowSnapshot {
        WindowSnapshot(app: app, frame: frame, isFrontmost: front, display: 0)
    }

    func testEmptyScreenSaysSo() {
        XCTAssertEqual(WindowReport.describe([], displays: [laptop]),
                       "No ordinary windows are open right now.")
    }

    func testCountsWindowsAppsAndDisplays() {
        let report = WindowReport.describe([
            window("Safari", CGRect(x: 0, y: 0, width: 700, height: 900)),
            window("Safari", CGRect(x: 700, y: 0, width: 700, height: 900)),
            window("Terminal", CGRect(x: 100, y: 100, width: 600, height: 400)),
        ], displays: [laptop])
        XCTAssertTrue(report.hasPrefix("3 windows across 2 apps on one display."), report)
    }

    func testSingularGrammar() {
        let report = WindowReport.describe([window("Safari", laptop)], displays: [laptop])
        XCTAssertTrue(report.hasPrefix("1 window across 1 app on one display."), report)
    }

    /// The busiest app leads, because a request to tidy is usually about it.
    func testBusiestAppComesFirst() {
        let report = WindowReport.describe([
            window("Notes", CGRect(x: 0, y: 0, width: 400, height: 400)),
            window("Chrome", CGRect(x: 0, y: 0, width: 400, height: 400)),
            window("Chrome", CGRect(x: 10, y: 0, width: 400, height: 400)),
        ], displays: [laptop])
        let lines = report.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[1].hasPrefix("Chrome"), report)
    }

    func testFrontmostIsMarked() {
        let report = WindowReport.describe([window("Safari", laptop, front: true)],
                                           displays: [laptop])
        XCTAssertTrue(report.contains("Safari, frontmost"), report)
    }

    /// Past the detail limit the per-window listing would be a wall of text,
    /// so it collapses to counts.
    func testManyWindowsCollapseToCounts() {
        let many = (0..<20).map { window("Chrome", CGRect(x: $0 * 10, y: 0, width: 400, height: 300)) }
        let report = WindowReport.describe(many, displays: [laptop])
        XCTAssertTrue(report.contains("Chrome: 20 windows"), report)
        XCTAssertTrue(report.contains("largest 400 by 300"), report)
    }

    // MARK: positions in words

    func testFullScreenWindowReadsAsFilling() {
        XCTAssertEqual(WindowReport.position(of: laptop, in: laptop), "filling the screen")
    }

    func testHalvesReadAsLeftAndRight() {
        let left = CGRect(x: 0, y: 0, width: 756, height: 944)
        let right = CGRect(x: 756, y: 0, width: 756, height: 944)
        XCTAssertEqual(WindowReport.position(of: left, in: laptop), "left")
        XCTAssertEqual(WindowReport.position(of: right, in: laptop), "right")
    }

    /// AppKit's y grows upward, so a high midpoint is the top of the screen.
    /// Getting this backwards would make every description wrong.
    func testTopIsHighY() {
        let top = CGRect(x: 500, y: 700, width: 400, height: 200)
        XCTAssertEqual(WindowReport.position(of: top, in: laptop), "top")
        let bottom = CGRect(x: 500, y: 20, width: 400, height: 200)
        XCTAssertEqual(WindowReport.position(of: bottom, in: laptop), "bottom")
    }

    func testCornerReadsAsTwoWords() {
        let corner = CGRect(x: 20, y: 700, width: 300, height: 200)
        XCTAssertEqual(WindowReport.position(of: corner, in: laptop), "top left")
    }

    func testMiddleReadsAsCentered() {
        let middle = CGRect(x: 600, y: 400, width: 300, height: 200)
        XCTAssertEqual(WindowReport.position(of: middle, in: laptop), "centered")
    }

    func testDegenerateDisplayDoesNotDivideByZero() {
        XCTAssertEqual(WindowReport.position(of: laptop, in: .zero), "somewhere")
    }
}

// MARK: - Clipboard history

final class ClipPolicyTests: XCTestCase {

    /// The whole reason this filter exists: a key copied out of a password
    /// manager must never reach the history.
    func testKnownCredentialShapesAreNeverStored() {
        let secrets = [
            "AGE-SECRET-KEY-1QQQQQQQQQQQQQQQQQQQQQQ",
            "sk-ant-api03-abcdefghijklmnop",
            "ghp_abcdefghijklmnopqrstuvwxyz0123",
            "github_pat_11ABCDEFG0abcdefg",
            "xoxb-123456789012-abcdefghij",
            "-----BEGIN OPENSSH PRIVATE KEY-----",
            "AKIAIOSFODNN7EXAMPLE",
        ]
        for secret in secrets {
            XCTAssertTrue(ClipPolicy.isSecret(secret), secret)
            XCTAssertNil(ClipPolicy.normalize(secret), secret)
        }
    }

    /// A long unbroken mixed-case token with digits is a key far more often
    /// than it is anything worth recalling.
    func testHighEntropyTokenIsTreatedAsSecret() {
        XCTAssertTrue(ClipPolicy.isSecret("aB3xY9zQ7wE2rT5yU8iO1pA4sD6fG0hJ"))
    }

    func testOrdinaryTextIsKept() {
        for ordinary in ["221B Baker Street, London",
                         "the meeting is at four",
                         "swift build -c release"] {
            XCTAssertFalse(ClipPolicy.isSecret(ordinary), ordinary)
        }
    }

    /// A URL is long and unbroken too, and is exactly the kind of thing people
    /// want back.
    func testLongURLIsNotMistakenForASecret() {
        let url = "https://example.com/some/quite/long/path?query=aB3xY9zQ7wE2rT5yU8iO1p"
        XCTAssertFalse(ClipPolicy.isSecret(url))
        XCTAssertNotNil(ClipPolicy.normalize(url))
    }

    func testEmptyAndOversizeAreDropped() {
        XCTAssertNil(ClipPolicy.normalize("   \n  "))
        XCTAssertNil(ClipPolicy.normalize(String(repeating: "a", count: ClipPolicy.maxLength + 1)))
    }

    func testNewestFirst() {
        var clips: [String] = []
        clips = ClipPolicy.insert("one", into: clips)
        clips = ClipPolicy.insert("two", into: clips)
        XCTAssertEqual(clips, ["two", "one"])
    }

    /// Re-copying something moves it up rather than making a second entry.
    func testRecopyMovesToFrontWithoutDuplicating() {
        var clips = ["b", "a"]
        clips = ClipPolicy.insert("a", into: clips)
        XCTAssertEqual(clips, ["a", "b"])
    }

    func testHistoryIsCapped() {
        var clips: [String] = []
        for index in 0..<(ClipPolicy.maxClips + 10) {
            clips = ClipPolicy.insert("clip \(index)", into: clips)
        }
        XCTAssertEqual(clips.count, ClipPolicy.maxClips)
        XCTAssertEqual(clips.first, "clip \(ClipPolicy.maxClips + 9)")
    }

    func testSecretDoesNotDisturbTheHistory() {
        let clips = ClipPolicy.insert("sk-ant-api03-abcdefghijklmnop", into: ["kept"])
        XCTAssertEqual(clips, ["kept"])
    }

    func testMatchByNumberIsOneBased() {
        XCTAssertEqual(ClipPolicy.match("2", in: ["a", "b", "c"]), 1)
        XCTAssertNil(ClipPolicy.match("9", in: ["a"]))
        XCTAssertNil(ClipPolicy.match("0", in: ["a"]))
    }

    func testMatchByWords() {
        XCTAssertEqual(ClipPolicy.match("baker", in: ["hello", "221B Baker Street"]), 1)
        XCTAssertNil(ClipPolicy.match("nowhere", in: ["hello"]))
    }

    func testEmptyQueryTakesTheMostRecent() {
        XCTAssertEqual(ClipPolicy.match("", in: ["newest", "older"]), 0)
    }

    func testEmptyHistorySummaryExplainsItself() {
        let summary = ClipPolicy.summary([])
        XCTAssertTrue(summary.contains("password"), summary)
    }

    func testSummaryIsNumberedFromOne() {
        XCTAssertTrue(ClipPolicy.summary(["hello"]).hasPrefix("1. hello"))
    }
}
