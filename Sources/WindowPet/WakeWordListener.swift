import AVFoundation
import AppKit
import Speech
import WindowPetCore

// MARK: - Lock and sleep, tracked in one place

// ScreenLockState, the pure rule, lives in WindowPetCore/ScreenLockState.swift.

/// Observes sleep, wake, lock and unlock once for the whole app and tells
/// each subscriber when to stop and when it may start again.
///
/// Subscribers: the wake-word listener, push-to-talk, and (by request to the
/// app side) the pet engine and quiet hours. A subscriber's `resume` runs
/// only once the Mac is awake and unlocked, never on wake alone.
@MainActor
final class ScreenLock {
    static let shared = ScreenLock()

    private var state: ScreenLockState
    private var subscribers: [(suspend: () -> Void, resume: () -> Void)] = []

    var isLocked: Bool { state.isLocked }
    /// True while the Mac is locked or asleep. Nothing should listen, speak
    /// or run scheduled work in this state.
    var isSuspended: Bool { state.isSuspended }

    private init() {
        state = ScreenLockState(isLocked: Self.sessionReportsLocked())
        // Main-queue observers, so assumeIsolated asserts the thread the block
        // already runs on. The mic must stop the instant the machine sleeps
        // or locks, which a hop would delay.
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil,
                       queue: .main) { _ in
            MainActor.assumeIsolated { ScreenLock.shared.handle(.willSleep) }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                       queue: .main) { _ in
            MainActor.assumeIsolated {
                ScreenLock.shared.handle(.didWake(sessionLocked: ScreenLock.sessionReportsLocked()))
            }
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil,
                        queue: .main) { _ in
            MainActor.assumeIsolated { ScreenLock.shared.handle(.locked) }
        }
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil,
                        queue: .main) { _ in
            MainActor.assumeIsolated { ScreenLock.shared.handle(.unlocked) }
        }
    }

    /// Registers a subscriber. `suspend` runs on sleep and on lock (possibly
    /// twice in a row, so it must be idempotent); `resume` runs only when the
    /// Mac becomes awake and unlocked again.
    func observe(suspend: @escaping () -> Void, resume: @escaping () -> Void) {
        subscribers.append((suspend, resume))
    }

    private func handle(_ event: ScreenLockState.Event) {
        switch state.apply(event) {
        case .suspend?: subscribers.forEach { $0.suspend() }
        case .resume?: subscribers.forEach { $0.resume() }
        case nil: break
        }
    }

    /// What the window server says right now. The key is present, and true,
    /// only while the login window covers the session.
    nonisolated static func sessionReportsLocked() -> Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (info["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }
}

// MARK: - Wake word

/// Always-on "Hey Rusty" with hands-free capture, built on ONE continuous
/// audio engine: the mic tap runs the whole time and wake-watching vs
/// command-capture are just different recognition requests fed by the same
/// buffers. (Stopping one engine and starting another between wake and
/// capture made the recognizer silently miss everything — the mic must
/// never blip mid-interaction.)
///
/// The engine stops only when: disabled, ⌥Space push-to-talk takes the mic,
/// or the machine sleeps/locks. It starts again only once the Mac is awake
/// AND unlocked (see ScreenLock). Watch sessions roll every ~45 s.
@MainActor
final class WakeWordListener: NSObject {

    private enum Mode { case watching, capturing }

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audio = AVAudioEngine()
    /// What the mic tap feeds. The tap runs on the audio IO thread, so it
    /// reads this lock-protected holder, never `activeRequest`.
    private let feed = RecognitionFeed()
    private var activeRequest: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Bumped with every new recognition request, so a late callback from a
    /// cancelled task cannot drive the session that replaced it.
    private var generation = 0
    private var mode: Mode = .watching
    private var restartTimer: DispatchSourceTimer?
    private var silenceTimer: DispatchSourceTimer?
    private(set) var enabled = false
    private var pausedExternally = false
    private var tapInstalled = false

    private var wakeHitAt: TimeInterval = 0
    private var wakeTranscript = ""
    private var captureTranscript = ""
    private var captureStartAt: TimeInterval = 0
    private var captureLastChangeAt: TimeInterval = 0
    private var captureDelivered = false

    var onWakeCommand: ((String) -> Void)?   // one-shot "hey rusty <command>"
    var onListeningStarted: (() -> Void)?    // bare wake → hands-free capture opened
    var onCapturePartial: ((String) -> Void)?
    var onCaptureFinal: ((String) -> Void)?
    /// A hands-free capture was cut off (lock, sleep, push-to-talk taking the
    /// mic, or the wake word switched off) and what it heard was discarded.
    /// Lets the app clear its listening state; nothing is submitted.
    var onCaptureCancelled: (() -> Void)?
    var onStatus: ((String) -> Void)?

    override init() {
        super.init()
        ScreenLock.shared.observe(suspend: { [weak self] in self?.stopEngine() },
                                  resume: { [weak self] in self?.startIfEnabled() })
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: "wakeWord")
        on ? startIfEnabled() : stopEngine()
    }

    /// ⌥Space push-to-talk needs the mic to itself.
    func yieldMicrophone() {
        pausedExternally = true
        stopEngine()
    }

    func reclaimMicrophone() {
        guard pausedExternally else { return }
        pausedExternally = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.startIfEnabled()
        }
    }

    /// Nothing listens while the Mac is locked or asleep; ScreenLock calls
    /// this again once it is awake and unlocked.
    private var mayListen: Bool {
        enabled && !pausedExternally && !ScreenLock.shared.isSuspended
    }

    /// The wake word keeps the microphone open, so its audio must never go
    /// to Apple's servers. A Mac without on-device recognition for English
    /// does not listen at all.
    private var canStayOnDevice: Bool { recognizer?.supportsOnDeviceRecognition == true }

    private func startIfEnabled() {
        guard mayListen, !audio.isRunning else { return }
        guard canStayOnDevice else {
            onStatus?("“Hey Rusty” needs on-device speech recognition, which this Mac doesn't have for English, so I'm not listening. Push-to-talk still works.")
            return
        }
        VoiceThreads.requestPermissions { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .speechDenied:
                self.onStatus?("I need Speech Recognition permission for “Hey Rusty”. System Settings, Privacy and Security.")
            case .microphoneDenied:
                self.onStatus?("I need Microphone permission for “Hey Rusty”. System Settings, Privacy and Security.")
            case .granted:
                self.startEngine()
            }
        }
    }

    private func startEngine() {
        // Checked again: the Mac can lock while the permission prompt is up.
        guard mayListen, canStayOnDevice, !audio.isRunning else { return }
        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            scheduleRestart(after: 3)
            return
        }
        if !tapInstalled {
            input.installTap(onBus: 0, bufferSize: 2048, format: format,
                             block: VoiceThreads.tap(feeding: feed))
            tapInstalled = true
        }
        audio.prepare()
        do { try audio.start() } catch {
            scheduleRestart(after: 3)
            return
        }
        beginWatchSession()
    }

    /// Stops listening and forgets the interaction in progress. Whatever was
    /// heard is dropped, not delivered: the callers are the lock screen,
    /// sleep, push-to-talk and switching the wake word off, and none of them
    /// should see a half-heard command run afterwards.
    private func stopEngine() {
        let wasCapturing = mode == .capturing && !captureDelivered
        // A new generation first, so the cancelled task's error callback and
        // a pending wake from a moment ago both find themselves stale.
        generation += 1
        mode = .watching
        wakeHitAt = 0
        wakeTranscript = ""
        captureTranscript = ""
        captureDelivered = true
        restartTimer?.cancel(); restartTimer = nil
        silenceTimer?.cancel(); silenceTimer = nil
        endActiveRecognition()
        if audio.isRunning { audio.stop() }
        if tapInstalled {
            audio.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if wasCapturing { onCaptureCancelled?() }
    }

    private func endActiveRecognition() {
        // Detach first, so the tap stops appending before endAudio.
        feed.swap(nil)
        activeRequest?.endAudio()
        task?.cancel()
        task = nil
        activeRequest = nil
    }

    // MARK: - Watch mode

    private func beginWatchSession() {
        guard audio.isRunning, let recognizer, recognizer.isAvailable else {
            scheduleRestart(after: 2)
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            stopEngine()
            return
        }
        endActiveRecognition()
        mode = .watching
        wakeHitAt = 0
        wakeTranscript = ""
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        activeRequest = req
        feed.swap(req)
        generation += 1
        let session = generation
        task = recognizer.recognitionTask(with: req, resultHandler: VoiceThreads.resultHandler { [weak self] heard in
            guard let self, self.generation == session else { return }
            self.handleWatch(heard)
        })
        scheduleRestart(after: 45) // rolling refresh
    }

    private func handleWatch(_ heard: VoiceThreads.Heard) {
        guard mode == .watching else { return }
        if let text = heard.text {
            if wakeHitAt == 0, WakeWord.matches(text) {
                wakeHitAt = CACurrentMediaTime()
                wakeTranscript = text
                // Let the utterance finish growing ("hey rusty mute the…").
                // Tied to this watch session: if the engine stops or the
                // session rolls over first, the wake is dropped.
                let session = generation
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self, self.generation == session else { return }
                    self.fireWake()
                }
            } else if wakeHitAt > 0 {
                wakeTranscript = text
            }
            if heard.isFinal, wakeHitAt == 0 {
                beginWatchSession()
                return
            }
        }
        if heard.failed, wakeHitAt == 0, mode == .watching {
            scheduleRestart(after: 1.2)
        }
    }

    private func fireWake() {
        // Checked again here: nothing heard may run once the Mac has locked.
        guard mode == .watching, wakeHitAt > 0, mayListen, audio.isRunning else { return }
        let command = WakeWord.extractCommand(wakeTranscript) ?? ""
        if !command.isEmpty {
            SoundFX.shared.play("ack")
            onWakeCommand?(command)
            beginWatchSession()
        } else {
            SoundFX.shared.play("wake")
            beginCaptureSession()
        }
    }

    // MARK: - Capture mode (same engine, new request — the mic never blips)

    /// Voice continuity: after Rusty finishes speaking, the conversation
    /// stays open. Reuses the same engine and capture pipeline as a bare
    /// wake, so a follow-up needs no new "hey rusty".
    func beginFollowUpCapture() {
        guard mayListen, audio.isRunning, mode == .watching else { return }
        endActiveRecognition()
        beginCaptureSession()
    }

    private func beginCaptureSession() {
        guard audio.isRunning, let recognizer, recognizer.supportsOnDeviceRecognition else { return }
        endActiveRecognition()
        restartTimer?.cancel()
        mode = .capturing
        captureTranscript = ""
        captureDelivered = false
        captureStartAt = CACurrentMediaTime()
        captureLastChangeAt = captureStartAt
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        activeRequest = req
        feed.swap(req)
        generation += 1
        let session = generation
        task = recognizer.recognitionTask(with: req, resultHandler: VoiceThreads.resultHandler { [weak self] heard in
            guard let self, self.generation == session else { return }
            self.handleCapture(heard)
        })
        onListeningStarted?()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.3, repeating: 0.3)
        t.setEventHandler { [weak self] in self?.checkCaptureSilence() }
        t.resume()
        silenceTimer = t
    }

    private func handleCapture(_ heard: VoiceThreads.Heard) {
        guard mode == .capturing else { return }
        if let text = heard.text {
            if text != captureTranscript {
                captureTranscript = text
                captureLastChangeAt = CACurrentMediaTime()
            }
            onCapturePartial?(text)
            if heard.isFinal { finishCapture() }
        }
        if heard.failed { finishCapture() }
    }

    private func checkCaptureSilence() {
        guard mode == .capturing else { return }
        let now = CACurrentMediaTime()
        let heard = !captureTranscript.isEmpty
        if (heard && now - captureLastChangeAt > 1.5)
            || (!heard && now - captureStartAt > 6) {
            finishCapture()
        }
    }

    private func finishCapture() {
        guard mode == .capturing, !captureDelivered, mayListen else { return }
        captureDelivered = true
        silenceTimer?.cancel(); silenceTimer = nil
        let text = captureTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        onCaptureFinal?(text)
        beginWatchSession()
    }

    private func scheduleRestart(after seconds: TimeInterval) {
        restartTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + seconds)
        t.setEventHandler { [weak self] in
            guard let self, self.mode == .watching else { return }
            self.audio.isRunning ? self.beginWatchSession() : self.startIfEnabled()
        }
        t.resume()
        restartTimer = t
    }
}
