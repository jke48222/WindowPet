import Foundation

/// ElevenLabs text-to-speech request construction — pure so it's testable.
/// Only Rusty's short spoken REPLIES are sent (never the user's speech,
/// which is recognized on-device).
/// Free TTS via Microsoft Edge's read-aloud voices (community edge-tts
/// tool — unofficial but long-stable, keyless, neural quality). Pure arg
/// construction; the app runs the process and plays the file.
public enum EdgeTTS {
    public static let defaultVoice = "en-US-AnaNeural" // bright kid voice — tiny-robot energy

    /// Keep spoken lines snappy and single-line for TTS.
    public static func sanitize(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > 280 { t = String(t.prefix(279)) + "…" }
        return t
    }

    public static func arguments(text: String, voice: String, outputPath: String) -> [String]? {
        let clean = sanitize(text)
        guard !clean.isEmpty else { return nil }
        return ["-m", "edge_tts", "--voice", voice, "--text", clean,
                "--write-media", outputPath]
    }
}

public enum ElevenLabs {
    public static let defaultVoiceID = "pNInz6obpgDQGcFmaJgB" // "Adam" premade
    public static let defaultModelID = "eleven_turbo_v2_5"

    public struct Request: Equatable {
        public let url: URL
        public let headers: [String: String]
        public let body: Data
    }

    public static func speechRequest(text: String, apiKey: String,
                                     voiceID: String = defaultVoiceID,
                                     modelID: String = defaultModelID) -> Request? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !apiKey.isEmpty,
              let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)?output_format=mp3_44100_128")
        else { return nil }
        let payload: [String: Any] = [
            "text": trimmed,
            "model_id": modelID,
            "voice_settings": ["stability": 0.45, "similarity_boost": 0.75,
                                "style": 0.4, "use_speaker_boost": true],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return Request(url: url,
                       headers: ["xi-api-key": apiKey,
                                 "Content-Type": "application/json",
                                 "Accept": "audio/mpeg"],
                       body: body)
    }
}
