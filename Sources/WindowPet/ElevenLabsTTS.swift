import AVFoundation
import Foundation
import WindowPetCore

/// Plays Rusty's replies through ElevenLabs when a key is configured;
/// callers fall back to the system voice otherwise (or on any failure).
/// Key sources: UserDefaults "elevenLabsKey" (set via the menu) or the
/// ELEVENLABS_API_KEY environment variable. Voice/model overridable via
/// defaults "elevenLabsVoice" / "elevenLabsModel".
@MainActor
final class ElevenLabsTTS: NSObject, AVAudioPlayerDelegate {

    private var player: AVAudioPlayer?
    /// The in-flight request, kept so a new line of speech cancels the old one.
    private var currentTask: Task<Void, Never>?
    var onError: ((String) -> Void)?
    /// Fires when playback actually ends (voice follow-up gating).
    var onFinished: (() -> Void)?

    // AVFoundation calls back without an actor, so hop before touching the
    // callback the app installed on the main thread.
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.onFinished?() }
    }

    static var apiKey: String? {
        if let k = UserDefaults.standard.string(forKey: "elevenLabsKey"), !k.isEmpty { return k }
        if let k = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"], !k.isEmpty { return k }
        return nil
    }

    var hasKey: Bool { Self.apiKey != nil }

    /// Attempts ElevenLabs playback; completion(false) → caller should use
    /// the system voice.
    func speak(_ text: String, completion: @escaping (Bool) -> Void) {
        guard let key = Self.apiKey else { completion(false); return }
        let voice = UserDefaults.standard.string(forKey: "elevenLabsVoice") ?? ElevenLabs.defaultVoiceID
        let model = UserDefaults.standard.string(forKey: "elevenLabsModel") ?? ElevenLabs.defaultModelID
        guard let spec = ElevenLabs.speechRequest(text: text, apiKey: key,
                                                  voiceID: voice, modelID: model) else {
            completion(false)
            return
        }
        var request = URLRequest(url: spec.url, timeoutInterval: 8)
        request.httpMethod = "POST"
        spec.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = spec.body

        currentTask?.cancel()
        currentTask = Task { [weak self] in
            let fetched = try? await URLSession.shared.data(for: request)
            guard !Task.isCancelled, let self else { return }
            guard let (data, response) = fetched,
                  let http = response as? HTTPURLResponse else {
                completion(false)
                return
            }
            if http.statusCode == 401 {
                self.onError?("ElevenLabs rejected the API key. Fix it under ElevenLabs API Key… in the menu bar.")
                completion(false)
                return
            }
            guard http.statusCode == 200, data.count > 400,
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

    func stop() {
        currentTask?.cancel()
        player?.stop()
    }
}
