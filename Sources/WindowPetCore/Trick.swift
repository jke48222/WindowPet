import Foundation

/// Teaching him a trick: a named sequence of steps he can perform again.
///
/// What gets recorded is what *Rusty* did, not what the user did. That is a
/// deliberate limit rather than a shortcut. Recording a person's keystrokes
/// would need input monitoring, which is a permission this app has spent its
/// whole design avoiding, and a trick made of his own verbs replays through
/// the same gate they originally passed: a step that confirmed when it was
/// recorded confirms again every time it runs.
public struct TrickStep: Codable, Equatable, Sendable {
    public let verb: String
    public let argument: String

    public init(verb: String, argument: String) {
        self.verb = verb
        self.argument = argument
    }

    public var description: String {
        argument.isEmpty ? verb : "\(verb) \(argument)"
    }
}

public struct Trick: Codable, Equatable, Sendable {
    public let name: String
    public let steps: [TrickStep]

    public init(name: String, steps: [TrickStep]) {
        self.name = name
        self.steps = steps
    }

    public var summary: String {
        steps.isEmpty
            ? "\(name) has no steps"
            : "\(name): " + steps.map(\.description).joined(separator: ", ")
    }
}

public enum TrickPolicy {

    /// A trick is a short routine. Past this it is a program, and a program
    /// wants a script rather than a toy robot.
    public static let maxSteps = 12
    public static let maxTricks = 20

    /// Verbs that are never recorded, because replaying them would be either
    /// meaningless or a trap.
    ///
    /// The read-only reporting verbs answer a question in the moment and mean
    /// nothing on replay. `run_admin` is excluded for a stronger reason:
    /// a privileged command saved under a friendly name, replayed later by
    /// saying one word, is exactly the shape of thing that should not exist,
    /// even though it would still ask for a password.
    public static let unrecordable: Set<String> = [
        "windows", "clips", "layouts", "watches", "schedules", "tricks",
        "look", "remember", "forget", "recall_clip", "read_file",
        "run_admin", "record_trick", "save_trick", "trick", "forget_trick",
        "watch", "unwatch", "schedule", "unschedule", "undo_arrangement",
    ]

    public static func isRecordable(verb: String) -> Bool {
        !unrecordable.contains(verb)
    }

    public static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Appends a step unless it is unrecordable or the routine is already
    /// full. Returns nil when nothing was added, so the caller can say so.
    public static func appending(_ step: TrickStep, to steps: [TrickStep]) -> [TrickStep]? {
        guard isRecordable(verb: step.verb), steps.count < maxSteps else { return nil }
        return steps + [step]
    }

    public static func listing(_ tricks: [Trick]) -> String {
        guard !tricks.isEmpty else {
            return "I do not know any tricks yet. Say start recording, do a few things, then tell me to save it under a name."
        }
        return tricks.map(\.summary).joined(separator: "\n")
    }

    public static func recordingStarted() -> String {
        "Recording. Everything you have me do from here goes into the trick, until you tell me to save it under a name."
    }

    public static func recordingSaved(_ trick: Trick) -> String {
        trick.steps.isEmpty
            ? "There was nothing to save: I did not do anything worth repeating while recording."
            : "Learned \(trick.name), \(trick.steps.count) "
                + "\(trick.steps.count == 1 ? "step" : "steps"). Ask me to do \(trick.name) any time."
    }
}
