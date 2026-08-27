import XCTest
@testable import WindowPetCore

/// End-to-end replays of the agentic loop: canned API responses go in, and the
/// exact messages array the next request would carry comes out. No network and
/// no AppKit, so the protocol itself is what gets tested rather than a mock of
/// it.
final class AgentLoopTests: XCTestCase {

    // MARK: - Test harness

    /// A scripted conversation. `responses` are the raw API bodies the server
    /// would return, in order; tool calls are answered with canned results.
    private struct Replay {
        var conversation = AgentConversation()
        var executed: [String] = []
        var finalAnswer: String?
        var stopped: String?
        var resends = 0

        /// Runs the loop the same way AgentSession does: begin an iteration,
        /// parse the turn, record it, decide, act.
        mutating func run(_ responses: [String], toolResult: (ClaudeAgent.ToolCall) -> String) {
            for body in responses {
                guard conversation.beginIteration() else { break }
                let result = ClaudeAgent.parseTurn(Data(body.utf8))
                if case .turn(let turn) = result { conversation.record(turn) }
                switch AgentLoop.decide(result, lastText: conversation.lastText) {
                case .answer(let text):
                    finalAnswer = text
                    return
                case .stop(let message):
                    stopped = message
                    return
                case .resend:
                    resends += 1
                case .execute(let calls):
                    var results: [(id: String, text: String, isError: Bool)] = []
                    for call in calls {
                        executed.append("\(call.name)(\(call.argument))")
                        results.append((id: call.id, text: toolResult(call), isError: false))
                    }
                    conversation.record(results: results)
                }
            }
        }
    }

    private func role(_ index: Int, in conversation: AgentConversation) -> String? {
        conversation.messages[index]["role"] as? String
    }

    private func blocks(_ index: Int, in conversation: AgentConversation) -> [[String: Any]] {
        conversation.messages[index]["content"] as? [[String: Any]] ?? []
    }

    // MARK: - Canned responses

    private func toolUse(id: String, name: String, argument: String,
                         thinking: String? = nil) -> String {
        var content: [String] = []
        if let thinking {
            content.append(#"{"type":"thinking","thinking":"\#(thinking)","signature":"sig_abc123"}"#)
        }
        content.append(#"{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":{"argument":"\#(argument)"}}"#)
        return #"{"content":[\#(content.joined(separator: ","))],"stop_reason":"tool_use"}"#
    }

    private func answer(_ text: String) -> String {
        #"{"content":[{"type":"text","text":"\#(text)"}],"stop_reason":"end_turn"}"#
    }

    // MARK: - A full multi-turn run

    /// The shape every agentic conversation has: ask, tool call, result, answer.
    func testTwoTurnToolThenAnswer() throws {
        var replay = Replay()
        replay.conversation.ask("open safari", situation: "on the desktop")
        replay.run([toolUse(id: "toolu_1", name: "open", argument: "Safari"),
                    answer("Safari is up.")]) { _ in "Opened Safari." }

        XCTAssertEqual(replay.executed, ["open(Safari)"])
        XCTAssertEqual(replay.finalAnswer, "Safari is up.")
        XCTAssertNil(replay.stopped)

        // user ask, assistant tool_use, user tool_result, assistant answer.
        XCTAssertEqual(replay.conversation.messages.count, 4)
        XCTAssertEqual(role(0, in: replay.conversation), "user")
        XCTAssertEqual(role(1, in: replay.conversation), "assistant")
        XCTAssertEqual(role(2, in: replay.conversation), "user")
        XCTAssertEqual(role(3, in: replay.conversation), "assistant")

        let toolResult = try XCTUnwrap(blocks(2, in: replay.conversation).first)
        XCTAssertEqual(toolResult["type"] as? String, "tool_result")
        XCTAssertEqual(toolResult["tool_use_id"] as? String, "toolu_1")
        XCTAssertEqual(toolResult["content"] as? String, "Opened Safari.")
        XCTAssertNil(toolResult["is_error"])
    }

    /// The situation line and the user's words both reach the model.
    func testAskCarriesSituationAndText() throws {
        var conversation = AgentConversation()
        conversation.ask("what is this", situation: "standing on Xcode")
        let content = try XCTUnwrap(conversation.messages[0]["content"] as? String)
        XCTAssertTrue(content.contains("standing on Xcode"))
        XCTAssertTrue(content.contains("what is this"))
    }

    func testPanelHistoryIsReplayedAheadOfTheQuestion() {
        let conversation = AgentConversation(history: [(role: "user", text: "hi"),
                                                       (role: "assistant", text: "hello")])
        XCTAssertEqual(conversation.messages.count, 2)
        XCTAssertEqual(conversation.messages[0]["role"] as? String, "user")
        XCTAssertEqual(conversation.messages[1]["role"] as? String, "assistant")
    }

    /// Anything that is not "assistant" is a user turn; an unknown role must
    /// never reach the API, which rejects it.
    func testUnknownHistoryRoleBecomesUser() {
        let conversation = AgentConversation(history: [(role: "system", text: "note")])
        XCTAssertEqual(conversation.messages[0]["role"] as? String, "user")
    }

    // MARK: - Echoing the assistant back

    /// Thinking blocks carry signatures the API validates on replay. If this
    /// breaks, multi-turn conversations start failing with 400s.
    func testThinkingSignatureSurvivesTheEcho() throws {
        var replay = Replay()
        replay.conversation.ask("open safari", situation: "desktop")
        replay.run([toolUse(id: "toolu_1", name: "open", argument: "Safari",
                            thinking: "They want a browser."),
                    answer("Done.")]) { _ in "ok" }

        let echoed = blocks(1, in: replay.conversation)
        let thinking = try XCTUnwrap(echoed.first { $0["type"] as? String == "thinking" })
        XCTAssertEqual(thinking["signature"] as? String, "sig_abc123")
        XCTAssertEqual(thinking["thinking"] as? String, "They want a browser.")
    }

    /// Server-side tools run on Anthropic's side. They must be echoed back
    /// untouched and must never be executed locally or given a tool_result.
    func testServerToolBlocksAreEchoedButNeverExecuted() throws {
        let body = """
        {"content":[\
        {"type":"server_tool_use","id":"srvtoolu_1","name":"web_search","input":{"query":"weather"}},\
        {"type":"web_search_tool_result","tool_use_id":"srvtoolu_1","content":[]},\
        {"type":"text","text":"It is clear today."}],"stop_reason":"end_turn"}
        """
        var replay = Replay()
        replay.conversation.ask("weather?", situation: "desktop")
        replay.run([body]) { _ in XCTFail("server tools must not be executed"); return "" }

        XCTAssertEqual(replay.executed, [])
        XCTAssertEqual(replay.finalAnswer, "It is clear today.")
        // The echo keeps the server blocks; only the ask and the echo exist,
        // with no tool_result message between them.
        XCTAssertEqual(replay.conversation.messages.count, 2)
        let echoed = blocks(1, in: replay.conversation)
        XCTAssertEqual(echoed.compactMap { $0["type"] as? String },
                       ["server_tool_use", "web_search_tool_result", "text"])
    }

    // MARK: - Parallel calls

    /// Every result for a turn rides in ONE user message. Splitting them
    /// teaches the model to stop calling tools in parallel.
    func testParallelCallsProduceASingleToolResultMessage() {
        let body = """
        {"content":[\
        {"type":"tool_use","id":"toolu_1","name":"mute","input":{"argument":""}},\
        {"type":"tool_use","id":"toolu_2","name":"maximize","input":{"argument":""}}],\
        "stop_reason":"tool_use"}
        """
        var replay = Replay()
        replay.conversation.ask("quiet and big", situation: "desktop")
        replay.run([body, answer("Done.")]) { _ in "ok" }

        XCTAssertEqual(replay.executed, ["mute()", "maximize()"])
        XCTAssertEqual(replay.conversation.messages.count, 4)
        let results = blocks(2, in: replay.conversation)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.compactMap { $0["tool_use_id"] as? String }, ["toolu_1", "toolu_2"])
    }

    /// A failed step is marked, so the model can adapt instead of assuming it
    /// worked.
    func testFailedToolResultCarriesTheErrorFlag() throws {
        var conversation = AgentConversation()
        conversation.record(results: [(id: "toolu_1", text: "No app named that.", isError: true)])
        let block = try XCTUnwrap((conversation.messages[0]["content"] as? [[String: Any]])?.first)
        XCTAssertEqual(block["is_error"] as? Bool, true)
    }

    /// An empty result would be an empty content block, which the API rejects.
    func testEmptyResultBecomesDone() throws {
        var conversation = AgentConversation()
        conversation.record(results: [(id: "toolu_1", text: "", isError: false)])
        let block = try XCTUnwrap((conversation.messages[0]["content"] as? [[String: Any]])?.first)
        XCTAssertEqual(block["content"] as? String, "done")
    }

    // MARK: - pause_turn

    /// A server tool that hits its own limit mid-turn: the conversation goes
    /// back unchanged, with no tool_result, and the server resumes it.
    func testPauseTurnResendsWithoutAToolResult() {
        let paused = #"{"content":[{"type":"text","text":"Reading…"}],"stop_reason":"pause_turn"}"#
        var replay = Replay()
        replay.conversation.ask("research this", situation: "desktop")
        replay.run([paused, answer("Here is what I found.")]) { _ in "ok" }

        XCTAssertEqual(replay.resends, 1)
        XCTAssertEqual(replay.finalAnswer, "Here is what I found.")
        // ask, paused echo, resumed echo. No user turn in between.
        XCTAssertEqual(replay.conversation.messages.count, 3)
        XCTAssertEqual(role(2, in: replay.conversation), "assistant")
    }

    /// A pause loop still costs iterations, so it cannot spin forever.
    func testRepeatedPausesRunOutOfIterations() {
        let paused = #"{"content":[{"type":"text","text":"Still reading"}],"stop_reason":"pause_turn"}"#
        var replay = Replay()
        replay.conversation.ask("research", situation: "desktop")
        replay.run(Array(repeating: paused, count: ClaudeAgent.maxIterations + 4)) { _ in "ok" }

        XCTAssertNil(replay.finalAnswer)
        XCTAssertEqual(replay.conversation.iterations, ClaudeAgent.maxIterations)
        XCTAssertEqual(replay.resends, ClaudeAgent.maxIterations)
    }

    // MARK: - Stopping

    func testIterationBudgetStopsAtTheCap() {
        var conversation = AgentConversation()
        for _ in 0..<ClaudeAgent.maxIterations {
            XCTAssertTrue(conversation.beginIteration())
        }
        XCTAssertFalse(conversation.beginIteration())
        XCTAssertEqual(conversation.iterations, ClaudeAgent.maxIterations)
    }

    /// Running out of steps still says something true rather than going quiet.
    func testExhaustedAnswerFallsBackToWhatWasSaid() {
        XCTAssertEqual(AgentLoop.exhaustedAnswer(lastText: "I got as far as the login page."),
                       "I got as far as the login page.")
        XCTAssertFalse(AgentLoop.exhaustedAnswer(lastText: "").isEmpty)
    }

    /// A closing turn that spends everything on tool calls still answers, using
    /// the last thing Rusty actually said.
    func testFinalTurnWithNoTextFallsBackToEarlierText() {
        var replay = Replay()
        replay.conversation.ask("tidy up", situation: "desktop")
        let spoke = """
        {"content":[{"type":"text","text":"Muting first."},\
        {"type":"tool_use","id":"toolu_1","name":"mute","input":{"argument":""}}],\
        "stop_reason":"tool_use"}
        """
        let silent = #"{"content":[],"stop_reason":"end_turn"}"#
        replay.run([spoke, silent]) { _ in "ok" }
        XCTAssertEqual(replay.finalAnswer, "Muting first.")
    }

    func testRefusalAnswersRatherThanFailing() {
        var replay = Replay()
        // Safety classifiers decline by ending the turn with stop_reason
        // "refusal" rather than by returning an error envelope.
        replay.run([#"{"content":[],"stop_reason":"refusal"}"#]) { _ in "ok" }
        XCTAssertNil(replay.stopped)
        XCTAssertEqual(replay.finalAnswer, "That one is outside what I can help with.")
    }

    /// Truncated with nothing to show for it is a failure, not an empty reply.
    func testEmptyMaxTokensTurnStopsTheLoop() {
        var replay = Replay()
        replay.run([#"{"content":[],"stop_reason":"max_tokens"}"#]) { _ in "ok" }
        XCTAssertNil(replay.finalAnswer)
        XCTAssertEqual(replay.stopped, "Claude call failed: \(ClaudeRouting.answerRanLongMessage)")
    }

    /// Truncated but with text already streamed: keep what arrived.
    func testTruncatedTurnWithTextStillAnswers() {
        var replay = Replay()
        replay.run([#"{"content":[{"type":"text","text":"Half an answ"}],"stop_reason":"max_tokens"}"#]) { _ in "ok" }
        XCTAssertEqual(replay.finalAnswer, "Half an answ")
    }

    func testApiErrorStopsTheLoop() {
        var replay = Replay()
        replay.run([#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#]) { _ in "ok" }
        XCTAssertNil(replay.finalAnswer)
        XCTAssertEqual(replay.stopped, "Claude call failed: Overloaded")
    }

    // MARK: - Streaming and buffered agree

    /// The app streams; the tests above parse buffered bodies. Both paths must
    /// reconstruct the same turn, or the loop would behave differently live
    /// than it does under test.
    func testStreamedTurnMatchesBufferedTurn() throws {
        let sse = [
            #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"open","input":{}}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"argument\":\"Safari\"}"}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
        ].map { "event: x\ndata: \($0)\n" }.joined(separator: "\n")

        let accumulator = StreamAccumulator()
        accumulator.consume(chunk: sse)
        guard case .turn(let streamed) = accumulator.finish() else { return XCTFail("expected a turn") }
        guard case .turn(let buffered) =
                ClaudeAgent.parseTurn(Data(toolUse(id: "toolu_1", name: "open", argument: "Safari").utf8))
        else { return XCTFail("expected a turn") }

        XCTAssertEqual(streamed.calls, buffered.calls)
        XCTAssertEqual(streamed.stopReason, buffered.stopReason)
        XCTAssertEqual(AgentLoop.decide(.turn(streamed), lastText: ""),
                       AgentLoop.decide(.turn(buffered), lastText: ""))
    }
}
