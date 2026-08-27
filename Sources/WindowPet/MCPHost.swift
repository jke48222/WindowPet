import Foundation
import WindowPetCore

/// Talks to MCP servers over stdio, so Rusty's abilities stop being a list
/// somebody has to recompile.
///
/// A server declared in mcp.json is spawned once, handshaken, asked for its
/// tools, and those tools join the same schema the built-in verbs use. Calls
/// go through the same confirmation gate: an MCP tool confirms every time
/// unless its server is marked `"trust": "always"` in the config, which is a
/// decision written down by a person rather than one the model can take.
/// A message from a server, carried as an Error so `Result` can hold it.
/// Everything here reports in sentences rather than codes, because every one
/// of these ends up in front of a person.
struct MCPFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

@MainActor
final class MCPHost {

    /// One running server.
    ///
    /// Unchecked Sendable with a real justification rather than a shrug: the
    /// two fields the reader thread touches, `replies` and `closed`, are only
    /// ever read or written while holding `lock`. Everything else on it stays
    /// on the main actor.
    private final class Server: @unchecked Sendable {
        let name: String
        let config: MCPServerConfig
        let process: Process
        let input: FileHandle
        let output: FileHandle
        var tools: [[String: Any]] = []
        var nextID = 1
        /// Replies arrive on a reader thread; each waiting call parks here
        /// until its id comes back.
        let lock = NSCondition()
        var replies: [Int: Result<[String: Any], MCPFailure>] = [:]
        var closed = false

        init(name: String, config: MCPServerConfig, process: Process,
             input: FileHandle, output: FileHandle) {
            self.name = name
            self.config = config
            self.process = process
            self.input = input
            self.output = output
        }
    }

    private var servers: [String: Server] = [:]
    private(set) var startupReport: [String] = []

    static var configURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("WindowPet", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("mcp.json")
    }

    /// Tool definitions for every connected server, in Anthropic's schema.
    var toolDefinitions: [[String: Any]] {
        servers.values.flatMap(\.tools)
    }

    var connectedNames: [String] { servers.keys.sorted() }

    func isTrusted(server: String) -> Bool {
        servers[server]?.config.isTrusted ?? false
    }

    /// Reads the config and starts every server in it. Failures are collected
    /// rather than thrown: one broken server entry must not stop the app or
    /// the other servers.
    func startAll() {
        stopAll()
        startupReport = []
        guard let data = try? Data(contentsOf: Self.configURL) else { return }
        guard let config = try? JSONDecoder().decode(MCPConfig.self, from: data) else {
            startupReport.append("mcp.json is not valid JSON, so no servers were started.")
            return
        }
        for (name, server) in config.servers.sorted(by: { $0.key < $1.key }) {
            switch start(name: MCPProtocol.sanitize(name), config: server) {
            case .success(let count):
                startupReport.append("\(name): \(count) \(count == 1 ? "tool" : "tools")")
            case .failure(let failure):
                startupReport.append("\(name): \(failure.message)")
            }
        }
    }

    func stopAll() {
        for server in servers.values {
            server.lock.lock()
            server.closed = true
            server.lock.broadcast()
            server.lock.unlock()
            server.process.terminate()
        }
        servers = [:]
    }

    private func start(name: String, config: MCPServerConfig) -> Result<Int, MCPFailure> {
        let process = Process()
        // A bare command name needs a PATH; a GUI app inherits almost none, so
        // the usual install locations are added explicitly.
        var environment = ProcessInfo.processInfo.environment
        let path = environment["PATH"] ?? ""
        environment["PATH"] = ([path] + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"])
            .filter { !$0.isEmpty }.joined(separator: ":")
        config.env?.forEach { environment[$0.key] = $0.value }
        process.environment = environment
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Through sh so a command on the PATH resolves the way it does in a
        // terminal, which is where these config lines are copied from.
        let quoted = ([config.command] + config.args)
            .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
        process.arguments = ["-c", quoted]

        let toServer = Pipe(), fromServer = Pipe()
        process.standardInput = toServer
        process.standardOutput = fromServer
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .failure(MCPFailure("could not start (\(error.localizedDescription))"))
        }
        let server = Server(name: name, config: config, process: process,
                            input: toServer.fileHandleForWriting,
                            output: fromServer.fileHandleForReading)
        servers[name] = server
        readLines(from: server)

        guard case .success(let initResult) = call(server: server, method: "initialize",
                                                   params: MCPProtocol.initializeParams,
                                                   timeout: 12) else {
            servers[name] = nil
            process.terminate()
            return .failure(MCPFailure("did not answer the handshake"))
        }
        _ = initResult
        if let notification = MCPProtocol.encodeNotification(method: "notifications/initialized",
                                                             params: [:]) {
            try? server.input.write(contentsOf: notification)
        }
        guard case .success(let listed) = call(server: server, method: "tools/list",
                                               params: [:], timeout: 12) else {
            servers[name] = nil
            process.terminate()
            return .failure(MCPFailure("did not list any tools"))
        }
        server.tools = MCPProtocol.toolDefinitions(from: listed, server: name)
        return .success(server.tools.count)
    }

    /// Runs one tool. `arguments` is the JSON object the model produced.
    func callTool(server serverName: String, tool: String,
                  arguments: [String: Any]) -> (result: String, ok: Bool) {
        guard let server = servers[serverName] else {
            return ("The \(serverName) server is not connected.", false)
        }
        let params = MCPProtocol.callParams(tool: tool, arguments: arguments)
        switch call(server: server, method: "tools/call", params: params, timeout: 60) {
        case .failure(let failure):
            return ("\(serverName) could not run \(tool): \(failure.message)", false)
        case .success(let result):
            return (MCPProtocol.resultText(result), !MCPProtocol.isError(result))
        }
    }

    // MARK: - JSON-RPC plumbing

    private func call(server: Server, method: String, params: [String: Any],
                      timeout: TimeInterval) -> Result<[String: Any], MCPFailure> {
        let id = server.nextID
        server.nextID += 1
        guard let payload = MCPProtocol.encode(id: id, method: method, params: params) else {
            return .failure(MCPFailure("could not encode the request"))
        }
        do {
            try server.input.write(contentsOf: payload)
        } catch {
            return .failure(MCPFailure("the server stopped listening"))
        }
        let deadline = Date().addingTimeInterval(timeout)
        server.lock.lock()
        defer { server.lock.unlock() }
        while server.replies[id] == nil && !server.closed {
            if !server.lock.wait(until: deadline) { break }
        }
        guard let reply = server.replies.removeValue(forKey: id) else {
            return .failure(MCPFailure(server.closed ? "the server exited" : "the server did not reply in time"))
        }
        return reply
    }

    /// One reader thread per server, parking on the pipe. Blocking reads are
    /// exactly right here and must not happen on the main actor, which is why
    /// this is a thread rather than a readabilityHandler.
    private func readLines(from server: Server) {
        let handle = server.output
        Thread.detachNewThread {
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard let line = String(data: lineData, encoding: .utf8) else { continue }
                    switch MCPProtocol.decode(line: line) {
                    case .result(let id, let payload):
                        server.lock.lock()
                        server.replies[id] = .success(payload)
                        server.lock.broadcast()
                        server.lock.unlock()
                    case .failure(let id, let message):
                        server.lock.lock()
                        server.replies[id] = .failure(MCPFailure(message))
                        server.lock.broadcast()
                        server.lock.unlock()
                    case .other:
                        continue
                    }
                }
            }
            server.lock.lock()
            server.closed = true
            server.lock.broadcast()
            server.lock.unlock()
        }
    }
}
