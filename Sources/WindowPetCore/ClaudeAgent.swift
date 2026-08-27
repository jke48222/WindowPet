import Foundation

/// The agentic loop: real Anthropic tool use, where Claude calls a tool, sees
/// the result, and decides the next move, instead of guessing a whole plan up
/// front. Pure request-building and parsing (Swift has no Anthropic SDK, so
/// this is the manual loop over raw HTTP); the executing side lives app-side.
///
/// Every tool is one verb from AssistantRouting with a single `argument`
/// string, so tool calls land on the SAME gated AssistantActions typed
/// commands use. Claude proposes, the gate disposes: nothing here can skip a
/// confirmation.
public enum ClaudeAgent {

    public static let maxIterations = 8

    public struct ToolCall: Equatable {
        public let id: String
        public let name: String
        public let argument: String
        public init(id: String, name: String, argument: String) {
            self.id = id
            self.name = name
            self.argument = argument
        }
    }

    public struct Turn: Equatable {
        public let text: String
        public let calls: [ToolCall]
        /// Verbatim assistant content, echoed back on the next request. Must
        /// not be edited: thinking blocks carry signatures the API checks.
        public let rawContent: [[String: Any]]
        public let stopReason: String

        public static func == (a: Turn, b: Turn) -> Bool {
            a.text == b.text && a.calls == b.calls && a.stopReason == b.stopReason
        }
    }

    public enum TurnResult: Equatable {
        case turn(Turn)
        case refused
        case failed(String)
    }

    /// When to reach for each verb. These descriptions are the model's only
    /// guide at call time, so they say *when*, not just what.
    static let toolGuide: [String: String] = [
        "open": "Open an installed Mac app by name. Argument: the app name. Only for apps that exist on this Mac; use open_url for websites.",
        "switch": "Bring an already-running app to the front. Argument: the app name.",
        "hide": "Hide a running app. Argument: the app name.",
        "quit": "Quit an app. Argument: the app name. The user must confirm this one, so call it only when they clearly asked.",
        "window_left": "Snap the frontmost window to the left half of the screen. Argument: empty.",
        "window_right": "Snap the frontmost window to the right half. Argument: empty.",
        "maximize": "Fill the screen with the frontmost window. Argument: empty.",
        "center": "Center the frontmost window. Argument: empty.",
        "volume_up": "Raise the system volume. Argument: empty.",
        "volume_down": "Lower the system volume. Argument: empty.",
        "mute": "Mute system audio. Argument: empty.",
        "unmute": "Unmute system audio. Argument: empty.",
        "play_pause": "Play or pause the current media. Argument: empty.",
        "next": "Skip to the next track. Argument: empty.",
        "previous": "Go to the previous track. Argument: empty.",
        "search": "Search the web in the browser. Argument: the query. Use only when no specific site fits; prefer open_url when you know the site.",
        "open_url": "Open a web page. Argument: a full https URL. Use for websites and streaming content, including a show's page or a site's search results.",
        "type_text": "Type text into whatever app is focused. Argument: the text.",
        "copy_text": "Put text on the clipboard. Argument: the text.",
        "press_keys": "Press one keyboard shortcut in the focused app. Argument: the combo, like cmd+t or cmd+shift+4.",
        "screenshot": "Save a screenshot to the Desktop. Argument: empty. Call this when the user wants a file; call look when you need to SEE the screen yourself.",
        "look": "Look at the user's screen and answer a question about it. Argument: what you want to know. Call this whenever the answer depends on what is on screen right now, including reading text, diagnosing an error, or checking whether an earlier step worked.",
        "run_applescript": "Run a short AppleScript. Argument: the script. This is the catch-all for anything the other tools cannot do: Notes, Reminders, Calendar, Music, System Events, timers, dark mode, and reading app state. Scripts that delete things or touch the shell need the user to confirm.",
        "run_admin": "Run one shell command as an administrator. Argument: the command. macOS asks the user for their password, so use it only when a task genuinely needs root.",
        "shortcut": "Run a Shortcuts automation by name. Argument: the shortcut name.",
        "remember": "Save a durable fact about this person for future conversations. Argument: the fact, in your own words ('prefers Safari over Chrome'). Call this when they tell you a preference, a name, a workflow, or how they want things done. Do not save secrets, passwords, or anything they would not want written to disk.",
        "forget": "Remove remembered facts. Argument: words identifying what to drop, or 'everything' to clear it all. Call this when they ask you to forget something.",
    ]

    /// Tools the agent handles itself rather than routing to the executor.
    public static let internalVerbs: Set<String> = ["look", "remember", "forget"]

    public static var toolDefinitions: [[String: Any]] {
        AssistantRouting.verbs.filter { $0 != "none" }.map { verb in
            [
                "name": verb,
                "description": toolGuide[verb] ?? "Perform the \(verb) action.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "argument": [
                            "type": "string",
                            "description": "The tool's input, or an empty string when it takes none.",
                        ],
                    ],
                    "required": ["argument"],
                ],
            ]
        }
    }

    static let systemPrompt = """
    You are Rusty, a little hand-painted windup robot who lives on the \
    user's macOS screen. You stand on window title bars, you can control \
    the computer, and you talk like a warm, slightly creaky old toy with a \
    sharp mind.

    You work by calling tools, one step at a time. After each tool you see \
    the result, so check it and adapt: if an app was not found, try the web \
    instead; if you need to know what is on screen, call look; if a step \
    failed, say so plainly rather than pretending it worked. Keep going \
    until the request is actually done, then stop and answer.

    Prefer the smallest number of steps that finishes the job. Do not call \
    a tool when you already know the answer, and do not repeat a tool that \
    just failed the same way. When the user only asked a question, just \
    answer it.

    You keep memory between conversations. When they tell you something \
    worth knowing later, a preference, a name, how they like something done, \
    call remember with it in your own words. Never save secrets, passwords, \
    or keys. Use what you already remember naturally, without announcing \
    that you are remembering, and call forget when they ask you to drop \
    something.

    Voice: warm, a bit mechanical, no emoji, and never an em dash. When you \
    are done, reply in one or two short sentences for an action, or a full \
    accurate answer for a question. Your reply may be read aloud, so end \
    naturally and never list options.
    """

    /// Builds one turn of the loop. `messages` is the running conversation
    /// (user turns, assistant echoes, and tool_result turns).
    ///
    /// The system prompt and tool definitions are identical on every
    /// iteration, so a cache breakpoint on the system block makes the whole
    /// tools+system prefix a cache read after the first call. Effort is
    /// "medium": the agent loop wants better judgment than one-shot routing,
    /// while a desktop assistant still has to feel quick.
    public static func agentRequest(messages: [[String: Any]], apiKey: String,
                                    model: String = ClaudeRouting.defaultModel,
                                    stream: Bool = false) -> ClaudeRouting.RequestSpec? {
        var payload: [String: Any] = [
            "model": model,
            "max_tokens": 8192,
            "system": [[
                "type": "text",
                "text": systemPrompt,
                "cache_control": ["type": "ephemeral"],
            ]],
            "tools": toolDefinitions,
            "output_config": ["effort": "medium"],
            "messages": messages,
        ]
        if stream { payload["stream"] = true }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return ClaudeRouting.messagesRequest(body: body, apiKey: apiKey)
    }

    public static func parseTurn(_ data: Data) -> TurnResult {
        switch ClaudeRouting.envelope(data) {
        case .failed(let message): return .failed(message)
        case .refused: return .refused
        case .content(let content, let stopReason):
            let calls: [ToolCall] = content.compactMap { block in
                guard block["type"] as? String == "tool_use",
                      let id = block["id"] as? String,
                      let name = block["name"] as? String else { return nil }
                let input = block["input"] as? [String: Any]
                return ToolCall(id: id, name: name,
                                argument: (input?["argument"] as? String) ?? "")
            }
            return resolveTurn(text: ClaudeRouting.joinedText(in: content), calls: calls,
                               rawContent: content, stopReason: stopReason)
        }
    }

    /// The one terminal decision shared by the buffered parser and the
    /// streaming accumulator: given an assembled turn, either fail on empty
    /// truncation or hand back the Turn.
    public static func resolveTurn(text: String, calls: [ToolCall],
                                   rawContent: [[String: Any]], stopReason: String) -> TurnResult {
        if stopReason == "max_tokens", calls.isEmpty, text.isEmpty {
            return .failed(ClaudeRouting.answerRanLongMessage)
        }
        return .turn(Turn(text: text, calls: calls, rawContent: rawContent, stopReason: stopReason))
    }

    // MARK: message builders

    public static func userMessage(_ text: String) -> [String: Any] {
        ["role": "user", "content": text]
    }

    /// Echoes the assistant turn back verbatim (thinking blocks included).
    public static func assistantEcho(_ rawContent: [[String: Any]]) -> [String: Any] {
        ["role": "assistant", "content": rawContent]
    }

    /// Every tool_result for a turn rides in ONE user message; splitting them
    /// teaches the model to stop calling tools in parallel.
    public static func toolResultMessage(_ results: [(id: String, text: String, isError: Bool)]) -> [String: Any] {
        let blocks: [[String: Any]] = results.map { result in
            var block: [String: Any] = [
                "type": "tool_result",
                "tool_use_id": result.id,
                "content": result.text.isEmpty ? "done" : result.text,
            ]
            if result.isError { block["is_error"] = true }
            return block
        }
        return ["role": "user", "content": blocks]
    }
}
