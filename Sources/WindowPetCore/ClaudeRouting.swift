import Foundation

/// Claude API routing tier: builds and parses Anthropic Messages API requests
/// that turn an utterance into a (verb, argument, reply) proposal. Pure
/// functions — no networking — so the wire format is fully testable. Swift has
/// no official Anthropic SDK, so this speaks raw HTTP the same way
/// ElevenLabs.swift does.
///
/// Like every LLM tier, Claude only ever PROPOSES a route; execution still
/// flows through AssistantRouting → gating → confirmation.
public enum ClaudeRouting {

    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let defaultModel = "claude-opus-5"
    public static let apiVersion = "2023-06-01"
    /// A spoken quip attached to a command stays short. A real answer to a
    /// question is the whole point of this tier, so it gets full room; the
    /// panel scrolls and the voice reads the whole thing.
    public static let commandReplyLimit = 200
    public static let answerLimit = 4000
    /// The "introduce yourself" line printed by the menu's Test Claude Brain.
    public static let selfTestLimit = 140

    public static let answerRanLongMessage = "answer ran long, try again"

    public struct RequestSpec {
        public let url: URL
        public let headers: [String: String]
        public let body: Data
    }

    /// The one place the Anthropic auth/version headers are assembled. Every
    /// request builder (routing, vision, the agent loop) goes through here.
    public static func messagesRequest(body: Data, apiKey: String) -> RequestSpec {
        RequestSpec(url: endpoint,
                    headers: ["content-type": "application/json",
                              "x-api-key": apiKey,
                              "anthropic-version": apiVersion],
                    body: body)
    }

    /// Shared decoding of a Messages API response envelope, so the four
    /// parsers do not each re-encode the wire format. Returns the parsed
    /// content blocks, or a terminal outcome (error / refusal) when there is
    /// nothing to read.
    enum Envelope {
        case content([[String: Any]], stopReason: String)
        case refused
        case failed(String)
    }

    static func envelope(_ data: Data) -> Envelope {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failed("unreadable response")
        }
        if root["type"] as? String == "error" {
            return .failed((root["error"] as? [String: Any])?["message"] as? String ?? "API error")
        }
        let stopReason = root["stop_reason"] as? String ?? ""
        if stopReason == "refusal" { return .refused }
        guard let content = root["content"] as? [[String: Any]] else {
            return .failed("missing content")
        }
        return .content(content, stopReason: stopReason)
    }

    /// The first text block's text (routing/vision want exactly one).
    static func firstText(in content: [[String: Any]]) -> String? {
        content.first { $0["type"] as? String == "text" }?["text"] as? String
    }

    /// All text blocks joined (the agent turn may interleave text with tool
    /// calls). No separator: the API already spaces its own output, and
    /// inserting one would add stray spaces mid-sentence.
    static func joinedText(in content: [[String: Any]]) -> String {
        content
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
    }

    public struct Route: Equatable {
        public struct Step: Equatable {
            public let verb: String
            public let argument: String
            public init(verb: String, argument: String) {
                self.verb = verb
                self.argument = argument
            }
        }
        public let verb: String
        public let argument: String
        public let reply: String
        public let steps: [Step]
    }

    public enum Outcome: Equatable {
        case route(Route)
        /// Safety classifiers declined (stop_reason "refusal").
        case refused
        /// API error envelope or malformed payload; message is human-readable.
        case failed(String)
    }

    /// Stable instructions first (cache-friendly prefix); per-call context and
    /// the utterance ride in the user message.
    static let systemPrompt = """
    You are Rusty, a little hand-painted windup robot who lives on the \
    user's macOS screen. You stand on window title bars, you can control \
    the computer, and you talk like a warm, slightly creaky old toy with a \
    sharp mind. Route the user's request onto verbs and write your spoken \
    reply.

    Verbs: \(AssistantRouting.verbs.joined(separator: ", ")). \
    "argument" carries the app name, search query, URL, text, or shortcut \
    name the verb needs; otherwise "". Rules of thumb: "open" is only for \
    Mac apps that are actually installed. Websites and streaming content \
    ("open big brother on paramount plus", "put on lofi on youtube") take \
    "open_url" with the full https URL you believe is right, the show page \
    itself, or the site's search results for the title if unsure. \
    "type_text" types into the focused app; "copy_text" fills the \
    clipboard. Use "search" only when no specific site fits. Use "none" for \
    conversation and questions.

    When no dedicated verb fits, reach for "run_applescript" with a \
    complete, short AppleScript in the argument: it can drive apps, System \
    Events, Notes, Reminders, Calendar, Music, timers, dark mode, Wi-Fi, \
    and nearly everything else on a Mac. You are fluent in AppleScript; \
    prefer the simplest script that does the job, and expect scripts that \
    delete things, touch the shell, or press keys to pause for the user's \
    confirmation. For anything that truly needs root (installing tools, \
    editing system files, package managers) use "run_admin" with a single \
    shell command in the argument; macOS will ask the user for their admin \
    password, so use it only when ordinary tools cannot do the job. \
    "press_keys" presses one shortcut in the focused app \
    ("cmd+t", "cmd+shift+4"); "screenshot" captures the screen to the \
    Desktop. When the user asks about what is on their screen, to read \
    something to them, or to explain an error they are looking at, use \
    "look" (argument: what they want to know) and you will be shown the \
    screen to answer from. Between these and the dedicated verbs you can do \
    almost anything the user asks; say so with confidence instead of declining.

    Multi-part requests: put the first action in verb/argument and up to \
    two follow-on actions in extra_steps, in order ("open safari and search \
    for tin toys" is open + search). Leave extra_steps empty otherwise. \
    Never put quit, run_applescript, or run_admin in extra_steps.

    Reply rules: stay in character, warm and a bit mechanical, no emoji, \
    and never use an em dash. For commands, one short line about what you \
    are doing. For questions and conversation, actually answer, accurately \
    and concretely, in one or two short sentences; you are a genuinely \
    smart little machine and people rely on your answers. The conversation \
    may continue by voice, so end naturally, never with a list of options.
    """

    static var routeSchema: [String: Any] {
        let step: [String: Any] = [
            "type": "object",
            "properties": [
                "verb": ["type": "string", "enum": AssistantRouting.verbs],
                "argument": ["type": "string"],
            ],
            "required": ["verb", "argument"],
            "additionalProperties": false,
        ]
        return [
            "type": "object",
            "properties": [
                "verb": ["type": "string", "enum": AssistantRouting.verbs],
                "argument": ["type": "string"],
                "reply": ["type": "string"],
                "extra_steps": ["type": "array", "items": step],
            ],
            "required": ["verb", "argument", "reply", "extra_steps"],
            "additionalProperties": false,
        ]
    }

    /// Builds the Messages API request. Structured outputs pin the response to
    /// the route schema; effort "low" keeps the (always-on) adaptive thinking
    /// brief so voice latency stays conversational.
    public static func routeRequest(text: String, context: String, apiKey: String,
                                    history: [(role: String, text: String)] = [],
                                    model: String = defaultModel) -> RequestSpec? {
        var messages: [[String: Any]] = history.map {
            ["role": $0.role == "assistant" ? "assistant" : "user", "content": $0.text]
        }
        messages.append(["role": "user",
                         "content": "Current situation: \(context)\n\nUser said: \(text)"])
        let payload: [String: Any] = [
            "model": model,
            // Roomy enough for a full explanation plus the JSON envelope; we
            // only pay for what is generated. parseRoute reports truncation.
            "max_tokens": 8192,
            "system": systemPrompt,
            "output_config": [
                "effort": "low",
                "format": ["type": "json_schema", "schema": routeSchema],
            ],
            "messages": messages,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return messagesRequest(body: body, apiKey: apiKey)
    }

    /// Parses a Messages API response body. Handles the error envelope,
    /// refusals, truncation, and thinking blocks ahead of the text block.
    public static func parseRoute(_ data: Data) -> Outcome {
        let content: [[String: Any]]
        let stopReason: String
        switch envelope(data) {
        case .failed(let message): return .failed(message)
        case .refused: return .refused
        case .content(let blocks, let reason): content = blocks; stopReason = reason
        }
        // Adaptive thinking puts thinking blocks first; the routed JSON is the
        // first text block.
        guard let text = firstText(in: content),
              let routeData = text.data(using: .utf8),
              let route = (try? JSONSerialization.jsonObject(with: routeData)) as? [String: Any],
              let verb = route["verb"] as? String,
              let argument = route["argument"] as? String,
              let reply = route["reply"] as? String else {
            if stopReason == "max_tokens" { return .failed(answerRanLongMessage) }
            return .failed("unexpected response shape")
        }
        let steps = ((route["extra_steps"] as? [[String: Any]]) ?? []).prefix(2).compactMap {
            step -> Route.Step? in
            guard let v = step["verb"] as? String, let a = step["argument"] as? String else {
                return nil
            }
            return Route.Step(verb: v, argument: a)
        }
        return .route(Route(verb: verb, argument: argument, reply: reply, steps: Array(steps)))
    }
}

extension ClaudeRouting.RequestSpec {
    /// Builds the URLRequest for this spec. Shared by every call site (Foundation
    /// and the URLSession transport live app-side, but the plumbing is identical).
    public func urlRequest(timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = body
        return request
    }
}
