import Foundation

/// When to keep his mouth shut.
///
/// Everything Rusty says unprompted, a watch firing or a scheduled ask
/// arriving, is an interruption. The difference between a useful assistant and
/// a nuisance is almost entirely whether it can tell a good moment from a bad
/// one, so this decides once, in one place, and the answer is deferral rather
/// than silence: a held announcement is delivered when the moment passes.
public enum QuietPolicy {

    /// Everything observable about whether now is a bad time. All of it comes
    /// from state the app already has, with no new permissions.
    public struct Conditions: Equatable, Sendable {
        /// A macOS Focus mode is on.
        public let focusOn: Bool
        /// Another app holds the microphone, which in practice means a call.
        public let micInUse: Bool
        /// Something is full screen: a video, a presentation, a share.
        public let immersion: Bool
        /// Rusty is already talking, so a second line would overlap the first.
        public let speaking: Bool
        /// The screen is locked or the machine is asleep.
        public let suspended: Bool

        public init(focusOn: Bool = false, micInUse: Bool = false, immersion: Bool = false,
                    speaking: Bool = false, suspended: Bool = false) {
            self.focusOn = focusOn
            self.micInUse = micInUse
            self.immersion = immersion
            self.speaking = speaking
            self.suspended = suspended
        }
    }

    public enum Verdict: Equatable, Sendable {
        /// Say it now, out loud.
        case speak
        /// Show it in the panel but do not speak: the user is present and can
        /// read, they just should not be talked over.
        case showSilently(reason: String)
        /// Hold it until the moment passes.
        case hold(reason: String)
    }

    /// Ordered by how strongly each condition says "not now". The reason is
    /// carried through so the panel can explain a held message rather than
    /// having one appear from nowhere later.
    public static func verdict(_ conditions: Conditions) -> Verdict {
        if conditions.suspended { return .hold(reason: "the screen was locked") }
        if conditions.focusOn { return .hold(reason: "Focus was on") }
        if conditions.micInUse { return .hold(reason: "your microphone was in use") }
        // A full-screen video is a poor time to talk and a fine time to show
        // something quietly at the edge of the screen.
        if conditions.immersion { return .showSilently(reason: "something was full screen") }
        if conditions.speaking { return .showSilently(reason: "I was mid-sentence") }
        return .speak
    }

    public static func shouldHold(_ conditions: Conditions) -> Bool {
        if case .hold = verdict(conditions) { return true }
        return false
    }

    /// How a held message reads when it finally arrives. Held announcements
    /// are worth a word of explanation, or a message about a build that
    /// finished forty minutes ago looks like a bug.
    public static func heldPreamble(reason: String, waited: TimeInterval) -> String {
        let minutes = Int((waited / 60).rounded())
        if minutes < 1 { return "" }
        let ago = minutes == 1 ? "a minute ago" : "\(minutes) minutes ago"
        return "This happened \(ago), and I held it because \(reason). "
    }

    /// Anything older than this is stale: a build that finished two hours ago
    /// is not news, and saying so is worse than saying nothing.
    public static let maxHold: TimeInterval = 2 * 3600

    public static func isStale(waited: TimeInterval) -> Bool { waited > maxHold }
}
