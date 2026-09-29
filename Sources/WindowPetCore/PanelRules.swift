import Foundation

// The decisions behind the assistant panel's safety gate, its timed hide and
// its history taint. CommandBar owns the AppKit side; these stay free of it
// so the tests can reach them.

/// Whether a Return answers the safety check on screen. It must be a new
/// press (a held Return auto-repeats past any delay), the user's attention
/// must have reached the panel, at least `delay` ago, and not so long ago
/// that the check has gone stale.
public enum ConfirmationGate {
    public enum Verdict: Equatable, Sendable {
        /// An auto-repeat: not a press at all.
        case ignore
        /// The panel has not had the user's attention since the check appeared.
        case notArmed
        case tooSoon
        case expired
        case approve
    }

    public static func decide(shownAt: Date, armedAt: Date?, now: Date, isRepeat: Bool,
                              delay: TimeInterval, lifetime: TimeInterval) -> Verdict {
        if isRepeat { return .ignore }
        guard let armedAt else { return .notArmed }
        let elapsed = now.timeIntervalSince(max(armedAt, shownAt))
        if elapsed < delay { return .tooSoon }
        if elapsed > lifetime { return .expired }
        return .approve
    }
}

/// What the timed hide does when it comes due.
public enum AutoHidePolicy {
    public enum Decision: Equatable, Sendable {
        case hide
        /// A request is running or a check is waiting: resume when it ends.
        case busy
        /// The panel has the keyboard: resume when focus leaves.
        case waitForFocus
        /// The pointer is over the panel: resume when it leaves.
        case pauseForHover
    }

    public static func decide(isKey: Bool, busy: Bool, pointerOver: Bool) -> Decision {
        if busy { return .busy }
        if isKey { return .waitForFocus }
        if pointerOver { return .pauseForHover }
        return .hide
    }
}

/// Where a panel request came from. Decides who may be interrupted, whether
/// the answer is spoken, whether a safety check may take the keyboard, and
/// whose words the request carries. `voice` is push-to-talk, where the user
/// is holding the key; `wakeWord` is anything the "Hey Rusty" listener
/// heard, which may be a video, a call or someone else in the room.
public enum RequestSource: Sendable, CaseIterable {
    case typed, voice, wakeWord, dropped, scheduled

    public var isVoice: Bool { self == .voice || self == .wakeWord }

    /// The request carries words the user did not type or say while holding
    /// the key: a dropped file, a standing ask (possibly written by the
    /// model), or whatever the wake word heard. It is treated like a web
    /// page: the run starts tainted, so gated tools confirm and Rusty's
    /// memory cannot change, and the taint stays on the conversation.
    public var isUntrusted: Bool { self == .dropped || self == .scheduled || self == .wakeWord }

    /// Heard by the wake word. On top of the taint, typing, key presses,
    /// shortcuts and tricks from it always confirm.
    public var isHeard: Bool { self == .wakeWord }
}

/// The rolling history replayed to the model, with the taint carried per
/// turn. A run is tainted when any turn it replays is, so outside content
/// keeps gating side effects for as long as it is in the window the model
/// sees, and no longer.
public struct ConversationHistory: Sendable {
    public struct Turn: Sendable {
        public let role: String
        public let text: String
        public let tainted: Bool
    }

    public let capacity: Int
    public private(set) var turns: [Turn] = []

    public init(capacity: Int) { self.capacity = capacity }

    public mutating func append(role: String, text: String, tainted: Bool) {
        turns.append(Turn(role: role, text: text, tainted: tainted))
        if turns.count > capacity { turns.removeFirst(turns.count - capacity) }
    }

    /// Every turn but the newest (the request now being made) carried
    /// nothing from outside.
    public var priorTurnsTainted: Bool { turns.dropLast().contains(where: \.tainted) }

    public var plain: [(role: String, text: String)] { turns.map { (role: $0.role, text: $0.text) } }
}
