import Foundation

/// Decides which model-written AppleScripts may run without a human Return.
///
/// This is an allow-list, not a deny-list. AppleScript reaches the shell in
/// too many ways to enumerate: `do shell script` with any spacing, Terminal's
/// `do script`, `run script` on a concatenated string, raw `«event»` codes,
/// AppleScriptObjC's NSTask, Finder `move`, Mail `send`. A list of bad words
/// misses the next spelling, so the rule is inverted: a script runs straight
/// through only when every statement in it matches one of a few known-safe
/// shapes (volume, notifications, dark mode, music playback). Everything else
/// waits for the user.
public enum AppleScriptPolicy {

    /// Longest script or command the confirmation row shows in full. Anything
    /// longer is refused outright rather than shown cut off, because the part
    /// past the cut is exactly where a hidden payload would sit.
    public static let maxConfirmableLength = 2000

    /// True only when the whole script is made of known-safe statements.
    public static func isKnownSafe(_ script: String) -> Bool {
        guard !script.isEmpty, script.count <= maxConfirmableLength else { return false }
        // Raw Apple event codes, comments (which could hide a continuation
        // trick), escapes, and control characters never appear in the safe
        // shapes, so their presence alone is enough to ask.
        for marker in ["«", "»", "--", "(*", "*)", "#", "\\"] where script.contains(marker) {
            return false
        }
        if script.unicodeScalars.contains(where: { isHidden($0) && !"\n\r\t".unicodeScalars.contains($0) }) {
            return false
        }
        let lines = statements(script)
        guard !lines.isEmpty else { return false }

        var stack: [Context] = []
        for line in lines {
            if line == "end tell" || line == "end" {
                guard !stack.isEmpty else { return false }
                stack.removeLast()
                continue
            }
            let context = stack.last ?? .top
            if let opened = opensBlock(line, in: context) {
                stack.append(opened)
                continue
            }
            guard isSafe(line, in: context) else { return false }
        }
        return stack.isEmpty
    }

    /// Lowercased statements, one per line, with `¬` continuations joined and
    /// every run of whitespace collapsed to one space. `do  shell  script`
    /// and a statement split across lines both compile, so both are folded
    /// into the one spelling the matcher sees.
    public static func statements(_ script: String) -> [String] {
        var text = script.lowercased()
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        text = text.replacingOccurrences(of: "¬[ \\t]*\\n", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "¬", with: " ")
        let unified = String(text.map { character -> Character in
            if character.isNewline { return "\n" }
            return character.isWhitespace ? " " : character
        })
        return unified.split(separator: "\n").compactMap { raw in
            let collapsed = raw.split(separator: " ").joined(separator: " ")
            return collapsed.isEmpty ? nil : collapsed
        }
    }

    // MARK: - Matching

    private enum Context: Equatable {
        case top
        case app(String)
        case appearance
    }

    /// Apps whose tell blocks may hold safe statements. Any other app's tell
    /// block asks, whatever it contains.
    private static let playerApps: Set<String> = ["music", "spotify"]
    private static let systemEvents = "system events"

    private static let quoted = #""[^"]*""#
    private static let tellApp = #"^tell (?:application|app) "([^"]+)""#

    private static func matches(_ line: String, _ pattern: String) -> Bool {
        line.range(of: "^(?:\(pattern))$", options: .regularExpression) != nil
    }

    private static func appName(opening line: String) -> String? {
        guard let range = line.range(of: tellApp + "$", options: .regularExpression) else {
            return nil
        }
        return String(line[range]).split(separator: "\"").dropFirst().first.map(String.init)
    }

    private static func opensBlock(_ line: String, in context: Context) -> Context? {
        // Only apps with safe statements may open a block; any other tell
        // falls through to isSafe, which refuses it.
        if let app = appName(opening: line), playerApps.contains(app) || app == systemEvents {
            return .app(app)
        }
        if line == "tell appearance preferences", context == .app(systemEvents) {
            return .appearance
        }
        return nil
    }

    private static func isSafe(_ line: String, in context: Context) -> Bool {
        // One-line tells: `tell application "Music" to play`.
        if let range = line.range(of: tellApp + " to ", options: .regularExpression) {
            let head = String(line[range]).dropLast(4)
            guard let app = appName(opening: String(head)) else { return false }
            return isSafe(String(line[range.upperBound...]), in: .app(app))
        }
        if line.hasPrefix("tell appearance preferences to "), context == .app(systemEvents) {
            return isSafe(String(line.dropFirst("tell appearance preferences to ".count)),
                          in: .appearance)
        }
        switch context {
        case .top: return isSafeTopLevel(line)
        case .app(let name) where playerApps.contains(name): return isSafePlayer(line)
        case .app(let name) where name == systemEvents: return isSafeSystemEvents(line)
        case .app: return false
        case .appearance: return isSafeAppearance(line)
        }
    }

    /// Words a volume expression may use. With no quotes allowed, nothing
    /// built from these can name an app, a file, or a command.
    private static let volumeWords: Set<String> = [
        "set", "get", "return", "volume", "settings", "output", "input", "alert",
        "muted", "of", "not", "true", "false", "min", "max", "round", "with", "without",
    ]

    private static func isVolumeExpression(_ line: String) -> Bool {
        guard matches(line, #"[a-z0-9 ()+\-*/,.]+"#) else { return false }
        let words = line.split(whereSeparator: { !$0.isLetter }).map(String.init)
        return words.contains("volume") && words.allSatisfy { volumeWords.contains($0) }
    }

    private static func isSafeTopLevel(_ line: String) -> Bool {
        if line.hasPrefix("set volume ") || line.hasPrefix("get volume")
            || line.hasPrefix("return ") || line.hasPrefix("output ") {
            return isVolumeExpression(line)
        }
        let notification = "display notification \(quoted)"
            + "(?: with title \(quoted))?(?: subtitle \(quoted))?(?: sound name \(quoted))?"
        return matches(line, notification)
            || matches(line, "beep(?: [0-9]{1,2})?")
            || matches(line, "delay [0-9]{1,2}(?:\\.[0-9]+)?")
    }

    private static func isSafePlayer(_ line: String) -> Bool {
        matches(line, "play|pause|playpause|stop|resume|next track|previous track|back track")
            || matches(line, "play (?:playlist|track) \(quoted)")
            || matches(line, "set sound volume to [0-9]{1,3}")
            || matches(line, "set (?:shuffling|shuffle enabled) to (?:true|false)")
            || matches(line, "set (?:song repeat|repeating) to (?:off|one|all)")
            || matches(line, "(?:get |return )?(?:(?:name|artist|album) of current track|player state|sound volume)")
    }

    private static func isSafeSystemEvents(_ line: String) -> Bool {
        let flip = "(?:true|false|not dark mode of appearance preferences)"
        return matches(line, "set dark mode of appearance preferences to \(flip)")
            || matches(line, "(?:get |return )?dark mode of appearance preferences")
    }

    private static func isSafeAppearance(_ line: String) -> Bool {
        matches(line, "set dark mode to (?:true|false|not dark mode)")
            || matches(line, "(?:get |return )?dark mode")
    }

    // MARK: - Showing what will run

    /// The exact text that will run, with nothing hidden: line breaks become
    /// a visible mark and invisible characters (controls, bidi overrides,
    /// zero-width spaces) are spelled out, so what the user reads in the
    /// confirmation row is what executes.
    public static func visible(_ text: String) -> String {
        var out = ""
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\n" && previousWasCR { previousWasCR = false; continue }
            previousWasCR = scalar == "\r"
            switch scalar {
            case "\n", "\r", "\u{2028}", "\u{2029}": out += " ⏎ "
            case "\t": out += "⇥"
            default:
                if isHidden(scalar) {
                    out += String(format: "\\u{%04X}", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    /// Characters that render as nothing, or that reorder what is around
    /// them, and so could make a command read differently from how it runs.
    static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F: return true
        case 0x061C, 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064,
             0x2066...0x2069, 0xFEFF: return true
        default: return false
        }
    }
}
