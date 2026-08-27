import AVFoundation
import Foundation
import WindowPetCore

/// Free neural TTS: runs the community edge-tts tool (Microsoft Edge
/// read-aloud voices — keyless, no account, unofficial-but-stable) and plays
/// the result. Finds a python3 that has the edge_tts package; callers fall
/// back to other providers when unavailable or failing.
final class EdgeTTSPlayer: NSObject, AVAudioPlayerDelegate {

    /// Fires when playback actually ends (voice follow-up gating).
    var onFinished: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinished?()
    }

    private var player: AVAudioPlayer?
    private var currentProcess: Process?
    private static var cachedPython: String?

    static var pythonPath: String? {
        if let cached = cachedPython { return cached }
        let candidates = [
            "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.14/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: path)
            probe.arguments = ["-c", "import edge_tts"]
            probe.standardError = FileHandle.nullDevice
            probe.standardOutput = FileHandle.nullDevice
            do {
                try probe.run()
                probe.waitUntilExit()
                if probe.terminationStatus == 0 {
                    cachedPython = path
                    return path
                }
            } catch { continue }
        }
        return nil
    }

    static var isAvailable: Bool { pythonPath != nil }

    var voice: String {
        UserDefaults.standard.string(forKey: "edgeVoice") ?? EdgeTTS.defaultVoice
    }

    func speak(_ text: String, completion: @escaping (Bool) -> Void) {
        guard let python = Self.pythonPath else { completion(false); return }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("rusty-say-\(UUID().uuidString).mp3")
        guard let args = EdgeTTS.arguments(text: text, voice: voice, outputPath: out.path) else {
            completion(false)
            return
        }
        currentProcess?.terminate()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = args
        proc.standardError = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                defer { try? FileManager.default.removeItem(at: out) }
                guard p.terminationStatus == 0,
                      let data = try? Data(contentsOf: out), data.count > 400,
                      let player = try? AVAudioPlayer(data: data) else {
                    completion(false)
                    return
                }
                self?.player?.stop()
                self?.player = player
                player.delegate = self
                player.play()
                completion(true)
            }
        }
        do {
            try proc.run()
            currentProcess = proc
        } catch {
            completion(false)
        }
    }

    func stop() {
        currentProcess?.terminate()
        player?.stop()
    }
}
