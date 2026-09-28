import AppKit
import Foundation
import WindowPetCore

/// Runs one agentic conversation: Claude calls a tool, sees the result, and
/// decides the next move, looping until the job is actually done. Holds the
/// running message history so a confirmation can pause the loop and resume it
/// exactly where it stopped.
///
/// Safety: every tool call maps onto the same gated AssistantAction the typed
/// grammar uses, so quit, dangerous AppleScript, and admin still stop the loop
/// and wait for a human Return (and the OS password on top, for admin). The
/// loop cannot spend those on its own no matter what it decides. On top of
/// that, once anything from outside the user's own words enters the run (a
/// web page, a file, an MCP result, the screen), every verb that could act on
/// that content also stops for a Return: see `AgentGate`.
///
/// Main-actor isolated on purpose. Every caller is the UI, the mutable state
/// here (`messages`, `memory`, `pending`, `iterations`) is a running
/// conversation, and two turns interleaving would corrupt it. Isolation makes
/// that structurally impossible rather than merely unlikely; the network wait
/// inside `streamTurn` is an await, so the main thread is never blocked.
@MainActor
final class AgentSession {

    enum Step {
        case done(String)
        case needsConfirmation(AssistantAction, summary: String)
        case failed(String)
    }

    /// What a stopped run reports. The panel ignores it (the user stopped the
    /// run, so there is nothing to show), but a headless caller gets a line.
    static let stoppedMessage = "Stopped."
    /// A request too long to show in full in the safety row is refused
    /// rather than approved half-read.
    static let tooLongToConfirm = "That is too long to show you in full for approval, so nothing ran. Break it into shorter steps."

    /// Narration for the panel while the loop works ("Opening Safari").
    var onProgress: ((String) -> Void)?
    /// Answer text as it streams in, chunk by chunk.
    var onTextDelta: ((String) -> Void)?

    /// The running conversation: message array, iteration budget, and the last
    /// thing Rusty managed to say. The rules live in WindowPetCore so they can
    /// be replayed in tests without a network.
    private var conversation = AgentConversation()

    /// Where the loop stopped for a confirmation: the gated action, the tool
    /// call it belongs to, results already collected this turn, and the calls
    /// still queued behind it.
    private var pending: (action: AssistantAction,
                          callId: String,
                          collected: [(id: String, text: String, isError: Bool)],
                          remaining: [ClaudeAgent.ToolCall])?

    var isAwaitingConfirmation: Bool { pending != nil }

    /// Set by `cancel()`. Checked before every API call and every tool, so a
    /// stopped run never takes another step.
    private(set) var isCancelled = false

    /// True once content the user did not write has entered this run. From
    /// then on, side-effecting verbs confirm (see `AgentGate`).
    private(set) var tainted = false

    /// The request came through the wake word (see `start`).
    private var heard = false

    /// Loaded once at the start of a turn and mutated in place, so a single
    /// turn does not read and decode the memory file five times over.
    private var memory = PetMemory()

    private var stopped: Bool { isCancelled || Task.isCancelled }

    /// Stops the run where it stands: no further API call, no further tool,
    /// and any waiting safety check is dropped rather than left to approve.
    func cancel() {
        isCancelled = true
        pending = nil
    }

    /// - Parameters:
    ///   - noteAs: what goes into the persistent memory thread in place of
    ///     `text`. A dropped file's prompt carries the file itself, which must
    ///     never be written to disk, so the panel passes the visible label.
    ///   - untrustedInput: the request itself carries outside content (a
    ///     dropped file, a standing ask the model may have written), so the
    ///     run starts tainted.
    ///   - untrustedInput: the request itself carries outside content (a
    ///     dropped file, a standing ask the model may have written), or the
    ///     panel history it replays does. The run starts tainted, because
    ///     taint belongs to the conversation, not to the one run that first
    ///     read the content.
    ///   - heard: the request came through the wake word, which hears any
    ///     audio nearby (a video, a call). Typing, key presses, shortcuts and
    ///     tricks then confirm (see `AgentGate`).
    func start(_ text: String, context: String,
               history: [(role: String, text: String)],
               noteAs: String? = nil, untrustedInput: Bool = false,
               heard: Bool = false) async -> Step {
        // No key: say so before touching memory or anything else, so a
        // headless or keyless attempt leaves no trace behind.
        guard ClaudeRouter.isConfigured else { return .failed(Self.notConfigured) }
        conversation = AgentConversation(history: history)
        tainted = untrustedInput
        self.heard = heard
        memory = PetMemoryStore.load()
        // Facts scoped to an app only come back while that app is in front.
        let block = memory.promptBlock(inApp: NSWorkspace.shared.frontmostApplication?.localizedName)
        let situation = block.isEmpty ? context : "\(context). \(block)"
        conversation.ask(text, situation: situation)
        // Keep a thread of the conversation across launches, minus anything
        // shaped like a credential. Written once the first request has
        // actually gone out (see runLoop), not before. Text the user did not
        // write is never replayed into later conversations: an untrusted
        // request is noted by its label, or neutrally.
        let said = noteAs ?? (untrustedInput ? "a request that carried outside content" : text)
        pendingUserNote = "they said: \(MemoryHygiene.redact(said, limit: 300))"
        return await runLoop()
    }

    static let notConfigured = "The Claude brain is not configured."

    /// The "they said" line, held until the first request is made.
    private var pendingUserNote: String?

    private func notePendingUserLine() {
        guard let line = pendingUserNote else { return }
        pendingUserNote = nil
        memory.noteExchange(line)
        PetMemoryStore.save(memory)
    }

    /// The user answered the safety check; finish that tool call and carry on.
    func resume(approved: Bool) async -> Step {
        guard let paused = pending else { return .failed("nothing was waiting") }
        pending = nil
        if stopped { return .failed(Self.stoppedMessage) }
        var collected = paused.collected
        if approved {
            let (result, ok) = await AssistantExecutor.executeAwaiting(paused.action)
            onProgress?(result)
            collected.append((id: paused.callId, text: result, isError: !ok))
            if AgentGate.bringsInOutsideContent(paused.action) { tainted = true }
        } else {
            collected.append((id: paused.callId,
                              text: "The user declined this step. Do not retry it.",
                              isError: false))
        }
        if let paused2 = await processCalls(paused.remaining, collected: collected) {
            return paused2
        }
        return await runLoop()
    }

    // MARK: - The loop

    private func runLoop() async -> Step {
        while conversation.beginIteration() {
            if stopped { return .failed(Self.stoppedMessage) }
            // Checked per iteration, not per turn: a loop that keeps deciding
            // to call one more tool is exactly the thing a daily ceiling is
            // for, and it should stop at the ceiling rather than past it.
            if let blocked = UsageMeter.shared.blockedMessage { return .failed(blocked) }
            let model = ClaudeRouter.model
            guard let key = ClaudeRouter.apiKey,
                  let spec = ClaudeAgent.agentRequest(messages: conversation.messages, apiKey: key,
                                                      model: model,
                                                      stream: true) else {
                return .failed(Self.notConfigured)
            }
            let result: ClaudeAgent.TurnResult
            do {
                result = try await streamTurn(spec, model: model)
            } catch AgentError.unauthorized {
                return .failed("Anthropic rejected the API key. Fix it under Anthropic API Key in the menu bar.")
            } catch AgentError.api(let sentence) {
                return .failed(sentence)
            } catch {
                if stopped || error is CancellationError { return .failed(Self.stoppedMessage) }
                return .failed("I couldn't reach Anthropic: \(error.localizedDescription)")
            }
            if stopped { return .failed(Self.stoppedMessage) }
            notePendingUserLine()
            if case .turn(let turn) = result {
                conversation.record(turn)
                // A web search or fetch ran inside this turn: its results are
                // outside content, and the tool calls in the same turn may be
                // acting on them.
                if AgentGate.carriesServerToolResults(turn.rawContent) { tainted = true }
            }

            switch AgentLoop.decide(result, lastText: conversation.lastText) {
            case .stop(let message):
                return .failed(message)
            case .answer(let answer):
                // Memory is replayed into every later conversation, which
                // starts untainted. An answer written after reading outside
                // content may repeat that content's instructions, so it is
                // recorded neutrally rather than word for word.
                memory.noteExchange(tainted
                    ? "you answered a request that used outside content"
                    : "you replied: \(MemoryHygiene.redact(answer, limit: 300))")
                PetMemoryStore.save(memory)
                return .done(answer)
            case .resend:
                // A server-side tool (web search or fetch) hit its own limit
                // mid-turn. The conversation goes back unchanged, with no
                // tool_result, and the server picks up where it paused. The
                // iteration cap still bounds this.
                onProgress?("Still reading…")
                continue
            case .execute(let calls):
                if let paused = await processCalls(calls, collected: []) {
                    return paused
                }
            }
        }
        // Hit the iteration cap: say so honestly instead of looping forever.
        return .done(AgentLoop.exhaustedAnswer(lastText: conversation.lastText))
    }

    private enum AgentError: Error {
        case unauthorized
        /// A non-retryable API error, already phrased for the user.
        case api(String)
    }

    /// One streamed turn. Text lands in `onTextDelta` as it arrives, so the
    /// panel fills in live instead of waiting for the whole response.
    ///
    /// Retries follow `AnthropicHTTP`: 429, 5xx and 529 (honouring
    /// `retry-after`), an overloaded or api error that arrives as an SSE
    /// `error` event before any content, and a dropped connection before any
    /// content. Once text has streamed into the panel a retry would repeat
    /// it, so a failure after that point is reported instead. A bad key, a
    /// cancelled run and every other 4xx never retry.
    private func streamTurn(_ spec: ClaudeRouting.RequestSpec,
                            model: String) async throws -> ClaudeAgent.TurnResult {
        var attempt = 0
        while true {
            attempt += 1
            if stopped { throw CancellationError() }
            var usage = UsageMeter.Usage()
            var sawContent = false
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: spec.urlRequest(timeout: 120))
                let http = response as? HTTPURLResponse
                let status = http?.statusCode ?? 200
                if status == 401 { throw AgentError.unauthorized }
                if !(200..<300).contains(status) {
                    // An error body is one plain JSON object with no `data:`
                    // prefix; the SSE reader would see nothing in it.
                    let body = try await Self.collect(bytes, limit: 64_000)
                    if AnthropicHTTP.isRetryable(status: status),
                       let wait = AnthropicHTTP.retryDelay(
                           attempt: attempt,
                           retryAfter: http?.value(forHTTPHeaderField: "retry-after")) {
                        try await Task.sleep(for: .seconds(wait))
                        continue
                    }
                    throw AgentError.api(AnthropicHTTP.explain(status: status, body: body, model: model))
                }
                let accumulator = StreamAccumulator()
                accumulator.onTextDelta = { [weak self] chunk in
                    guard let self, !self.stopped else { return }
                    self.onTextDelta?(chunk)
                }
                var streamError: (type: String?, message: String?)?
                // Usage is read here rather than through the accumulator so
                // cache writes are counted too; only the two events that carry
                // it are decoded a second time.
                defer { UsageMeter.shared.record(usage, model: model) }
                for try await line in bytes.lines {
                    if stopped { throw CancellationError() }
                    if line.contains("content_block_start") { sawContent = true }
                    if line.contains("\"usage\""), let event = Self.dataEvent(line),
                       let reported = UsageMeter.Usage.from(event) {
                        usage.merge(reported)
                    }
                    if line.contains("\"error\""), let event = Self.dataEvent(line),
                       event["type"] as? String == "error" {
                        let error = event["error"] as? [String: Any]
                        streamError = (error?["type"] as? String, error?["message"] as? String)
                    }
                    accumulator.consume(line: line)
                }
                if let streamError {
                    let transient = streamError.type == "overloaded_error"
                        || streamError.type == "api_error"
                    if transient, !sawContent,
                       let wait = AnthropicHTTP.retryDelay(attempt: attempt, retryAfter: nil) {
                        try await Task.sleep(for: .seconds(wait))
                        continue
                    }
                    if transient {
                        throw AgentError.api("Anthropic is busy right now. Try again in a moment.")
                    }
                }
                return accumulator.finish()
            } catch let error as AgentError {
                throw error
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if stopped { throw CancellationError() }
                if !sawContent, AnthropicHTTP.isRetryable(error: error),
                   let wait = AnthropicHTTP.retryDelay(attempt: attempt, retryAfter: nil) {
                    try await Task.sleep(for: .seconds(wait))
                    continue
                }
                throw error
            }
        }
    }

    /// Decodes one SSE `data:` line.
    private static func dataEvent(_ line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Reads a (non-streamed) error body, bounded.
    private static func collect(_ bytes: URLSession.AsyncBytes, limit: Int) async throws -> Data {
        var body = Data()
        for try await byte in bytes {
            body.append(byte)
            if body.count >= limit { break }
        }
        return body
    }

    /// Executes a turn's tool calls in order. Returns a Step when a call needs
    /// the user (or the run was stopped), or nil once every result is appended
    /// to the conversation.
    private func processCalls(_ calls: [ClaudeAgent.ToolCall],
                              collected: [(id: String, text: String, isError: Bool)]) async -> Step? {
        var results = collected
        for (index, call) in calls.enumerated() {
            if stopped { return .failed(Self.stoppedMessage) }
            // Screen sight is a Claude capability, not a local action: run the
            // vision request and hand the answer back as the tool result.
            if call.name == "look" {
                onProgress?("Looking at the screen")
                let seen = await ClaudeRouter.look(question: call.argument)
                results.append((id: call.id, text: seen, isError: false))
                // What is on screen can be anything, including instructions.
                tainted = true
                continue
            }
            if call.name == "remember" || call.name == "forget" {
                // Memory outlives the run and rides along in every later
                // conversation, so outside content must not be able to write
                // or wipe it.
                if tainted {
                    results.append((id: call.id,
                                    text: "Not done: memory can't be changed in a request that read outside content. Ask the user to tell you directly.",
                                    isError: true))
                    continue
                }
                if call.name == "remember" {
                    // "in Xcode: keep the left half" saves a fact that only
                    // surfaces while Xcode is in front.
                    let (scope, raw) = PetMemory.splitScope(call.argument)
                    let text = MemoryHygiene.redact(raw, limit: 400)
                    memory.remember(text, scope: scope)
                    PetMemoryStore.save(memory)
                    onProgress?(scope.map { "Noted for \($0): \(text)" } ?? "Noted: \(text)")
                    results.append((id: call.id, text: "Saved.", isError: false))
                } else {
                    if PetMemory.normalize(call.argument) == "everything" {
                        memory.forgetEverything()
                        onProgress?("Cleared what I remembered")
                    } else {
                        memory.forget(matching: call.argument)
                        onProgress?("Forgot that")
                    }
                    PetMemoryStore.save(memory)
                    results.append((id: call.id, text: "Done.", isError: false))
                }
                continue
            }
            // A tool from an MCP server. Routed before the verb table, since
            // its name is qualified and belongs to no built-in verb, and it
            // still becomes a gated AssistantAction so trust stays a config
            // decision rather than the model's to make.
            if let entry = AssistantExecutor.shared.mcp.resolve(qualified: call.name) {
                let server = entry.server, tool = entry.tool
                let action = AssistantAction.mcpCall(
                    server: server, tool: tool, arguments: call.rawArguments,
                    trusted: AssistantExecutor.shared.mcp.isTrusted(server: server))
                if action.needsConfirmation && action.exceedsConfirmableLength {
                    results.append((id: call.id, text: Self.tooLongToConfirm, isError: true))
                    continue
                }
                if action.needsConfirmation {
                    pending = (action: action, callId: call.id, collected: results,
                               remaining: Array(calls.dropFirst(index + 1)))
                    return .needsConfirmation(action, summary: AgentGate.summary(action, tainted: tainted))
                }
                let (result, ok) = await AssistantExecutor.executeAwaiting(action)
                onProgress?("Ran \(tool) on \(server)")
                results.append((id: call.id, text: result, isError: !ok))
                tainted = true
                continue
            }
            // Internal verbs are handled by the branches above; if one is
            // ever added to ClaudeAgent.internalVerbs without a branch here,
            // fail loudly rather than routing it to the executor, which would
            // reject it as an invalid argument.
            if ClaudeAgent.internalVerbs.contains(call.name) {
                results.append((id: call.id,
                                text: "The \(call.name) tool isn't wired up; nothing ran.",
                                isError: true))
                continue
            }
            guard let action = AssistantRouting.action(verb: call.name, argument: call.argument) else {
                results.append((id: call.id,
                                text: "That tool needs a valid argument; nothing ran.",
                                isError: true))
                continue
            }
            if AgentGate.requiresConfirmation(action, tainted: tainted, heard: heard) {
                if action.exceedsConfirmableLength {
                    results.append((id: call.id, text: Self.tooLongToConfirm, isError: true))
                    continue
                }
                pending = (action: action, callId: call.id, collected: results,
                           remaining: Array(calls.dropFirst(index + 1)))
                return .needsConfirmation(action, summary: AgentGate.summary(action, tainted: tainted,
                                                                             heard: heard))
            }
            let (result, ok) = await AssistantExecutor.executeAwaiting(action)
            onProgress?(result)
            results.append((id: call.id, text: result, isError: !ok))
            if AgentGate.bringsInOutsideContent(action) { tainted = true }
        }
        if stopped { return .failed(Self.stoppedMessage) }
        conversation.record(results: results)
        return nil
    }
}

/// The app-side half of the confirmation gate, layered on top of
/// `AssistantAction.needsConfirmation` (which covers quit, admin, dangerous
/// AppleScript, read_file and untrusted MCP calls).
///
/// The extra rule is about where an instruction could have come from. Once a
/// web page, a file, an MCP result, the screen or the clipboard history is in
/// the conversation, the model may be following text the user never wrote, so
/// every verb that acts on the Mac or sends data out needs a human Return for
/// the rest of the run. A few verbs confirm regardless: a standing ask runs
/// the full agent unattended later, a URL carrying a long payload is a way to
/// send data out, and `open` with a path launches an arbitrary program.
@MainActor
enum AgentGate {

    /// - Parameter heard: the request came through the wake word, which
    ///   hears whatever audio is nearby. The verbs that put keystrokes into
    ///   the app in front, or run something saved by name, then confirm.
    static func requiresConfirmation(_ action: AssistantAction, tainted: Bool,
                                     heard: Bool = false) -> Bool {
        if action.needsConfirmation { return true }
        if heard, requiresConfirmationWhenHeard(action) { return true }
        switch action {
        case .schedule:
            return true
        case .openURL(let url):
            return tainted || carriesPayload(url)
        // `switch` launches the app when it is not running (`open -a`), so it
        // is gated exactly like `open`.
        case .openApp(let name), .switchApp(let name):
            return name.contains("/") || tainted
        case .typeText, .pressKeys, .copyText, .runShortcut, .runAppleScript, .runTrick,
             .search:
            return tainted
        // The user's own saved things: standing asks, tricks, layouts and
        // watches. Like memory, outside content must not be able to delete,
        // overwrite or plant them without a Return.
        case .unschedule, .forgetTrick, .saveTrick, .startRecordingTrick, .saveLayout,
             .stopWatching:
            return tainted
        default:
            return false
        }
    }

    private static func requiresConfirmationWhenHeard(_ action: AssistantAction) -> Bool {
        switch action {
        case .typeText, .pressKeys, .runShortcut, .runTrick: return true
        default: return false
        }
    }

    /// Results that put outside or sensitive content into the conversation.
    /// Listings of user-named items count too: a name can be written by a
    /// tainted run and read back by a later one.
    static func bringsInOutsideContent(_ action: AssistantAction) -> Bool {
        switch action {
        case .readFile, .listClips, .recallClip, .mcpCall,
             .listTricks, .listLayouts, .listSchedules, .listWatches:
            return true
        default: return false
        }
    }

    /// Server tools (web search, web fetch) ran inside this turn.
    static func carriesServerToolResults(_ content: [[String: Any]]) -> Bool {
        content.contains { block in
            guard let type = block["type"] as? String else { return false }
            return type == "server_tool_use" || type.hasSuffix("_tool_result")
        }
    }

    /// A query, fragment or path segment long enough to carry data out.
    static func carriesPayload(_ url: URL) -> Bool {
        if (url.query?.count ?? 0) > 40 || (url.fragment?.count ?? 0) > 40 { return true }
        return url.pathComponents.contains { $0.count > 40 }
    }

    /// What the safety check shows, so the user sees exactly what would run.
    static func summary(_ action: AssistantAction, tainted: Bool = false,
                        heard: Bool = false) -> String {
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "the app in front"
        // Never truncated: what is typed, copied, opened or scheduled is the
        // whole string, so the row shows the whole string. Payloads too long
        // to show are refused before this (exceedsConfirmableLength).
        let show = AppleScriptPolicy.visible
        let what: String
        switch action {
        case .typeText(let text): what = "Type into \(front): \(show(text))"
        case .pressKeys(let combo): what = "Press \(show(combo)) in \(front)"
        case .copyText(let text): what = "Copy to the clipboard: \(show(text))"
        case .openURL(let url): what = "Open \(show(url.absoluteString))"
        case .openApp(let name): what = "Open \(show(name))"
        case .switchApp(let name): what = "Switch to \(show(name))"
        case .runShortcut(let name): what = "Run the shortcut \(show(name))"
        case .runTrick(let name): what = "Run the trick \(show(name))"
        case .search(let query): what = "Search the web for \(show(query))"
        case .schedule(let raw): what = "Set up a standing ask that runs on its own: \(show(raw))"
        case .unschedule(let name): what = "Remove the standing ask \(show(name))"
        case .forgetTrick(let name): what = "Forget the trick \(show(name))"
        case .saveTrick(let name): what = "Save the recorded steps as the trick \(show(name))"
        case .startRecordingTrick: what = "Start recording a new trick"
        case .saveLayout(let name): what = "Save the current windows as the layout \(show(name))"
        case .stopWatching(let name): what = "Stop watching \(show(name))"
        default: what = action.confirmationSummary ?? "Confirm this step"
        }
        guard !action.needsConfirmation else { return what }
        if tainted { return "After reading content you did not write, Rusty wants to: \(what)" }
        if heard { return "From a request the wake word heard, Rusty wants to: \(what)" }
        return what
    }
}

/// Keeps credentials out of the memory file, which is written to disk and
/// replayed into every later conversation.
enum MemoryHygiene {
    /// Replaces every token shaped like a secret with a marker and caps the
    /// length. Per token, because a key usually sits inside a sentence
    /// ("ANTHROPIC_API_KEY=sk-ant-…") where the whole line reads as prose.
    static func redact(_ text: String, limit: Int) -> String {
        if ClipPolicy.isSecret(text) && !text.contains(where: \.isWhitespace) {
            return "[redacted]"
        }
        let tokens = text.split(omittingEmptySubsequences: false,
                                whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        var redacted = tokens.map { token -> String in
            let piece = String(token)
            let lowered = piece.lowercased()
            if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
                return ClipPolicy.isSecret(piece) ? "[redacted]" : piece
            }
            // `KEY=value` and `key: value` hide the secret behind a prefix.
            let parts = piece.split(whereSeparator: { "=:\"'`".contains($0) }).map(String.init)
            if ClipPolicy.isSecret(piece) || parts.contains(where: ClipPolicy.isSecret) {
                return "[redacted]"
            }
            return piece
        }.joined(separator: " ")
        if redacted.count > limit { redacted = String(redacted.prefix(limit)) + "…" }
        return redacted
    }
}
