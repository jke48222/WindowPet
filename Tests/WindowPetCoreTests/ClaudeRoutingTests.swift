import XCTest
@testable import WindowPetCore

final class ClaudeRoutingTests: XCTestCase {

    // MARK: request builder

    func testRequestShape() throws {
        let spec = try XCTUnwrap(ClaudeRouting.routeRequest(text: "open Safari",
                                                            context: "frontmost app: Finder",
                                                            apiKey: "sk-ant-test"))
        XCTAssertEqual(spec.url.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(spec.headers["x-api-key"], "sk-ant-test")
        XCTAssertEqual(spec.headers["anthropic-version"], "2023-06-01")
        XCTAssertEqual(spec.headers["content-type"], "application/json")

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: spec.body) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "claude-opus-5")
        XCTAssertNil(body["thinking"], "omit thinking — adaptive is the model default")
        XCTAssertNil(body["temperature"], "sampling params are rejected on claude-opus-5")

        let outputConfig = try XCTUnwrap(body["output_config"] as? [String: Any])
        XCTAssertEqual(outputConfig["effort"] as? String, "low")
        let format = try XCTUnwrap(outputConfig["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertEqual((schema["required"] as? [String])?.sorted(),
                       ["argument", "extra_steps", "reply", "verb"])
        let props = try XCTUnwrap(schema["properties"] as? [String: Any])
        let verbEnum = try XCTUnwrap((props["verb"] as? [String: Any])?["enum"] as? [String])
        XCTAssertEqual(verbEnum, AssistantRouting.verbs)

        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        let content = try XCTUnwrap(messages[0]["content"] as? String)
        XCTAssertTrue(content.contains("open Safari"))
        XCTAssertTrue(content.contains("frontmost app: Finder"))

        let system = try XCTUnwrap(body["system"] as? String)
        XCTAssertTrue(system.contains("Rusty"))
        XCTAssertTrue(system.contains("none, open, switch"))
    }

    func testRequestUsesCallerModel() throws {
        let spec = try XCTUnwrap(ClaudeRouting.routeRequest(text: "hi", context: "",
                                                            apiKey: "k", model: "claude-fable-5"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: spec.body) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "claude-fable-5")
    }

    // MARK: response parser

    private func data(_ json: String) -> Data { Data(json.utf8) }

    func testParseRouteSuccess() {
        let payload = data(#"""
        {"type":"message","stop_reason":"end_turn","content":[
          {"type":"text","text":"{\"verb\":\"open\",\"argument\":\"Safari\",\"reply\":\"Cranking Safari open!\"}"}]}
        """#)
        XCTAssertEqual(ClaudeRouting.parseRoute(payload),
                       .route(.init(verb: "open", argument: "Safari",
                                    reply: "Cranking Safari open!", steps: [])))
    }

    func testParseSkipsThinkingBlocks() {
        let payload = data(#"""
        {"type":"message","stop_reason":"end_turn","content":[
          {"type":"thinking","thinking":"","signature":"sig"},
          {"type":"text","text":"{\"verb\":\"none\",\"argument\":\"\",\"reply\":\"Gears say hello.\"}"}]}
        """#)
        XCTAssertEqual(ClaudeRouting.parseRoute(payload),
                       .route(.init(verb: "none", argument: "", reply: "Gears say hello.",
                                    steps: [])))
    }

    func testParseRefusal() {
        let payload = data(#"""
        {"type":"message","stop_reason":"refusal","content":[],
         "stop_details":{"type":"refusal","category":"cyber"}}
        """#)
        XCTAssertEqual(ClaudeRouting.parseRoute(payload), .refused)
    }

    func testParseErrorEnvelope() {
        let payload = data(#"""
        {"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}
        """#)
        XCTAssertEqual(ClaudeRouting.parseRoute(payload), .failed("invalid x-api-key"))
    }

    func testParseTruncation() {
        let payload = data(#"""
        {"type":"message","stop_reason":"max_tokens","content":[{"type":"thinking","thinking":""}]}
        """#)
        XCTAssertEqual(ClaudeRouting.parseRoute(payload), .failed("answer ran long, try again"))
    }

    func testParseGarbage() {
        XCTAssertEqual(ClaudeRouting.parseRoute(data("not json")), .failed("unreadable response"))
    }

    func testParseMultiStepPlan() {
        let payload = data(#"""
        {"type":"message","stop_reason":"end_turn","content":[
          {"type":"text","text":"{\"verb\":\"open\",\"argument\":\"Safari\",\"reply\":\"On it.\",\"extra_steps\":[{\"verb\":\"search\",\"argument\":\"tin toys\"},{\"verb\":\"quit\",\"argument\":\"Safari\"},{\"verb\":\"mute\",\"argument\":\"\"}]}"}]}
        """#)
        guard case .route(let route) = ClaudeRouting.parseRoute(payload) else {
            return XCTFail("expected route")
        }
        XCTAssertEqual(route.verb, "open")
        // Steps cap at two; the cap is a hard safety rail on plan length.
        XCTAssertEqual(route.steps, [.init(verb: "search", argument: "tin toys"),
                                     .init(verb: "quit", argument: "Safari")])
    }

    func testRequestCarriesHistory() throws {
        let history: [(role: String, text: String)] = [
            (role: "user", text: "open notes"),
            (role: "assistant", text: "Notes is up."),
        ]
        let spec = try XCTUnwrap(ClaudeRouting.routeRequest(text: "now hide it", context: "c",
                                                            apiKey: "k", history: history))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: spec.body) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(messages[0]["content"] as? String, "open notes")
        XCTAssertEqual(messages[1]["role"] as? String, "assistant")
        XCTAssertEqual((messages[2]["content"] as? String)?.contains("now hide it"), true)
    }

    // MARK: open_url verb gate

    func testOpenURLMapping() {
        XCTAssertEqual(AssistantRouting.action(verb: "open_url",
                                               argument: "https://www.paramountplus.com/shows/big-brother/"),
                       .openURL(URL(string: "https://www.paramountplus.com/shows/big-brother/")!))
        XCTAssertEqual(AssistantRouting.action(verb: "open_url", argument: "paramountplus.com"),
                       .openURL(URL(string: "https://paramountplus.com")!))
        XCTAssertNil(AssistantRouting.action(verb: "open_url", argument: "javascript:alert(1)"))
        XCTAssertNil(AssistantRouting.action(verb: "open_url", argument: "file:///etc/passwd"))
        XCTAssertNil(AssistantRouting.action(verb: "open_url", argument: "not a url"))
        XCTAssertNil(AssistantRouting.action(verb: "open_url", argument: ""))
        XCTAssertNil(AssistantRouting.action(verb: "open_url", argument: "localhost"))
    }

    func testOpenURLNeverConfirms() {
        XCTAssertFalse(AssistantAction.openURL(URL(string: "https://a.com")!).needsConfirmation)
    }

    // MARK: universal tools

    func testUniversalVerbMappings() {
        XCTAssertEqual(AssistantRouting.action(verb: "press_keys", argument: "cmd+t"),
                       .pressKeys("cmd+t"))
        XCTAssertEqual(AssistantRouting.action(verb: "screenshot", argument: ""), .screenshot)
        XCTAssertEqual(AssistantRouting.action(verb: "run_applescript",
                                               argument: "display notification \"hi\""),
                       .runAppleScript("display notification \"hi\""))
        XCTAssertNil(AssistantRouting.action(verb: "run_applescript", argument: ""))
    }

    func testDangerousScriptsNeedConfirmation() {
        XCTAssertTrue(AssistantAction.runAppleScript("do shell script \"rm -rf ~\"").needsConfirmation)
        XCTAssertTrue(AssistantAction.runAppleScript("tell app \"Finder\" to empty trash").needsConfirmation)
        XCTAssertTrue(AssistantAction.runAppleScript("tell app \"Reminders\" to delete reminder 1").needsConfirmation)
        XCTAssertTrue(AssistantAction.runAppleScript("tell app \"System Events\" to keystroke \"x\"").needsConfirmation)
        XCTAssertFalse(AssistantAction.runAppleScript("set volume output volume 30").needsConfirmation)
        XCTAssertFalse(AssistantAction.runAppleScript("display notification \"tea time\"").needsConfirmation)
        XCTAssertFalse(AssistantAction.pressKeys("cmd+t").needsConfirmation)
        XCTAssertFalse(AssistantAction.screenshot.needsConfirmation)
    }

    func testConfirmationSummaryShowsScript() {
        let action = AssistantAction.runAppleScript("do shell script \"uptime\"")
        XCTAssertEqual(action.confirmationSummary, "Run AppleScript: do shell script \"uptime\"")
        XCTAssertEqual(AssistantAction.quitApp("Slack").confirmationSummary, "Quit Slack")
        XCTAssertNil(AssistantAction.screenshot.confirmationSummary)
    }

    // MARK: reply sanitizing per tier

    func testSanitizeReplyStripsEmDashes() {
        XCTAssertEqual(AssistantRouting.sanitizeReply("Done — window slid — enjoy"),
                       "Done, window slid, enjoy")
        XCTAssertEqual(AssistantRouting.sanitizeReply("Ready—set"), "Ready, set")
    }

    func testNewVerbMappings() {
        XCTAssertEqual(AssistantRouting.action(verb: "type_text", argument: "hello"),
                       .typeText("hello"))
        XCTAssertEqual(AssistantRouting.action(verb: "copy_text", argument: "abc"),
                       .copyText("abc"))
        XCTAssertNil(AssistantRouting.action(verb: "type_text", argument: ""))
        if case .typeText(let t)? = AssistantRouting.action(
            verb: "type_text", argument: String(repeating: "x", count: 900)) {
            XCTAssertEqual(t.count, 400)
        } else {
            XCTFail("expected capped typeText")
        }
    }

    func testSanitizeReplyTierLimits() {
        let long = String(repeating: "a", count: 300)
        XCTAssertEqual(AssistantRouting.sanitizeReply(long).count, 90)
        XCTAssertEqual(AssistantRouting.sanitizeReply(long, limit: ClaudeRouting.commandReplyLimit).count,
                       ClaudeRouting.commandReplyLimit)
        XCTAssertEqual(AssistantRouting.sanitizeReply("short", limit: ClaudeRouting.commandReplyLimit),
                       "short")
    }

    func testAnswerLimitKeepsLongText() {
        // A real answer to a question must survive intact, not get clipped.
        let essay = String(repeating: "word ", count: 400)  // 2000 chars
        let cleaned = AssistantRouting.sanitizeReply(essay, limit: ClaudeRouting.answerLimit)
        XCTAssertEqual(cleaned.count, 1999)  // trailing space trimmed, nothing else lost
        XCTAssertFalse(cleaned.hasSuffix("…"))
    }

    // MARK: vision (screen sight)

    func testLookIsASchemaVerb() {
        // Claude can pick "look", but it maps to no executor action: the
        // brain intercepts it for the vision path.
        XCTAssertTrue(AssistantRouting.verbs.contains("look"))
        XCTAssertNil(AssistantRouting.action(verb: "look", argument: "what's on my screen"))
    }

    func testVisionRequestShape() throws {
        let spec = try XCTUnwrap(ClaudeRouting.visionRequest(
            question: "what does this error say", imageBase64: "QUJD", apiKey: "sk-ant-v"))
        XCTAssertEqual(spec.headers["x-api-key"], "sk-ant-v")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: spec.body) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "claude-opus-5")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["type"] as? String, "image")
        let source = try XCTUnwrap(content[0]["source"] as? [String: Any])
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/png")
        XCTAssertEqual(source["data"] as? String, "QUJD")
        XCTAssertEqual(content[1]["type"] as? String, "text")
        XCTAssertEqual((content[1]["text"] as? String)?.contains("what does this error say"), true)
        // No structured-output format on a vision answer (it's prose).
        let outputConfig = try XCTUnwrap(body["output_config"] as? [String: Any])
        XCTAssertNil(outputConfig["format"])
    }

    func testVisionRequestDefaultsEmptyQuestion() throws {
        let spec = try XCTUnwrap(ClaudeRouting.visionRequest(
            question: "   ", imageBase64: "QUJD", apiKey: "k"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: spec.body) as? [String: Any])
        let content = try XCTUnwrap((body["messages"] as? [[String: Any]])?[0]["content"] as? [[String: Any]])
        XCTAssertEqual((content[1]["text"] as? String)?.contains("What is on my screen"), true)
    }

    func testParseTextSuccess() {
        let payload = Data(#"""
        {"type":"message","stop_reason":"end_turn","content":[
          {"type":"thinking","thinking":""},
          {"type":"text","text":"The error says the disk is full."}]}
        """#.utf8)
        XCTAssertEqual(ClaudeRouting.parseText(payload), .text("The error says the disk is full."))
    }

    func testParseTextRefusalAndError() {
        let refusal = Data(#"{"type":"message","stop_reason":"refusal","content":[]}"#.utf8)
        XCTAssertEqual(ClaudeRouting.parseText(refusal), .refused)
        let err = Data(#"{"type":"error","error":{"type":"overloaded_error","message":"busy"}}"#.utf8)
        XCTAssertEqual(ClaudeRouting.parseText(err), .failed("busy"))
        XCTAssertEqual(ClaudeRouting.parseText(Data("nonsense".utf8)), .failed("unreadable response"))
    }
}
