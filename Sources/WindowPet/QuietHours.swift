import AVFoundation
import AppKit
import WindowPetCore

/// Reads whether now is a bad time to speak, and holds what he wanted to say
/// until it is not.
///
/// Every signal here comes from state the app can already see, with no new
/// permissions: the Focus database macOS writes for its own use, the audio
/// system's own "somebody else has the microphone" flag, and the engine's
/// existing sense of full-screen immersion.
@MainActor
final class QuietHours {

    /// Delivers a held announcement when the moment passes.
    var onRelease: ((String) -> Void)?
    /// Whether Rusty is mid-sentence, supplied by the app.
    var speakingProvider: (() -> Bool)?
    /// Whether the engine is suspended (screen locked, machine asleep).
    var suspendedProvider: (() -> Bool)?
    /// Whether something is full screen.
    var immersionProvider: (() -> Bool)?

    private struct Held {
        let text: String
        let reason: String
        let at: Date
    }

    private var held: [Held] = []
    private var ticker: DispatchSourceTimer?

    var isEnabled: Bool {
        // On by default. An assistant that talks over a call once has already
        // lost the argument for talking at all.
        UserDefaults.standard.object(forKey: "quietHours") == nil
            || UserDefaults.standard.bool(forKey: "quietHours")
    }

    var conditions: QuietPolicy.Conditions {
        QuietPolicy.Conditions(
            focusOn: Self.focusIsOn,
            micInUse: Self.microphoneInUseElsewhere,
            immersion: immersionProvider?() ?? false,
            speaking: speakingProvider?() ?? false,
            suspended: suspendedProvider?() ?? false)
    }

    /// Returns the text to say now, or nil when it was held for later.
    /// `showAnyway` is what the panel should display regardless: a held
    /// message still belongs in the transcript, it just does not interrupt.
    func offer(_ text: String) -> (speak: String?, show: String) {
        guard isEnabled else { return (text, text) }
        switch QuietPolicy.verdict(conditions) {
        case .speak:
            return (text, text)
        case .showSilently:
            return (nil, text)
        case .hold(let reason):
            held.append(Held(text: text, reason: reason, at: Date()))
            startTickerIfNeeded()
            return (nil, text)
        }
    }

    var heldCount: Int { held.count }

    func clear() {
        held.removeAll()
        stopTicker()
    }

    private func startTickerIfNeeded() {
        guard ticker == nil else { return }
        // Every fifteen seconds. A held message is not urgent by definition,
        // and polling the Focus file harder would cost more than it is worth.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        ticker = timer
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    private func tick() {
        guard !held.isEmpty else { return stopTicker() }
        // Anything too old is dropped rather than delivered: a build that
        // finished two hours ago is not news.
        let now = Date()
        held.removeAll { QuietPolicy.isStale(waited: now.timeIntervalSince($0.at)) }
        guard !QuietPolicy.shouldHold(conditions) else {
            if held.isEmpty { stopTicker() }
            return
        }
        let ready = held
        held.removeAll()
        stopTicker()
        for item in ready {
            let waited = now.timeIntervalSince(item.at)
            onRelease?(QuietPolicy.heldPreamble(reason: item.reason, waited: waited) + item.text)
        }
    }

    // MARK: - Reading the machine

    /// Another app holds the microphone, which in practice means a call.
    /// AVFoundation answers this without any capture session of our own.
    static var microphoneInUseElsewhere: Bool {
        guard let device = AVCaptureDevice.default(for: .audio) else { return false }
        return device.isInUseByAnotherApplication
    }

    /// macOS keeps the current Focus in a small database under the user's
    /// library. There is no public API for it, so this reads the file and
    /// treats any failure as "not in Focus": guessing wrong toward silence
    /// would mean a watch that never fires, which is worse than one that
    /// speaks during a Focus mode.
    static var focusIsOn: Bool {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
        guard let data = try? Data(contentsOf: base),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let records = root["data"] as? [[String: Any]] else { return false }
        // An active Focus writes a storeAssertionRecords entry; an empty list
        // is the normal, nothing-on state.
        return records.contains { record in
            guard let assertions = record["storeAssertionRecords"] as? [[String: Any]] else {
                return false
            }
            return !assertions.isEmpty
        }
    }
}
