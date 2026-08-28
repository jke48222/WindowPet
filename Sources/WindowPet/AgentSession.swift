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
/// loop cannot spend those on its own no matter what it decides.
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

    /// Loaded once at the start of a turn and mutated in place, so a single
    /// turn does not read and decode the memory file five times over.
    private var memory = PetMemory()

    func start(_ text: String, context: String,
               history: [(role: String, text: String)]) async -> Step {
        conversation = AgentConversation(history: history)
        memory = PetMemoryStore.load()
        // Facts scoped to an app only come back while that app is in front.
        let block = memory.promptBlock(inApp: NSWorkspace.shared.frontmostApplication?.localizedName)
        let situation = block.isEmpty ? context : "\(context). \(block)"
        conversation.ask(text, situation: situation)
        // Keep a thread of the conversation across launches.
        memory.noteExchange("they said: \(text)")
        PetMemoryStore.save(memory)
        return await runLoop()
    }

    /// The user answered the safety check; finish that tool call and carry on.
    func resume(approved: Bool) async -> Step {
        guard let paused = pending else { return .failed("nothing was waiting") }
        pending = nil
        var collected = paused.collected
        if approved {
            let (result, ok) = await AssistantExecutor.executeAwaiting(paused.action)
            onProgress?(result)
            collected.append((id: paused.callId, text: result, isError: !ok))
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
            // Checked per iteration, not per turn: a loop that keeps deciding
            // to call one more tool is exactly the thing a daily ceiling is
            // for, and it should stop at the ceiling rather than past it.
            if let blocked = UsageMeter.shared.blockedMessage { return .failed(blocked) }
            guard let key = ClaudeRouter.apiKey,
                  let spec = ClaudeAgent.agentRequest(messages: conversation.messages, apiKey: key,
                                                      model: ClaudeRouter.model,
                                                      stream: true) else {
                return .failed("The Claude brain is not configured.")
            }
            let result: ClaudeAgent.TurnResult
            do {
                result = try await streamTurn(spec)
            } catch AgentError.unauthorized {
                return .failed("Anthropic rejected the API key. Fix it under Anthropic API Key in the menu bar.")
            } catch {
                return .failed("I couldn't reach Anthropic: \(error.localizedDescription)")
            }
            if case .turn(let turn) = result { conversation.record(turn) }

            switch AgentLoop.decide(result, lastText: conversation.lastText) {
            case .stop(let message):
                return .failed(message)
            case .answer(let answer):
                memory.noteExchange("you replied: \(answer)")
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

    private enum AgentError: Error { case unauthorized }

    /// One streamed turn. Text lands in `onTextDelta` as it arrives, so the
    /// panel fills in live instead of waiting for the whole response.
    /// Transient failures (429, 5xx, dropped connections) retry with backoff;
    /// a bad key or a real API error does not.
    private func streamTurn(_ spec: ClaudeRouting.RequestSpec) async throws -> ClaudeAgent.TurnResult {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: spec.urlRequest(timeout: 120))
                if let http = response as? HTTPURLResponse {
                    if http.statusCode == 401 { throw AgentError.unauthorized }
                    if http.statusCode == 429 || http.statusCode >= 500 {
                        // Drain and retry: overloaded or rate limited.
                        for try await _ in bytes.lines { break }
                        if attempt <= 3 {
                            try? await Task.sleep(nanoseconds: UInt64(attempt) * 800_000_000)
                            continue
                        }
                        return .failed("Anthropic is busy right now. Try again in a moment.")
                    }
                }
                let accumulator = StreamAccumulator()
                accumulator.onTextDelta = { [weak self] chunk in
                    self?.onTextDelta?(chunk)
                }
                // Usage comes from the accumulator's single parse, so lines
                // are not decoded twice just to meter cost.
                accumulator.onUsage = { input, cached, output in
                    UsageMeter.shared.record(input: input, cached: cached, output: output)
                }
                for try await line in bytes.lines {
                    accumulator.consume(line: line)
                }
                return accumulator.finish()
            } catch let error as AgentError {
                throw error
            } catch {
                // Connection dropped mid-stream: one clean retry, then report.
                if attempt <= 2 {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    continue
                }
                throw error
            }
        }
    }

    /// Executes a turn's tool calls in order. Returns a Step when a call needs
    /// the user, or nil once every result is appended to the conversation.
    private func processCalls(_ calls: [ClaudeAgent.ToolCall],
                              collected: [(id: String, text: String, isError: Bool)]) async -> Step? {
        var results = collected
        for (index, call) in calls.enumerated() {
            // Screen sight is a Claude capability, not a local action: run the
            // vision request and hand the answer back as the tool result.
            if call.name == "look" {
                onProgress?("Looking at the screen")
                let seen = await ClaudeRouter.look(question: call.argument)
                results.append((id: call.id, text: seen, isError: false))
                continue
            }
            if call.name == "remember" {
                // "in Xcode: keep the left half" saves a fact that only
                // surfaces while Xcode is in front.
                let (scope, text) = PetMemory.splitScope(call.argument)
                memory.remember(text, scope: scope)
                PetMemoryStore.save(memory)
                onProgress?(scope.map { "Noted for \($0): \(text)" } ?? "Noted: \(text)")
                results.append((id: call.id, text: "Saved.", isError: false))
                continue
            }
            if call.name == "forget" {
                if PetMemory.normalize(call.argument) == "everything" {
                    memory.forgetEverything()
                    onProgress?("Cleared what I remembered")
                } else {
                    memory.forget(matching: call.argument)
                    onProgress?("Forgot that")
                }
                PetMemoryStore.save(memory)
                results.append((id: call.id, text: "Done.", isError: false))
                continue
            }
            // A tool from an MCP server. Routed before the verb table, since
            // its name is qualified and belongs to no built-in verb, and it
            // still becomes a gated AssistantAction so trust stays a config
            // decision rather than the model's to make.
            if let (server, tool) = MCPProtocol.split(qualified: call.name),
               AssistantExecutor.shared.mcp.connectedNames.contains(server) {
                let action = AssistantAction.mcpCall(
                    server: server, tool: tool, arguments: call.rawArguments,
                    trusted: AssistantExecutor.shared.mcp.isTrusted(server: server))
                if action.needsConfirmation {
                    pending = (action: action, callId: call.id, collected: results,
                               remaining: Array(calls.dropFirst(index + 1)))
                    return .needsConfirmation(action,
                                              summary: action.confirmationSummary ?? "Confirm this step")
                }
                let (result, ok) = await AssistantExecutor.executeAwaiting(action)
                onProgress?("Ran \(tool) on \(server)")
                results.append((id: call.id, text: result, isError: !ok))
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
            if action.needsConfirmation {
                pending = (action: action, callId: call.id, collected: results,
                           remaining: Array(calls.dropFirst(index + 1)))
                let summary = action.confirmationSummary ?? "Confirm this step"
                return .needsConfirmation(action, summary: summary)
            }
            let (result, ok) = await AssistantExecutor.executeAwaiting(action)
            onProgress?(result)
            results.append((id: call.id, text: result, isError: !ok))
        }
        conversation.record(results: results)
        return nil
    }
}
