import Foundation

/// The daily spend ceiling. Reporting a bill after the fact is not a control,
/// so this is the piece that actually stops work: it is consulted before every
/// model call, including each iteration of the agentic loop, which means a
/// runaway plan costs one more iteration rather than a whole day's budget.
///
/// Pure policy, no clock and no storage, so every branch is testable.
public enum BudgetPolicy {

    /// What Rusty ships with. A ceiling nobody set is not a ceiling, so the
    /// default is a real number rather than "off".
    public static let defaultLimit = 5.0

    /// Zero means no ceiling. Spelled out because "limit: 0" reads like
    /// "spend nothing" at a glance, and it means the opposite.
    public static let unlimited = 0.0

    /// Where the user starts hearing about it, as a fraction of the limit.
    public static let warnFraction = 0.8

    public enum State: Equatable {
        case ok
        case nearLimit
        case exceeded
    }

    public static func state(spent: Double, limit: Double) -> State {
        guard limit > unlimited else { return .ok }
        if spent >= limit { return .exceeded }
        if spent >= limit * warnFraction { return .nearLimit }
        return .ok
    }

    /// Checked before a call rather than after, so the ceiling is a gate and
    /// not a postmortem.
    public static func allowsCall(spent: Double, limit: Double) -> Bool {
        state(spent: spent, limit: limit) != .exceeded
    }

    /// Sub-cent amounts read as "under a cent" rather than a misleading $0.00.
    public static func money(_ amount: Double) -> String {
        amount > 0 && amount < 0.01 ? "under a cent" : String(format: "$%.2f", amount)
    }

    /// The ceiling always reads as a dollar amount. `money` is for what was
    /// spent, where "under a cent" is the honest answer; "my under a cent
    /// daily limit" is not a sentence, and nobody sets a sub-cent ceiling.
    public static func limitAmount(_ limit: Double) -> String {
        String(format: "$%.2f", limit)
    }

    /// In Rusty's voice, and it names the way out instead of only refusing.
    public static func exceededMessage(spent: Double, limit: Double) -> String {
        "I have spent \(money(spent)) on thinking today, which is my \(limitAmount(limit)) daily limit. Raise it under Daily Spend Limit in the menu bar and I will pick this back up."
    }

    public static func nearLimitMessage(spent: Double, limit: Double) -> String {
        "Worth knowing: \(money(spent)) of my \(limitAmount(limit)) daily limit is spent."
    }

    /// Parses what someone types into the limit box. Accepts "5", "$5",
    /// "5.50", and the words for switching it off. Anything else returns nil
    /// so a typo cannot quietly remove the ceiling.
    public static func parseLimit(_ raw: String) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if ["none", "off", "no limit", "unlimited"].contains(text) { return unlimited }
        var stripped = text
        if stripped.hasPrefix("$") { stripped.removeFirst() }
        stripped = stripped.replacingOccurrences(of: ",", with: "")
        guard let value = Double(stripped), value.isFinite, value >= 0 else { return nil }
        return value
    }

    /// How the ceiling reads in the menu.
    public static func limitDescription(_ limit: Double) -> String {
        limit <= unlimited ? "no limit" : "\(limitAmount(limit)) a day"
    }
}
