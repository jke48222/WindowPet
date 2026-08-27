import XCTest
@testable import WindowPetCore

final class StreamAccumulatorTests: XCTestCase {

    /// Builds an SSE body the way the API sends one.
    private func sse(_ events: [String]) -> String {
        events.map { "event: x\ndata: \($0)\n" }.joined(separator: "\n")
    }

    func testStreamsTextDeltasInOrder() {
        let acc = StreamAccumulator()
        var chunks: [String] = []
        acc.onTextDelta = { chunks.append($0) }
        acc.consume(chunk: sse([
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Safari "}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"is open."}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
        ]))
        XCTAssertEqual(chunks, ["Safari ", "is open."])
        guard case .turn(let turn) = acc.finish() else { return XCTFail("expected turn") }
        XCTAssertEqual(turn.text, "Safari is open.")
        XCTAssertEqual(turn.stopReason, "end_turn")
        XCTAssertTrue(turn.calls.isEmpty)
    }

    func testReassemblesToolCallFromPartialJSON() {
        // Tool input arrives as JSON text split across deltas.
        let acc = StreamAccumulator()
        acc.consume(chunk: sse([
            #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_9","name":"open","input":{}}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"argu"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"ment\": \"Safari\"}"}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
        ]))
        guard case .turn(let turn) = acc.finish() else { return XCTFail("expected turn") }
        XCTAssertEqual(turn.calls, [.init(id: "toolu_9", name: "open", argument: "Safari",
                                          rawArguments: #"{"argument":"Safari"}"#)])
        XCTAssertEqual(turn.stopReason, "tool_use")
        // The echoed block must carry the parsed input, not the raw fragments.
        let toolBlock = turn.rawContent.first { $0["type"] as? String == "tool_use" }
        XCTAssertEqual((toolBlock?["input"] as? [String: Any])?["argument"] as? String, "Safari")
    }

    func testPreservesThinkingSignatureForReplay() {
        // The API validates this signature when the turn is echoed back, so
        // losing it would break the very next request in the loop.
        let acc = StreamAccumulator()
        acc.consume(chunk: sse([
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc123"}}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Done."}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
        ]))
        guard case .turn(let turn) = acc.finish() else { return XCTFail("expected turn") }
        let thinking = turn.rawContent.first { $0["type"] as? String == "thinking" }
        XCTAssertEqual(thinking?["signature"] as? String, "abc123")
        XCTAssertEqual(thinking?["thinking"] as? String, "hmm")
        // Thinking text is never part of the visible answer.
        XCTAssertEqual(turn.text, "Done.")
    }

    func testBlockOrderIsPreserved() {
        let acc = StreamAccumulator()
        acc.consume(chunk: sse([
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"one "}}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"two"}}"#,
        ]))
        guard case .turn(let turn) = acc.finish() else { return XCTFail("expected turn") }
        XCTAssertEqual(turn.text, "one two")
        XCTAssertEqual(turn.rawContent.count, 2)
    }

    func testRefusalAndErrorSurfaces() {
        let refused = StreamAccumulator()
        refused.consume(chunk: sse([
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"refusal"}}"#,
        ]))
        XCTAssertEqual(refused.finish(), .refused)

        let errored = StreamAccumulator()
        errored.consume(chunk: sse([
            #"{"type":"error","error":{"type":"overloaded_error","message":"busy"}}"#,
        ]))
        XCTAssertEqual(errored.finish(), .failed("busy"))
    }

    func testIgnoresNonDataLinesAndDoneMarker() {
        let acc = StreamAccumulator()
        acc.consume(line: "event: content_block_delta")
        acc.consume(line: "")
        acc.consume(line: ": keep-alive comment")
        acc.consume(line: "data: [DONE]")
        XCTAssertEqual(acc.finish(), .failed("empty stream"))
    }

    func testToolWithNoArgumentStreamsNoJSON() {
        // "mute" takes nothing, so no input_json_delta ever arrives.
        let acc = StreamAccumulator()
        acc.consume(chunk: sse([
            #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t1","name":"mute","input":{}}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
        ]))
        guard case .turn(let turn) = acc.finish() else { return XCTFail("expected turn") }
        XCTAssertEqual(turn.calls, [.init(id: "t1", name: "mute", argument: "")])
    }

    func testTruncationIsReported() {
        let acc = StreamAccumulator()
        acc.consume(chunk: sse([
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#,
        ]))
        XCTAssertEqual(acc.finish(), .failed("answer ran long, try again"))
    }

    /// Shapes captured from a real streamed response, including the pieces
    /// that are easy to guess wrong: `ping` keep-alives, the `caller` field
    /// on a tool block, and usage split across message_start/message_delta.
    func testRealWireShapeFromLiveCapture() {
        let acc = StreamAccumulator()
        let lines = [
            #"data: {"type":"message_start","message":{"type":"message","usage":{"input_tokens":417,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}"#,
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_01PdqtYqg9G7Rd5NgPaj3uuU","name":"open","input":{},"caller":{"type":"direct"}}}"#,
            #"data: {"type":"ping"}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"argum"}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"ent\":\"Safari\"}"}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":48}}"#,
            #"data: {"type":"message_stop"}"#,
        ]
        lines.forEach { acc.consume(line: $0) }

        guard case .turn(let turn) = acc.finish() else { return XCTFail("expected turn") }
        XCTAssertEqual(turn.calls,
                       [.init(id: "toolu_01PdqtYqg9G7Rd5NgPaj3uuU", name: "open", argument: "Safari",
                              rawArguments: #"{"argument":"Safari"}"#)])
        XCTAssertEqual(turn.stopReason, "tool_use")

        // Usage is summed from both ends of the stream.
        let counted = lines.compactMap { StreamAccumulator.usage(inLine: $0) }
        XCTAssertEqual(counted.reduce(0) { $0 + $1.input }, 417)
        XCTAssertEqual(counted.reduce(0) { $0 + $1.output }, 49)
    }

    func testUsageIgnoresUnrelatedLines() {
        XCTAssertNil(StreamAccumulator.usage(inLine: "event: ping"))
        XCTAssertNil(StreamAccumulator.usage(inLine: #"data: {"type":"ping"}"#))
        XCTAssertNil(StreamAccumulator.usage(inLine: "not a stream line"))
    }

    func testStreamedTurnEchoesBackIdenticallyToNonStreamed() {
        // A streamed turn and a buffered one must produce the same shape, or
        // the loop would behave differently depending on transport.
        let acc = StreamAccumulator()
        acc.consume(chunk: sse([
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"On it."}}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"open","input":{}}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"argument\":\"Safari\"}"}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
        ]))
        guard case .turn(let streamed) = acc.finish() else { return XCTFail("expected turn") }

        let buffered = ClaudeAgent.parseTurn(Data(#"""
        {"type":"message","stop_reason":"tool_use","content":[
          {"type":"text","text":"On it."},
          {"type":"tool_use","id":"toolu_1","name":"open","input":{"argument":"Safari"}}]}
        """#.utf8))
        guard case .turn(let direct) = buffered else { return XCTFail("expected turn") }

        XCTAssertEqual(streamed.text, direct.text)
        XCTAssertEqual(streamed.calls, direct.calls)
        XCTAssertEqual(streamed.stopReason, direct.stopReason)
        XCTAssertEqual(streamed.rawContent.count, direct.rawContent.count)
    }
}
