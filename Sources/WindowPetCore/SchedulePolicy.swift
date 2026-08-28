import Foundation

/// Standing asks: "every weekday at nine, tell me my first meeting."
///
/// Rusty is already running all day, which is the only reason this is worth
/// building: a scheduled ask needs no daemon, no login item beyond the app
/// itself, and no server. Parsing and next-fire arithmetic are pure so the
/// calendar edge cases are testable without waiting for Tuesday.
public enum SchedulePolicy {

    /// More than a handful of standing asks is a to-do list, not an assistant,
    /// and each one spends money when it fires.
    public static let maxEntries = 10

    public enum Cadence: String, Codable, Equatable, Sendable {
        case once
        case daily
        case weekdays
        case weekends
        case weekly
    }

    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public let id: Int
        /// What to ask, in the user's words, run through the agent when due.
        public let request: String
        public let cadence: Cadence
        /// Minutes since midnight, local time.
        public let minuteOfDay: Int
        /// For `weekly`, 1 is Sunday, matching Calendar's weekday numbering.
        public let weekday: Int?
        /// Absolute fire time for `once`, which needs no recurrence maths.
        public let fireAt: Date?
        public private(set) var lastFiredAt: Date?

        public init(id: Int, request: String, cadence: Cadence, minuteOfDay: Int,
                    weekday: Int? = nil, fireAt: Date? = nil, lastFiredAt: Date? = nil) {
            self.id = id
            self.request = request
            self.cadence = cadence
            self.minuteOfDay = minuteOfDay
            self.weekday = weekday
            self.fireAt = fireAt
            self.lastFiredAt = lastFiredAt
        }

        public mutating func markFired(at date: Date) { lastFiredAt = date }

        public var timeOfDay: String {
            let hour = minuteOfDay / 60, minute = minuteOfDay % 60
            let suffix = hour < 12 ? "am" : "pm"
            let display = hour % 12 == 0 ? 12 : hour % 12
            return minute == 0 ? "\(display)\(suffix)"
                               : String(format: "%d:%02d%@", display, minute, suffix)
        }

        public var description: String {
            switch cadence {
            case .once:
                return "once at \(timeOfDay): \(request)"
            case .daily:
                return "every day at \(timeOfDay): \(request)"
            case .weekdays:
                return "every weekday at \(timeOfDay): \(request)"
            case .weekends:
                return "every weekend at \(timeOfDay): \(request)"
            case .weekly:
                let name = SchedulePolicy.weekdayNames[(weekday ?? 2) - 1]
                return "every \(name) at \(timeOfDay): \(request)"
            }
        }
    }

    public static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday",
                                      "Thursday", "Friday", "Saturday"]

    // MARK: - Is it due

    /// True when `entry` should run now. Deliberately conservative in two
    /// ways: it never fires twice in the same minute, and it never fires for a
    /// slot that has already passed by more than the grace window, so a laptop
    /// waking at 3pm does not replay every morning it slept through.
    public static let graceMinutes = 10

    public static func isDue(_ entry: Entry, now: Date, calendar: Calendar = .current) -> Bool {
        if let fireAt = entry.fireAt, entry.cadence == .once {
            guard entry.lastFiredAt == nil else { return false }
            let elapsed = now.timeIntervalSince(fireAt)
            return elapsed >= 0 && elapsed <= Double(graceMinutes) * 60
        }
        let components = calendar.dateComponents([.hour, .minute, .weekday], from: now)
        guard let hour = components.hour, let minute = components.minute,
              let weekday = components.weekday else { return false }
        guard matches(cadence: entry.cadence, weekday: weekday, entryWeekday: entry.weekday) else {
            return false
        }
        let nowMinutes = hour * 60 + minute
        let elapsed = nowMinutes - entry.minuteOfDay
        guard elapsed >= 0, elapsed <= graceMinutes else { return false }
        // Once per day, however many times the tick runs inside the window.
        if let last = entry.lastFiredAt, calendar.isDate(last, inSameDayAs: now) { return false }
        return true
    }

    static func matches(cadence: Cadence, weekday: Int, entryWeekday: Int?) -> Bool {
        switch cadence {
        case .daily: return true
        // Calendar numbers Sunday as 1 and Saturday as 7.
        case .weekdays: return weekday >= 2 && weekday <= 6
        case .weekends: return weekday == 1 || weekday == 7
        case .weekly: return weekday == entryWeekday
        case .once: return false
        }
    }

    // MARK: - Parsing what a person says

    /// Reads "every weekday at 9: tell me my first meeting" and the shapes
    /// around it. The request is whatever follows the colon, or whatever is
    /// left once the timing words are removed.
    public static func parse(_ raw: String, id: Int, now: Date = Date(),
                             calendar: Calendar = .current) -> Entry? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var timing = trimmed
        var request = ""
        if let colon = trimmed.firstIndex(of: ":") {
            timing = String(trimmed[trimmed.startIndex..<colon])
            request = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
        }
        guard !request.isEmpty else { return nil }

        let lowered = timing.lowercased()

        // "in 20 minutes" and "in 2 hours" are one-off reminders.
        if let relative = relativeFireDate(from: lowered, now: now) {
            let components = calendar.dateComponents([.hour, .minute], from: relative)
            return Entry(id: id, request: request, cadence: .once,
                         minuteOfDay: (components.hour ?? 0) * 60 + (components.minute ?? 0),
                         fireAt: relative)
        }

        guard let minuteOfDay = timeOfDay(in: lowered) else { return nil }

        if lowered.contains("weekday") {
            return Entry(id: id, request: request, cadence: .weekdays, minuteOfDay: minuteOfDay)
        }
        if lowered.contains("weekend") {
            return Entry(id: id, request: request, cadence: .weekends, minuteOfDay: minuteOfDay)
        }
        for (index, name) in weekdayNames.enumerated() where lowered.contains(name.lowercased()) {
            return Entry(id: id, request: request, cadence: .weekly,
                         minuteOfDay: minuteOfDay, weekday: index + 1)
        }
        if lowered.contains("every day") || lowered.contains("daily")
            || lowered.contains("each day") {
            return Entry(id: id, request: request, cadence: .daily, minuteOfDay: minuteOfDay)
        }
        // A bare time with no recurrence word means the next time it comes
        // round, once.
        let fireAt = nextOccurrence(ofMinute: minuteOfDay, after: now, calendar: calendar)
        return Entry(id: id, request: request, cadence: .once,
                     minuteOfDay: minuteOfDay, fireAt: fireAt)
    }

    /// "in 20 minutes", "in an hour", "in 2 hours".
    static func relativeFireDate(from lowered: String, now: Date) -> Date? {
        guard lowered.contains("in ") else { return nil }
        let pattern = #"in\s+(a|an|one|\d+)\s*(minute|minutes|min|mins|hour|hours|hr|hrs)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: lowered,
                                           range: NSRange(lowered.startIndex..., in: lowered)),
              let countRange = Range(match.range(at: 1), in: lowered),
              let unitRange = Range(match.range(at: 2), in: lowered) else { return nil }
        let countText = String(lowered[countRange])
        let count = ["a", "an", "one"].contains(countText) ? 1 : (Int(countText) ?? 0)
        guard count > 0 else { return nil }
        let unit = String(lowered[unitRange])
        let seconds = unit.hasPrefix("h") ? count * 3600 : count * 60
        return now.addingTimeInterval(TimeInterval(seconds))
    }

    /// Reads "9", "9am", "09:30", "6:15pm", "half past" is not supported on
    /// purpose: a schedule that half-understands a time is worse than one that
    /// asks again.
    public static func timeOfDay(in lowered: String) -> Int? {
        let pattern = #"(\d{1,2})(?::(\d{2}))?\s*(am|pm)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(lowered.startIndex..., in: lowered)
        for match in regex.matches(in: lowered, range: range) {
            guard let hourRange = Range(match.range(at: 1), in: lowered),
                  var hour = Int(lowered[hourRange]) else { continue }
            var minute = 0
            if let minuteRange = Range(match.range(at: 2), in: lowered) {
                minute = Int(lowered[minuteRange]) ?? 0
            }
            var meridiem: String?
            if let meridiemRange = Range(match.range(at: 3), in: lowered) {
                meridiem = String(lowered[meridiemRange])
            }
            if let meridiem {
                guard hour >= 1, hour <= 12 else { continue }
                if meridiem == "pm", hour != 12 { hour += 12 }
                if meridiem == "am", hour == 12 { hour = 0 }
            } else {
                guard hour <= 23 else { continue }
            }
            guard minute <= 59 else { continue }
            return hour * 60 + minute
        }
        return nil
    }

    static func nextOccurrence(ofMinute minuteOfDay: Int, after now: Date,
                               calendar: Calendar) -> Date {
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = minuteOfDay / 60
        components.minute = minuteOfDay % 60
        components.second = 0
        let today = calendar.date(from: components) ?? now
        return today > now ? today : today.addingTimeInterval(24 * 3600)
    }

    // MARK: - Talking about it

    public static func acknowledgement(_ entry: Entry) -> String {
        "Set: \(entry.description)"
    }

    public static func listing(_ entries: [Entry]) -> String {
        guard !entries.isEmpty else {
            return "Nothing is scheduled. Ask me to do something at a time, like every weekday at 9: tell me what is on my calendar."
        }
        return entries.enumerated()
            .map { "\($0.offset + 1). \($0.element.description)" }
            .joined(separator: "\n")
    }

    /// Said before a scheduled run, so an answer arriving unprompted is never
    /// mysterious.
    public static func preamble(_ entry: Entry) -> String {
        "You asked me to do this at \(entry.timeOfDay)."
    }
}
