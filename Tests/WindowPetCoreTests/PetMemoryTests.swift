import XCTest
@testable import WindowPetCore

final class PetMemoryTests: XCTestCase {

    func testRemembersFacts() {
        var memory = PetMemory()
        memory.remember("prefers Safari over Chrome")
        memory.remember("standup is at 9:30")
        XCTAssertEqual(memory.facts.map(\.text),
                       ["prefers Safari over Chrome", "standup is at 9:30"])
    }

    func testRewordingsDoNotPileUp() {
        // Punctuation and casing differences are the same fact, otherwise the
        // list silts up with near-duplicates.
        var memory = PetMemory()
        memory.remember("Prefers Safari over Chrome")
        memory.remember("prefers safari over chrome!")
        XCTAssertEqual(memory.facts.count, 1)
        // The newer wording wins.
        XCTAssertEqual(memory.facts[0].text, "prefers safari over chrome!")
    }

    func testRejectsJunk() {
        var memory = PetMemory()
        memory.remember("")
        memory.remember("   ")
        memory.remember("ok")  // too short to be a fact
        XCTAssertTrue(memory.facts.isEmpty)
    }

    func testLongFactsAreTrimmed() {
        var memory = PetMemory()
        memory.remember(String(repeating: "x", count: 500))
        XCTAssertEqual(memory.facts[0].text.count, PetMemory.maxFactLength)
    }

    func testOldestFactsFallOffTheEnd() {
        var memory = PetMemory()
        for i in 0..<(PetMemory.maxFacts + 5) { memory.remember("fact number \(i)") }
        XCTAssertEqual(memory.facts.count, PetMemory.maxFacts)
        XCTAssertEqual(memory.facts.first?.text, "fact number 5")
    }

    func testForgetMatchesLoosely() {
        var memory = PetMemory()
        memory.remember("prefers Safari over Chrome")
        memory.remember("standup is at 9:30")
        memory.forget(matching: "safari")
        XCTAssertEqual(memory.facts.map(\.text), ["standup is at 9:30"])
    }

    func testForgetAlsoClearsRecentTail() {
        // Otherwise a "forgotten" secret keeps echoing through recent context.
        var memory = PetMemory()
        memory.remember("the code is kettle-42")
        memory.noteExchange("they said: the code is kettle-42")
        memory.noteExchange("they said: what's the weather")
        memory.forget(matching: "kettle-42")
        XCTAssertFalse(memory.promptBlock.contains("kettle-42"))
        XCTAssertTrue(memory.recent.contains { $0.contains("weather") })  // unrelated stays
    }

    func testForgetEverythingClearsBoth() {
        var memory = PetMemory()
        memory.remember("likes dark mode")
        memory.noteExchange("they said: hello")
        memory.forgetEverything()
        XCTAssertTrue(memory.facts.isEmpty)
        XCTAssertTrue(memory.recent.isEmpty)
        XCTAssertEqual(memory.promptBlock, "")
    }

    func testRecentExchangesAreCapped() {
        var memory = PetMemory()
        for i in 0..<20 { memory.noteExchange("line \(i)") }
        XCTAssertEqual(memory.recent.count, PetMemory.maxRecent)
        XCTAssertEqual(memory.recent.last, "line 19")
    }

    func testPromptBlockIsEmptyOnAFreshInstall() {
        // A brand new user should send no memory noise at all.
        XCTAssertEqual(PetMemory().promptBlock, "")
    }

    func testPromptBlockCarriesBothHalves() {
        var memory = PetMemory()
        memory.remember("prefers Safari")
        memory.noteExchange("they said: open my email")
        let block = memory.promptBlock
        XCTAssertTrue(block.contains("prefers Safari"))
        XCTAssertTrue(block.contains("open my email"))
    }

    func testRoundTripsThroughJSON() throws {
        var memory = PetMemory()
        memory.remember("prefers Safari")
        memory.noteExchange("they said: hi")
        let data = try JSONEncoder().encode(memory)
        let restored = try JSONDecoder().decode(PetMemory.self, from: data)
        XCTAssertEqual(restored, memory)
    }

    func testMemoryToolsAreRoutedInternally() {
        // remember/forget are handled by the agent, not the executor, so they
        // must not map to an AssistantAction.
        XCTAssertTrue(ClaudeAgent.internalVerbs.contains("remember"))
        XCTAssertTrue(ClaudeAgent.internalVerbs.contains("forget"))
        XCTAssertNil(AssistantRouting.action(verb: "remember", argument: "x"))
        XCTAssertNil(AssistantRouting.action(verb: "forget", argument: "x"))
        // But they are still offered to the model as tools.
        let names = ClaudeAgent.toolDefinitions.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("remember"))
        XCTAssertTrue(names.contains("forget"))
    }
}
