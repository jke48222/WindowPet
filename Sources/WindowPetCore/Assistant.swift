import Foundation

/// A1 of the assistant: a small, GATED verb set parsed from typed commands.
/// Pure and unit-tested; execution lives app-side. Destructive verbs (quit)
/// are marked so the UI can require confirmation. Natural-language routing
/// (A2) will layer on top of these same actions.
public enum AssistantAction: Equatable {
    public enum WindowMove: String { case left, right, maximize, center }
    public enum VolumeOp: String { case up, down, mute, unmute }
    public enum MediaOp: String { case playpause, next, previous }

    case openApp(String)
    case switchApp(String)
    case hideApp(String)
    case quitApp(String)          // destructive → confirm
    case windowMove(WindowMove)
    case volume(VolumeOp)
    case media(MediaOp)
    case search(String)
    case openURL(URL)
    case typeText(String)
    case copyText(String)
    case pressKeys(String)
    case screenshot
    case runAppleScript(String)
    case runAdminShell(String)     // root via the macOS password prompt; always confirms
    case runShortcut(String)

    public var needsConfirmation: Bool {
        switch self {
        case .quitApp: return true
        case .runAppleScript(let script): return AssistantRouting.isDangerousScript(script)
        case .runAdminShell: return true  // privileged: never runs without a human Return + password
        default: return false
        }
    }

    /// Shown in the safety-check row so the user sees exactly what a
    /// confirmation would run.
    public var confirmationSummary: String? {
        switch self {
        case .quitApp(let name): return "Quit \(name)"
        case .runAppleScript(let script): return "Run AppleScript: \(script.prefix(220))"
        case .runAdminShell(let cmd):
            return "Run as administrator (macOS will ask for your password): \(cmd.prefix(200))"
        default: return nil
        }
    }
}

/// Maps LLM-proposed (verb, argument) pairs onto the SAME gated actions the
/// typed grammar uses — the model proposes, this (and the confirmation layer)
/// disposes. Unknown verbs map to nothing.
public enum AssistantRouting {
    public static let verbs = [
        "none", "open", "switch", "hide", "quit",
        "window_left", "window_right", "maximize", "center",
        "volume_up", "volume_down", "mute", "unmute",
        "play_pause", "next", "previous", "search", "open_url",
        "type_text", "copy_text", "press_keys", "screenshot",
        "run_applescript", "run_admin", "look", "remember", "forget", "shortcut",
    ]
    // "look" is a Claude-only capability (it needs vision), so it's a valid
    // schema verb but has no AssistantAction: the brain intercepts it and
    // routes the screen image through ClaudeRouting.visionRequest instead of
    // the sync executor.

    /// LLM-proposed URLs are opened only when they are plain web links.
    /// Bare domains get https:// prepended; anything that isn't http(s)
    /// (javascript:, file:, data:, …) is rejected.
    public static func webURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let candidate: String
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            candidate = trimmed
        } else if trimmed.contains("://") || trimmed.hasPrefix("/") {
            return nil
        } else if trimmed.contains(".") {
            candidate = "https://" + trimmed
        } else {
            return nil
        }
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, host.contains(".") else { return nil }
        return url
    }

    public static func action(verb rawVerb: String, argument rawArg: String) -> AssistantAction? {
        let verb = rawVerb.lowercased().trimmingCharacters(in: .whitespaces)
        let arg = rawArg.trimmingCharacters(in: .whitespacesAndNewlines)
        switch verb {
        case "open", "launch": return arg.isEmpty ? nil : .openApp(arg)
        case "switch", "focus", "activate": return arg.isEmpty ? nil : .switchApp(arg)
        case "hide": return arg.isEmpty ? nil : .hideApp(arg)
        case "quit", "close": return arg.isEmpty ? nil : .quitApp(arg)
        case "window_left": return .windowMove(.left)
        case "window_right": return .windowMove(.right)
        case "maximize": return .windowMove(.maximize)
        case "center": return .windowMove(.center)
        case "volume_up": return .volume(.up)
        case "volume_down": return .volume(.down)
        case "mute": return .volume(.mute)
        case "unmute": return .volume(.unmute)
        case "play_pause", "play", "pause": return .media(.playpause)
        case "next": return .media(.next)
        case "previous": return .media(.previous)
        case "search": return arg.isEmpty ? nil : .search(arg)
        case "open_url", "url", "website": return webURL(from: arg).map { .openURL($0) }
        case "type_text", "type": return arg.isEmpty ? nil : .typeText(String(arg.prefix(400)))
        case "copy_text", "copy": return arg.isEmpty ? nil : .copyText(arg)
        case "press_keys", "press", "hotkey": return arg.isEmpty ? nil : .pressKeys(arg)
        case "screenshot": return .screenshot
        case "run_applescript", "applescript", "script":
            return arg.isEmpty ? nil : .runAppleScript(arg)
        case "run_admin", "sudo", "admin":
            return arg.isEmpty ? nil : .runAdminShell(arg)
        case "shortcut": return arg.isEmpty ? nil : .runShortcut(arg)
        default: return nil
        }
    }

    /// Scripts that touch the shell, files, sessions, or power state need a
    /// human Return first. Biased toward confirming: one extra keypress on a
    /// benign "delete the reminder" beats one silent "rm -rf".
    public static func isDangerousScript(_ script: String) -> Bool {
        let lowered = script.lowercased()
        let markers = [
            "do shell script", "delete", "erase", "empty trash", "trash",
            "shut down", "shutdown", "restart", "log out", "logout",
            "keystroke", "key code", "sudo", "rm -", "format", "password",
        ]
        return markers.contains { lowered.contains($0) }
    }

    /// Bubble hygiene: single-line, no quotes-of-quotes, no em dashes. The
    /// caller sets the length: 90 for the on-device tier, a short cap for a
    /// command quip, or ClaudeRouting.answerLimit so a real answer survives
    /// in full.
    public static func sanitizeReply(_ raw: String, limit: Int = 90) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: "\n", with: " ")
        // House style: no em dashes, ever.
        text = text.replacingOccurrences(of: " — ", with: ", ")
        text = text.replacingOccurrences(of: "—", with: ", ")
        text = text.replacingOccurrences(of: ",  ", with: ", ")
        if text.count > limit { text = String(text.prefix(limit - 1)) + "…" }
        return text
    }
}

/// Push-to-talk key discipline: a quick tap toggles the command bar; holding
/// past the threshold means "listen while held".
public enum PushToTalk {
    public static let holdThreshold: TimeInterval = 0.35
    public static func isHold(downDuration: TimeInterval) -> Bool {
        downDuration >= holdThreshold
    }
}

/// "Hey Rusty" wake-phrase matching over live transcripts, plus one-shot
/// command extraction ("hey rusty mute the sound" routes directly).
/// Lowercase, punctuation-to-space, whitespace-collapsed tokenization, shared
/// by wake-word matching and memory dedup so the two never drift.
public enum TextNormalize {
    public static func tokens(_ text: String) -> String {
        let letters = text.lowercased().map { c -> Character in
            c.isLetter || c.isNumber ? c : " "
        }
        return String(letters).split(separator: " ").joined(separator: " ")
    }
}

public enum WakeWord {
    public static let phrases = ["hey rusty", "hey rustie", "hay rusty", "hey rusti"]

    static func normalize(_ text: String) -> String { TextNormalize.tokens(text) }

    public static func matches(_ transcript: String) -> Bool {
        let norm = normalize(transcript)
        return phrases.contains { norm.contains($0) }
    }

    /// Everything after the wake phrase, "" if the phrase stands alone,
    /// nil if no phrase present.
    public static func extractCommand(_ transcript: String) -> String? {
        let norm = normalize(transcript)
        for phrase in phrases {
            if let range = norm.range(of: phrase) {
                return String(norm[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}

public enum AssistantParser {

    public static func parse(_ raw: String) -> AssistantAction? {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        let lower = input.lowercased()

        func rest(after prefixes: [String]) -> String? {
            for p in prefixes where lower.hasPrefix(p + " ") {
                let r = String(input.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
                return r.isEmpty ? nil : r
            }
            return nil
        }

        if let app = rest(after: ["open", "launch", "start"]) { return .openApp(app) }
        if let app = rest(after: ["switch to", "focus", "activate", "go to"]) { return .switchApp(app) }
        if let app = rest(after: ["hide"]) { return .hideApp(app) }
        if let app = rest(after: ["quit", "close app", "kill"]) { return .quitApp(app) }

        switch lower {
        case "move window left", "window left", "left half": return .windowMove(.left)
        case "move window right", "window right", "right half": return .windowMove(.right)
        case "maximize", "maximize window", "fill window": return .windowMove(.maximize)
        case "center window", "center": return .windowMove(.center)
        case "volume up", "louder": return .volume(.up)
        case "volume down", "quieter": return .volume(.down)
        case "mute": return .volume(.mute)
        case "unmute": return .volume(.unmute)
        case "play", "pause", "play pause": return .media(.playpause)
        case "next", "next track", "skip": return .media(.next)
        case "previous", "previous track", "back": return .media(.previous)
        default: break
        }

        if let q = rest(after: ["search", "google"]) { return .search(q) }
        if let name = rest(after: ["shortcut", "run shortcut"]) { return .runShortcut(name) }
        return nil
    }
}
