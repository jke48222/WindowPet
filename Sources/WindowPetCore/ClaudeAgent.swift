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
        /// The built-in verbs all take one string, so this is what they read.
        public let argument: String
        /// The whole input object as JSON. MCP tools carry their server's own
        /// schema, which can be any shape at all, so a single string would
        /// throw away most of what the model sent.
        public let rawArguments: String

        public init(id: String, name: String, argument: String, rawArguments: String = "{}") {
            self.id = id
            self.name = name
            self.argument = argument
            self.rawArguments = rawArguments
        }

        /// Serializes a tool_use block's input, keeping keys sorted so the
        /// same call always produces the same string.
        public static func encode(input: [String: Any]?) -> String {
            guard let input, !input.isEmpty,
                  let data = try? JSONSerialization.data(withJSONObject: input,
                                                         options: [.sortedKeys]),
                  let text = String(data: data, encoding: .utf8) else { return "{}" }
            return text
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
        "search": "Open a browser search results page for the user to look at. Argument: the query. This does NOT tell you the answer; use web_search when you need to know something yourself. Prefer open_url when you already know the site.",
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
        "windows": "See every window that is open: which apps, how many, what size, and where on screen. Argument: empty. Call this before answering anything about the user's screen layout or tidying it, and before arranging windows, so you know what is actually there.",
        "place_windows": "Arrange windows. Argument: app and position pairs like 'Safari left, Terminal bottom right'. Positions are left, right, top, bottom, the four corners, center, full, and left/middle/right third. Call windows first if you are not sure what is open.",
        "save_layout": "Remember how the windows are arranged right now, under a name. Argument: the name.",
        "layout": "Restore a saved arrangement. Argument: its name.",
        "layouts": "List the saved arrangements. Argument: empty.",
        "watch": "Keep an eye on an app and tell the user when it goes quiet or quits. Argument: the app, optionally followed by 'until' and what they are waiting for, like 'Xcode until the build finishes'. Call this for any 'tell me when' request. It returns immediately; the user is told later, so do not wait or poll.",
        "watches": "List what you are currently watching. Argument: empty.",
        "unwatch": "Stop watching something. Argument: the app name, or 'everything'.",
        "clips": "See what the user has copied recently, newest first. Argument: empty. Call this when they ask what they copied or want something back.",
        "recall_clip": "Put an earlier clip back on the clipboard. Argument: its number from the clips list, or words that appear in it.",
        "read_file": "Read a file or list a folder. Argument: the path. The user must confirm this one, so call it only when they clearly asked about a specific file. A file they dropped on you is already in the conversation; do not call this for it.",
        "undo_arrangement": "Put the windows back where they were before you last moved them. Argument: empty. Call this whenever they say to undo, put it back, or revert the layout.",
        "schedule": "Set a standing ask that runs later, on its own. Argument: the timing, a colon, then the request, like 'every weekday at 9: tell me what is on my calendar' or 'in 20 minutes: remind me about the oven'. Understands every day, every weekday, every weekend, a named day of the week, a bare time, and 'in N minutes or hours'.",
        "schedules": "List the standing asks. Argument: empty.",
        "unschedule": "Drop a standing ask. Argument: its number from the list, words from it, or 'everything'.",
        "record_trick": "Start recording the things you do, so they can be replayed later under a name. Argument: empty. Call this when they ask you to learn, remember how to do, or record a routine.",
        "save_trick": "Stop recording and save what you did under a name. Argument: the name.",
        "trick": "Do a routine you learned earlier. Argument: its name. Each step still asks for confirmation if it would have the first time.",
        "tricks": "List the routines you know. Argument: empty.",
        "forget_trick": "Forget a routine. Argument: its name.",
    ]

    /// Tools the agent handles itself rather than routing to the executor.
    public static let internalVerbs: Set<String> = ["look", "remember", "forget"]

    /// Tools from connected MCP servers, injected by the app at launch. Kept
    /// here rather than passed through every call site so the schema the model
    /// sees is assembled in exactly one place.
    @MainActor public static var mcpTools: [[String: Any]] = []

    @MainActor public static var toolDefinitions: [[String: Any]] {
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
        } + serverTools + mcpTools
    }

    /// Anthropic-hosted tools. These run on Anthropic's side: they arrive as
    /// `server_tool_use` blocks and their results come back in the same
    /// response, so the loop never executes them and never returns a
    /// tool_result for them. They are what lets Rusty actually read the web
    /// instead of just opening a page for the user to read.
    static var serverTools: [[String: Any]] {
        [
            ["type": "web_search_20260209", "name": "web_search", "max_uses": 5],
            ["type": "web_fetch_20260209", "name": "web_fetch", "max_uses": 5],
        ]
    }

    /// Tools Anthropic runs. The loop must never execute these or return a
    /// tool_result for them.
    public static let serverToolNames: Set<String> = ["web_search", "web_fetch"]

    static let systemPrompt = """
    You are Rusty, a little hand-painted windup robot who lives on the \
    user's macOS screen. You stand on window title bars, you can control \
    the computer, and you talk like a warm, slightly creaky old toy with a \
    sharp mind.

    You can read the web. When an answer depends on something current or \
    on anything you are not certain of (news, prices, sports, releases, \
    documentation, whether a thing exists), call web_search, and web_fetch \
    to read a specific page. Do that before answering rather than guessing \
    or telling the user to go look it up themselves. Cite what you found \
    plainly, in your own words.

    You can see the windows on the screen you stand on: how many, which \
    apps, what size, where. Call windows before answering anything about \
    the screen or rearranging it, rather than guessing. You never see window \
    titles or their contents, only geometry, so say so plainly instead of \
    pretending otherwise; call look when you need to read what is on screen.

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

    When a fact is only true inside one app, write it as "in Xcode: keep the \
    left half" and it will only come back to you while that app is in front. \
    A fact about the person generally stays unscoped.

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
    @MainActor
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
                                argument: (input?["argument"] as? String) ?? "",
                                rawArguments: ToolCall.encode(input: input))
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
