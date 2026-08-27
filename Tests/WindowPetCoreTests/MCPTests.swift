import XCTest
@testable import WindowPetCore

final class MCPProtocolTests: XCTestCase {

    private func json(_ data: Data) throws -> [String: Any] {
        let line = String(data: data, encoding: .utf8) ?? ""
        // Every message is one line; the newline is the frame delimiter.
        XCTAssertTrue(line.hasSuffix("\n"), "stdio framing needs a trailing newline")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    // MARK: encoding

    func testRequestIsFramedJSONRPC() throws {
        let payload = try json(try XCTUnwrap(
            MCPProtocol.encode(id: 7, method: "tools/list", params: [:])))
        XCTAssertEqual(payload["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(payload["id"] as? Int, 7)
        XCTAssertEqual(payload["method"] as? String, "tools/list")
    }

    /// A notification has no id, which is how the server knows not to reply.
    func testNotificationCarriesNoID() throws {
        let payload = try json(try XCTUnwrap(
            MCPProtocol.encodeNotification(method: "notifications/initialized", params: [:])))
        XCTAssertNil(payload["id"])
        XCTAssertEqual(payload["method"] as? String, "notifications/initialized")
    }

    func testHandshakeDeclaresTheClient() {
        let params = MCPProtocol.initializeParams
        XCTAssertEqual(params["protocolVersion"] as? String, MCPProtocol.version)
        let client = params["clientInfo"] as? [String: Any]
        XCTAssertEqual(client?["name"] as? String, "WindowPet")
    }

    // MARK: decoding

    func testDecodesAResult() {
        let response = MCPProtocol.decode(line: #"{"jsonrpc":"2.0","id":3,"result":{"ok":true}}"#)
        guard case .result(let id, let payload) = response else { return XCTFail("expected a result") }
        XCTAssertEqual(id, 3)
        XCTAssertEqual(payload["ok"] as? Bool, true)
    }

    func testDecodesAnError() {
        let response = MCPProtocol.decode(
            line: #"{"jsonrpc":"2.0","id":4,"error":{"code":-32601,"message":"no such tool"}}"#)
        XCTAssertEqual(response, .failure(id: 4, message: "no such tool"))
    }

    /// Servers log to stdout. A log line is not a reply, and treating it as
    /// one would wake a call with nonsense.
    func testNonRepliesAreIgnored() {
        XCTAssertEqual(MCPProtocol.decode(line: "starting up..."), .other)
        XCTAssertEqual(MCPProtocol.decode(line: ""), .other)
        XCTAssertEqual(MCPProtocol.decode(line: #"{"jsonrpc":"2.0","method":"log"}"#), .other)
    }

    func testResultWithNoPayloadIsStillAResult() {
        guard case .result(_, let payload) = MCPProtocol.decode(line: #"{"id":1}"#) else {
            return XCTFail("expected a result")
        }
        XCTAssertTrue(payload.isEmpty)
    }

    // MARK: names

    func testQualifiedNamesRoundTrip() {
        let name = MCPProtocol.qualifiedName(server: "notes", tool: "search")
        XCTAssertEqual(name, "notes__search")
        let split = MCPProtocol.split(qualified: name)
        XCTAssertEqual(split?.server, "notes")
        XCTAssertEqual(split?.tool, "search")
    }

    /// Anthropic tool names allow letters, digits, underscore and hyphen. A
    /// server naming a tool something else must not break the whole request.
    func testAwkwardNamesAreCoercedRatherThanRejected() {
        XCTAssertEqual(MCPProtocol.sanitize("my server!"), "my_server_")
        XCTAssertEqual(MCPProtocol.sanitize("read-file"), "read-file")
    }

    func testUnqualifiedNameIsNotAnMCPTool() {
        XCTAssertNil(MCPProtocol.split(qualified: "open"))
        XCTAssertNil(MCPProtocol.split(qualified: "__search"))
        XCTAssertNil(MCPProtocol.split(qualified: "notes__"))
    }

    // MARK: tool definitions

    func testToolsKeepTheirOwnSchema() throws {
        let listed: [String: Any] = ["tools": [
            ["name": "search",
             "description": "Search the notes.",
             "inputSchema": ["type": "object",
                             "properties": ["query": ["type": "string"]],
                             "required": ["query"]]],
        ]]
        let tools = MCPProtocol.toolDefinitions(from: listed, server: "notes")
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["name"] as? String, "notes__search")
        // The server is named in the description so the model, and the person
        // reading a confirmation, know where a tool came from.
        XCTAssertEqual(tools[0]["description"] as? String, "[notes] Search the notes.")
        let schema = try XCTUnwrap(tools[0]["input_schema"] as? [String: Any])
        XCTAssertEqual(schema["required"] as? [String], ["query"])
    }

    func testToolWithNoSchemaStillGetsAValidOne() throws {
        let tools = MCPProtocol.toolDefinitions(from: ["tools": [["name": "ping"]]], server: "s")
        let schema = try XCTUnwrap(tools[0]["input_schema"] as? [String: Any])
        XCTAssertEqual(schema["type"] as? String, "object")
    }

    func testNamelessToolsAreSkipped() {
        let tools = MCPProtocol.toolDefinitions(
            from: ["tools": [["description": "no name"], ["name": ""]]], server: "s")
        XCTAssertTrue(tools.isEmpty)
    }

    func testNoToolsListIsEmptyRatherThanAnError() {
        XCTAssertTrue(MCPProtocol.toolDefinitions(from: [:], server: "s").isEmpty)
    }

    // MARK: results

    func testTextBlocksAreJoined() {
        let result: [String: Any] = ["content": [["type": "text", "text": "one"],
                                                 ["type": "text", "text": "two"]]]
        XCTAssertEqual(MCPProtocol.resultText(result), "one\ntwo")
    }

    /// A block the model cannot see is named rather than dropped, so it never
    /// answers as though nothing came back.
    func testUnreadableBlocksAreNamedNotDropped() {
        let result: [String: Any] = ["content": [["type": "image", "data": "…"]]]
        XCTAssertTrue(MCPProtocol.resultText(result).contains("image"))
    }

    func testStructuredOnlyResultIsSerialized() {
        let result: [String: Any] = ["structuredContent": ["count": 3]]
        XCTAssertTrue(MCPProtocol.resultText(result).contains("3"))
    }

    /// An empty result must not become an empty tool_result block, which the
    /// Messages API rejects.
    func testEmptyResultBecomesDone() {
        XCTAssertEqual(MCPProtocol.resultText([:]), "done")
        XCTAssertEqual(MCPProtocol.resultText(["content": []]), "done")
    }

    func testErrorFlagIsRead() {
        XCTAssertTrue(MCPProtocol.isError(["isError": true]))
        XCTAssertFalse(MCPProtocol.isError([:]))
    }

    // MARK: config

    func testConfigReadsTheDocumentedSpelling() throws {
        let json = #"{"servers":{"notes":{"command":"npx","args":["-y","server"]}}}"#
        let config = try JSONDecoder().decode(MCPConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.servers["notes"]?.command, "npx")
        XCTAssertEqual(config.servers["notes"]?.args, ["-y", "server"])
    }

    /// Other clients spell it mcpServers, and people paste those configs in.
    func testConfigAlsoReadsTheOtherSpelling() throws {
        let json = #"{"mcpServers":{"notes":{"command":"npx"}}}"#
        let config = try JSONDecoder().decode(MCPConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.servers["notes"]?.command, "npx")
    }

    /// Trust is off unless a person wrote it down. This is the line between a
    /// tool the model may run freely and one that stops for a human.
    func testTrustDefaultsToAsking() throws {
        let json = #"{"servers":{"a":{"command":"x"},"b":{"command":"y","trust":"always"}}}"#
        let config = try JSONDecoder().decode(MCPConfig.self, from: Data(json.utf8))
        XCTAssertFalse(try XCTUnwrap(config.servers["a"]).isTrusted)
        XCTAssertTrue(try XCTUnwrap(config.servers["b"]).isTrusted)
    }

    func testExampleConfigIsValid() throws {
        let config = try JSONDecoder().decode(MCPConfig.self, from: Data(MCPConfig.example.utf8))
        XCTAssertFalse(config.servers.isEmpty)
    }

    // MARK: gating

    /// The safety story for MCP: an untrusted server's tool confirms, exactly
    /// like quit and admin do.
    func testUntrustedMCPCallsConfirm() {
        let untrusted = AssistantAction.mcpCall(server: "notes", tool: "delete",
                                                arguments: "{}", trusted: false)
        XCTAssertTrue(untrusted.needsConfirmation)
        XCTAssertEqual(untrusted.confirmationSummary, "Run delete on the notes server")
    }

    func testTrustedMCPCallsRunDirectly() {
        let trusted = AssistantAction.mcpCall(server: "notes", tool: "search",
                                              arguments: "{}", trusted: true)
        XCTAssertFalse(trusted.needsConfirmation)
    }

    func testConfirmationShowsTheArguments() {
        let action = AssistantAction.mcpCall(server: "fs", tool: "write",
                                             arguments: #"{"path":"/tmp/x"}"#, trusted: false)
        XCTAssertTrue(try! XCTUnwrap(action.confirmationSummary).contains("/tmp/x"))
    }

    /// The tool_use input is carried whole, because an MCP tool's parameters
    /// are its server's own schema and a single string would lose them.
    func testToolCallCarriesTheWholeInput() {
        let encoded = ClaudeAgent.ToolCall.encode(input: ["path": "/tmp/x", "depth": 2])
        XCTAssertEqual(encoded, #"{"depth":2,"path":"\/tmp\/x"}"#)
        XCTAssertEqual(ClaudeAgent.ToolCall.encode(input: nil), "{}")
        XCTAssertEqual(ClaudeAgent.ToolCall.encode(input: [:]), "{}")
    }
}

// MARK: - Reading files

final class FilePolicyTests: XCTestCase {

    func testTextKindsAreRecognized() {
        XCTAssertEqual(FilePolicy.kind(ofPath: "/tmp/notes.md"), .text)
        XCTAssertEqual(FilePolicy.kind(ofPath: "/tmp/Main.swift"), .text)
        XCTAssertEqual(FilePolicy.kind(ofPath: "/tmp/report.PDF"), .pdf)
    }

    func testUnknownKindsNameThemselves() {
        XCTAssertEqual(FilePolicy.kind(ofPath: "/tmp/photo.heic"), .other("heic"))
        XCTAssertEqual(FilePolicy.kind(ofPath: "/tmp/binary"), .other("file"))
    }

    func testShortFilesAreNotTouched() {
        XCTAssertEqual(FilePolicy.excerpt("hello", name: "a.txt"), "hello")
    }

    /// Truncation is announced. Silently cutting a document would let the
    /// model answer confidently about a file it only half saw.
    func testTruncationSaysSo() {
        let long = String(repeating: "a", count: 100)
        let excerpt = FilePolicy.excerpt(long, name: "big.txt", limit: 10)
        XCTAssertTrue(excerpt.hasPrefix(String(repeating: "a", count: 10)))
        XCTAssertTrue(excerpt.contains("continues past this point"))
        XCTAssertTrue(excerpt.contains("100"))
    }

    func testSizesReadInWords() {
        XCTAssertEqual(FilePolicy.readableSize(512), "512 bytes")
        XCTAssertEqual(FilePolicy.readableSize(2_048), "2 KB")
        XCTAssertEqual(FilePolicy.readableSize(3_500_000), "3.5 MB")
    }

    func testDropPromptReadsAsTheUserSpeaking() {
        let prompt = FilePolicy.dropPrompt(name: "notes.md", kind: .text, byteCount: 100)
        XCTAssertTrue(prompt.hasPrefix("I dropped notes.md on you"))
    }

    /// A file that cannot be read as words says so in the prompt itself, so
    /// the model never pretends to have read it.
    func testUnreadableDropSaysWhatItIs() {
        let prompt = FilePolicy.dropPrompt(name: "photo.heic", kind: .other("heic"),
                                           byteCount: 2_400_000)
        XCTAssertTrue(prompt.contains("heic"))
        XCTAssertTrue(prompt.contains("2.4 MB"))
        XCTAssertTrue(prompt.contains("cannot show you"))
    }

    /// Reading an arbitrary path is exactly what a prompt injection would try,
    /// so the tool form stops for a human every time.
    func testReadFileAlwaysConfirms() {
        let action = AssistantAction.readFile("/Users/someone/.ssh/id_rsa")
        XCTAssertTrue(action.needsConfirmation)
        XCTAssertEqual(action.confirmationSummary, "Read the file at /Users/someone/.ssh/id_rsa")
    }

    /// The awareness verbs are read-only or reversible, so they never gate.
    /// A confirmation on every "what windows are open" would be noise.
    func testAwarenessVerbsDoNotGate() {
        let harmless: [AssistantAction] = [
            .listWindows, .listLayouts, .listWatches, .listClips,
            .placeWindows([WindowPlacement(app: "Safari", slot: .left)]),
            .watchApp(app: "Xcode", reason: ""), .recallClip("1"),
        ]
        for action in harmless {
            XCTAssertFalse(action.needsConfirmation, "\(action) should not gate")
        }
    }
}
