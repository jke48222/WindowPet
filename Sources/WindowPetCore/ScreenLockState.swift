import Foundation

/// The lock and sleep rules as a pure state machine, so the decision can be
/// checked without a real lock screen.
///
/// The rule it encodes: anything that listens, speaks or animates stops the
/// moment the Mac sleeps or locks, and starts again only when the Mac is both
/// awake and unlocked. Waking is not unlocking. With a password required
/// after sleep, `didWake` arrives while the lock screen is still up, and
/// `screenIsUnlocked` only comes after the user authenticates.
public struct ScreenLockState: Equatable, Sendable {
    public enum Event: Sendable {
        case locked, unlocked, willSleep
        /// `sessionLocked` is what the window server reports at wake time.
        case didWake(sessionLocked: Bool)
    }
    public enum Action: Sendable { case suspend, resume }

    public private(set) var isLocked: Bool
    public private(set) var isAsleep = false

    public init(isLocked: Bool) { self.isLocked = isLocked }

    /// True while the Mac is locked or asleep.
    public var isSuspended: Bool { isLocked || isAsleep }

    /// Applies one event and says what listeners should do, if anything.
    public mutating func apply(_ event: Event) -> Action? {
        let wasSuspended = isSuspended
        switch event {
        case .locked:
            isLocked = true
        case .unlocked:
            isLocked = false
        case .willSleep:
            isAsleep = true
        case .didWake(let sessionLocked):
            isAsleep = false
            // The lock notification can land after wake, or not at all when
            // the lock happened during sleep. The session state is the
            // authority at this moment.
            if sessionLocked { isLocked = true }
        }
        if isSuspended { return .suspend }
        return wasSuspended ? .resume : nil
    }
}
