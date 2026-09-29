import AVFoundation
import Speech
import WindowPetCore

// MARK: - Callbacks that arrive on other threads

/// Holds the recognition request the microphone tap feeds.
///
/// AVAudioEngine calls a tap block on its own IO thread. A block written
/// inside a @MainActor class is inferred @MainActor in Swift 6, and the
/// runtime traps the moment the IO thread calls it. So the tap never touches
/// main-actor state. It appends to whatever request this holder has, and the
/// main actor swaps requests in and out under the same lock.
final class RecognitionFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    /// Installs `next` as the request the tap feeds and returns the one it
    /// replaced. Once this returns, the tap can no longer append to the old
    /// request, so calling `endAudio()` on it is safe.
    @discardableResult
    func swap(_ next: SFSpeechAudioBufferRecognitionRequest?) -> SFSpeechAudioBufferRecognitionRequest? {
        lock.lock()
        defer { lock.unlock() }
        let old = request
        request = next
        return old
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        request?.append(buffer)
    }
}

/// Builds every callback that Speech and AVFoundation invoke off the main
/// thread. Each one is created here, outside main-actor isolation, so none of
/// them carries the runtime executor check that traps on a background thread.
/// Results cross back to the main actor as plain values.
enum VoiceThreads {

    /// What a recognition callback reported, copied out on the callback's thread.
    struct Heard: Sendable {
        let text: String?
        let isFinal: Bool
        let failed: Bool
    }

    enum Permission: Sendable {
        case granted, speechDenied, microphoneDenied
    }

    /// The microphone tap. It runs on the audio IO thread and only feeds the
    /// current request.
    nonisolated static func tap(feeding feed: RecognitionFeed) -> AVAudioNodeTapBlock {
        return { buffer, _ in feed.append(buffer) }
    }

    /// A recognition result handler that copies what matters and delivers it
    /// on the main queue, in order.
    nonisolated static func resultHandler(
        _ deliver: @escaping @MainActor @Sendable (Heard) -> Void
    ) -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        return { result, error in
            let heard = Heard(text: result?.bestTranscription.formattedString,
                              isFinal: result?.isFinal ?? false,
                              failed: error != nil)
            DispatchQueue.main.async { deliver(heard) }
        }
    }

    /// Speech Recognition, then Microphone. Both system callbacks arrive on
    /// background queues; the answer is delivered on the main queue.
    nonisolated static func requestPermissions(
        _ done: @escaping @MainActor @Sendable (Permission) -> Void
    ) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                DispatchQueue.main.async { done(.speechDenied) }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { done(granted ? .granted : .microphoneDenied) }
            }
        }
    }
}

/// Push-to-talk speech input. The microphone and recognizer run ONLY between
/// beginListening/endListening (key held) — no always-on audio, no permanent
/// mic indicator, zero idle cost. Push-to-talk uses on-device recognition
/// whenever the locale supports it; dictation requires it and refuses to
/// start otherwise. Permissions (Microphone + Speech Recognition) prompt on
/// first use and every failure surfaces as a bubble-friendly message.
///
/// Every session is its own: a timer or callback left over from one press
/// checks `generation` and does nothing to the next, and a permission answer
/// that arrives after the key was let go starts nothing.
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
    private let feed = RecognitionFeed()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Bumped per listening session, so a late callback from a cancelled
    /// task, or the fallback delivery of an earlier press, cannot write into
    /// the next one.
    private var generation = 0
    private var lastTranscript = ""
    private var delivered = false
    private var autoStop = false
    /// True from the key going down until it comes up. The permission prompt
    /// is asynchronous and, on first use, answered after the key is released,
    /// so the answer has to check this before it opens the microphone.
    private var wantsListening = false
    /// Bumped per beginListening, so only the newest permission answer acts.
    private var listenRequest = 0
    /// Dictation promises nothing leaves the Mac, so it never falls back to
    /// Apple's server recognizer.
    private var requireOnDevice = false
    /// Where this session's results go. Captured when the session starts, so
    /// a dictation borrowing the handlers for the next press cannot receive
    /// the tail of this one.
    private var sessionPartial: ((String) -> Void)?
    private var sessionFinal: ((String) -> Void)?
    /// The handlers installed when the newest press began, for its
    /// permission answer.
    private var pressHandlers: (state: ((String) -> Void)?, final: ((String) -> Void)?) = (nil, nil)
    /// Bumped per dictation borrow, so handing the handlers back for one
    /// press cannot undo the borrow of the next.
    private var borrow = 0
    private var startedAt: TimeInterval = 0
    private var lastChangeAt: TimeInterval = 0
    private var silenceTimer: DispatchSourceTimer?
    private let synthesizer = AVSpeechSynthesizer()

    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onState: ((String) -> Void)?

    override init() {
        super.init()
        // A held push-to-talk key must not keep the mic open behind the lock
        // screen or across sleep, and what was heard is thrown away rather
        // than delivered: nothing may act behind the lock screen.
        ScreenLock.shared.observe(suspend: { [weak self] in
            self?.discardSession(because: "The Mac locked, so I stopped listening and dropped what I heard.")
        }, resume: {})
    }

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
        borrow += 1
        let mine = borrow
        // Save the panel's handlers only when they are the ones installed. A
        // borrow that has not been handed back yet holds the previous
        // dictation's closures, and saving those would lose the panel's voice.
        if savedHandlers == nil { savedHandlers = (onPartial, onFinal, onState) }
        onPartial = partial
        onFinal = { [weak self] text in
            final(text)
            self?.restoreHandlers(borrow: mine)
        }
        onState = { state in
            // "listening" is the engine coming up, not something to say.
            if state != "listening" { problem(state) }
        }
        beginListening(autoStop: false, onDeviceOnly: true)
    }

    /// Said when dictation cannot keep the audio on the Mac.
    static let dictationNeedsOnDeviceNote = "Dictation needs on-device speech recognition, which this Mac doesn't have for English, so I'm not listening. Nothing was recorded."

    private var savedHandlers: (partial: ((String) -> Void)?,
                                final: ((String) -> Void)?,
                                state: ((String) -> Void)?)?

    /// Ends a dictation borrow and guarantees the panel's handlers come back.
    /// `endListening` returns early when the engine never started, and a
    /// permission refusal never delivers a final result at all, so restoring
    /// only on delivery would leave the panel's voice replaced for the rest of
    /// the session.
    func endDictation() {
        let mine = borrow
        endListening()
        // Nothing is on its way (the engine never started, or a refusal has
        // already ended it), so the panel gets its voice back now.
        guard sessionFinal != nil else {
            restoreHandlers(borrow: mine)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.restoreHandlers(borrow: mine)
        }
    }

    /// Hands the handlers back, unless a newer dictation has borrowed them
    /// since; that one hands them back itself.
    private func restoreHandlers(borrow mine: Int) {
        guard mine == borrow, let saved = savedHandlers else { return }
        onPartial = saved.partial
        onFinal = saved.final
        onState = saved.state
        savedHandlers = nil
    }

    func beginListening(autoStop: Bool = false) {
        beginListening(autoStop: autoStop, onDeviceOnly: false)
    }

    /// True while a press is held or its microphone is still open, including
    /// while the permission check for it is pending.
    var isListening: Bool { wantsListening || audio.isRunning }

    private func beginListening(autoStop: Bool, onDeviceOnly: Bool) {
        self.autoStop = autoStop
        requireOnDevice = onDeviceOnly
        listenRequest += 1
        let request = listenRequest
        // Refused before any prompt: asking for the microphone for something
        // that will not run would be a promise the app cannot keep.
        if onDeviceOnly, let recognizer, !recognizer.supportsOnDeviceRecognition {
            wantsListening = false
            onState?(Self.dictationNeedsOnDeviceNote)
            return
        }
        wantsListening = true
        let prompting = SFSpeechRecognizer.authorizationStatus() == .notDetermined
            || AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
        // The handlers of this press. A dictation that ended before the
        // answer came has already handed the panel its handlers back, and
        // the answer to the dictation must not land in the panel.
        pressHandlers = (onState, onFinal)
        VoiceThreads.requestPermissions { [weak self] outcome in
            // A newer press asked again; its answer decides.
            guard let self, request == self.listenRequest else { return }
            let (state, final) = self.pressHandlers
            switch outcome {
            case .speechDenied:
                state?("I need Speech Recognition permission. System Settings, Privacy and Security.")
            case .microphoneDenied:
                state?("I need Microphone permission. System Settings, Privacy and Security.")
            case .granted:
                if self.wantsListening {
                    self.startEngine()
                } else if prompting {
                    // The key came up while the system prompts were showing.
                    // Opening the microphone now would record with nothing
                    // left to stop it.
                    state?("Permission granted. Hold the key again to talk.")
                } else {
                    // A tap shorter than the permission check: over before it
                    // began, which is the same as hearing nothing.
                    final?("")
                }
            }
        }
    }

    private func startEngine() {
        guard wantsListening, !audio.isRunning else { return }
        guard !ScreenLock.shared.isSuspended else {
            wantsListening = false
            onState?("The Mac is locked.")
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            wantsListening = false
            onState?("Speech recognizer isn't available right now.")
            return
        }
        guard recognizer.supportsOnDeviceRecognition || !requireOnDevice else {
            wantsListening = false
            onState?(Self.dictationNeedsOnDeviceNote)
            return
        }
        // The previous press was released but its final result has not come
        // yet. It is delivered now, with what it heard, to its own handler:
        // a dictation's words still reach the app they were meant for, and
        // nothing of it can leak into this session.
        if sessionFinal != nil, !delivered { deliver() }
        // A new session from here on: anything still scheduled for the last
        // one (its fallback delivery, its late results) sees a stale
        // generation and does nothing.
        generation += 1
        let session = generation
        lastTranscript = ""
        delivered = false
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true // private by construction
        }

        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            wantsListening = false
            onState?("No usable microphone input.")
            return
        }
        request = req
        feed.swap(req)
        input.installTap(onBus: 0, bufferSize: 1024, format: format,
                         block: VoiceThreads.tap(feeding: feed))
        audio.prepare()
        do {
            try audio.start()
        } catch {
            input.removeTap(onBus: 0)
            feed.swap(nil)
            request = nil
            wantsListening = false
            onState?("Couldn't start the microphone: \(error.localizedDescription)")
            return
        }
        sessionPartial = onPartial
        sessionFinal = onFinal
        onState?("listening")
        startedAt = CACurrentMediaTime()
        lastChangeAt = startedAt
        if autoStop { startSilenceTimer() }
        task = recognizer.recognitionTask(with: req, resultHandler: VoiceThreads.resultHandler { [weak self] heard in
            guard let self, self.generation == session else { return }
            if let text = heard.text {
                if text != self.lastTranscript {
                    self.lastTranscript = text
                    self.lastChangeAt = CACurrentMediaTime()
                }
                self.sessionPartial?(text)
                if heard.isFinal { self.deliver() }
            }
            if heard.failed, !self.audio.isRunning { self.deliver() }
        })
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
        // Before the guard: a release while the permission prompt is still
        // up must stop the answer from opening the microphone.
        wantsListening = false
        silenceTimer?.cancel()
        silenceTimer = nil
        guard audio.isRunning else { return }
        audio.inputNode.removeTap(onBus: 0)
        audio.stop()
        feed.swap(nil)
        request?.endAudio()
        // The final callback usually lands quickly; don't wait forever. Tied
        // to this session: if the key is pressed again first, this does
        // nothing to the new one.
        let session = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.generation == session else { return }
            self.deliver()
        }
    }

    private func deliver() {
        guard !delivered else { return }
        delivered = true
        task?.cancel()
        task = nil
        feed.swap(nil)
        request = nil
        let final = sessionFinal
        sessionPartial = nil
        sessionFinal = nil
        final?(lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Ends the session without delivering anything: the Mac locked or went
    /// to sleep, and nothing heard before that may run behind the lock
    /// screen. Says so only when there was a session to end, which also hands
    /// the wake word its microphone back.
    private func discardSession(because note: String) {
        let wasLive = wantsListening || audio.isRunning || sessionFinal != nil
        wantsListening = false
        listenRequest += 1  // a permission answer still on its way starts nothing
        generation += 1     // late results and the fallback delivery are ignored
        delivered = true
        silenceTimer?.cancel()
        silenceTimer = nil
        if audio.isRunning {
            audio.inputNode.removeTap(onBus: 0)
            audio.stop()
        }
        feed.swap(nil)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        lastTranscript = ""
        sessionPartial = nil
        sessionFinal = nil
        if wasLive { onState?(note) }
    }

    /// Spoken replies, provider-selectable (menu → Voice): "system" (the
    /// on-device macOS voice, the default), "edge" (Microsoft's online neural
    /// voices, which the user has to pick), or "elevenlabs" (uses credits).
    /// Edge and ElevenLabs send the reply text off the Mac, and replies can
    /// quote the clipboard, files and the screen, so neither is ever used
    /// unless the user chose it. Every provider falls back to the system
    /// voice, never to another online service.
    var eleven: ElevenLabsTTS? {
        didSet { eleven?.onFinished = { [weak self] in self?.onSpeechFinished?() } }
    }
    var edge: EdgeTTSPlayer? {
        didSet {
            edge?.onFinished = { [weak self] in self?.onSpeechFinished?() }
            // Look for edge-tts off the main thread now, so the first reply
            // does not wait on it.
            if Self.provider == "edge" { EdgeTTSPlayer.warmUp() }
        }
    }

    /// Fires once the reply audio has fully played, whichever provider spoke
    /// it. Drives the voice follow-up window.
    var onSpeechFinished: (() -> Void)?

    /// Whether speak() will produce audio at all (spoken replies enabled).
    var willSpeak: Bool {
        UserDefaults.standard.object(forKey: "spokenReplies") == nil
            || UserDefaults.standard.bool(forKey: "spokenReplies")
    }

    static let providerKey = "voiceProvider"
    static let defaultProvider = "system"

    static var provider: String {
        UserDefaults.standard.string(forKey: providerKey) ?? defaultProvider
    }

    func speak(_ text: String) {
        guard willSpeak else { return }
        // One voice at a time: a new line replaces whatever is still being
        // synthesised or played, by any provider. A superseded Edge line is
        // dropped, never re-spoken by the system voice.
        synthesizer.stopSpeaking(at: .immediate)
        edge?.stop()
        eleven?.stop()
        switch Self.provider {
        case "elevenlabs" where eleven?.hasKey == true:
            eleven?.speak(text) { [weak self] ok in
                if !ok { self?.systemSpeak(text) }
            }
        case "edge":
            speakEdge(text)
        default:
            systemSpeak(text)
        }
    }

    /// Only reached when the user picked the Microsoft voice. isAvailable
    /// never blocks: until the background probe finds edge-tts, the reply
    /// uses the system voice.
    private func speakEdge(_ text: String) {
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
