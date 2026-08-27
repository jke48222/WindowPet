import Foundation

/// The agentic loop's decision table and running conversation, lifted out of
/// the app so a whole multi-turn exchange can be replayed in tests with canned
/// API responses: no network, no window server, no AppKit.
///
/// The app keeps what only it can do (HTTP, executing tools, asking the user),
/// and this owns what must be exactly right every time: when to stop, what to
/// echo back, and the shape of the messages array.
public enum AgentLoop {

    /// What to do with a turn that just came back.
    public enum Decision: Equatable {
        /// The model is done. Carries the answer, already trimmed to length.
        case answer(String)
        /// A server-side tool paused mid-turn. Send the conversation back as
        /// it stands, with no tool_result, and Anthropic resumes it.
        case resend
        /// Local tools to run, in order. Every result rides back in ONE user
        /// message; splitting them teaches the model to stop batching calls.
        case execute([ClaudeAgent.ToolCall])
        /// Stop and say why.
        case stop(String)
    }

    /// `lastText` is the most recent non-empty text from earlier in the loop,
    /// so a final turn that carries only tool calls still has something to say.
    public static func decide(_ result: ClaudeAgent.TurnResult, lastText: String) -> Decision {
        switch result {
        case .refused:
            return .answer("That one is outside what I can help with.")
        case .failed(let message):
            return .stop("Claude call failed: \(message)")
        case .turn(let turn):
            if turn.stopReason == "pause_turn" { return .resend }
            if turn.calls.isEmpty {
                let text = turn.text.isEmpty ? lastText : turn.text
                return .answer(AssistantRouting.sanitizeReply(text, limit: ClaudeRouting.answerLimit))
            }
            return .execute(turn.calls)
        }
    }

    /// What Rusty says when the iteration cap stops the loop: whatever he last
    /// managed to say, or an honest admission, never silence.
    public static func exhaustedAnswer(lastText: String) -> String {
        let tail = lastText.isEmpty
            ? "I took several steps but couldn't finish that one."
            : lastText
        return AssistantRouting.sanitizeReply(tail, limit: ClaudeRouting.answerLimit)
    }
}

/// The running message array for one conversation, including the iteration
/// budget. A value type on purpose: a turn either advances it or it does not,
/// with no half-applied state to reason about.
public struct AgentConversation {

    public private(set) var messages: [[String: Any]] = []
    public private(set) var iterations = 0
    /// The most recent non-empty assistant text, used when the closing turn
    /// spends all its tokens on tool calls.
    public private(set) var lastText = ""

    /// `history` is the panel's own transcript, replayed so the model sees the
    /// conversation the user sees.
    public init(history: [(role: String, text: String)] = []) {
        messages = history.map {
            ["role": $0.role == "assistant" ? "assistant" : "user", "content": $0.text]
        }
    }

    /// Opens the turn. The situation line rides with the request so the model
    /// knows what is on screen and what it already remembers.
    public mutating func ask(_ text: String, situation: String) {
        messages.append(ClaudeAgent.userMessage(
            "Current situation: \(situation)\n\nUser said: \(text)"))
    }

    /// True while there is iteration budget left. Called once per model call,
    /// so the count reflects requests actually made.
    public mutating func beginIteration(cap: Int = ClaudeAgent.maxIterations) -> Bool {
        guard iterations < cap else { return false }
        iterations += 1
        return true
    }

    /// Echoes the assistant turn back verbatim. Never edit `rawContent`:
    /// thinking blocks carry signatures the API validates on replay, and
    /// server tool results must survive exactly as sent.
    public mutating func record(_ turn: ClaudeAgent.Turn) {
        if !turn.text.isEmpty { lastText = turn.text }
        messages.append(ClaudeAgent.assistantEcho(turn.rawContent))
    }

    public mutating func record(results: [(id: String, text: String, isError: Bool)]) {
        messages.append(ClaudeAgent.toolResultMessage(results))
    }
}
