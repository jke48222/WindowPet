import Foundation

/// Rebuilds a Messages API turn from a server-sent event stream, so answers
/// can appear word by word instead of arriving all at once.
///
/// Pure and incremental: feed it SSE lines, read text deltas as they land,
/// and take the finished Turn at the end. It reconstructs the assistant's
/// content blocks faithfully (thinking signatures included) because the
/// agentic loop echoes that content back verbatim on the next request.
public final class StreamAccumulator {

    /// Fires for each chunk of visible answer text as it arrives.
    public var onTextDelta: ((String) -> Void)?
    /// Fires when a line carries token usage, so a caller does not have to
    /// re-parse every line to meter cost.
    public var onUsage: ((_ input: Int, _ cached: Int, _ output: Int) -> Void)?

    private struct Block {
        var type: String
        var text: String = ""          // text / thinking body
        var signature: String = ""     // thinking signature
        var id: String = ""            // tool_use
        var name: String = ""          // tool_use
        var partialJSON: String = ""   // tool_use input, streamed as JSON text
        /// The block exactly as the server opened it. Server-side tool blocks
        /// (web search and fetch) are echoed back from this verbatim, since
        /// anything dropped would corrupt the replayed conversation.
        var original: [String: Any] = [:]
    }

    private var blocks: [Int: Block] = [:]
    private var stopReason: String?
    private var errorMessage: String?
    private var sawRefusal = false

    public init() {}

    /// Decodes one `data:` line into an event object. Keep-alives, comments,
    /// and `[DONE]` return nil. Shared by consume and the usage reader.
    static func event(from line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, payload != "[DONE]",
              let data = payload.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Feeds one raw line from the stream. Non-data lines are ignored, so
    /// callers can hand over every line without filtering.
    public func consume(line: String) {
        guard let event = Self.event(from: line),
              let type = event["type"] as? String else { return }
        if let usage = Self.usage(in: event) {
            onUsage?(usage.input, usage.cached, usage.output)
        }

        switch type {
        case "error":
            errorMessage = ((event["error"] as? [String: Any])?["message"] as? String)
                ?? "stream error"

        case "content_block_start":
            guard let index = event["index"] as? Int,
                  let block = event["content_block"] as? [String: Any],
                  let blockType = block["type"] as? String else { return }
            var new = Block(type: blockType)
            new.id = block["id"] as? String ?? ""
            new.name = block["name"] as? String ?? ""
            new.text = block["text"] as? String ?? ""
            new.original = block
            blocks[index] = new

        case "content_block_delta":
            guard let index = event["index"] as? Int,
                  let delta = event["delta"] as? [String: Any],
                  let deltaType = delta["type"] as? String,
                  var block = blocks[index] else { return }
            switch deltaType {
            case "text_delta":
                let chunk = delta["text"] as? String ?? ""
                block.text += chunk
                if !chunk.isEmpty { onTextDelta?(chunk) }
            case "thinking_delta":
                block.text += delta["thinking"] as? String ?? ""
            case "signature_delta":
                // Must survive verbatim: the API validates it on replay.
                block.signature += delta["signature"] as? String ?? ""
            case "input_json_delta":
                block.partialJSON += delta["partial_json"] as? String ?? ""
            default:
                break
            }
            blocks[index] = block

        case "message_delta":
            if let delta = event["delta"] as? [String: Any],
               let reason = delta["stop_reason"] as? String {
                stopReason = reason
                if reason == "refusal" { sawRefusal = true }
            }

        default:
            break
        }
    }

    /// Convenience for feeding a whole buffered body at once.
    public func consume(chunk: String) {
        chunk.split(separator: "\n", omittingEmptySubsequences: false)
            .forEach { consume(line: String($0)) }
    }

    /// Token counts carried by a decoded event, if any. Usage rides on
    /// `message_start` (input side, including cache reads) and `message_delta`
    /// (output side), so both are handled here.
    static func usage(in event: [String: Any]) -> (input: Int, cached: Int, output: Int)? {
        var usage = event["usage"] as? [String: Any]
        if usage == nil, let message = event["message"] as? [String: Any] {
            usage = message["usage"] as? [String: Any]
        }
        guard let usage else { return nil }
        return (input: usage["input_tokens"] as? Int ?? 0,
                cached: usage["cache_read_input_tokens"] as? Int ?? 0,
                output: usage["output_tokens"] as? Int ?? 0)
    }

    /// Line convenience, for callers reading a raw SSE line.
    public static func usage(inLine line: String) -> (input: Int, cached: Int, output: Int)? {
        event(from: line).flatMap(usage(in:))
    }

    public func finish() -> ClaudeAgent.TurnResult {
        if let errorMessage { return .failed(errorMessage) }
        if sawRefusal { return .refused }
        guard !blocks.isEmpty else { return .failed("empty stream") }

        var rawContent: [[String: Any]] = []
        var text = ""
        var calls: [ClaudeAgent.ToolCall] = []

        for index in blocks.keys.sorted() {
            guard let block = blocks[index] else { continue }
            switch block.type {
            case "text":
                text += block.text
                rawContent.append(["type": "text", "text": block.text])
            case "thinking":
                var thinking: [String: Any] = ["type": "thinking", "thinking": block.text]
                if !block.signature.isEmpty { thinking["signature"] = block.signature }
                rawContent.append(thinking)
            case "tool_use", "server_tool_use":
                let input: [String: Any]
                if let data = block.partialJSON.data(using: .utf8),
                   let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    input = parsed
                } else {
                    input = [:]  // empty-argument tools stream no JSON at all
                }
                var rebuilt = block.original
                rebuilt["input"] = input
                rawContent.append(rebuilt)
                // Only client tools become calls to execute. Server tools
                // (web search and fetch) already ran on Anthropic's side and
                // must never get a tool_result from us.
                if block.type == "tool_use" {
                    calls.append(ClaudeAgent.ToolCall(
                        id: block.id, name: block.name,
                        argument: (input["argument"] as? String) ?? "",
                        rawArguments: ClaudeAgent.ToolCall.encode(input: input)))
                }
            default:
                // Server tool results and anything else unrecognized are
                // echoed exactly as received so replay stays valid.
                rawContent.append(block.original.isEmpty ? ["type": block.type] : block.original)
            }
        }

        return ClaudeAgent.resolveTurn(text: text, calls: calls,
                                       rawContent: rawContent, stopReason: stopReason ?? "")
    }
}
