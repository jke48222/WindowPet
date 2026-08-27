import Foundation
import WindowPetCore

/// Tracks what Rusty's thinking actually costs, so the bill is never a
/// surprise. Reads token counts straight out of the streamed events and
/// keeps a running total for today, persisted across launches.
///
/// Prices are the published per-million rates for the model in use; cached
/// reads are far cheaper than fresh input, which is why the agentic loop's
/// cache breakpoint matters and why they're counted separately.
final class UsageMeter {
    static let shared = UsageMeter()

    private struct Rates {
        let input: Double
        let cachedRead: Double
        let output: Double
    }

    /// Dollars per million tokens.
    private static let rates: [String: Rates] = [
        "claude-opus-5": Rates(input: 5, cachedRead: 0.5, output: 25),
        "claude-opus-4-8": Rates(input: 5, cachedRead: 0.5, output: 25),
        "claude-sonnet-5": Rates(input: 3, cachedRead: 0.3, output: 15),
        "claude-fable-5": Rates(input: 10, cachedRead: 1, output: 50),
        "claude-haiku-4-5": Rates(input: 1, cachedRead: 0.1, output: 5),
    ]

    private let dayKey = "usageDay"
    private let inputKey = "usageInput"
    private let cachedKey = "usageCached"
    private let outputKey = "usageOutput"

    private var input = 0
    private var cached = 0
    private var output = 0

    private init() {
        rolloverIfNeeded()
        let defaults = UserDefaults.standard
        input = defaults.integer(forKey: inputKey)
        cached = defaults.integer(forKey: cachedKey)
        output = defaults.integer(forKey: outputKey)
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
            defaults.set(0, forKey: inputKey)
            defaults.set(0, forKey: cachedKey)
            defaults.set(0, forKey: outputKey)
            input = 0; cached = 0; output = 0
        }
    }

    func record(input newInput: Int, cached newCached: Int, output newOutput: Int) {
        rolloverIfNeeded()
        input += newInput
        cached += newCached
        output += newOutput
        let defaults = UserDefaults.standard
        defaults.set(input, forKey: inputKey)
        defaults.set(cached, forKey: cachedKey)
        defaults.set(output, forKey: outputKey)
    }

    var todaysCost: Double {
        let rate = Self.rates[ClaudeRouter.model] ?? Self.rates["claude-opus-5"]!
        return (Double(input) / 1_000_000) * rate.input
            + (Double(cached) / 1_000_000) * rate.cachedRead
            + (Double(output) / 1_000_000) * rate.output
    }

    /// One line for the menu. Sub-cent days read as "under a cent" rather
    /// than a misleading $0.00.
    var summary: String {
        rolloverIfNeeded()
        let total = input + cached + output
        guard total > 0 else { return "Usage today: nothing yet" }
        let cost = todaysCost
        let money = cost < 0.01 ? "under a cent" : String(format: "$%.2f", cost)
        let tokens = total >= 1000 ? "\(total / 1000)k tokens" : "\(total) tokens"
        return "Usage today: \(tokens), \(money)"
    }
}
