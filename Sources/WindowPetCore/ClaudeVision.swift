import Foundation

/// Screen sight: builds and parses the Anthropic Messages API request that
/// sends a screenshot plus the user's question and gets back a plain-text
/// answer. Same raw-HTTP approach as ClaudeRouting (no Swift SDK exists).
/// Read-only by nature, so nothing here gates or executes; the brain just
/// speaks the answer.
extension ClaudeRouting {

    public enum TextResult: Equatable {
        case text(String)
        case refused
        case failed(String)
    }

    static let visionSystemPrompt = """
    You are Rusty, a little windup robot assistant looking at the user's Mac \
    screen for them. Answer their question about what is on screen: read \
    text back, explain errors, summarize, or point out what they need. Be \
    accurate and concrete, warm and a bit mechanical, no emoji, never an em \
    dash. Keep it to what they asked; the answer may be read aloud, so end \
    naturally.
    """

    /// `imageBase64` is a base64 PNG of the screen (no data: prefix, no
    /// newlines). No structured output here, the reply is prose.
    public static func visionRequest(question: String, imageBase64: String,
                                     apiKey: String,
                                     model: String = defaultModel) -> RequestSpec? {
        let prompt = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let asked = prompt.isEmpty ? "What is on my screen right now?" : prompt
        let payload: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": visionSystemPrompt,
            "output_config": ["effort": "low"],
            "messages": [
                ["role": "user", "content": [
                    ["type": "image",
                     "source": ["type": "base64", "media_type": "image/png",
                                "data": imageBase64]],
                    ["type": "text", "text": "The user asked: \(asked)"],
                ]],
            ],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return messagesRequest(body: body, apiKey: apiKey)
    }

    /// Pulls the first text block out of a Messages API response, handling
    /// the error envelope, refusals, and thinking-blocks-first ordering.
    public static func parseText(_ data: Data) -> TextResult {
        switch envelope(data) {
        case .failed(let message): return .failed(message)
        case .refused: return .refused
        case .content(let content, _):
            guard let text = firstText(in: content), !text.isEmpty else {
                return .failed("no answer came back")
            }
            return .text(text)
        }
    }
}
