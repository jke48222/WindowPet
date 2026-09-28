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
        @Guide(description: "Action verb. Exactly one of: none, open, switch, hide, quit, window_left, window_right, maximize, center, volume_up, volume_down, mute, unmute, play_pause, next, previous, search, open_url, type_text, copy_text, press_keys, screenshot, run_applescript, run_admin, shortcut, windows, place_windows, layouts, layout, save_layout, undo_arrangement, watch, watches, unwatch, schedule, schedules, unschedule, clips, recall_clip, tricks, trick, record_trick, save_trick, forget_trick, remember, forget. Use 'none' for pure conversation; 'open_url' (argument = full https URL) for websites; 'open' only for installed Mac apps; 'windows' to list what is open; 'place_windows' (argument like 'Safari left, Terminal bottom right') to arrange windows; 'watch' (argument like 'Xcode until the build finishes') to be told when an app changes; 'schedule' (argument like 'every weekday at 9 tell me what is on my calendar') for a standing ask; 'clips' for what was copied; 'remember' (argument = the fact) and 'forget' (argument = what to forget) for preferences; 'run_applescript' (argument = a short AppleScript) for anything else; 'run_admin' (argument = one shell command) only for tasks needing root, which prompts for the password.")
        var verb: String
        @Guide(description: "The app name, search query, shortcut name, layout or trick name, window arrangement, watch, standing ask or fact when the verb needs one; otherwise empty.")
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

    /// - Parameters:
    ///   - untrusted: the text (or the history riding with it) carries
    ///     content the user did not write: a dropped file, a standing ask,
    ///     words the wake word heard, or a conversation that read any of
    ///     those. Every proposed action is then gated as a tainted agent run
    ///     would be, so the on-device model cannot be talked into typing or
    ///     opening something without a Return.
    ///   - heard: the request came through the wake word; typing, key
    ///     presses, shortcuts and tricks confirm (see `AgentGate`).
    ///   - grammarAlreadyTried: the caller already parsed and ran the exact
    ///     grammar (the panel always has), so it is not run a second time.
    ///   - grammarMiss: what that attempt said when it failed, kept as the
    ///     honest answer if nothing smarter handles the request.
    static func handle(_ text: String, context: String,
                       history: [(role: String, text: String)] = [],
                       untrusted: Bool = false,
                       heard: Bool = false,
                       grammarAlreadyTried: Bool = false,
                       grammarMiss previousMiss: String? = nil) async -> Outcome {
        // A grammar match only wins when its target actually exists — "open
        // big brother on paramount plus" parses as openApp but is a website
        // request, so a miss falls through to the smarter tiers. Untrusted
        // text is never a command in its own right.
        var grammarMiss = previousMiss
        if !grammarAlreadyTried, !untrusted, let action = AssistantParser.parse(text) {
            if action.needsConfirmation { return .needsConfirmation(action, reply: nil) }
            let (result, ok) = await AssistantExecutor.executeAwaiting(action)
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
                // steps. Gated verbs still confirm; a gated step inside a plan
                // is dropped rather than silently run. The model proposed
                // these, so the app-side gate applies as well (a standing ask
                // or a URL carrying a payload confirms).
                var actions: [AssistantAction] = []
                if let primary = AssistantRouting.action(verb: route.verb, argument: route.argument) {
                    actions.append(primary)
                }
                for step in route.steps {
                    guard step.verb != "run_applescript", step.verb != "run_admin" else { continue }
                    if let a = AssistantRouting.action(verb: step.verb, argument: step.argument),
                       !AgentGate.requiresConfirmation(a, tainted: untrusted, heard: heard) {
                        actions.append(a)
                    }
                }
                // A quip riding a command stays short; a standalone answer to
                // a question keeps its full length.
                let limit = actions.isEmpty ? ClaudeRouting.answerLimit
                                            : ClaudeRouting.commandReplyLimit
                let reply = AssistantRouting.sanitizeReply(route.reply, limit: limit)
                if let first = actions.first {
                    if AgentGate.requiresConfirmation(first, tainted: untrusted, heard: heard) {
                        return .needsConfirmation(first, reply: reply.isEmpty ? nil : reply)
                    }
                    // A failed step ends the plan and is reported as it is:
                    // the model's cheerful quip would claim a success.
                    var results: [String] = []
                    for action in actions {
                        let (result, ok) = await AssistantExecutor.executeAwaiting(action)
                        results.append(result)
                        if !ok {
                            return results.count == 1
                                ? .unrecognized(result)
                                : .executed(results.joined(separator: " "), reply: nil)
                        }
                    }
                    return .executed(results.joined(separator: " "),
                                     reply: reply.isEmpty ? nil : reply)
                }
                if !reply.isEmpty { return .reply(reply) }
            } catch ClaudeRouter.RouterError.unauthorized {
                return .unrecognized("Anthropic rejected the API key. Fix it under Anthropic API Key… in the menu bar.")
            } catch ClaudeRouter.RouterError.refused {
                return .reply("That one's outside what I can help with.")
            } catch ClaudeRouter.RouterError.api(let message) {
                // Billing, an unknown model, a request too large: falling back
                // quietly would hide the one thing the user can fix.
                return .unrecognized(message)
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
                if let memoryOutcome = handleMemory(verb: route.verb, argument: route.argument,
                                                    untrusted: untrusted) {
                    return memoryOutcome
                }
                if let action = AssistantRouting.action(verb: route.verb, argument: route.argument) {
                    if AgentGate.requiresConfirmation(action, tainted: untrusted, heard: heard) {
                        return .needsConfirmation(action, reply: reply.isEmpty ? nil : reply)
                    }
                    // A refusal (no Accessibility, no such app) is shown as
                    // it is, never covered by the model's quip.
                    let (result, ok) = await AssistantExecutor.executeAwaiting(action)
                    guard ok else { return .unrecognized(result) }
                    return .executed(result, reply: reply.isEmpty ? nil : reply)
                }
                // No action came of it, but the quip may sound like one did.
                // Say plainly what happened instead: the grammar's own
                // refusal when there was one, or that the verb needs Claude.
                if let grammarMiss { return .unrecognized(grammarMiss) }
                let verb = route.verb.lowercased().trimmingCharacters(in: .whitespaces)
                if verb == "look" { return .unrecognized(Self.needsClaude) }
                if !verb.isEmpty, verb != "none", AssistantRouting.verbs.contains(verb) {
                    return .unrecognized("I couldn't tell what to \(verb.replacingOccurrences(of: "_", with: " ")) there. Try saying it another way.")
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

    /// Said when a keyless request reaches something only the Claude brain
    /// can do, instead of a quip that pretends it was done.
    static let needsClaude = "That one needs the Claude brain. Add an Anthropic API key under Anthropic API Key in the menu bar."

    /// `remember` and `forget` on the on-device route, with the agent's rule:
    /// memory rides along in every later conversation, so a request carrying
    /// outside content may not write or wipe it. Nil for any other verb.
    private static func handleMemory(verb rawVerb: String, argument: String,
                                     untrusted: Bool) -> Outcome? {
        let verb = rawVerb.lowercased().trimmingCharacters(in: .whitespaces)
        guard verb == "remember" || verb == "forget" else { return nil }
        let argument = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !argument.isEmpty else { return .unrecognized("Tell me what to \(verb).") }
        if untrusted {
            return .unrecognized("I won't change what I remember from a request that carried outside content. Tell me directly.")
        }
        var memory = PetMemoryStore.load()
        if verb == "remember" {
            let (scope, raw) = PetMemory.splitScope(argument)
            let fact = MemoryHygiene.redact(raw, limit: 400)
            memory.remember(fact, scope: scope)
            PetMemoryStore.save(memory)
            return .executed(scope.map { "Noted for \($0): \(fact)" } ?? "Noted: \(fact)", reply: nil)
        }
        if PetMemory.normalize(argument) == "everything" {
            memory.forgetEverything()
            PetMemoryStore.save(memory)
            return .executed("Cleared what I remembered.", reply: nil)
        }
        memory.forget(matching: argument)
        PetMemoryStore.save(memory)
        return .executed("Forgot that.", reply: nil)
    }
}
