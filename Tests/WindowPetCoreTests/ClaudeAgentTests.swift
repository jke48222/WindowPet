import XCTest
@testable import WindowPetCore

final class ClaudeAgentTests: XCTestCase {

    // MARK: tool definitions

    func testToolDefinitionsCoverEveryActionableVerb() throws {
        let tools = ClaudeAgent.toolDefinitions
        let names = tools.compactMap { $0["name"] as? String }
        // "none" is conversation, not a tool; everything else is callable.
        // Anthropic-hosted web tools ride alongside the client verbs.
        XCTAssertEqual(Set(names),
                       Set(AssistantRouting.verbs.filter { $0 != "none" })
                           .union(ClaudeAgent.serverToolNames))
        XCTAssertFalse(names.contains("none"))

        // Server tools carry no schema of ours; only client tools are checked.
        for tool in tools where !ClaudeAgent.serverToolNames.contains(tool["name"] as? String ?? "") {
            let description = try XCTUnwrap(tool["description"] as? String)
            XCTAssertFalse(description.isEmpty, "every tool needs a when-to-call description")
            let schema = try XCTUnwrap(tool["input_schema"] as? [String: Any])
            XCTAssertEqual(schema["type"] as? String, "object")
            XCTAssertEqual(schema["required"] as? [String], ["argument"])
            let props = try XCTUnwrap(schema["properties"] as? [String: Any])
            XCTAssertNotNil(props["argument"])
        }
    }

    func testEveryToolNameMapsBackToAGatedAction() {
        // The loop's whole safety story: a tool call becomes the same
        // AssistantAction a typed command would, so gating still applies.
        // Arguments are per-verb because the mappers validate them (open_url
        // only accepts a real https URL, for instance).
        let sample = ["open_url": "https://example.com", "press_keys": "cmd+t"]
        for name in ClaudeAgent.toolDefinitions.compactMap({ $0["name"] as? String })
        where !ClaudeAgent.internalVerbs.contains(name)
            && !ClaudeAgent.serverToolNames.contains(name) {
            XCTAssertNotNil(AssistantRouting.action(verb: name, argument: sample[name] ?? "x"),
                            "\(name) should map to an action")
        }
    }

    func testGatedToolsStillRequireConfirmation() {
        // Reachable through the loop, but never runnable by it alone.
        XCTAssertTrue(AssistantRouting.action(verb: "quit", argument: "Slack")!.needsConfirmation)
        XCTAssertTrue(AssistantRouting.action(verb: "run_admin", argument: "whoami")!.needsConfirmation)
        XCTAssertTrue(AssistantRouting.action(
            verb: "run_applescript", argument: "do shell script \"rm x\"")!.needsConfirmation)
    }

    // MARK: server-side web tools

    func testWebToolsAreOffered() throws {
        let tools = ClaudeAgent.toolDefinitions
        let byName = Dictionary(uniqueKeysWithValues: tools.compactMap { tool -> (String, [String: Any])? in
            guard let name = tool["name"] as? String else { return nil }
            return (name, tool)
        })
        // Anthropic-hosted: declared by type, with no input_schema of ours.
        XCTAssertEqual(byName["web_search"]?["type"] as? String, "web_search_20260209")
        XCTAssertEqual(byName["web_fetch"]?["type"] as? String, "web_fetch_20260209")
        XCTAssertNil(byName["web_search"]?["input_schema"])
        // The client-side "search" tool still exists and is distinct: it opens
        // a page for the user rather than reading the web for Rusty.
        XCTAssertNotNil(byName["search"]?["input_schema"])
    }

    func testServerToolsAreNotClientVerbs() {
        // They must never be routed to the executor or treated as internal.
        XCTAssertNil(AssistantRouting.action(verb: "web_search", argument: "x"))
        XCTAssertNil(AssistantRouting.action(verb: "web_fetch", argument: "x"))
        XCTAssertFalse(ClaudeAgent.internalVerbs.contains("web_search"))
    }

    func testServerToolUseIsNeverExecutedAsAClientCall() {
        // server_tool_use ran on Anthropic's side already. Returning a
        // tool_result for it, or executing it locally, would corrupt the turn.
        let payload = Data(#"""
        {"type":"message","stop_reason":"tool_use","content":[
          {"type":"server_tool_use","id":"srv_1","name":"web_search","input":{"query":"tin robots"}},
          {"type":"web_search_tool_result","tool_use_id":"srv_1","content":[]},
          {"type":"tool_use","id":"toolu_1","name":"open","input":{"argument":"Safari"}}]}
        """#.utf8)
        guard case .turn(let turn) = ClaudeAgent.parseTurn(payload) else {
            return XCTFail("expected a turn")
        }
        XCTAssertEqual(turn.calls, [.init(id: "toolu_1", name: "open", argument: "Safari")])
        // All three blocks still echo back for replay.
        XCTAssertEqual(turn.rawContent.count, 3)
    }

    func testPauseTurnIsATurnNotAFailure() {
        // A long server-tool turn pauses; the loop resumes it rather than
        // treating the empty answer as the final one.
        let payload = Data(#"""
        {"type":"message","stop_reason":"pause_turn","content":[
          {"type":"server_tool_use","id":"srv_1","name":"web_search","input":{"query":"x"}}]}
        """#.utf8)
        guard case .turn(let turn) = ClaudeAgent.parseTurn(payload) else {
            return XCTFail("expected a turn, not a failure")
        }
        XCTAssertEqual(turn.stopReason, "pause_turn")
        XCTAssertTrue(turn.calls.isEmpty)
    }

    // MARK: request

    func testAgentRequestShape() throws {
        let messages = [ClaudeAgent.userMessage("open safari")]
        let spec = try XCTUnwrap(ClaudeAgent.agentRequest(messages: messages, apiKey: "sk-ant-a"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: spec.body) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "claude-opus-5")
        XCTAssertNil(body["thinking"], "adaptive thinking is the default on opus 5")
        XCTAssertNil(body["temperature"], "sampling params are rejected")

        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertFalse(tools.isEmpty)

        // Cache breakpoint on system caches tools+system, the identical
        // prefix resent on every iteration of the loop.
        let system = try XCTUnwrap(body["system"] as? [[String: Any]])
        XCTAssertEqual((system.last?["cache_control"] as? [String: Any])?["type"] as? String,
                       "ephemeral")

        let outputConfig = try XCTUnwrap(body["output_config"] as? [String: Any])
        XCTAssertEqual(outputConfig["effort"] as? String, "medium")

        let sent = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0]["role"] as? String, "user")
    }

    // MARK: turn parsing

    private func data(_ s: String) -> Data { Data(s.utf8) }

    func testParseTurnExtractsToolCalls() {
        let payload = data(#"""
        {"type":"message","stop_reason":"tool_use","content":[
          {"type":"thinking","thinking":"","signature":"sig"},
          {"type":"text","text":"On it."},
          {"type":"tool_use","id":"toolu_1","name":"open","input":{"argument":"Safari"}},
          {"type":"tool_use","id":"toolu_2","name":"search","input":{"argument":"tin toys"}}]}
        """#)
        guard case .turn(let turn) = ClaudeAgent.parseTurn(payload) else {
            return XCTFail("expected a turn")
        }
        XCTAssertEqual(turn.stopReason, "tool_use")
        XCTAssertEqual(turn.text, "On it.")
        XCTAssertEqual(turn.calls, [
            .init(id: "toolu_1", name: "open", argument: "Safari"),
            .init(id: "toolu_2", name: "search", argument: "tin toys"),
        ])
        // Raw content is echoed verbatim; thinking blocks carry signatures.
        XCTAssertEqual(turn.rawContent.count, 4)
    }

    func testParseTurnFinalAnswerHasNoCalls() {
        let payload = data(#"""
        {"type":"message","stop_reason":"end_turn","content":[
          {"type":"text","text":"Safari is open and searching."}]}
        """#)
        guard case .turn(let turn) = ClaudeAgent.parseTurn(payload) else {
            return XCTFail("expected a turn")
        }
        XCTAssertTrue(turn.calls.isEmpty)
        XCTAssertEqual(turn.text, "Safari is open and searching.")
    }

    func testParseTurnHandlesRefusalAndError() {
        XCTAssertEqual(
            ClaudeAgent.parseTurn(data(#"{"type":"message","stop_reason":"refusal","content":[]}"#)),
            .refused)
        XCTAssertEqual(
            ClaudeAgent.parseTurn(data(#"{"type":"error","error":{"type":"x","message":"boom"}}"#)),
            .failed("boom"))
        XCTAssertEqual(ClaudeAgent.parseTurn(data("garbage")), .failed("unreadable response"))
    }

    func testMissingArgumentDefaultsToEmpty() {
        let payload = data(#"""
        {"type":"message","stop_reason":"tool_use","content":[
          {"type":"tool_use","id":"t1","name":"mute","input":{}}]}
        """#)
        guard case .turn(let turn) = ClaudeAgent.parseTurn(payload) else {
            return XCTFail("expected a turn")
        }
        XCTAssertEqual(turn.calls.first?.argument, "")
    }

    // MARK: message builders

    func testToolResultsRideInOneMessage() throws {
        // Splitting results across messages trains the model out of parallel
        // tool calls, so they must all share a single user turn.
        let message = ClaudeAgent.toolResultMessage([
            (id: "t1", text: "Opening Safari", isError: false),
            (id: "t2", text: "I couldn't find an app called Foo.", isError: true),
        ])
        XCTAssertEqual(message["role"] as? String, "user")
        let blocks = try XCTUnwrap(message["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0]["type"] as? String, "tool_result")
        XCTAssertEqual(blocks[0]["tool_use_id"] as? String, "t1")
        XCTAssertNil(blocks[0]["is_error"])
        XCTAssertEqual(blocks[1]["is_error"] as? Bool, true)
    }

    func testEmptyToolResultStillCarriesContent() throws {
        let message = ClaudeAgent.toolResultMessage([(id: "t1", text: "", isError: false)])
        let blocks = try XCTUnwrap(message["content"] as? [[String: Any]])
        XCTAssertEqual(blocks[0]["content"] as? String, "done")
    }

    func testAssistantEchoPreservesContent() throws {
        let raw: [[String: Any]] = [["type": "text", "text": "hi"]]
        let echo = ClaudeAgent.assistantEcho(raw)
        XCTAssertEqual(echo["role"] as? String, "assistant")
        let content = try XCTUnwrap(echo["content"] as? [[String: Any]])
        XCTAssertEqual(content[0]["text"] as? String, "hi")
    }
}
