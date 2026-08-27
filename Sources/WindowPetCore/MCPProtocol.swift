import Foundation

/// Model Context Protocol, client side: the JSON-RPC 2.0 framing and the three
/// calls that matter (initialize, tools/list, tools/call).
///
/// This is the lever that stops Rusty's abilities being a list somebody has to
/// recompile. A server declared in mcp.json shows up as tools in the same
/// schema the built-in verbs use, and its calls pass the same confirmation
/// gate. Pure encode and decode; the process and its pipes live app-side.
public enum MCPProtocol {

    public static let version = "2025-06-18"

    /// Servers are addressed as `server.tool` so two servers can both offer a
    /// "search" without colliding, and so a tool name always says where it
    /// came from when it appears in a confirmation.
    public static let separator = "__"

    public static func qualifiedName(server: String, tool: String) -> String {
        "\(sanitize(server))\(separator)\(sanitize(tool))"
    }

    public static func split(qualified: String) -> (server: String, tool: String)? {
        guard let range = qualified.range(of: separator) else { return nil }
        let server = String(qualified[qualified.startIndex..<range.lowerBound])
        let tool = String(qualified[range.upperBound...])
        guard !server.isEmpty, !tool.isEmpty else { return nil }
        return (server, tool)
    }

    /// Anthropic tool names allow letters, digits, underscore and hyphen. A
    /// server that names a tool something else must not break the whole
    /// request, so the name is coerced rather than rejected.
    public static func sanitize(_ name: String) -> String {
        let mapped = name.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" ? character : "_"
        }
        return String(mapped)
    }

    // MARK: - Requests

    /// One line of newline-delimited JSON-RPC, which is how stdio servers
    /// frame messages.
    public static func encode(id: Int, method: String, params: [String: Any]?) -> Data? {
        var payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { payload["params"] = params }
        guard var data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        data.append(0x0A)
        return data
    }

    /// A notification carries no id and expects no reply.
    public static func encodeNotification(method: String, params: [String: Any]?) -> Data? {
        var payload: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { payload["params"] = params }
        guard var data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        data.append(0x0A)
        return data
    }

    public static var initializeParams: [String: Any] {
        [
            "protocolVersion": version,
            "capabilities": [:],
            "clientInfo": ["name": "WindowPet", "version": "1.1.0"],
        ]
    }

    public static func callParams(tool: String, arguments: [String: Any]) -> [String: Any] {
        ["name": tool, "arguments": arguments]
    }

    // MARK: - Responses

    public enum Response: Equatable {
        case result(id: Int, payload: [String: Any])
        case failure(id: Int, message: String)
        /// A notification or log line from the server, which is not a reply.
        case other

        public static func == (a: Response, b: Response) -> Bool {
            switch (a, b) {
            case (.other, .other): return true
            case (.result(let ida, _), .result(let idb, _)): return ida == idb
            case (.failure(let ida, let ma), .failure(let idb, let mb)):
                return ida == idb && ma == mb
            default: return false
            }
        }
    }

    public static func decode(line: String) -> Response {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return .other }
        // Servers are free to log to stdout; anything without an id is not a
        // reply to us and is ignored rather than treated as a failure.
        guard let id = root["id"] as? Int else { return .other }
        if let error = root["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "the server reported an error"
            return .failure(id: id, message: message)
        }
        return .result(id: id, payload: root["result"] as? [String: Any] ?? [:])
    }

    // MARK: - Tools

    /// Turns a tools/list result into Anthropic tool definitions. Each keeps
    /// the server's own JSON Schema, so the model sees the real parameters
    /// rather than a lowest common denominator.
    public static func toolDefinitions(from result: [String: Any], server: String)
        -> [[String: Any]] {
        guard let tools = result["tools"] as? [[String: Any]] else { return [] }
        return tools.compactMap { tool in
            guard let name = tool["name"] as? String, !name.isEmpty else { return nil }
            let schema = tool["inputSchema"] as? [String: Any]
                ?? ["type": "object", "properties": [String: Any]()]
            let described = tool["description"] as? String ?? "A tool provided by \(server)."
            return [
                "name": qualifiedName(server: server, tool: name),
                "description": "[\(server)] \(described)",
                "input_schema": schema,
            ]
        }
    }

    /// Flattens a tools/call result into the text a tool_result carries.
    /// Image and resource blocks are named rather than dropped, so the model
    /// knows something came back that it cannot see.
    public static func resultText(_ result: [String: Any]) -> String {
        guard let content = result["content"] as? [[String: Any]] else {
            // Some servers answer with structured content and no blocks.
            if let structured = result["structuredContent"],
               let data = try? JSONSerialization.data(withJSONObject: structured),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
            return "done"
        }
        let parts = content.compactMap { block -> String? in
            switch block["type"] as? String {
            case "text": return block["text"] as? String
            case "image": return "[an image the tool returned, which I cannot see]"
            case "resource": return "[a resource the tool returned]"
            default: return nil
            }
        }
        let joined = parts.joined(separator: "\n")
        return joined.isEmpty ? "done" : joined
    }

    /// True when the server flagged the call as failed. The loop reports this
    /// as a tool error so the model can adapt instead of assuming success.
    public static func isError(_ result: [String: Any]) -> Bool {
        result["isError"] as? Bool == true
    }
}

/// One server as declared in mcp.json.
public struct MCPServerConfig: Codable, Equatable, Sendable {
    public let command: String
    public let args: [String]
    public let env: [String: String]?
    /// "ask" (the default) confirms every call. "always" trusts the server,
    /// which is a choice a person makes deliberately in the config file.
    public let trust: String?

    public init(command: String, args: [String] = [], env: [String: String]? = nil,
                trust: String? = nil) {
        self.command = command
        self.args = args
        self.env = env
        self.trust = trust
    }

    /// Hand-written config, so everything except the command is optional. The
    /// synthesized decoder would reject `{"command": "npx"}` for a missing
    /// `args`, and the whole file would fail over one omitted line.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try container.decode(String.self, forKey: .command)
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        env = try container.decodeIfPresent([String: String].self, forKey: .env)
        trust = try container.decodeIfPresent(String.self, forKey: .trust)
    }

    public var isTrusted: Bool { trust?.lowercased() == "always" }
}

public struct MCPConfig: Codable, Equatable, Sendable {
    public let servers: [String: MCPServerConfig]

    public init(servers: [String: MCPServerConfig]) {
        self.servers = servers
    }

    /// Both spellings are in the wild: this file uses `servers`, while several
    /// other clients use `mcpServers`. Accepting either saves people copying a
    /// config in and finding nothing happened.
    enum CodingKeys: String, CodingKey {
        case servers
        case mcpServers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let direct = try container.decodeIfPresent([String: MCPServerConfig].self, forKey: .servers) {
            servers = direct
        } else {
            servers = try container.decodeIfPresent([String: MCPServerConfig].self,
                                                    forKey: .mcpServers) ?? [:]
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(servers, forKey: .servers)
    }

    public static let example = """
    {
      "servers": {
        "notes": {
          "command": "npx",
          "args": ["-y", "@modelcontextprotocol/server-filesystem", "/Users/you/Documents"],
          "trust": "ask"
        }
      }
    }
    """
}
