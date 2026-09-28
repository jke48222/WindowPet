import AVFoundation
import Foundation
import WindowPetCore

/// Microsoft's neural read-aloud voices through the community edge-tts tool
/// (keyless, no account). The reply text is sent to Microsoft's online
/// service, so this provider is opt-in: VoiceInput uses it only when the user
/// picked it, and the menu item should carry `privacyNote`. Finds a python3
/// that has the edge_tts package; callers fall back to the system voice when
/// it is unavailable or fails.
@MainActor
final class EdgeTTSPlayer: NSObject, AVAudioPlayerDelegate {

    /// One line for the menu or a confirmation, shown before the user opts in.
    static let privacyNote = "Sends the text of each spoken reply to Microsoft's online read-aloud service. Replies can quote your clipboard, files and screen."

    /// Fires when playback actually ends (voice follow-up gating).
    var onFinished: (() -> Void)?

    // AVFoundation calls this back without an actor, so hop before touching
    // the callback the rest of the app installed on the main thread.
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.onFinished?() }
    }

    private var player: AVAudioPlayer?
    private var currentProcess: Process?
    /// Bumped by every speak() and stop(). A synthesis that finishes under an
    /// older token was superseded or stopped on purpose: it plays nothing and
    /// reports nothing, so the caller never mistakes it for a failure and
    /// re-speaks the stale line in the system voice.
    private var speechToken = 0

    // MARK: - Finding edge-tts (never on the main thread)

    private enum Probe {
        case notStarted
        case running
        case found(String)
        case missing(since: Date)
    }

    private static var probe: Probe = .notStarted
    private static var probeWaiters: [@MainActor (Bool) -> Void] = []

    /// How long a failed search is trusted before one more background look,
    /// so installing edge-tts later is noticed without a relaunch. `refresh()`
    /// looks again immediately.
    static let missRetryInterval: TimeInterval = 30 * 60

    /// The python3 that can import edge_tts, if the search found one. Never
    /// blocks: when nothing is known yet it starts the background search and
    /// returns nil, so the caller uses the system voice for this reply.
    static var pythonPath: String? {
        switch probe {
        case .found(let path):
            return path
        case .notStarted:
            startProbe()
        case .missing(let since) where Date().timeIntervalSince(since) > missRetryInterval:
            startProbe()
        case .missing, .running:
            break
        }
        return nil
    }

    static var isAvailable: Bool { pythonPath != nil }

    /// For diagnostics: what the search knows, without starting one.
    static var statusDescription: String {
        switch probe {
        case .notStarted: return "not checked yet"
        case .running: return "checking"
        case .found(let path): return "available (\(path))"
        case .missing: return "NOT available"
        }
    }

    /// Starts the background search if it has not run. Call at launch when
    /// the Microsoft voice is selected, so the first reply does not wait.
    static func warmUp() {
        if case .notStarted = probe { startProbe() }
    }

    /// Searches again now, for an explicit action such as picking the
    /// Microsoft voice in the menu. `done` runs on the main actor with the
    /// result.
    static func refresh(_ done: (@MainActor (Bool) -> Void)? = nil) {
        if let done { probeWaiters.append(done) }
        if case .running = probe { return }
        startProbe()
    }

    /// Runs `done` once the search has an answer (at once if it already has).
    static func whenProbed(_ done: @escaping @MainActor (Bool) -> Void) {
        switch probe {
        case .found: done(true)
        case .missing: done(false)
        case .notStarted, .running:
            probeWaiters.append(done)
            if case .notStarted = probe { startProbe() }
        }
    }

    private static func startProbe() {
        probe = .running
        findPythonInBackground { path in
            EdgeTTSPlayer.probe = path.map { .found($0) } ?? .missing(since: Date())
            let waiters = EdgeTTSPlayer.probeWaiters
            EdgeTTSPlayer.probeWaiters = []
            waiters.forEach { $0(path != nil) }
        }
    }

    private nonisolated static func findPythonInBackground(
        _ done: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            let path = firstPythonWithEdgeTTS()
            DispatchQueue.main.async { done(path) }
        }
    }

    /// Where to look. /usr/bin/python3 is deliberately absent: it is only a
    /// shim, and on a Mac without the Command Line Tools running it opens the
    /// "install developer tools" dialog. The real interpreter inside the
    /// active developer directory is used instead, and only when it exists.
    nonisolated static func candidatePaths(developerDirectory: String?) -> [String] {
        var paths = [
            "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.14/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.13/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
        ]
        if let dir = developerDirectory, !dir.isEmpty {
            paths.append((dir as NSString).appendingPathComponent("usr/bin/python3"))
        }
        return paths
    }

    private nonisolated static func firstPythonWithEdgeTTS() -> String? {
        var seen = Set<String>()
        for path in candidatePaths(developerDirectory: activeDeveloperDirectory()) {
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            // Framework "Current" and Homebrew links often point at the same
            // interpreter; ask each one once.
            let real = (path as NSString).resolvingSymlinksInPath
            guard seen.insert(real).inserted else { continue }
            if run(path, ["-c", "import edge_tts"], timeout: 8)?.status == 0 {
                return path
            }
        }
        return nil
    }

    /// `xcode-select -p` only prints the active developer directory; unlike
    /// the /usr/bin/python3 shim it never offers to install anything.
    private nonisolated static func activeDeveloperDirectory() -> String? {
        guard let result = run("/usr/bin/xcode-select", ["-p"], timeout: 3),
              result.status == 0 else { return nil }
        let dir = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.fileExists(atPath: dir) ? dir : nil
    }

    /// Runs a short command on the calling (background) thread and gives up
    /// after `timeout`, so a hung interpreter cannot wedge the search.
    private nonisolated static func run(_ path: String, _ args: [String],
                                        timeout: TimeInterval) -> (status: Int32, output: String)? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in exited.signal() }
        do { try proc.run() } catch { return nil }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return (proc.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    var voice: String {
        UserDefaults.standard.string(forKey: "edgeVoice") ?? EdgeTTS.defaultVoice
    }

    /// Synthesises and plays `text`. completion(false) means this request
    /// genuinely failed and the caller should use the system voice. A request
    /// replaced by a newer speak() or ended by stop() never calls completion.
    func speak(_ text: String, completion: @escaping (Bool) -> Void) {
        // Supersedes whatever came before, even when this one fails early.
        cancelCurrent()
        let token = speechToken
        guard let python = Self.pythonPath else { completion(false); return }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("rusty-say-\(UUID().uuidString).mp3")
        guard let args = EdgeTTS.arguments(text: text, voice: voice, outputPath: out.path) else {
            completion(false)
            return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = args
        proc.standardError = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        currentProcess = proc
        Task { [weak self] in
            defer { try? FileManager.default.removeItem(at: out) }
            // Replaced before it even started: never launch it.
            guard let self, token == self.speechToken else { return }
            let ok = await Self.finish(proc)
            // Replaced or stopped while synthesising: the non-zero status is
            // our own SIGTERM, not a failure, and the line is no longer wanted.
            guard token == self.speechToken else { return }
            self.currentProcess = nil
            guard ok,
                  let data = try? Data(contentsOf: out), data.count > 400,
                  let player = try? AVAudioPlayer(data: data) else {
                completion(false)
                return
            }
            self.player?.stop()
            self.player = player
            player.delegate = self
            player.play()
            completion(true)
        }
    }

    /// Invalidates the request in flight and ends its process. A Process that
    /// has not launched yet must not be terminated (Foundation raises); its
    /// Task sees the new token and never launches it.
    private func cancelCurrent() {
        speechToken &+= 1
        if let proc = currentProcess, proc.isRunning { proc.terminate() }
        currentProcess = nil
    }

    /// Runs the synthesizer off the main actor. The termination handler
    /// captures only the continuation, so nothing owned by the main actor
    /// crosses threads.
    private nonisolated static func finish(_ proc: Process) async -> Bool {
        await withCheckedContinuation { continuation in
            proc.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus == 0)
            }
            do {
                try proc.run()
            } catch {
                proc.terminationHandler = nil
                continuation.resume(returning: false)
            }
        }
    }

    func stop() {
        cancelCurrent()
        player?.stop()
    }
}
