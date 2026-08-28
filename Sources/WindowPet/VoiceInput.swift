import AVFoundation
import Speech
import WindowPetCore

/// Push-to-talk speech input. The microphone and recognizer run ONLY between
/// beginListening/endListening (key held) — no always-on audio, no permanent
/// mic indicator, zero idle cost. On-device recognition whenever the locale
/// supports it. Permissions (Microphone + Speech Recognition) prompt on
/// first use and every failure surfaces as a bubble-friendly message.
@MainActor
final class VoiceInput: NSObject, AVSpeechSynthesizerDelegate {

    // AVFoundation delivers this without an actor; hop before touching the
    // main-actor callback the app installed.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.onSpeechFinished?() }
    }

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audio = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var lastTranscript = ""
    private var delivered = false
    private var autoStop = false
    private var startedAt: TimeInterval = 0
    private var lastChangeAt: TimeInterval = 0
    private var silenceTimer: DispatchSourceTimer?
    private let synthesizer = AVSpeechSynthesizer()

    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onState: ((String) -> Void)?

    static var authorizationSummary: String {
        let speech: String
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: speech = "authorized"
        case .denied: speech = "denied"
        case .restricted: speech = "restricted"
        case .notDetermined: speech = "not asked yet"
        @unknown default: speech = "unknown"
        }
        let mic: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = "authorized"
        case .denied: mic = "denied"
        case .restricted: mic = "restricted"
        case .notDetermined: mic = "not asked yet"
        @unknown default: mic = "unknown"
        }
        return "speech \(speech), mic \(mic)"
    }

    /// autoStop: hands-free mode (wake word) — capture ends after ~1.6 s of
    /// silence following speech, or 6 s of hearing nothing at all.
    /// Dictation borrows the same recognizer with its own callbacks, so the
    /// panel's handlers are left alone and restored when the hold ends. One
    /// audio engine, two purposes, no second microphone session.
    func beginDictation(partial: @escaping (String) -> Void,
                        final: @escaping (String) -> Void,
                        problem: @escaping (String) -> Void) {
        savedHandlers = (onPartial, onFinal, onState)
        onPartial = partial
        onFinal = { [weak self] text in
            final(text)
            self?.restoreHandlers()
        }
        onState = { state in
            // "listening" is the engine coming up, not something to say.
            if state != "listening" { problem(state) }
        }
        beginListening(autoStop: false)
    }

    private var savedHandlers: (partial: ((String) -> Void)?,
                                final: ((String) -> Void)?,
                                state: ((String) -> Void)?)?

    /// Ends a dictation borrow and guarantees the panel's handlers come back.
    /// `endListening` returns early when the engine never started, and a
    /// permission refusal never delivers a final result at all, so restoring
    /// only on delivery would leave the panel's voice replaced for the rest of
    /// the session.
    func endDictation() {
        endListening()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.restoreHandlers()
        }
    }

    private func restoreHandlers() {
        guard let saved = savedHandlers else { return }
        onPartial = saved.partial
        onFinal = saved.final
        onState = saved.state
        savedHandlers = nil
    }

    func beginListening(autoStop: Bool = false) {
        self.autoStop = autoStop
        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            DispatchQueue.main.async {
                guard auth == .authorized else {
                    self?.onState?("I need Speech Recognition permission. System Settings, Privacy and Security.")
                    return
                }
                self?.requestMicThenStart()
            }
        }
    }

    private func requestMicThenStart() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard granted else {
                    self?.onState?("I need Microphone permission. System Settings, Privacy and Security.")
                    return
                }
                self?.startEngine()
            }
        }
    }

    private func startEngine() {
        guard !audio.isRunning else { return }
        guard let recognizer, recognizer.isAvailable else {
            onState?("Speech recognizer isn't available right now.")
            return
        }
        lastTranscript = ""
        delivered = false
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true // private by construction
        }
        request = req

        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            onState?("No usable microphone input.")
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        audio.prepare()
        do {
            try audio.start()
        } catch {
            input.removeTap(onBus: 0)
            onState?("Couldn't start the microphone: \(error.localizedDescription)")
            return
        }
        onState?("listening")
        startedAt = CACurrentMediaTime()
        lastChangeAt = startedAt
        if autoStop { startSilenceTimer() }
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    if text != self.lastTranscript {
                        self.lastTranscript = text
                        self.lastChangeAt = CACurrentMediaTime()
                    }
                    self.onPartial?(text)
                    if result.isFinal { self.deliver() }
                }
                if error != nil, !self.audio.isRunning { self.deliver() }
            }
        }
    }

    private func startSilenceTimer() {
        silenceTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.3, repeating: 0.3)
        t.setEventHandler { [weak self] in
            guard let self, self.audio.isRunning else { return }
            let now = CACurrentMediaTime()
            let heard = !self.lastTranscript.isEmpty
            if (heard && now - self.lastChangeAt > 1.6)
                || (!heard && now - self.startedAt > 6) {
                self.endListening()
            }
        }
        t.resume()
        silenceTimer = t
    }

    func endListening() {
        silenceTimer?.cancel()
        silenceTimer = nil
        guard audio.isRunning else { return }
        audio.inputNode.removeTap(onBus: 0)
        audio.stop()
        request?.endAudio()
        // The final callback usually lands quickly; don't wait forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.deliver()
        }
    }

    private func deliver() {
        guard !delivered else { return }
        delivered = true
        task?.cancel()
        task = nil
        request = nil
        onFinal?(lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Spoken replies, provider-selectable (menu → Voice): "edge" (free
    /// Microsoft neural — default), "elevenlabs" (uses credits; kept on the
    /// back burner), or "system". Every provider falls back to the system
    /// voice on failure. Toggleable from the menu.
    var eleven: ElevenLabsTTS? {
        didSet { eleven?.onFinished = { [weak self] in self?.onSpeechFinished?() } }
    }
    var edge: EdgeTTSPlayer? {
        didSet { edge?.onFinished = { [weak self] in self?.onSpeechFinished?() } }
    }

    /// Fires once the reply audio has fully played, whichever provider spoke
    /// it. Drives the voice follow-up window.
    var onSpeechFinished: (() -> Void)?

    /// Whether speak() will produce audio at all (spoken replies enabled).
    var willSpeak: Bool {
        UserDefaults.standard.object(forKey: "spokenReplies") == nil
            || UserDefaults.standard.bool(forKey: "spokenReplies")
    }

    static var provider: String {
        UserDefaults.standard.string(forKey: "voiceProvider") ?? "edge"
    }

    func speak(_ text: String) {
        guard willSpeak else { return }
        synthesizer.stopSpeaking(at: .immediate)
        switch Self.provider {
        case "elevenlabs" where eleven?.hasKey == true:
            eleven?.speak(text) { [weak self] ok in
                if !ok { self?.speakFree(text) }
            }
        case "system":
            systemSpeak(text)
        default:
            speakFree(text)
        }
    }

    private func speakFree(_ text: String) {
        if let edge, EdgeTTSPlayer.isAvailable {
            edge.speak(text) { [weak self] ok in
                if !ok { self?.systemSpeak(text) }
            }
        } else {
            systemSpeak(text)
        }
    }

    /// Best installed system voice: premium > enhanced > compact, preferring
    /// en-US. (Better ones can be downloaded in System Settings →
    /// Accessibility → Spoken Content → System Voice → Manage Voices.)
    static let bestSystemVoice: AVSpeechSynthesisVoice? = {
        func score(_ v: AVSpeechSynthesisVoice) -> Int {
            var s = 0
            switch v.quality {
            case .premium: s += 20
            case .enhanced: s += 10
            default: break
            }
            if v.language == "en-US" { s += 2 } else if v.language.hasPrefix("en") { s += 1 }
            return s
        }
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .max { score($0) < score($1) }
    }()

    static var fallbackVoiceDescription: String {
        guard let v = bestSystemVoice else { return "system default" }
        let quality = v.quality == .premium ? "premium" : (v.quality == .enhanced ? "enhanced" : "compact")
        return "\(v.name) (\(quality), \(v.language))"
    }

    private func systemSpeak(_ text: String) {
        synthesizer.delegate = self
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.5
        utterance.voice = Self.bestSystemVoice
        synthesizer.speak(utterance)
    }
}
