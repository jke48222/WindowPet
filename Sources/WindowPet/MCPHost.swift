import AppKit
import CryptoKit
import Darwin
import Foundation
import LocalAuthentication
import Security
import WindowPetCore

/// Talks to MCP servers over stdio, so Rusty's abilities stop being a list
/// somebody has to recompile.
///
/// A server declared in mcp.json is spawned, handshaken, asked for its tools,
/// and those tools join the same schema the built-in verbs use. Calls go
/// through the same confirmation gate: an MCP tool confirms every time unless
/// its server is marked `"trust": "always"` in the config, which is a decision
/// written down by a person rather than one the model can take.
///
/// Three rules keep a config file from becoming a way in:
/// - An entry runs only after a person has approved that exact command line,
///   arguments, environment and trust level (fingerprints in the Keychain).
///   A new or edited entry is skipped until it is approved again.
/// - A server is spawned as its own responsible process, so it does not
///   inherit WindowPet's Accessibility, Microphone, Screen Recording or
///   Automation grants; macOS asks for them on its own behalf.
/// - A server gets a minimal environment (PATH, HOME, locale) plus what its
///   entry lists, never the app's own API keys.
///
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
    /// ever read or written while holding `lock`. It also enqueues replies to
    /// server requests on `writer`, an immutable serial queue, which is safe
    /// from any thread. Everything else on it stays on the main actor.
    private final class Server: @unchecked Sendable {
        let name: String
        let config: MCPServerConfig
        let process: ChildProcess
        var tools: [[String: Any]] = []
        var nextID = 1
        /// Replies arrive on a reader thread; each waiting call parks here
        /// until its id comes back.
        let lock = NSCondition()
        var replies: [Int: Result<[String: Any], MCPFailure>] = [:]
        var closed = false
        /// Requests are written here, in order, off the main actor: a
        /// server that stops reading its stdin fills the pipe, and a
        /// blocking write would freeze the pet with it.
        let writer: DispatchQueue

        init(name: String, config: MCPServerConfig, process: ChildProcess) {
            self.name = name
            self.config = config
            self.process = process
            writer = DispatchQueue(label: "WindowPet.mcp.writer.\(name)")
        }

        var isClosed: Bool {
            lock.lock()
            defer { lock.unlock() }
            return closed
        }
    }

    /// Servers that finished the handshake. Only these are offered to the
    /// model or routed to.
    private var servers: [String: Server] = [:]
    /// Spawned, still handshaking.
    private var starting: [String: Server] = [:]
    /// Bumped by every start and stop, so a handshake that finishes after a
    /// reconnect cannot resurrect a server from the previous generation.
    private var generation = 0
    private(set) var startupReport: [String] = []
    /// True while handshakes from the last `startAll` are still running.
    private(set) var isStarting = false

    /// The set of connected servers or their tools changed: a handshake
    /// finished or a server exited. `ClaudeAgent.mcpTools` is already
    /// refreshed when this fires; it is for the menu title.
    var onChange: (() -> Void)?
    /// Every handshake from the last `startAll` has finished. Carries the
    /// final report, one line per server.
    var onStartupFinished: (([String]) -> Void)?

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

    /// Model-facing tool name to (server, the tool name it declared). Every
    /// tool_use resolves through this rather than re-splitting the sanitized
    /// name, so a server is called with `files.read`, not `files_read`.
    private(set) var toolIndex = MCPToolIndex()

    func resolve(qualified: String) -> MCPToolIndex.Entry? {
        guard let entry = toolIndex.resolve(qualified), servers[entry.server] != nil else { return nil }
        return entry
    }

    func isTrusted(server: String) -> Bool {
        servers[server]?.config.isTrusted ?? false
    }

    /// Reads the config and starts every approved server in it, without
    /// blocking: servers are spawned here and their handshakes finish in the
    /// background, each one's tools joining `ClaudeAgent.mcpTools` as it
    /// answers. `onStartupFinished` fires with the report once all are done.
    ///
    /// `askForApproval` shows the approval dialog for a new or changed entry.
    /// Pass it only when a person is there to answer (the pet at launch, the
    /// Reconnect menu item), never from a headless mode; without it such an
    /// entry is skipped and named in the report.
    func startAll(askForApproval: Bool = false) {
        guard let launch = launchServers(askForApproval: askForApproval) else {
            onStartupFinished?(startupReport)
            return
        }
        Task { @MainActor in
            let report = await self.finishHandshakes(launch)
            if launch.generation == self.generation { self.onStartupFinished?(report) }
        }
    }

    /// The same, for callers that must have the tool list before going on
    /// (a headless `--ask` run). Returns the report.
    @discardableResult
    func startAllAndWait(askForApproval: Bool = false) async -> [String] {
        guard let launch = launchServers(askForApproval: askForApproval) else { return startupReport }
        return await finishHandshakes(launch)
    }

    private struct Launch {
        let generation: Int
        let order: [String]
        var lines: [String: String]
        let spawned: [(display: String, server: Server)]
    }

    /// The synchronous half: stop what is running, read the config, check
    /// approvals and spawn. `startupReport` says "starting" for each spawned
    /// server as soon as this returns. Nil when nothing was spawned.
    private func launchServers(askForApproval: Bool) -> Launch? {
        stopAll()
        startupReport = []
        guard let data = try? Data(contentsOf: Self.configURL) else { return nil }
        guard let config = try? JSONDecoder().decode(MCPConfig.self, from: data) else {
            startupReport = ["mcp.json is not valid JSON, so no servers were started."]
            return nil
        }
        let order = config.servers.keys.sorted()
        var lines: [String: String] = [:]
        var spawned: [(display: String, server: Server)] = []
        for display in order {
            guard let entry = config.servers[display] else { continue }
            let name = MCPProtocol.sanitize(display)
            guard MCPApprovals.isApproved(name: name, config: entry, interactive: askForApproval)
                    || (askForApproval && MCPApprovals.ask(name: display, config: entry)) else {
                lines[display] = "\(display): not started, because it is new or changed and has not been approved. Choose Reconnect Tool Servers to review it."
                continue
            }
            switch spawn(name: name, config: entry) {
            case .failure(let failure):
                lines[display] = "\(display): \(failure.message)"
            case .success(let server):
                starting[name] = server
                spawned.append((display, server))
                lines[display] = "\(display): starting"
            }
        }
        startupReport = order.compactMap { lines[$0] }
        guard !spawned.isEmpty else { return nil }
        isStarting = true
        return Launch(generation: generation, order: order, lines: lines, spawned: spawned)
    }

    /// The asynchronous half. Every handshake runs at once; a slow `npx`
    /// download holds up only its own server, and never the main thread.
    private func finishHandshakes(_ launch: Launch) async -> [String] {
        var lines = launch.lines
        let handshakes = launch.spawned.map { entry in
            Task { @MainActor in
                (entry.display, await self.connect(entry.server, display: entry.display,
                                                   generation: launch.generation))
            }
        }
        for handshake in handshakes {
            let (display, line) = await handshake.value
            if let line { lines[display] = line }
        }
        guard launch.generation == generation else { return startupReport }
        isStarting = false
        startupReport = launch.order.compactMap { lines[$0] }
        return startupReport
    }

    /// Finishes one server's handshake and, if it is still wanted, puts it
    /// in service. Returns its report line, or nil when a later start or stop
    /// made it moot.
    private func connect(_ server: Server, display: String, generation gen: Int) async -> String? {
        let result = await handshake(server)
        guard gen == generation else { return nil }
        starting[server.name] = nil
        switch result {
        case .success(let listed):
            // Built here, on the main actor and one server at a time, so two
            // servers finishing together can never claim the same name.
            toolIndex.remove(server: server.name)
            let catalog = MCPProtocol.catalog(from: listed, server: server.name,
                                              taken: toolIndex.names)
            server.tools = catalog.definitions
            toolIndex.merge(catalog.index)
            servers[server.name] = server
            toolsChanged()
            let count = catalog.definitions.count
            return "\(display): \(count) \(count == 1 ? "tool" : "tools")"
        case .failure(let failure):
            server.process.terminate()
            return "\(display): \(failure.message)"
        }
    }

    func stopAll() {
        generation += 1
        isStarting = false
        for server in Array(servers.values) + Array(starting.values) {
            server.lock.lock()
            server.closed = true
            server.lock.broadcast()
            server.lock.unlock()
            server.process.terminate()
        }
        let hadTools = !servers.isEmpty
        servers = [:]
        starting = [:]
        toolIndex = MCPToolIndex()
        if hadTools { toolsChanged() }
    }

    private func toolsChanged() {
        ClaudeAgent.mcpTools = toolDefinitions
        onChange?()
    }

    /// Called on the main actor when a server's stdout reaches EOF. A dead
    /// server's tools are withdrawn at once, so the model stops calling it.
    private func serverDidExit(_ server: Server) {
        if servers[server.name] === server {
            servers[server.name] = nil
            toolIndex.remove(server: server.name)
            toolsChanged()
        }
    }

    // MARK: - Spawning

    /// The environment a server sees: enough to find and run its command,
    /// plus exactly what its config entry adds. Nothing else from the app's
    /// environment (ANTHROPIC_API_KEY, ELEVENLABS_API_KEY, tokens) crosses.
    static func childEnvironment(parent: [String: String],
                                 config: [String: String]?) -> [String: String] {
        let passed = ["PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "TERM"]
        var environment: [String: String] = [:]
        for key in passed { environment[key] = parent[key] }
        for (key, value) in parent where key.hasPrefix("LC_") { environment[key] = value }
        // A bare command name needs a PATH; a GUI app inherits almost none,
        // so the usual install locations are added explicitly.
        let path = environment["PATH"] ?? ""
        environment["PATH"] = ([path] + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"])
            .filter { !$0.isEmpty }.joined(separator: ":")
        config?.forEach { environment[$0.key] = $0.value }
        return environment
    }

    /// The command line as `sh -c` will run it.
    static func commandLine(_ config: MCPServerConfig) -> String {
        ([config.command] + config.args)
            .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
    }

    private func spawn(name: String, config: MCPServerConfig) -> Result<Server, MCPFailure> {
        let environment = Self.childEnvironment(parent: ProcessInfo.processInfo.environment,
                                                config: config.env)
        // Through sh so a command on the PATH resolves the way it does in a
        // terminal, which is where these config lines are copied from.
        let process: ChildProcess
        do {
            process = try ChildProcess.spawn(executable: "/bin/sh",
                                             arguments: ["-c", Self.commandLine(config)],
                                             environment: environment)
        } catch {
            return .failure(MCPFailure("could not start (\(error.localizedDescription))"))
        }
        let server = Server(name: name, config: config, process: process)
        readLines(from: server)
        return .success(server)
    }

    /// `initialize`, the `initialized` notification, then `tools/list`, all
    /// awaited off the main actor. The timeouts are generous because a first
    /// `npx` run downloads its package before it can answer.
    private func handshake(_ server: Server) async -> Result<[String: Any], MCPFailure> {
        guard case .success = await request(server: server, method: "initialize",
                                            params: MCPProtocol.initializeParams,
                                            timeout: 30) else {
            return .failure(MCPFailure("did not answer the handshake"))
        }
        if let notification = MCPProtocol.encodeNotification(method: "notifications/initialized",
                                                             params: [:]) {
            _ = await write(notification, to: server)
        }
        guard case .success(let listed) = await request(server: server, method: "tools/list",
                                                        params: [:], timeout: 15) else {
            return .failure(MCPFailure("did not list any tools"))
        }
        return .success(listed)
    }

    /// Runs one tool. `arguments` is the JSON object the model produced.
    ///
    /// Async, and deliberately so. A tool call goes to another process and can
    /// take a minute; waiting for that on the main actor would freeze the
    /// creature and the panel along with it. The request is written here, on
    /// the main actor, and only the waiting happens elsewhere.
    func callTool(server serverName: String, tool: String,
                  arguments: [String: Any]) async -> (result: String, ok: Bool) {
        guard let server = servers[serverName] else {
            return ("The \(serverName) server is not connected.", false)
        }
        let params = MCPProtocol.callParams(tool: tool, arguments: arguments)
        switch await request(server: server, method: "tools/call", params: params, timeout: 60) {
        case .failure(let failure):
            return ("\(serverName) could not run \(tool): \(failure.message)", false)
        case .success(let result):
            return (MCPProtocol.resultText(result), !MCPProtocol.isError(result))
        }
    }

    // MARK: - JSON-RPC plumbing

    private func request(server: Server, method: String, params: [String: Any],
                         timeout: TimeInterval) async -> Result<[String: Any], MCPFailure> {
        switch await send(server: server, method: method, params: params) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let id):
            return await Self.awaitReply(server: server, id: id, timeout: timeout)
        }
    }

    /// Writes one request and returns its id. The id is allocated here, on
    /// the main actor; the write itself happens on the server's own queue.
    private func send(server: Server, method: String,
                      params: [String: Any]) async -> Result<Int, MCPFailure> {
        let id = server.nextID
        server.nextID += 1
        guard let payload = MCPProtocol.encode(id: id, method: method, params: params) else {
            return .failure(MCPFailure("could not encode the request"))
        }
        guard await write(payload, to: server) else {
            return .failure(MCPFailure("the server stopped listening"))
        }
        return .success(id)
    }

    /// How long a server may leave its stdin full before it is taken to have
    /// stopped listening.
    static let writeDeadline: TimeInterval = 15

    /// False when the server is gone or stopped reading. The write runs on
    /// the server's serial queue (so requests never interleave and the main
    /// actor never blocks) against a non-blocking pipe with a deadline. A
    /// server that misses the deadline is terminated: its replies can no
    /// longer be trusted to line up with requests. The pipe is also set up
    /// with F_SETNOSIGPIPE, so writing to a server that exited fails with
    /// EPIPE instead of killing WindowPet with SIGPIPE.
    private func write(_ payload: Data, to server: Server) async -> Bool {
        guard !server.isClosed, server.process.isRunning else { return false }
        let fd = server.process.stdin.fileDescriptor
        let deadline = Date().addingTimeInterval(Self.writeDeadline)
        let written = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            // Enqueued synchronously, before this call suspends, so two
            // requests sent in order are written in order.
            server.writer.async {
                continuation.resume(returning: MCPHost.writeAll(payload, to: fd, deadline: deadline,
                                                                closed: { server.isClosed }))
            }
        }
        if !written, !server.isClosed {
            server.process.terminate()
        }
        return written
    }

    /// Writes every byte or gives up at the deadline. The descriptor is
    /// non-blocking, so a full pipe waits in poll(2) rather than in write(2).
    private nonisolated static func writeAll(_ payload: Data, to fd: Int32, deadline: Date,
                                             closed: () -> Bool) -> Bool {
        payload.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
            guard let base = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                if closed() { return false }
                let n = Darwin.write(fd, base + offset, buffer.count - offset)
                if n > 0 {
                    offset += n
                    continue
                }
                if n < 0 && errno == EINTR { continue }
                guard n < 0, errno == EAGAIN || errno == EWOULDBLOCK else { return false }
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { return false }
                var waiter = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                // In slices of at most half a second, so a server that exits
                // meanwhile is noticed promptly.
                let slice = Int32(min(remaining, 0.5) * 1000)
                if poll(&waiter, 1, max(slice, 1)) < 0 && errno != EINTR { return false }
                if waiter.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { return false }
            }
            return true
        }
    }

    /// The blocking half, off the main actor. `Server` guards the two fields
    /// this touches with its lock, which is the whole reason it is unchecked
    /// Sendable.
    private nonisolated static func awaitReply(server: Server, id: Int,
                                               timeout: TimeInterval) async
        -> Result<[String: Any], MCPFailure> {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: waitForReply(server: server, id: id,
                                                            timeout: timeout))
            }
        }
    }

    /// Parks on the server's condition until its reply arrives or the deadline
    /// passes. Never call this from the main actor.
    private nonisolated static func waitForReply(server: Server, id: Int,
                                                 timeout: TimeInterval)
        -> Result<[String: Any], MCPFailure> {
        let deadline = Date().addingTimeInterval(timeout)
        server.lock.lock()
        defer { server.lock.unlock() }
        while server.replies[id] == nil && !server.closed {
            if !server.lock.wait(until: deadline) { break }
        }
        guard let reply = server.replies.removeValue(forKey: id) else {
            return .failure(MCPFailure(server.closed
                ? "the server exited" : "the server did not reply in time"))
        }
        return reply
    }

    /// One reader thread per server, parking on the pipe. Blocking reads are
    /// exactly right here and must not happen on the main actor, which is why
    /// this is a thread rather than a readabilityHandler.
    private func readLines(from server: Server) {
        let handle = server.process.stdout
        // Captured here, on the main actor, for answering server requests
        // from the reader thread.
        let stdinFD = server.process.stdin.fileDescriptor
        let replyDeadline = Self.writeDeadline
        Thread.detachNewThread { [weak self] in
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
                        // A server's own request (ping, or anything we do not
                        // implement) gets its answer so the server never
                        // stalls waiting; the write goes through the same
                        // serial queue as our requests, so bytes never mix.
                        if let reply = MCPProtocol.serverRequestReply(line: line) {
                            server.writer.async {
                                _ = MCPHost.writeAll(reply, to: stdinFD,
                                                     deadline: Date().addingTimeInterval(replyDeadline),
                                                     closed: { server.isClosed })
                            }
                        }
                        continue
                    }
                }
            }
            server.lock.lock()
            server.closed = true
            server.lock.broadcast()
            server.lock.unlock()
            Task { @MainActor in self?.serverDidExit(server) }
        }
    }
}

// MARK: - Approval

/// Which mcp.json entries a person has approved, by fingerprint of
/// everything that decides what runs: name, command, arguments, environment
/// and trust.
///
/// Kept in the data-protection keychain, under WindowPet's keychain access
/// group, rather than next to mcp.json or in the login keychain. Only a
/// program signed into that group can create or read the item, so a process
/// that plants an entry in mcp.json cannot also plant the approval for it (a
/// login-keychain item can be created by any process running as the user,
/// `security add-generic-password -A` included, and would be read silently).
/// A build without the entitlement (swift run, a self-signed development
/// build) cannot use that keychain and falls back to the login keychain,
/// which does not have this protection.
@MainActor
enum MCPApprovals {

    private static let service = "WindowPet MCP approvals"
    private static let account = "approved-servers"

    static func fingerprint(name: String, config: MCPServerConfig) -> String {
        let canonical: [String: Any] = [
            "name": name,
            "command": config.command,
            "args": config.args,
            "env": config.env ?? [:],
            "trust": config.trust ?? "ask",
        ]
        let data = (try? JSONSerialization.data(withJSONObject: canonical,
                                                options: [.sortedKeys])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isApproved(name: String, config: MCPServerConfig, interactive: Bool) -> Bool {
        load(interactive: interactive).contains(fingerprint(name: name, config: config))
    }

    /// Shows the exact command line and asks. "Don't Run" is the default
    /// button, so a stray Return never approves anything.
    static func ask(name display: String, config: MCPServerConfig) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Run the tool server \u{201C}\(display)\u{201D}?"
        let envNames = (config.env ?? [:]).keys.sorted()
        let env = envNames.isEmpty ? "" : "\n\nEnvironment it sets: \(envNames.joined(separator: ", ")) (values hidden)"
        let trust = config.isTrusted
            ? "\n\nIt is marked trust: always, so Rusty will run its tools without asking each time."
            : ""
        alert.informativeText = "mcp.json has a new or changed entry. Approving runs this command every time WindowPet starts, as its own process:\n\n\(MCPHost.commandLine(config))\(env)\(trust)\n\nOnly approve it if you added it yourself."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Don't Run")
        alert.addButton(withTitle: "Run It")
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        var approved = load(interactive: true)
        approved.insert(fingerprint(name: MCPProtocol.sanitize(display), config: config))
        save(approved)
        return true
    }

    private static func baseQuery(dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    /// Reads the approvals. The data-protection keychain is authoritative
    /// whenever this build can use it: an empty result there means nothing
    /// is approved, and a login-keychain item (which anyone could have
    /// written) is never consulted. Never shows a Keychain prompt unless
    /// `interactive`; a headless run treats an unreadable item as nothing
    /// approved.
    private static func load(interactive: Bool) -> Set<String> {
        var query = baseQuery(dataProtection: true)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecMissingEntitlement { return loadLegacy(interactive: interactive) }
        guard status == errSecSuccess else { return [] }
        return decode(item)
    }

    private static func loadLegacy(interactive: Bool) -> Set<String> {
        var query = baseQuery(dataProtection: false)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !interactive {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return [] }
        return decode(item)
    }

    private static func decode(_ item: CFTypeRef?) -> Set<String> {
        guard let data = item as? Data,
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(list)
    }

    private static func save(_ approved: Set<String>) {
        guard let data = try? JSONEncoder().encode(approved.sorted()) else { return }
        if save(data, dataProtection: true) == errSecMissingEntitlement {
            _ = save(data, dataProtection: false)
        }
    }

    private static func save(_ data: Data, dataProtection: Bool) -> OSStatus {
        let query = baseQuery(dataProtection: dataProtection)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var add = query
        add[kSecValueData as String] = data
        if dataProtection {
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        return SecItemAdd(add as CFDictionary, nil)
    }
}

// MARK: - Child process

/// A child spawned with posix_spawn rather than Process, for two things
/// Process cannot do: it disclaims responsibility (so macOS attributes the
/// child's privacy requests to the child, not to WindowPet and its grants),
/// and its stdin is marked F_SETNOSIGPIPE (so writing to a dead server is an
/// error, not a SIGPIPE that terminates the app).
final class ChildProcess: @unchecked Sendable {

    struct SpawnError: LocalizedError {
        let code: Int32
        var errorDescription: String? { String(cString: strerror(code)) }
    }

    let pid: pid_t
    let stdin: FileHandle
    let stdout: FileHandle
    private let lock = NSLock()
    private var exited = false

    private init(pid: pid_t, stdin: FileHandle, stdout: FileHandle) {
        self.pid = pid
        self.stdin = stdin
        self.stdout = stdout
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !exited
    }

    /// SIGTERM, only while the child has not been reaped, so a recycled pid
    /// is never signalled.
    func terminate() {
        lock.lock()
        defer { lock.unlock() }
        if !exited { kill(pid, SIGTERM) }
    }

    /// `responsibility_spawnattrs_setdisclaim` is the libsystem call Terminal,
    /// Chromium and LLDB use for exactly this. Looked up at run time; if it is
    /// ever missing the child is still spawned, just without the disclaim.
    private typealias DisclaimFunction = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    private static let disclaim: DisclaimFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else {
            return nil
        }
        return unsafeBitCast(symbol, to: DisclaimFunction.self)
    }()

    static func spawn(executable: String, arguments: [String],
                      environment: [String: String]) throws -> ChildProcess {
        var toChild: [Int32] = [0, 0]
        var fromChild: [Int32] = [0, 0]
        guard pipe(&toChild) == 0 else { throw SpawnError(code: errno) }
        guard pipe(&fromChild) == 0 else {
            close(toChild[0]); close(toChild[1])
            throw SpawnError(code: errno)
        }
        _ = fcntl(toChild[1], F_SETNOSIGPIPE, 1)
        // Our end of the child's stdin never blocks: MCPHost waits for room
        // in poll(2) with a deadline instead (see `writeAll`).
        _ = fcntl(toChild[1], F_SETFL, fcntl(toChild[1], F_GETFL) | O_NONBLOCK)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, toChild[0], 0)
        posix_spawn_file_actions_adddup2(&actions, fromChild[1], 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Close every other descriptor in the child, and give it default
        // signal handling and an empty mask whatever the app has set.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT
                                                    | POSIX_SPAWN_SETSIGDEF
                                                    | POSIX_SPAWN_SETSIGMASK))
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attributes, &all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)
        _ = disclaim?(&attributes, 1)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        close(toChild[0])
        close(fromChild[1])
        guard status == 0 else {
            close(toChild[1])
            close(fromChild[0])
            throw SpawnError(code: status)
        }
        let child = ChildProcess(pid: pid,
                                 stdin: FileHandle(fileDescriptor: toChild[1], closeOnDealloc: true),
                                 stdout: FileHandle(fileDescriptor: fromChild[0], closeOnDealloc: true))
        // Reap it when it exits, so it never lingers as a zombie.
        let childPID = pid
        Thread.detachNewThread {
            var exitStatus: Int32 = 0
            while waitpid(childPID, &exitStatus, 0) == -1 && errno == EINTR {}
            child.lock.lock()
            child.exited = true
            child.lock.unlock()
        }
        return child
    }
}
