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

    /// Anthropic tool names must match ^[a-zA-Z0-9_-]{1,64}$. A request
    /// carrying one longer or with any other character fails outright, taking
    /// every built-in tool down with it.
    public static let maxToolNameLength = 64
    /// Room kept for the server half of a qualified name, so a long server
    /// name cannot crowd its tools out.
    static let maxServerPartLength = 20

    /// The model-facing name for one server's tool: `server__tool`, ASCII
    /// only and at most 64 characters. When sanitizing or shortening changed
    /// the tool's name, a short hash of the original is appended, so
    /// `files.read` and `files_read` on one server never collide.
    ///
    /// This name is for the model only. The server must be called with the
    /// tool's original name, which `MCPToolIndex` keeps.
    public static func qualifiedName(server: String, tool: String) -> String {
        var serverPart = sanitize(server)
        if serverPart.count > maxServerPartLength {
            serverPart = String(serverPart.prefix(maxServerPartLength - 7)) + "_" + shortHash(server)
        }
        let budget = maxToolNameLength - serverPart.count - separator.count
        var toolPart = sanitize(tool)
        if toolPart != tool || toolPart.count > budget {
            toolPart = String(toolPart.prefix(budget - 7)) + "_" + shortHash(tool)
        }
        return "\(serverPart)\(separator)\(toolPart)"
    }

    /// Splits a qualified name at the first separator. The halves are the
    /// sanitized, model-facing forms; use `MCPToolIndex.resolve` to get the
    /// original tool name a server actually declared.
    public static func split(qualified: String) -> (server: String, tool: String)? {
        guard let range = qualified.range(of: separator) else { return nil }
        let server = String(qualified[qualified.startIndex..<range.lowerBound])
        let tool = String(qualified[range.upperBound...])
        guard !server.isEmpty, !tool.isEmpty else { return nil }
        return (server, tool)
    }

    /// Anthropic tool names allow ASCII letters, digits, underscore and
    /// hyphen. A server that names a tool something else must not break the
    /// whole request, so the name is coerced rather than rejected. Accented
    /// and other non-ASCII letters are coerced too: `isLetter` alone would
    /// let them through and the API would reject the request.
    public static func sanitize(_ name: String) -> String {
        let mapped = name.unicodeScalars.map { scalar -> Character in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", "-", "_": return Character(scalar)
            default: return "_"
            }
        }
        return mapped.isEmpty ? "_" : String(mapped)
    }

    /// Six hex digits of FNV-1a over the UTF-8 bytes. Stable across launches,
    /// unlike Swift's seeded Hasher, so a tool keeps its name between runs.
    static func shortHash(_ text: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        let hex = String(hash & 0xFF_FFFF, radix: 16)
        return String(repeating: "0", count: 6 - hex.count) + hex
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
        // A message with a method is the server talking first: a request of
        // its own (ping may come from either side at any time) or a
        // notification. Neither is a reply, even when its id happens to match
        // one of ours; taking it for one would hand the waiting call an empty
        // result and drop the real reply. `serverRequestReply` answers these.
        if root["method"] != nil { return .other }
        // Servers are free to log to stdout; anything without an id is not a
        // reply to us and is ignored rather than treated as a failure.
        guard let id = root["id"] as? Int else { return .other }
        if let error = root["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "the server reported an error"
            return .failure(id: id, message: message)
        }
        return .result(id: id, payload: root["result"] as? [String: Any] ?? [:])
    }

    /// JSON-RPC's "method not found" code.
    public static let methodNotFound = -32601

    /// The line to write back when `line` is a request the server sent us,
    /// or nil when it is anything else (a reply, a notification, a log line).
    ///
    /// A server that sends a request waits for the answer, so leaving one
    /// unanswered can stall it. `ping` gets the empty result the spec asks
    /// for; anything else gets a method-not-found error, since this client
    /// declares no capabilities (no sampling, roots or elicitation). The id
    /// is echoed exactly as sent, string or number.
    public static func serverRequestReply(line: String) -> Data? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let method = root["method"] as? String,
              let id = root["id"], id is String || id is NSNumber
        else { return nil }
        var payload: [String: Any] = ["jsonrpc": "2.0", "id": id]
        if method == "ping" {
            payload["result"] = [String: Any]()
        } else {
            payload["error"] = ["code": methodNotFound,
                                "message": "WindowPet does not handle \(method)"]
        }
        guard var reply = try? JSONSerialization.data(withJSONObject: payload,
                                                      options: [.sortedKeys])
        else { return nil }
        reply.append(0x0A)
        return reply
    }

    // MARK: - Tools

    /// Turns a tools/list result into Anthropic tool definitions. Each keeps
    /// the server's own JSON Schema, so the model sees the real parameters
    /// rather than a lowest common denominator.
    public static func toolDefinitions(from result: [String: Any], server: String)
        -> [[String: Any]] {
        catalog(from: result, server: server).definitions
    }

    /// The definitions plus the index from each model-facing name back to the
    /// server and the tool's original name. Names already in `taken` (other
    /// servers' tools) are never reused.
    public static func catalog(from result: [String: Any], server: String,
                               taken: Set<String> = []) -> MCPCatalog {
        guard let tools = result["tools"] as? [[String: Any]] else {
            return MCPCatalog(definitions: [], index: MCPToolIndex())
        }
        var used = taken
        var definitions: [[String: Any]] = []
        var index = MCPToolIndex()
        for tool in tools {
            guard let name = tool["name"] as? String, !name.isEmpty else { continue }
            var qualified = qualifiedName(server: server, tool: name)
            var attempt = 1
            while used.contains(qualified) {
                // Two declared names that sanitize and hash alike: keep both,
                // told apart by a counter, rather than letting one shadow the
                // other.
                attempt += 1
                qualified = qualifiedName(server: server, tool: "\(name)#\(attempt)")
            }
            used.insert(qualified)
            index.register(qualified: qualified, server: server, tool: name)
            let schema = tool["inputSchema"] as? [String: Any]
                ?? ["type": "object", "properties": [String: Any]()]
            let described = tool["description"] as? String ?? "A tool provided by \(server)."
            definitions.append([
                "name": qualified,
                "description": "[\(server)] \(described)",
                "input_schema": schema,
            ])
        }
        return MCPCatalog(definitions: definitions, index: index)
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

/// What one server's tools/list turns into: the definitions the model sees,
/// and the index that maps each back to what the server declared.
public struct MCPCatalog {
    public let definitions: [[String: Any]]
    public let index: MCPToolIndex
}

/// Model-facing tool name to (server, original tool name). The host keeps one
/// of these and resolves every tool_use through it, instead of re-splitting
/// the sanitized name, so a server is always called with the name it
/// declared (`files.read`, not `files_read`).
public struct MCPToolIndex: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let server: String
        public let tool: String
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public mutating func register(qualified: String, server: String, tool: String) {
        entries[qualified] = Entry(server: server, tool: tool)
    }

    /// Folds another server's index in. Catalogs built with `taken` never
    /// share a name, so nothing is overwritten.
    public mutating func merge(_ other: MCPToolIndex) {
        entries.merge(other.entries) { current, _ in current }
    }

    /// Drops every tool of one server, for when it disconnects.
    public mutating func remove(server: String) {
        entries = entries.filter { $0.value.server != server }
    }

    public func resolve(_ qualified: String) -> Entry? { entries[qualified] }

    public var names: Set<String> { Set(entries.keys) }
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

    /// The sample written by "Edit Tool Servers". It starts nothing:
    /// `servers` is empty and the sample lives under `_example`, which the
    /// decoder does not read, so opening the file never runs `npx`.
    public static let example = """
    {
      "servers": {},
      "_example": {
        "notes": {
          "command": "npx",
          "args": ["-y", "@modelcontextprotocol/server-filesystem", "/Users/you/Documents"],
          "trust": "ask"
        }
      },
      "_howto": "Nothing here runs until it is inside servers. Move an entry from _example into servers, point it at a real folder, save, then choose Reconnect Tool Servers."
    }
    """

    /// Earlier builds wrote the sample as a live server. A config whose only
    /// server is still `npx` pointed at the placeholder folder was never
    /// edited, so it can be swapped for the inert sample before anything
    /// starts.
    public static func isUntouchedLegacyExample(_ data: Data) -> Bool {
        guard let config = try? JSONDecoder().decode(MCPConfig.self, from: data),
              config.servers.count == 1,
              let only = config.servers.values.first else { return false }
        return only.command == "npx" && only.args.contains("/Users/you/Documents")
    }
}
