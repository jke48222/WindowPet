import Foundation
import WindowPetCore

/// Cloud brain: routes utterances through the Anthropic Messages API
/// (claude-opus-5). Sits between the free grammar and the on-device model in
/// AssistantBrain's chain — used only when a key is configured. Key sources:
/// UserDefaults "anthropicKey" (menu) or the ANTHROPIC_API_KEY environment
/// variable, mirroring ElevenLabsTTS.
enum ClaudeRouter {

    enum RouterError: Error {
        case unauthorized
        case refused
        case failed(String)
    }

    static var apiKey: String? {
        if let k = UserDefaults.standard.string(forKey: "anthropicKey"), !k.isEmpty { return k }
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
        } catch RouterError.failed(let message) {
            return "Claude call failed: \(message)"
        } catch {
            return "Couldn't reach Anthropic: \(error.localizedDescription)"
        }
    }

    static func route(_ text: String, context: String,
                      history: [(role: String, text: String)] = []) async throws
        -> ClaudeRouting.Route {
        guard let key = apiKey,
              let spec = ClaudeRouting.routeRequest(text: text, context: context,
                                                    apiKey: key, history: history,
                                                    model: model) else {
            throw RouterError.failed("not configured")
        }
        let (data, response) = try await URLSession.shared.data(for: spec.urlRequest(timeout: 30))
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            throw RouterError.unauthorized
        }
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
        guard let key = apiKey else {
            return "I need the Claude brain to see the screen. Add an Anthropic API key in the menu bar."
        }
        guard let base64 = ScreenCapture.snapshotBase64() else {
            return "I couldn't grab the screen. Turn on Screen Recording for WindowPet in System Settings, Privacy and Security, then ask again."
        }
        guard let spec = ClaudeRouting.visionRequest(question: question, imageBase64: base64,
                                                      apiKey: key, model: model) else {
            return "Something went wrong preparing the screen image."
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: spec.urlRequest(timeout: 45))
            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                return "The API key was rejected. Paste a fresh one under Anthropic API Key."
            }
            switch ClaudeRouting.parseText(data) {
            case .text(let answer):
                return AssistantRouting.sanitizeReply(answer, limit: ClaudeRouting.answerLimit)
            case .refused:
                return "I'd rather not weigh in on what's on screen there."
            case .failed(let message):
                return "I couldn't read the screen: \(message)"
            }
        } catch {
            return "I couldn't reach Anthropic to look: \(error.localizedDescription)"
        }
    }
}
