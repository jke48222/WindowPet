import XCTest
@testable import WindowPetCore

final class BudgetPolicyTests: XCTestCase {

    // MARK: state

    func testUnderLimitIsOK() {
        XCTAssertEqual(BudgetPolicy.state(spent: 1.00, limit: 5), .ok)
    }

    func testEightyPercentIsTheWarningLine() {
        XCTAssertEqual(BudgetPolicy.state(spent: 3.99, limit: 5), .ok)
        XCTAssertEqual(BudgetPolicy.state(spent: 4.00, limit: 5), .nearLimit)
    }

    /// Exactly at the limit is over: the next call would cross it.
    func testExactlyAtLimitIsExceeded() {
        XCTAssertEqual(BudgetPolicy.state(spent: 5.00, limit: 5), .exceeded)
    }

    func testZeroLimitMeansNoCeiling() {
        XCTAssertEqual(BudgetPolicy.state(spent: 900, limit: BudgetPolicy.unlimited), .ok)
        XCTAssertTrue(BudgetPolicy.allowsCall(spent: 900, limit: BudgetPolicy.unlimited))
    }

    /// A negative limit is nonsense but must not become an accidental ceiling
    /// of zero that blocks everything.
    func testNegativeLimitBehavesAsNoCeiling() {
        XCTAssertTrue(BudgetPolicy.allowsCall(spent: 10, limit: -1))
    }

    func testAllowsCallTracksState() {
        XCTAssertTrue(BudgetPolicy.allowsCall(spent: 4.99, limit: 5))
        XCTAssertFalse(BudgetPolicy.allowsCall(spent: 5.01, limit: 5))
    }

    func testSpendingNothingIsFine() {
        XCTAssertEqual(BudgetPolicy.state(spent: 0, limit: 5), .ok)
    }

    // MARK: money formatting

    func testSubCentReadsAsWords() {
        XCTAssertEqual(BudgetPolicy.money(0.003), "under a cent")
    }

    func testZeroIsNotUnderACent() {
        XCTAssertEqual(BudgetPolicy.money(0), "$0.00")
    }

    func testDollarsRoundToCents() {
        XCTAssertEqual(BudgetPolicy.money(4.567), "$4.57")
    }

    // MARK: messages

    /// The stop must say how to get past it, or it reads as a broken app.
    func testExceededMessageNamesTheMenuItem() {
        let message = BudgetPolicy.exceededMessage(spent: 5.20, limit: 5)
        XCTAssertTrue(message.contains("$5.20"))
        XCTAssertTrue(message.contains("$5.00"))
        XCTAssertTrue(message.contains("Daily Spend Limit"))
    }

    /// House style: no em dashes anywhere the user can see.
    func testMessagesAvoidEmDashes() {
        for message in [BudgetPolicy.exceededMessage(spent: 5, limit: 5),
                        BudgetPolicy.nearLimitMessage(spent: 4, limit: 5),
                        BudgetPolicy.limitDescription(5),
                        BudgetPolicy.limitDescription(0)] {
            XCTAssertFalse(message.contains("\u{2014}"), message)
            XCTAssertFalse(message.contains("\u{2013}"), message)
        }
    }

    // MARK: parsing what the user types

    func testParsesPlainNumber() {
        XCTAssertEqual(BudgetPolicy.parseLimit("5"), 5)
    }

    func testParsesDollarSignAndDecimals() {
        XCTAssertEqual(BudgetPolicy.parseLimit(" $12.50 "), 12.50)
    }

    func testParsesThousandsSeparator() {
        XCTAssertEqual(BudgetPolicy.parseLimit("$1,000"), 1000)
    }

    func testWordsSwitchTheCeilingOff() {
        for word in ["none", "None", "off", "no limit", "unlimited"] {
            XCTAssertEqual(BudgetPolicy.parseLimit(word), BudgetPolicy.unlimited, word)
        }
    }

    /// The important one: garbage must not parse, because silently reading as
    /// zero would remove the ceiling entirely.
    func testGarbageIsRejectedRatherThanReadAsZero() {
        for junk in ["", "abc", "$", "five", "3 dollars", "-"] {
            XCTAssertNil(BudgetPolicy.parseLimit(junk), junk)
        }
    }

    func testNegativeAmountIsRejected() {
        XCTAssertNil(BudgetPolicy.parseLimit("-5"))
    }

    func testInfinityIsRejected() {
        XCTAssertNil(BudgetPolicy.parseLimit("inf"))
    }

    /// A ceiling reads as a dollar amount even when it is below a cent, or the
    /// stop message says "my under a cent daily limit".
    func testLimitAlwaysReadsAsAnAmount() {
        let message = BudgetPolicy.exceededMessage(spent: 0.02, limit: 0.009)
        XCTAssertTrue(message.contains("$0.01"), message)
        XCTAssertFalse(message.contains("my under a cent"), message)
    }

    // MARK: menu text

    func testLimitDescription() {
        XCTAssertEqual(BudgetPolicy.limitDescription(5), "$5.00 a day")
        XCTAssertEqual(BudgetPolicy.limitDescription(BudgetPolicy.unlimited), "no limit")
    }

    /// Shipping with no ceiling would defeat the point of having one.
    func testDefaultLimitIsARealCeiling() {
        XCTAssertGreaterThan(BudgetPolicy.defaultLimit, 0)
    }
}
