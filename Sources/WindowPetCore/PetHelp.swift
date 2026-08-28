import Foundation

/// What Rusty can do, in his own words.
///
/// A verb list nobody can find is a verb list nobody uses, and by now there
/// are more than twenty of them. This is the one place that copy lives, so the
/// menu, the onboarding and any future help sheet cannot drift apart, and so
/// the house rules about it (no emoji, no em dashes) are testable.
public enum PetHelp {

    public struct Section: Equatable, Sendable {
        public let title: String
        public let lines: [String]

        public init(title: String, lines: [String]) {
            self.title = title
            self.lines = lines
        }
    }

    public static let sections: [Section] = [
        Section(title: "Talking to him", lines: [
            "Tap the summon shortcut and type, or hold it and speak.",
            "Say hey rusty followed by what you want, if the wake word is on.",
            "Drop a file on him to have him read it.",
            "Double click him to open the panel.",
        ]),
        Section(title: "Your windows", lines: [
            "Ask what is open and he will tell you, without ever reading a title.",
            "Say put Safari left and Terminal bottom right, and he will.",
            "Save an arrangement under a name and ask for it back later.",
            "Say put it back to undo the last arrangement.",
        ]),
        Section(title: "Keeping watch", lines: [
            "Tell me when the build finishes. He goes and stands on that window.",
            "Every weekday at 9, tell me what is on my calendar.",
            "He holds anything he wants to say while Focus is on or you are on a call.",
        ]),
        Section(title: "Doing things", lines: [
            "Open apps, move windows, run AppleScript, press keys, search the web.",
            "Dictation: hold the dictation shortcut and speak straight into the app in front, with nothing sent anywhere.",
            "Ask what you copied recently and have any of it back.",
            "Teach him a routine: start recording, do a few things, save it under a name.",
        ]),
        Section(title: "What always asks first", lines: [
            "Quitting an app, anything needing an administrator, and destructive scripts.",
            "Reading a file he chose himself. A file you dropped on him is already yours to share.",
            "Any tool from a server you have not marked as trusted.",
        ]),
    ]

    /// The whole thing as plain text, which is what the panel shows.
    public static func text(summonShortcut: String, dictationShortcut: String) -> String {
        var lines: [String] = []
        for section in sections {
            lines.append(section.title)
            for line in section.lines {
                lines.append("  " + line)
            }
            lines.append("")
        }
        return lines
            .joined(separator: "\n")
            .replacingOccurrences(of: "the summon shortcut", with: summonShortcut)
            .replacingOccurrences(of: "the dictation shortcut", with: dictationShortcut)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The first-run hello. Says only what a person needs before they start,
    /// and names the permissions rather than letting macOS ask cold.
    public static func onboarding(summonShortcut: String, dictationShortcut: String) -> String {
        """
        He walks along your windows, and he is also a full assistant. Tap \
        \(summonShortcut) and ask him anything, hold it to talk, or say "hey rusty". \
        Hold \(dictationShortcut) and whatever you say goes straight into the app in \
        front, with nothing sent anywhere. Drop a file on him and he will read it.

        A few permissions make him whole. Accessibility lets him ride and \
        arrange your windows. Microphone and Speech Recognition make voice and \
        dictation work, and recognition stays on this Mac. Full Disk Access, \
        under the menu bar, lets him reach protected files when you ask. \
        Anything needing an administrator asks for your password first.

        Bring your own Anthropic API key, under the menu bar, to give him his \
        smartest brain. He keeps himself to a daily spending limit you can \
        change, and he will tell you when he reaches it.
        """
    }
}
