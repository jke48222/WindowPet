import Foundation

/// Adaptive Tier-1 polling cadence. Energy is the product constraint
/// (budgets: <0.3% CPU idle, <3% active), so the poll rate follows observed
/// motion instead of running hot:
///
///   no target      → 2 Hz   (waiting for a window to exist)
///   target, still  → 10 Hz  (dossier's Tier-1 band; drag-start latency ≤100 ms)
///   target, moving → 60 Hz  (only while frames are actually changing)
///
/// "Moving" means a frame change was seen within `motionHoldSeconds`.
/// This is a plain timer policy for the milestone; the CADisplayLink swap
/// (CVDisplayLink is deprecated on modern macOS) comes with real animation in S2.
public enum RatePolicy {
    public static let motionHoldSeconds: TimeInterval = 0.6

    public static let deepIdleAfterSeconds: TimeInterval = 20

    public static func interval(hasTarget: Bool, sinceMotion: TimeInterval) -> TimeInterval {
        guard hasTarget else { return 0.5 }
        if sinceMotion < motionHoldSeconds { return 1.0 / 60.0 }
        // Deep idle: nothing has moved for a while; 4 Hz (bottom of the
        // dossier's Tier-1 band) halves-again the idle wakeup cost. Workspace
        // notifications still retarget instantly; only drag-START latency
        // after long stillness pays (≤250 ms, then 60 Hz catches up).
        return sinceMotion > deepIdleAfterSeconds ? 0.25 : 0.1
    }
}
