import CoreGraphics
import Foundation

/// Exponentially-decaying event rate (τ-based). Used for window-title-change
/// frequency: a compiling Terminal retitles constantly; a quiet one doesn't.
/// Pure and clock-agnostic — timestamps come in, rates come out.
public struct DecayingRate {
    public let tau: TimeInterval
    private var value: Double = 0
    private var lastAt: TimeInterval = 0

    public init(tau: TimeInterval = 3.0) { self.tau = tau }

    public mutating func hit(at now: TimeInterval) {
        value = rate(at: now) + 1
        lastAt = now
    }

    /// Events-per-τ-window equivalent, decayed to `now`.
    public func rate(at now: TimeInterval) -> Double {
        guard lastAt > 0 else { return 0 }
        return value * exp(-max(0, now - lastAt) / tau)
    }
}

/// Reaction thresholds, pinned and pure. The engine asks; this answers.
public enum ReactionPolicy {
    /// Fullscreen video/game: window covers essentially the whole screen.
    /// Deliberately above "maximized" (~96–97% with the menu bar visible).
    public static let immersionCoverage: CGFloat = 0.985
    /// User-away gap that earns a welcome-back greeting.
    public static let awayThreshold: TimeInterval = 90
    /// Title-change rate that reads as "something is happening in there".
    public static let agitationRate: Double = 1.2

    public static let distractionBundleIDs: Set<String> = [
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.microsoft.teams2",
        "com.atebits.Tweetie2", // X
    ]

    public static func isImmersive(coverage: CGFloat) -> Bool {
        coverage >= immersionCoverage
    }

    public static func isReturnGreeting(awaySeconds: TimeInterval) -> Bool {
        awaySeconds >= awayThreshold
    }

    /// Idle long enough, by the system's own idle clock (keys, scrolling,
    /// trackpad, pointer, clicks), to count as away.
    public static func isAway(idleSeconds: TimeInterval) -> Bool {
        idleSeconds >= awayThreshold
    }

    /// How long the user has been away when the Mac comes back from a lock
    /// or sleep: the idle time they had built up when it locked, plus the
    /// time it stayed locked (wall clock, since the media clock stops during
    /// sleep). A clock that went backwards counts as no time.
    public static func awayAcrossSuspend(idleAtSuspend: TimeInterval,
                                         suspendedFor: TimeInterval) -> TimeInterval {
        max(0, idleAtSuspend) + max(0, suspendedFor)
    }

    /// Input happened since the previous sample: the idle clock went back.
    /// Samples arrive every few hundred milliseconds, so a real event shows
    /// up as a drop of well over the slack.
    public static func inputResumed(previousIdle: TimeInterval, idle: TimeInterval,
                                    slack: TimeInterval = 0.25) -> Bool {
        idle + slack < previousIdle
    }

    public static func isDistraction(bundleID: String?) -> Bool {
        bundleID.map(distractionBundleIDs.contains) ?? false
    }

    public static func isAgitated(titleRate: Double) -> Bool {
        titleRate >= agitationRate
    }
}
