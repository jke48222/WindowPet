import Foundation
import WindowPetCore

/// Tracks what Rusty's thinking actually costs, so the bill is never a
/// surprise. Every model call (the streamed agent turns, the one-shot router
/// and the screen `look`) reports its usage here, and today's spend is kept
/// in dollars, priced per call at the model that made it.
///
/// Prices are the published per-million rates. Cache reads are far cheaper
/// than fresh input and cache writes cost a premium over it, which is why
/// both are counted separately from plain input.
@MainActor
final class UsageMeter {
    static let shared = UsageMeter()

    /// Token counts for one call, as the API reports them. The four input
    /// sides are disjoint: `input` excludes both cache reads and cache writes.
    struct Usage: Equatable {
        var input = 0
        var cacheRead = 0
        var cacheWrite = 0
        var output = 0
        /// Server-side web searches run inside the call. Billed per search,
        /// not per token, so they are counted separately.
        var webSearches = 0

        var isEmpty: Bool {
            input == 0 && cacheRead == 0 && cacheWrite == 0 && output == 0 && webSearches == 0
        }

        /// Streamed usage is cumulative: `message_start` carries the input
        /// side and `message_delta` repeats or extends it. Keeping the largest
        /// value per field counts each token once however the server splits
        /// the report.
        mutating func merge(_ other: Usage) {
            input = max(input, other.input)
            cacheRead = max(cacheRead, other.cacheRead)
            cacheWrite = max(cacheWrite, other.cacheWrite)
            output = max(output, other.output)
            webSearches = max(webSearches, other.webSearches)
        }

        /// Reads the `usage` object from a response body, a `message_start`
        /// event (nested under `message`) or a `message_delta` event.
        static func from(_ object: [String: Any]) -> Usage? {
            var usage = object["usage"] as? [String: Any]
            if usage == nil, let message = object["message"] as? [String: Any] {
                usage = message["usage"] as? [String: Any]
            }
            guard let usage else { return nil }
            // `server_tool_use.web_search_requests` rides in the same object:
            // in `message_delta` for a stream, at the top level of a body.
            let serverTools = usage["server_tool_use"] as? [String: Any]
            return Usage(input: usage["input_tokens"] as? Int ?? 0,
                         cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
                         cacheWrite: usage["cache_creation_input_tokens"] as? Int ?? 0,
                         output: usage["output_tokens"] as? Int ?? 0,
                         webSearches: serverTools?["web_search_requests"] as? Int ?? 0)
        }

        /// A whole non-streaming response body.
        static func from(body: Data) -> Usage? {
            guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
                return nil
            }
            return from(root)
        }
    }

    struct Rates {
        let input: Double
        let cachedRead: Double
        let cacheWrite: Double
        let output: Double

        /// Cache reads bill at a tenth of input and five-minute cache writes
        /// at a quarter more, for every current model.
        init(input: Double, output: Double) {
            self.input = input
            self.cachedRead = input * 0.1
            self.cacheWrite = input * 1.25
            self.output = output
        }
    }

    /// Dollars per million tokens.
    static let rates: [String: Rates] = [
        "claude-fable-5-1": Rates(input: 10, output: 50),
        "claude-fable-5": Rates(input: 10, output: 50),
        "claude-opus-5": Rates(input: 5, output: 25),
        "claude-opus-4-8": Rates(input: 5, output: 25),
        "claude-sonnet-5": Rates(input: 2, output: 10),
        "claude-sonnet-4-6": Rates(input: 3, output: 15),
        "claude-haiku-4-5": Rates(input: 1, output: 5),
    ]

    /// An unknown model is priced like the default rather than as free, so
    /// the ceiling still means something.
    static func rates(for model: String) -> Rates {
        rates[model] ?? rates[ClaudeRouting.defaultModel] ?? Rates(input: 5, output: 25)
    }

    /// Web search is billed at $10 per 1,000 searches, on every model.
    static let webSearchPrice = 0.01

    /// What one call cost, in dollars: tokens at the model's rates, plus the
    /// web searches it ran.
    static func cost(of usage: Usage, model: String) -> Double {
        let rate = rates(for: model)
        return (Double(usage.input) * rate.input
            + Double(usage.cacheRead) * rate.cachedRead
            + Double(usage.cacheWrite) * rate.cacheWrite
            + Double(usage.output) * rate.output) / 1_000_000
            + Double(usage.webSearches) * webSearchPrice
    }

    private let dayKey = "usageDay"
    private let limitKey = "dailyBudget"
    private let inputKey = "usageInput"
    private let cachedKey = "usageCached"
    private let cacheWriteKey = "usageCacheWrite"
    private let outputKey = "usageOutput"
    private let costKey = "usageCost"
    private let warnedKey = "usageWarnedDay"

    private var input = 0
    private var cached = 0
    private var cacheWrite = 0
    private var output = 0
    /// Today's spend in dollars, accumulated call by call at each call's own
    /// model, so switching models mid-day never re-prices what was spent.
    private var cost: Double = 0

    private init() {
        rolloverIfNeeded()
        let defaults = UserDefaults.standard
        input = defaults.integer(forKey: inputKey)
        cached = defaults.integer(forKey: cachedKey)
        cacheWrite = defaults.integer(forKey: cacheWriteKey)
        output = defaults.integer(forKey: outputKey)
        if defaults.object(forKey: costKey) != nil {
            cost = defaults.double(forKey: costKey)
        } else {
            // A day that started before spend was kept in dollars: price the
            // tokens so far once, at the model in use, and carry on from there.
            cost = Self.cost(of: Usage(input: input, cacheRead: cached,
                                       cacheWrite: cacheWrite, output: output),
                             model: ClaudeRouter.model)
            defaults.set(cost, forKey: costKey)
        }
    }

    // Allocated once: DateFormatter is expensive to construct.
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private var today: String { Self.dayFormatter.string(from: Date()) }

    private func rolloverIfNeeded() {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: dayKey) != today {
            defaults.set(today, forKey: dayKey)
            for key in [inputKey, cachedKey, cacheWriteKey, outputKey] {
                defaults.set(0, forKey: key)
            }
            defaults.set(0.0, forKey: costKey)
            input = 0; cached = 0; cacheWrite = 0; output = 0; cost = 0
        }
    }

    /// Records one call's usage, priced at the model that made the call.
    func record(_ usage: Usage, model: String) {
        guard !usage.isEmpty else { return }
        rolloverIfNeeded()
        input += usage.input
        cached += usage.cacheRead
        cacheWrite += usage.cacheWrite
        output += usage.output
        cost += Self.cost(of: usage, model: model)
        let defaults = UserDefaults.standard
        defaults.set(input, forKey: inputKey)
        defaults.set(cached, forKey: cachedKey)
        defaults.set(cacheWrite, forKey: cacheWriteKey)
        defaults.set(output, forKey: outputKey)
        defaults.set(cost, forKey: costKey)
        // Every call site records through here, so this is the one place the
        // near-limit warning can be said the moment spending crosses it.
        if let warning = warningIfNewlyNear() { onNearLimit?(warning) }
    }

    /// Said once per day when spending first crosses the warning mark. The
    /// chat panel sets it; a headless run leaves it unset.
    var onNearLimit: ((String) -> Void)?

    /// Older call shape, kept for callers that only know three counts.
    func record(input newInput: Int, cached newCached: Int, output newOutput: Int) {
        record(Usage(input: newInput, cacheRead: newCached, output: newOutput),
               model: ClaudeRouter.model)
    }

    var todaysCost: Double {
        rolloverIfNeeded()
        return cost
    }

    // MARK: - The ceiling

    /// Dollars per day. Zero is no ceiling. Absent means nobody has changed
    /// it, so the shipping default applies rather than "unlimited".
    var limit: Double {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: limitKey) != nil else { return BudgetPolicy.defaultLimit }
            return defaults.double(forKey: limitKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: limitKey) }
    }

    var state: BudgetPolicy.State {
        rolloverIfNeeded()
        return BudgetPolicy.state(spent: todaysCost, limit: limit)
    }

    /// nil when the next model call may go ahead. Otherwise the sentence to
    /// show the user in place of making it. Callers check this immediately
    /// before spending, never after.
    var blockedMessage: String? {
        guard state == .exceeded else { return nil }
        return BudgetPolicy.exceededMessage(spent: todaysCost, limit: limit)
    }

    /// Said once per day, the first time spending crosses the warning mark,
    /// so the ceiling is never a surprise when it arrives.
    func warningIfNewlyNear() -> String? {
        guard state == .nearLimit else { return nil }
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: warnedKey) != today else { return nil }
        defaults.set(today, forKey: warnedKey)
        return BudgetPolicy.nearLimitMessage(spent: todaysCost, limit: limit)
    }

    /// One line for the menu. Sub-cent days read as "under a cent" rather
    /// than a misleading $0.00.
    var summary: String {
        rolloverIfNeeded()
        let total = input + cached + cacheWrite + output
        let ceiling = BudgetPolicy.limitDescription(limit)
        guard total > 0 else { return "Usage today: nothing yet (\(ceiling))" }
        let tokens = total >= 1000 ? "\(total / 1000)k tokens" : "\(total) tokens"
        return "Usage today: \(tokens), \(BudgetPolicy.money(todaysCost)) of \(ceiling)"
    }
}
