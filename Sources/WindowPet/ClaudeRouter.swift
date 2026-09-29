import Foundation
import WindowPetCore

/// Cloud brain: routes utterances through the Anthropic Messages API
/// (claude-opus-5). Sits between the free grammar and the on-device model in
/// AssistantBrain's chain — used only when a key is configured. Key sources:
/// the login Keychain (set from the menu, see SecretStore) or the
/// ANTHROPIC_API_KEY environment variable, mirroring ElevenLabsTTS.
enum ClaudeRouter {

    enum RouterError: Error {
        case unauthorized
        case refused
        case failed(String)
        /// The daily spend ceiling stopped the call. Carries the sentence to
        /// show the user, so no caller has to reconstruct it.
        case overBudget(String)
        /// Anthropic answered with a non-retryable error (billing, unknown
        /// model, request too large). Carries the sentence to show, because
        /// quietly falling back to another tier would hide the fix.
        case api(String)
    }

    static var apiKey: String? {
        if let k = SecretStore.read(.anthropic) { return k }
        if let k = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !k.isEmpty { return k }
        return nil
    }

    static var isConfigured: Bool { apiKey != nil }

    static var model: String {
        UserDefaults.standard.string(forKey: "anthropicModel") ?? ClaudeRouting.defaultModel
    }

    /// One live round trip so the user can verify the brain from the menu.
    static func selfTest() async -> String {
        guard isConfigured else {
            return "No Anthropic key set. Add one under Anthropic API Key… in the menu bar."
        }
        do {
            let route = try await route("Introduce yourself in one short sentence.",
                                        context: "self test from the menu", history: [])
            let reply = AssistantRouting.sanitizeReply(route.reply, limit: ClaudeRouting.selfTestLimit)
            return "Claude brain is working (\(model)). Rusty says: \(reply)"
        } catch RouterError.unauthorized {
            return "The API key was rejected. Paste a fresh one under Anthropic API Key…"
        } catch RouterError.refused {
            return "Claude declined the test request, but the key and connection work."
        } catch RouterError.overBudget(let message) {
            return message
        } catch RouterError.api(let message) {
            return message
        } catch RouterError.failed(let message) {
            return "Claude call failed: \(message)"
        } catch {
            return "Couldn't reach Anthropic: \(error.localizedDescription)"
        }
    }

    static func route(_ text: String, context: String,
                      history: [(role: String, text: String)] = []) async throws
        -> ClaudeRouting.Route {
        if let blocked = await UsageMeter.shared.blockedMessage {
            throw RouterError.overBudget(blocked)
        }
        let model = self.model
        guard let key = apiKey,
              let spec = ClaudeRouting.routeRequest(text: text, context: context,
                                                    apiKey: key, history: history,
                                                    model: model) else {
            throw RouterError.failed("not configured")
        }
        let (data, status) = try await AnthropicHTTP.send(spec.urlRequest(timeout: 30))
        if status == 401 { throw RouterError.unauthorized }
        guard (200..<300).contains(status) else {
            throw RouterError.api(AnthropicHTTP.explain(status: status, body: data, model: model))
        }
        await AnthropicHTTP.meter(body: data, model: model)
        switch ClaudeRouting.parseRoute(data) {
        case .route(let route):
            return route
        case .refused:
            throw RouterError.refused
        case .failed(let message):
            throw RouterError.failed(message)
        }
    }

    /// Screen sight: capture the screen, downscale it, and ask Claude the
    /// user's question about it. Returns a spoken answer (or an honest
    /// explanation of what went wrong). Read-only, so no gating.
    static func look(question: String) async -> String {
        if let blocked = await UsageMeter.shared.blockedMessage { return blocked }
        guard let key = apiKey else {
            return "I need the Claude brain to see the screen. Add an Anthropic API key in the menu bar."
        }
        guard let base64 = ScreenCapture.snapshotBase64() else {
            return "I couldn't grab the screen. Turn on Screen Recording for WindowPet in System Settings, Privacy and Security, then ask again."
        }
        let model = self.model
        guard let spec = ClaudeRouting.visionRequest(question: question, imageBase64: base64,
                                                      apiKey: key, model: model) else {
            return "Something went wrong preparing the screen image."
        }
        do {
            let (data, status) = try await AnthropicHTTP.send(spec.urlRequest(timeout: 45))
            if status == 401 {
                return "The API key was rejected. Paste a fresh one under Anthropic API Key."
            }
            guard (200..<300).contains(status) else {
                return "I couldn't read the screen. "
                    + AnthropicHTTP.explain(status: status, body: data, model: model)
            }
            // A screenshot is thousands of input tokens: it counts toward the
            // daily ceiling like every other call.
            await AnthropicHTTP.meter(body: data, model: model)
            switch ClaudeRouting.parseText(data) {
            case .text(let answer):
                return AssistantRouting.sanitizeReply(answer, limit: ClaudeRouting.answerLimit)
            case .refused:
                return "I'd rather not weigh in on what's on screen there."
            case .failed(let message):
                return "I couldn't read the screen: \(message)"
            }
        } catch is CancellationError {
            return "Stopped before I looked."
        } catch {
            return "I couldn't reach Anthropic to look: \(error.localizedDescription)"
        }
    }
}

/// The HTTP rules every Anthropic call follows, in one place: which statuses
/// retry and for how long, and how an error body turns into a sentence a
/// person can act on. Shared by the router, the vision call and the streamed
/// agent loop, so the three can never disagree.
enum AnthropicHTTP {

    /// Attempts in total, including the first.
    static let maxAttempts = 4
    /// Longest single wait. A server asking for more than this is better
    /// reported than waited on with the panel saying "Thinking…".
    static let maxWait: TimeInterval = 30

    /// Rate limits, overload (529), server errors, timeouts and conflicts
    /// retry. Every other 4xx is a request that will fail the same way again.
    static func isRetryable(status: Int) -> Bool {
        status == 408 || status == 409 || status == 429 || (500...599).contains(status)
    }

    /// Transport failures worth another try: the connection dropped or timed
    /// out. A cancelled request is the user stopping, never retried.
    static func isRetryable(error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost,
             .notConnectedToInternet, .dnsLookupFailed, .cannotFindHost,
             .secureConnectionFailed, .badServerResponse:
            return true
        default:
            return false
        }
    }

    /// Seconds to wait before attempt `attempt + 1`, or nil to stop retrying.
    /// Exponential backoff (1, 2, 4 s) with a little jitter, never shorter
    /// than the server's own `retry-after`, and nil when that asks for more
    /// than `maxWait`.
    static func retryDelay(attempt: Int, retryAfter: String?,
                           jitter: Double = Double.random(in: 0...0.25)) -> TimeInterval? {
        guard attempt < maxAttempts else { return nil }
        let backoff = pow(2, Double(max(0, attempt - 1))) + jitter
        let asked = retryAfter.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } ?? 0
        if asked > maxWait { return nil }
        return min(maxWait, max(backoff, asked))
    }

    /// `error.type` and `error.message` from an Anthropic error body.
    static func apiError(in body: Data) -> (type: String?, message: String?) {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let error = root["error"] as? [String: Any] else { return (nil, nil) }
        return (error["type"] as? String, error["message"] as? String)
    }

    /// A sentence for a failed call that says what to do about it.
    static func explain(status: Int, body: Data, model: String) -> String {
        let (type, rawMessage) = apiError(in: body)
        let message = rawMessage.map { String($0.prefix(240)) }
        let detail = message.map { " (\($0))" } ?? ""
        switch status {
        case 400:
            if let message, message.lowercased().contains("credit balance") {
                return "Your Anthropic credit balance is too low. Add credit in the Anthropic Console, then ask again."
            }
            return "Anthropic rejected the request\(detail)."
        case 401:
            return "Anthropic rejected the API key. Fix it under Anthropic API Key in the menu bar."
        case 402:
            return "Anthropic reports a billing problem on this account\(detail). Check Plans and Billing in the Anthropic Console."
        case 403:
            return "This API key is not allowed to do that\(detail)."
        case 404:
            if type == "not_found_error" || message?.lowercased().contains("model") == true {
                return "Anthropic does not recognise the model \(model). Check the anthropicModel setting, or delete it to use the default."
            }
            return "Anthropic could not find that\(detail)."
        case 413:
            return "That request was too large for Claude. Try a shorter question or a smaller file."
        case 429:
            return "Anthropic is rate limiting this key right now. Try again in a moment."
        case 500...599:
            return "Anthropic is busy right now. Try again in a moment."
        default:
            return "Anthropic returned an error \(status)\(detail)."
        }
    }

    /// One non-streaming request with the retry policy applied. Returns the
    /// final body and status; the caller decides what a non-2xx means.
    static func send(_ request: URLRequest) async throws -> (Data, Int) {
        var attempt = 0
        while true {
            attempt += 1
            try Task.checkCancellation()
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let http = response as? HTTPURLResponse
                let status = http?.statusCode ?? 200
                if isRetryable(status: status),
                   let wait = retryDelay(attempt: attempt,
                                         retryAfter: http?.value(forHTTPHeaderField: "retry-after")) {
                    try await Task.sleep(for: .seconds(wait))
                    continue
                }
                return (data, status)
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if isRetryable(error: error),
                   let wait = retryDelay(attempt: attempt, retryAfter: nil) {
                    try await Task.sleep(for: .seconds(wait))
                    continue
                }
                throw error
            }
        }
    }

    /// Meters a non-streaming response body against the daily ceiling.
    @MainActor
    static func meter(body: Data, model: String) {
        if let usage = UsageMeter.Usage.from(body: body) {
            UsageMeter.shared.record(usage, model: model)
        }
    }
}
