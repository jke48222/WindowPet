import Foundation

/// Evidence-based Tier-2 health policy, kept pure for testing.
///
/// The problem it solves: Electron apps (Slack, VS Code, Discord, Notion…)
/// ship with accessibility disabled; an AXObserver attaches "successfully"
/// and then simply never fires. Instead of trusting bundle sniffing, we watch
/// for the contradiction: Tier 1 saw the app's windows MOVE, but Tier 2 heard
/// nothing for a whole probation period. First contradiction → set Electron's
/// documented `AXManualAccessibility` hook and keep listening. Second → mark
/// the app degraded: the pet still stands on its windows correctly (Tier 1),
/// it just has no event-driven opinions about them.
public enum Tier2Policy {
    public enum Decision: Equatable {
        case none
        case forceManualAccessibility
        case markDegraded
    }

    public static let probationSeconds: TimeInterval = 4

    public static func probe(attachedFor: TimeInterval,
                             eventsSeen: Int,
                             sawTier1Motion: Bool,
                             alreadyForced: Bool,
                             alreadyDegraded: Bool) -> Decision {
        guard !alreadyDegraded,
              eventsSeen == 0,
              sawTier1Motion,
              attachedFor >= probationSeconds else { return .none }
        return alreadyForced ? .markDegraded : .forceManualAccessibility
    }
}
