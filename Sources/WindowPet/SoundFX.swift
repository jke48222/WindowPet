import AVFoundation

/// Tiny synthesized UI sounds, generated once at launch (no assets). The
/// timbre is a struck kalimba tine, not a beep: a warm fundamental with a
/// long exponential decay, plus two fast-dying inharmonic partials (~3.9x,
/// ~8.9x — bar-vibration modes) that give the attack its woody "tick".
final class SoundFX {
    static let shared = SoundFX()
    private var players: [String: AVAudioPlayer] = [:]

    private init() {
        // wake: two rising notes, a gentle "I'm listening" (G4 → C5)
        players["wake"] = Self.make([(392, 0.00), (523, 0.13)])
        // ack: single warm tap (C5)
        players["ack"] = Self.make([(523, 0.00)])
        // miss: soft descending pair, apologetic not alarming (D4 → A3)
        players["miss"] = Self.make([(294, 0.00), (220, 0.15)], level: 0.7)
    }

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: "uiSounds") == nil
            || UserDefaults.standard.bool(forKey: "uiSounds")
    }

    func play(_ name: String) {
        guard Self.enabled, let p = players[name] else { return }
        p.stop()
        p.currentTime = 0
        p.volume = 0.3
        p.play()
    }

    private static func make(_ notes: [(hz: Double, at: Double)], level: Double = 1.0) -> AVAudioPlayer? {
        let rate = 44100.0
        let tail = 0.55
        let total = (notes.map(\.at).max() ?? 0) + tail
        var mix = [Double](repeating: 0, count: Int(rate * total))

        for (hz, at) in notes {
            let start = Int(rate * at)
            let count = Int(rate * tail)
            for i in 0..<count where start + i < mix.count {
                let t = Double(i) / rate
                let attack = min(1, t / 0.003)
                // Partials: (multiple, amplitude, decay time-constant).
                var v = 0.0
                for (m, a, tau) in [(1.0, 1.0, 0.16), (3.9, 0.22, 0.045), (8.9, 0.07, 0.018)] {
                    v += a * exp(-t / tau) * sin(2 * .pi * hz * m * t)
                }
                mix[start + i] += v * attack
            }
        }

        let peak = max(mix.map(abs).max() ?? 1, 0.0001)
        let samples = mix.map { Int16(($0 / peak) * 0.55 * level * 32000) }

        var data = Data()
        func put(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); put(36 + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); put(16); put16(1); put16(1)
        put(UInt32(rate)); put(UInt32(rate * 2)); put16(2); put16(16)
        data.append(contentsOf: Array("data".utf8)); put(byteCount)
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return try? AVAudioPlayer(data: data)
    }
}
