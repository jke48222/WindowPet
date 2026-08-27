import AppKit
import WindowPetCore

/// Live watches: "tell me when the build finishes."
///
/// Rusty is already standing on these windows and already counting how often
/// each app changes them, so a watch costs one comparison per second rather
/// than a new subscription. The signal is deliberately coarse: window
/// geometry and count for the app, plus the Accessibility event stream when
/// it is on. No window title is read, here or anywhere.
@MainActor
final class WatchRegistry {

    /// Called when a watch resolves, with the sentence to say out loud.
    var onFire: ((String) -> Void)?

    private var watches: [WatchPolicy.Watch] = []
    private var lastActivity: [Int: TimeInterval] = [:]
    /// The fingerprint of an app's windows last time we looked. A change in
    /// any window's position, size or count counts as activity.
    private var fingerprints: [Int: String] = [:]
    private var nextID = 1
    private var ticker: DispatchSourceTimer?

    var active: [WatchPolicy.Watch] { watches }

    /// Starts a watch and returns what to tell the user, or a refusal.
    func watch(app rawApp: String, reason: String, now: TimeInterval) -> String {
        guard watches.count < WatchPolicy.maxConcurrent else {
            return "I am already watching \(watches.count) things, which is my limit. Ask me to stop watching one first."
        }
        guard let running = AssistantExecutor.runningApp(named: rawApp) else {
            return "\(rawApp) isn't running, so there is nothing for me to watch."
        }
        let name = running.localizedName ?? rawApp
        if let existing = watches.first(where: { $0.app == name }) {
            return "I am already watching \(existing.app)."
        }
        let watch = WatchPolicy.Watch(id: nextID, app: name, reason: reason, startedAt: now)
        nextID += 1
        watches.append(watch)
        lastActivity[watch.id] = now
        fingerprints[watch.id] = fingerprint(forApp: name)
        startTickerIfNeeded()
        return WatchPolicy.acknowledgement(watch)
    }

    func stop(matching raw: String) -> String {
        let needle = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !watches.isEmpty else { return "I am not watching anything." }
        if needle.isEmpty || needle == "everything" || needle == "all" {
            let count = watches.count
            clear()
            return "Stopped watching \(count) \(count == 1 ? "thing" : "things")."
        }
        guard let index = watches.firstIndex(where: { $0.app.lowercased().contains(needle) }) else {
            return "I am not watching anything called \(raw)."
        }
        let removed = watches.remove(at: index)
        lastActivity[removed.id] = nil
        fingerprints[removed.id] = nil
        if watches.isEmpty { stopTicker() }
        return "Stopped watching \(removed.app)."
    }

    func listing() -> String { WatchPolicy.listing(watches) }

    func clear() {
        watches.removeAll()
        lastActivity.removeAll()
        fingerprints.removeAll()
        stopTicker()
    }

    /// An Accessibility event about `pid` counts as activity for any watch on
    /// that app. Cheap, and it catches apps that churn their title while
    /// leaving their window exactly where it is.
    func noteActivity(pid: pid_t, now: TimeInterval) {
        guard !watches.isEmpty,
              let name = NSRunningApplication(processIdentifier: pid)?.localizedName else { return }
        for watch in watches where watch.app == name {
            lastActivity[watch.id] = now
        }
    }

    // MARK: - The tick

    private func startTickerIfNeeded() {
        guard ticker == nil else { return }
        // Once a second. A watch is a promise measured in tens of seconds, so
        // anything faster is spending battery to be no more correct.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        ticker = timer
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    private func tick() {
        guard !watches.isEmpty else { return stopTicker() }
        let now = CACurrentMediaTime()
        var fired: [(WatchPolicy.Watch, WatchPolicy.Outcome)] = []

        for watch in watches {
            let running = AssistantExecutor.runningApp(named: watch.app) != nil
            if running {
                let current = fingerprint(forApp: watch.app)
                if current != fingerprints[watch.id] {
                    fingerprints[watch.id] = current
                    lastActivity[watch.id] = now
                }
            }
            let outcome = WatchPolicy.evaluate(watch,
                                               lastActivityAt: lastActivity[watch.id] ?? watch.startedAt,
                                               appRunning: running, now: now)
            if outcome != .waiting { fired.append((watch, outcome)) }
        }

        for (watch, outcome) in fired {
            watches.removeAll { $0.id == watch.id }
            lastActivity[watch.id] = nil
            fingerprints[watch.id] = nil
            if let message = WatchPolicy.message(for: outcome, watch: watch) {
                onFire?(message)
            }
        }
        if watches.isEmpty { stopTicker() }
    }

    /// Position, size and count of the app's windows, as one comparable
    /// string. Geometry only, and no title anywhere near it.
    private func fingerprint(forApp name: String) -> String {
        WindowInventory.snapshots()
            .filter { $0.app == name }
            .map { "\(Int($0.frame.minX)),\(Int($0.frame.minY)),\(Int($0.frame.width)),\(Int($0.frame.height))" }
            .joined(separator: "|")
    }
}
