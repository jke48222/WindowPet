import AVFoundation
import AppKit
import Speech
import WindowPetCore

/// Always-on "Hey Rusty" with hands-free capture, built on ONE continuous
/// audio engine: the mic tap runs the whole time and wake-watching vs
/// command-capture are just different recognition requests fed by the same
/// buffers. (Stopping one engine and starting another between wake and
/// capture made the recognizer silently miss everything — the mic must
/// never blip mid-interaction.)
///
/// The engine stops only when: disabled, ⌥Space push-to-talk takes the mic,
/// or the machine sleeps/locks. Watch sessions roll every ~45 s.
final class WakeWordListener: NSObject {

    private enum Mode { case watching, capturing }

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audio = AVAudioEngine()
    private var activeRequest: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
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
    var onStatus: ((String) -> Void)?

    override init() {
        super.init()
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil,
                       queue: .main) { [weak self] _ in self?.stopEngine() }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                       queue: .main) { [weak self] _ in self?.startIfEnabled() }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil,
                        queue: .main) { [weak self] _ in self?.stopEngine() }
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil,
                        queue: .main) { [weak self] _ in self?.startIfEnabled() }
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

    private func startIfEnabled() {
        guard enabled, !pausedExternally, !audio.isRunning else { return }
        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            DispatchQueue.main.async {
                guard auth == .authorized else {
                    self?.onStatus?("I need Speech Recognition permission for “Hey Rusty”. System Settings, Privacy and Security.")
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async {
                        guard granted else {
                            self?.onStatus?("I need Microphone permission for “Hey Rusty”. System Settings, Privacy and Security.")
                            return
                        }
                        self?.startEngine()
                    }
                }
            }
        }
    }

    private func startEngine() {
        guard enabled, !pausedExternally, !audio.isRunning else { return }
        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            scheduleRestart(after: 3)
            return
        }
        if !tapInstalled {
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                self?.activeRequest?.append(buffer)
            }
            tapInstalled = true
        }
        audio.prepare()
        do { try audio.start() } catch {
            scheduleRestart(after: 3)
            return
        }
        beginWatchSession()
    }

    private func stopEngine() {
        restartTimer?.cancel(); restartTimer = nil
        silenceTimer?.cancel(); silenceTimer = nil
        endActiveRecognition()
        if audio.isRunning { audio.stop() }
        if tapInstalled {
            audio.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    private func endActiveRecognition() {
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
        endActiveRecognition()
        mode = .watching
        wakeHitAt = 0
        wakeTranscript = ""
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        activeRequest = req
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async { self?.handleWatch(result: result, error: error) }
        }
        scheduleRestart(after: 45) // rolling refresh
    }

    private func handleWatch(result: SFSpeechRecognitionResult?, error: Error?) {
        guard mode == .watching else { return }
        if let result {
            let text = result.bestTranscription.formattedString
            if wakeHitAt == 0, WakeWord.matches(text) {
                wakeHitAt = CACurrentMediaTime()
                wakeTranscript = text
                // Let the utterance finish growing ("hey rusty mute the…").
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.fireWake()
                }
            } else if wakeHitAt > 0 {
                wakeTranscript = text
            }
            if result.isFinal, wakeHitAt == 0 {
                beginWatchSession()
            }
        }
        if error != nil, wakeHitAt == 0, mode == .watching {
            scheduleRestart(after: 1.2)
        }
    }

    private func fireWake() {
        guard mode == .watching, wakeHitAt > 0 else { return }
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
        guard enabled, !pausedExternally, audio.isRunning, mode == .watching else { return }
        endActiveRecognition()
        beginCaptureSession()
    }

    private func beginCaptureSession() {
        guard audio.isRunning, let recognizer else { return }
        endActiveRecognition()
        restartTimer?.cancel()
        mode = .capturing
        captureTranscript = ""
        captureDelivered = false
        captureStartAt = CACurrentMediaTime()
        captureLastChangeAt = captureStartAt
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        activeRequest = req
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async { self?.handleCapture(result: result, error: error) }
        }
        onListeningStarted?()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.3, repeating: 0.3)
        t.setEventHandler { [weak self] in self?.checkCaptureSilence() }
        t.resume()
        silenceTimer = t
    }

    private func handleCapture(result: SFSpeechRecognitionResult?, error: Error?) {
        guard mode == .capturing else { return }
        if let result {
            let text = result.bestTranscription.formattedString
            if text != captureTranscript {
                captureTranscript = text
                captureLastChangeAt = CACurrentMediaTime()
            }
            onCapturePartial?(text)
            if result.isFinal { finishCapture() }
        }
        if error != nil { finishCapture() }
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
        guard mode == .capturing, !captureDelivered else { return }
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
