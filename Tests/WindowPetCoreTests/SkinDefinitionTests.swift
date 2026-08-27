import XCTest
@testable import WindowPetCore

final class SkinDefinitionTests: XCTestCase {

    func testHexFormats() throws {
        let full = try XCTUnwrap(HexColor.parse("#3399ff"))
        XCTAssertEqual(full.r, 0.2, accuracy: 0.01)
        XCTAssertEqual(full.g, 0.6, accuracy: 0.01)
        XCTAssertEqual(full.b, 1.0, accuracy: 0.01)
        XCTAssertEqual(full.a, 1.0, accuracy: 0.01)

        // Shorthand expands, alpha is honored, and the hash is optional.
        let short = try XCTUnwrap(HexColor.parse("#39f"))
        XCTAssertEqual(short.r, 0.2, accuracy: 0.01)
        XCTAssertEqual(short.b, 1.0, accuracy: 0.01)
        let alpha = try XCTUnwrap(HexColor.parse("3399ff80"))
        XCTAssertEqual(alpha.a, 0.5, accuracy: 0.01)
    }

    func testBadHexIsRejected() {
        for bad in ["", "#", "nope", "#12345", "#zzz", "#3399ff0"] {
            XCTAssertNil(HexColor.parse(bad), "\(bad) should not parse")
        }
    }

    func testExampleSkinIsValid() {
        // The file handed to a first-time skin author must actually work.
        XCTAssertTrue(SkinDefinition.example.problems.isEmpty)
    }

    func testProblemsAreReportedNotSwallowed() {
        let broken = SkinDefinition(
            name: "", sprites: "chrome", accent: "nope", thinking: "#fff",
            glassTop: "#fff", glassBottom: "#fff", border: "#fff",
            userText: "#fff", rustyText: "#fff", bubbleFill: "#fff",
            bubbleText: "#fff")
        let problems = broken.problems
        XCTAssertTrue(problems.contains { $0.contains("name") })
        XCTAssertTrue(problems.contains { $0.contains("sprites") })
        XCTAssertTrue(problems.contains { $0.contains("accent") })
    }

    func testIDIsStableAndNamespaced() {
        let a = SkinDefinition.example
        let b = SkinDefinition(name: "  MY   skin ", sprites: "tinplate",
                               accent: "#fff", thinking: "#fff", glassTop: "#fff",
                               glassBottom: "#fff", border: "#fff", userText: "#fff",
                               rustyText: "#fff", bubbleFill: "#fff", bubbleText: "#fff")
        XCTAssertEqual(a.id, b.id, "same name should mean the same skin")
        XCTAssertTrue(a.id.hasPrefix("custom:"), "must not collide with a built-in id")
    }

    func testRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(SkinDefinition.example)
        let restored = try JSONDecoder().decode(SkinDefinition.self, from: data)
        XCTAssertEqual(restored, SkinDefinition.example)
    }
}
