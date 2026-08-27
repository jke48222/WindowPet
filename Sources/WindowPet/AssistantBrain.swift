import AppKit
import WindowPetCore

#if canImport(FoundationModels)
import FoundationModels

/// On-device natural-language routing (Apple Foundation Models, macOS 26+).
/// The model only ever PROPOSES a (verb, argument, reply) — execution flows
/// through the same AssistantRouting → gating → confirmation pipeline as
/// typed commands. Private, free, no network.
@available(macOS 26.0, *)
enum FoundationRouter {

    @Generable
    struct Route {
        @Guide(description: "Action verb. Exactly one of: none, open, switch, hide, quit, window_left, window_right, maximize, center, volume_up, volume_down, mute, unmute, play_pause, next, previous, search, open_url, type_text, copy_text, press_keys, screenshot, run_applescript, run_admin, shortcut. Use 'none' for pure conversation; 'open_url' (argument = full https URL) for websites; 'open' only for installed Mac apps; 'run_applescript' (argument = a short AppleScript) for anything else; 'run_admin' (argument = one shell command) only for tasks needing root, which prompts for the password.")
        var verb: String
        @Guide(description: "The app name, search query, or shortcut name when the verb needs one; otherwise empty.")
        var argument: String
        @Guide(description: "Rusty's reply: at most 12 words, cheerful tin-robot voice, plain text.")
        var reply: String
    }

    static var availabilityDescription: String {
        switch SystemLanguageModel.default.availability {
        case .available: return "available"
        case .unavailable(let reason): return "unavailable (\(reason))"
        @unknown default: return "unknown"
        }
    }

    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static func route(_ text: String, context: String) async throws -> (verb: String, argument: String, reply: String) {
        let session = LanguageModelSession(instructions: """
        You are Rusty, a small cheerful tin robot who lives on the user's macOS \
        screen — you stand on window title bars and can control the computer. \
        Route the user's request to exactly one verb from the allowed list \
        (or 'none' for conversation) and write a very short in-character reply. \
        Current situation: \(context)
        """)
        let response = try await session.respond(to: text, generating: Route.self)
        return (response.content.verb, response.content.argument, response.content.reply)
    }
}
#endif

/// Unified handling for anything typed into the command bar: exact grammar
/// first (instant, free), Claude second when a key is configured (smartest),
/// on-device LLM third, honest fallback last.
@MainActor
final class AssistantBrain {

    enum Outcome {
        case executed(String, reply: String?)
        case needsConfirmation(AssistantAction, reply: String?)
        case reply(String)
        case unrecognized(String)
    }

    static var naturalLanguageAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return FoundationRouter.isAvailable }
        #endif
        return false
    }

    static var naturalLanguageStatus: String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return FoundationRouter.availabilityDescription }
        #endif
        return "requires macOS 26+"
    }

    /// One-line description of the smartest tier currently reachable — shown
    /// in the menu so it's obvious which brain answers.
    static var brainDescription: String {
        if ClaudeRouter.isConfigured { return "Claude (\(ClaudeRouter.model))" }
        if naturalLanguageAvailable { return "On-Device (Apple)" }
        return "Grammar Only"
    }

    static func handle(_ text: String, context: String,
                       history: [(role: String, text: String)] = []) async -> Outcome {
        // A grammar match only wins when its target actually exists — "open
        // big brother on paramount plus" parses as openApp but is a website
        // request, so a miss falls through to the smarter tiers.
        var grammarMiss: String?
        if let action = AssistantParser.parse(text) {
            if action.needsConfirmation { return .needsConfirmation(action, reply: nil) }
            let (result, ok) = AssistantExecutor.executeChecked(action)
            if ok { return .executed(result, reply: nil) }
            if !ClaudeRouter.isConfigured && !naturalLanguageAvailable {
                return .unrecognized(result)
            }
            grammarMiss = result
        }
        if ClaudeRouter.isConfigured {
            do {
                let route = try await ClaudeRouter.route(text, context: context, history: history)
                // Screen sight: Claude asked to look, so capture the screen
                // and answer from the image instead of routing an action.
                if route.verb == "look" {
                    let question = route.argument.isEmpty ? text : route.argument
                    return .reply(await ClaudeRouter.look(question: question))
                }
                // The plan is the primary action plus up to two follow-on
                // steps. Destructive verbs still confirm; a destructive step
                // inside a plan is dropped rather than silently run.
                var actions: [AssistantAction] = []
                if let primary = AssistantRouting.action(verb: route.verb, argument: route.argument) {
                    actions.append(primary)
                }
                for step in route.steps {
                    guard step.verb != "run_applescript", step.verb != "run_admin" else { continue }
                    if let a = AssistantRouting.action(verb: step.verb, argument: step.argument),
                       !a.needsConfirmation {
                        actions.append(a)
                    }
                }
                // A quip riding a command stays short; a standalone answer to
                // a question keeps its full length.
                let limit = actions.isEmpty ? ClaudeRouting.answerLimit
                                            : ClaudeRouting.commandReplyLimit
                let reply = AssistantRouting.sanitizeReply(route.reply, limit: limit)
                if let first = actions.first {
                    if first.needsConfirmation {
                        return .needsConfirmation(first, reply: reply.isEmpty ? nil : reply)
                    }
                    var results: [String] = []
                    for action in actions {
                        results.append(AssistantExecutor.executeChecked(action).result)
                    }
                    return .executed(results.joined(separator: " "),
                                     reply: reply.isEmpty ? nil : reply)
                }
                if !reply.isEmpty { return .reply(reply) }
            } catch ClaudeRouter.RouterError.unauthorized {
                return .unrecognized("Anthropic rejected the API key. Fix it under Anthropic API Key… in the menu bar.")
            } catch ClaudeRouter.RouterError.refused {
                return .reply("That one's outside what I can help with.")
            } catch ClaudeRouter.RouterError.overBudget(let message) {
                // Say it rather than quietly dropping to the on-device tier:
                // a ceiling nobody is told about looks like a broken app.
                return .unrecognized(message)
            } catch {
                // Network or transient API trouble: quietly fall through to
                // the on-device tier so voice keeps working offline.
            }
        }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), FoundationRouter.isAvailable {
            do {
                let recent = history.suffix(4).map { "\($0.role): \($0.text)" }
                    .joined(separator: " / ")
                let fmContext = recent.isEmpty ? context : context + " Recent chat: " + recent
                let route = try await FoundationRouter.route(text, context: fmContext)
                let reply = AssistantRouting.sanitizeReply(route.reply)
                if let action = AssistantRouting.action(verb: route.verb, argument: route.argument) {
                    if action.needsConfirmation {
                        return .needsConfirmation(action, reply: reply.isEmpty ? nil : reply)
                    }
                    return .executed(AssistantExecutor.execute(action),
                                     reply: reply.isEmpty ? nil : reply)
                }
                if !reply.isEmpty { return .reply(reply) }
            } catch {
                return .unrecognized("Thinking hardware hiccuped (\(error.localizedDescription))")
            }
        }
        #endif
        if let grammarMiss { return .unrecognized(grammarMiss) }
        return .unrecognized("Try “open Safari”, “window left”, “mute”… (natural language: \(naturalLanguageStatus))")
    }
}
