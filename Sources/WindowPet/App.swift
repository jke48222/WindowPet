import AppKit
import ServiceManagement
import WindowPetCore

@main
enum Main {
    static func main() {
        // Line-buffer stdout so --verbose/--diag logs reach redirected files
        // promptly (print() is block-buffered when stdout isn't a tty).
        setvbuf(stdout, nil, _IOLBF, 0)
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    enum Mode {
        case pet                    // normal: ambient companion
        case diag(TimeInterval)     // verbose logs for N seconds, then exit
        case testRig                // self-driving end-to-end check, exits 0/1
        case bench(TimeInterval)    // energy benchmark, asserts budgets, exits 0/1
        case helperWindow           // rig prop: opens a titled window, wiggles it, exits
        case helperTitleSpam        // rig prop: retitles rapidly (fake build), exits
        case ask(String)            // headless: run one prompt through the agent, print, exit
    }

    private var mode: Mode = .pet
    private var characterName = "Rusty (built-in)"
    private var stage: OverlayStage!
    private var engine: PetEngine!
    private var statusItem: NSStatusItem?
    private var rig: TestRig?
    private var bench: BenchRunner?
    private var commandBar: CommandBar?
    private var voice: VoiceInput?
    private var wake: WakeWordListener?

    func applicationDidFinishLaunching(_ notification: Notification) {
        mode = Self.parseMode(CommandLine.arguments)

        // Rig prop: a separate process whose window the rig's Tier-2 observer
        // watches — real cross-process AX events, no engine, no panels.
        if case .helperWindow = mode {
            NSApp.setActivationPolicy(.accessory)
            runHelperWindow(spamTitle: false)
            return
        }
        if case .helperTitleSpam = mode {
            NSApp.setActivationPolicy(.accessory)
            runHelperWindow(spamTitle: true)
            return
        }

        // Accessory = no Dock icon, no app menu — for the rig too: regular
        // never-activated background apps get their window presentation
        // suppressed in some environments, accessory apps don't, and the rig
        // forces its own PID as the tracking target so it doesn't need
        // activation anyway.
        NSApp.setActivationPolicy(.accessory)

        stage = OverlayStage()

        let verbose: Bool
        switch mode {
        case .pet: verbose = CommandLine.arguments.contains("--verbose")
        case .diag, .testRig, .helperWindow, .helperTitleSpam: verbose = true
        case .bench, .ask: verbose = false
        }

        // Character selection: --character <shimeji-pack-dir> (persisted), or
        // the built-in Rusty. A bad path falls back loudly but harmlessly.
        var sprites = SpriteSet()
        characterName = "Rusty (built-in)"
        let args = CommandLine.arguments
        var packPath: String?
        if let i = args.firstIndex(of: "--character"), i + 1 < args.count {
            packPath = args[i + 1]
            UserDefaults.standard.set(packPath, forKey: "characterPath")
        } else if case .pet = mode {
            packPath = UserDefaults.standard.string(forKey: "characterPath")
        }
        if let packPath {
            if packPath == "builtin" {
                UserDefaults.standard.removeObject(forKey: "characterPath")
            } else if let loaded = ShimejiImporter.load(packAt: URL(fileURLWithPath: packPath)) {
                sprites = loaded.set
                characterName = "\(loaded.name) (shimeji)"
            } else {
                print("WindowPet: could not load character pack at \(packPath) — using Rusty")
            }
        }

        engine = PetEngine(stage: stage, verbose: verbose, sprites: sprites)

        // Tool servers come up before the mode switch, not with the panel:
        // they are part of what the agent can do, so a headless --ask run and
        // the rig get the same tool list the running pet does.
        AssistantExecutor.shared.mcp.startAll()
        ClaudeAgent.mcpTools = AssistantExecutor.shared.mcp.toolDefinitions

        switch mode {
        case .pet:
            installStatusItem()
            installCommandBar()
            showOnboardingIfNeeded()
            engine.start()
        case .diag(let seconds):
            print("diag: running for \(Int(seconds))s (Tier 1 only, bounds-only, no permissions)")
            print("diag: sprite frames loaded = \(engine.spriteFrameCount)")
            print("diag: accessibility trusted = \(AXPermission.trusted)")
            print("diag: natural language = \(AssistantBrain.naturalLanguageStatus)")
            print("diag: brain = \(AssistantBrain.brainDescription)")
            print("diag: voice permissions = \(VoiceInput.authorizationSummary)")
            print("diag: reply voice = \(ElevenLabsTTS.apiKey == nil ? "system (no ElevenLabs key)" : "ElevenLabs")")
            print("diag: fallback voice = \(VoiceInput.fallbackVoiceDescription)")
            print("diag: voice provider = \(VoiceInput.provider) (edge-tts \(EdgeTTSPlayer.isAvailable ? "available" : "NOT available"))")
            print("diag: wake word = \(UserDefaults.standard.object(forKey: "wakeWord") == nil || UserDefaults.standard.bool(forKey: "wakeWord") ? "on" : "off")")
            if let front = NSWorkspace.shared.frontmostApplication {
                print("diag: frontmost app = \(front.localizedName ?? "?") pid=\(front.processIdentifier)")
            }
            engine.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                print("diag: final state = \(self?.engine.stateName ?? "?")")
                if let n = self?.engine.debugNeeds {
                    print(String(format: "diag: needs — energy %.2f, curiosity %.2f, attention %.2f, boredom %.2f%@",
                                 n.energy, n.curiosity, n.attention, n.boredom,
                                 (self?.engine.isSleeping ?? false) ? " (sleeping)" : ""))
                }
                for line in self?.engine.tier2.summaryLines ?? [] { print("diag: tier2 — \(line)") }
                print("diag: summon = \(HotKeyStore.current.displayName), "
                      + "dictation = \(HotKeyStore.dictation.displayName)")
                print("diag: quiet hours = \(self?.quietHours?.isEnabled == false ? "off" : "on")"
                      + ", focus \(QuietHours.focusIsOn ? "on" : "off")"
                      + ", mic \(QuietHours.microphoneInUseElsewhere ? "in use elsewhere" : "free")")
                let services = AssistantExecutor.shared
                print("diag: standing asks = \(services.schedules.entries.count), "
                      + "tricks = \(TrickStore.load().count), "
                      + "layouts = \(LayoutStore.load().count), "
                      + "clips = \(services.clipboard.clips.count)")
                print("diag: done")
                exit(0)
            }
        case .testRig:
            rig = TestRig(engine: engine, stage: stage)
            rig?.run()
        case .ask(let prompt):
            // Headless agent run: the full loop with real tools and real
            // streaming, no panel. For debugging and end-to-end verification.
            print("ask: \(prompt)")
            let session = AgentSession()
            session.onProgress = { print("step: \($0)") }
            session.onTextDelta = { chunk in
                FileHandle.standardOutput.write(Data(chunk.utf8))
            }
            Task {
                let step = await session.start(prompt, context: "headless test run",
                                               history: [])
                await MainActor.run {
                    switch step {
                    case .done(let answer):
                        print("\nanswer: \(answer)")
                        exit(0)
                    case .needsConfirmation(_, let summary):
                        print("\nwould need confirmation: \(summary)")
                        exit(0)
                    case .failed(let message):
                        print("\nfailed: \(message)")
                        exit(1)
                    }
                }
            }
        case .bench(let seconds):
            bench = BenchRunner(engine: engine, phaseSeconds: seconds)
            bench?.run()
        case .helperWindow, .helperTitleSpam:
            break // handled above
        }
    }

    private func runHelperWindow(spamTitle: Bool) {
        let w = NSWindow(contentRect: CGRect(x: 320, y: 320, width: 420, height: 260),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "WindowPet AX helper"
        w.isReleasedWhenClosed = false
        w.orderFrontRegardless()
        var step = 0
        // Main-queue dispatch timers rather than Timer: their handlers stay
        // on the main actor, so the window and the step counter are touched
        // from exactly one place.
        let ticker = DispatchSource.makeTimerSource(queue: .main)
        if spamTitle {
            // A fake build: retitle ~3×/s for ~4.5 s so observers see
            // kAXTitleChanged bursts, then exit.
            ticker.schedule(deadline: .now() + 0.33, repeating: 0.33)
            ticker.setEventHandler {
                step += 1
                w.title = "compiling step \(step) of 14…"
                if step > 14 { exit(0) }
            }
        } else {
            // Wiggle for ~3.5 s so an observer sees kAXWindowMoved events.
            ticker.schedule(deadline: .now() + 1.0 / 30.0, repeating: 1.0 / 30.0)
            ticker.setEventHandler {
                step += 1
                w.setFrameOrigin(CGPoint(x: 320 + CGFloat(step % 40) * 3, y: 320))
                if step > 105 { exit(0) }
            }
        }
        ticker.resume()
        helperTicker = ticker
    }

    private static func parseMode(_ args: [String]) -> Mode {
        if let i = args.firstIndex(of: "--bench") {
            let seconds = (i + 1 < args.count ? TimeInterval(args[i + 1]) : nil) ?? 20
            return .bench(seconds)
        }
        if args.contains("--helper-title-spam") { return .helperTitleSpam }
        if args.contains("--helper-window") { return .helperWindow }
        if args.contains("--testrig") { return .testRig }
        if let i = args.firstIndex(of: "--ask"), i + 1 < args.count {
            return .ask(args[i + 1])
        }
        if let i = args.firstIndex(of: "--diag") {
            let seconds = (i + 1 < args.count ? TimeInterval(args[i + 1]) : nil) ?? 6
            return .diag(seconds)
        }
        return .pet
    }

    // MARK: - Status item

    private func installCommandBar() {
        let bar = CommandBar()
        bar.registerHotKey() // ⌥Space
        bar.petAnchorProvider = { [weak self] in self?.engine.anchor ?? .zero }
        bar.contextProvider = { [weak self] in self?.engine.assistantContext() ?? "" }
        // Every input method lands in the same chat panel; this is the one
        // place outcomes fan out to the pet (animation), the voice (TTS),
        // and the microphone hand-back.
        bar.onOutcome = { [weak self] outcome, fromVoice in
            guard let self else { return }
            switch outcome {
            case .executed(let result, let reply):
                self.engine.assistantDidAct(result: result)
                let line = reply ?? result
                if fromVoice {
                    self.speakThenListen(line)
                } else {
                    self.voice?.speak(line)
                }
            case .reply(let reply):
                if fromVoice {
                    self.speakThenListen(reply)
                } else {
                    self.voice?.speak(reply)
                }
            case .needsConfirmation:
                // The user is at the keyboard for the safety check.
                if fromVoice { self.wake?.reclaimMicrophone() }
            case .unrecognized:
                if fromVoice { self.wake?.reclaimMicrophone() }
            }
        }
        stage.onDoubleClick = { [weak bar] in bar?.toggle() }
        // Dropping a file on him is the most direct thing you can ask a
        // creature standing on your screen to do.
        stage.onFilesDropped = { [weak bar] urls in bar?.submitDroppedFiles(urls) }
        commandBar = bar

        // Long-lived services. The watch registry keeps ticking between
        // turns, which is the point of it, and speaks through the panel when
        // something it promised to notice happens.
        // Anything Rusty says unprompted goes through the quiet gate first,
        // so a watch firing never talks over a call.
        let quiet = QuietHours()
        quiet.speakingProvider = { [weak self] in self?.voice?.willSpeak ?? false }
        quiet.suspendedProvider = { [weak self] in self?.engine.stateName == "suspended" }
        quiet.immersionProvider = { [weak self] in self?.engine.immersionActive ?? false }
        quiet.onRelease = { [weak self] message in self?.announce(message, spoken: true) }
        quietHours = quiet

        AssistantExecutor.shared.watches.onFire = { [weak self] message in
            self?.announce(message, spoken: true)
        }
        // A live watch sends him to stand on the window and lights his lamp,
        // so the promise is visible rather than taken on faith.
        AssistantExecutor.shared.watches.onWatchingChanged = { [weak self] pid in
            guard let self else { return }
            if let pid {
                self.engine.standWatch(overPID: pid)
            } else {
                self.engine.endWatch()
            }
        }
        // A standing ask runs the full agent when it comes due, and announces
        // itself so an answer arriving unprompted is never mysterious.
        AssistantExecutor.shared.schedules.onFire = { [weak self] entry in
            self?.commandBar?.runScheduled(entry)
        }
        AssistantExecutor.shared.clipboard.start()

        // Dictation: hold the second shortcut and speak into whatever app is
        // in front. No model, no request, nothing leaves the machine.
        if let voice {
            let dictation = Dictation(voice: voice)
            dictation.onStatus = { [weak self] text in self?.stage.say(text, for: 2.5) }
            dictation.onProblem = { [weak self] message in
                self?.commandBar?.systemNote(message)
            }
            self.dictation = dictation
            bar.onDictateStart = { [weak self] in self?.dictation?.begin() }
            bar.onDictateEnd = { [weak self] in self?.dictation?.end() }
        }

        // A3: hold ⌥Space to talk; the live transcript streams into the
        // chat panel (dimmed until final).
        let voice = VoiceInput()
        let eleven = ElevenLabsTTS()
        eleven.onError = { [weak bar] message in bar?.systemNote(message) }
        voice.eleven = eleven
        voice.edge = EdgeTTSPlayer()
        voice.onState = { [weak bar] state in
            if state != "listening" { bar?.systemNote(state) }
        }
        voice.onPartial = { [weak bar] text in bar?.voiceTranscript(text) }
        voice.onFinal = { [weak bar] text in bar?.finishVoice(text) }
        bar.onHoldStart = { [weak self] in
            self?.wake?.yieldMicrophone()
            self?.commandBar?.beginVoice()
            self?.voice?.beginListening()
        }
        bar.onHoldEnd = { [weak self] in self?.voice?.endListening() }
        self.voice = voice

        // A4: "Hey Rusty" — always-on wake word (menu-toggleable). A one-shot
        // utterance ("hey rusty mute the sound") routes directly; a bare
        // "hey rusty" opens hands-free capture that ends on silence. All of
        // it plays out in the chat panel.
        let wake = WakeWordListener()
        wake.onStatus = { [weak bar] message in bar?.systemNote(message) }
        wake.onWakeCommand = { [weak self] command in
            guard let self else { return }
            self.engine.assistantSummoned()
            self.commandBar?.submitVoice(command)
        }
        wake.onListeningStarted = { [weak self] in
            guard let self else { return }
            self.engine.assistantSummoned()
            self.commandBar?.beginVoice()
        }
        wake.onCapturePartial = { [weak self] text in
            self?.commandBar?.voiceTranscript(text)
        }
        wake.onCaptureFinal = { [weak self] text in
            guard let self else { return }
            if text.isEmpty {
                if self.followUpActive {
                    self.followUpActive = false
                    self.commandBar?.endVoiceQuietly()
                    self.wake?.reclaimMicrophone()
                    return
                }
                SoundFX.shared.play("miss")
            }
            self.followUpActive = false
            self.commandBar?.finishVoice(text)
        }
        self.wake = wake
        if UserDefaults.standard.object(forKey: "wakeWord") == nil
            || UserDefaults.standard.bool(forKey: "wakeWord") {
            wake.setEnabled(true)
        }
    }

    /// Voice continuity: speak the reply, and once the audio finishes (or
    /// right away when spoken replies are off) reopen hands-free capture so
    /// the user can keep talking without another "hey rusty". Silence in
    /// that window ends the conversation quietly.
    private var followUpActive = false

    private func speakThenListen(_ line: String) {
        guard let wake, wake.enabled else {
            voice?.speak(line)
            self.wake?.reclaimMicrophone()
            return
        }
        let startFollowUp = { [weak self] in
            guard let self else { return }
            self.followUpActive = true
            self.wake?.reclaimMicrophone()
            self.wake?.beginFollowUpCapture()
        }
        if let voice, voice.willSpeak {
            voice.onSpeechFinished = { [weak self] in
                self?.voice?.onSpeechFinished = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { startFollowUp() }
            }
            voice.speak(line)
            // Safety net: if no provider ever reports finishing, reopen anyway.
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                guard let self, self.voice?.onSpeechFinished != nil else { return }
                self.voice?.onSpeechFinished = nil
                startFollowUp()
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { startFollowUp() }
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Template image: the system renders it white on dark menu bars,
        // black on light — same contract as every other status icon.
        if let url = Bundle.module.url(forResource: "menubar_icon", withExtension: "png"),
           let icon = NSImage(contentsOf: url) {
            icon.isTemplate = true
            icon.size = NSSize(width: 18, height: 18)
            item.button?.image = icon
        } else {
            item.button?.title = "R"
        }
        let menu = NSMenu()
        let info = NSMenuItem(title: "Waking up…", action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        let senses = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        senses.isEnabled = false
        menu.addItem(senses)
        let brain = NSMenuItem(title: "Brain: \(AssistantBrain.brainDescription)",
                               action: nil, keyEquivalent: "")
        brain.isEnabled = false
        menu.addItem(brain)
        let usage = NSMenuItem(title: UsageMeter.shared.summary, action: nil, keyEquivalent: "")
        usage.isEnabled = false
        menu.addItem(usage)
        usageItem = usage
        menu.addItem(NSMenuItem(title: "Daily Spend Limit…", action: #selector(setSpendLimit),
                                keyEquivalent: ""))
        let abilities = NSMenu()
        let clipboardItem = NSMenuItem(title: "Remember What I Copy",
                                       action: #selector(toggleClipboardHistory), keyEquivalent: "")
        clipboardItem.state = AssistantExecutor.shared.clipboard.isEnabled ? .on : .off
        abilities.addItem(clipboardItem)
        clipboardHistoryItem = clipboardItem
        abilities.addItem(NSMenuItem(title: "Forget Copied Clips",
                                     action: #selector(clearClipboardHistory), keyEquivalent: ""))
        abilities.addItem(.separator())
        let quietItem = NSMenuItem(title: "Stay Quiet During Focus And Calls",
                                   action: #selector(toggleQuietHours), keyEquivalent: "")
        quietItem.state = (quietHours?.isEnabled ?? true) ? .on : .off
        abilities.addItem(quietItem)
        quietHoursItem = quietItem
        abilities.addItem(NSMenuItem(title: "Dictation Shortcut…",
                                     action: #selector(changeDictationHotKey), keyEquivalent: ""))
        abilities.addItem(.separator())
        let mcpStatus = NSMenuItem(title: mcpMenuTitle(), action: nil, keyEquivalent: "")
        mcpStatus.isEnabled = false
        abilities.addItem(mcpStatus)
        mcpItem = mcpStatus
        abilities.addItem(NSMenuItem(title: "Edit Tool Servers…", action: #selector(editMCPConfig),
                                     keyEquivalent: ""))
        abilities.addItem(NSMenuItem(title: "Reconnect Tool Servers",
                                     action: #selector(reloadMCP), keyEquivalent: ""))
        let abilitiesItem = NSMenuItem(title: "Abilities", action: nil, keyEquivalent: "")
        abilitiesItem.submenu = abilities
        menu.addItem(abilitiesItem)
        let character = NSMenuItem(title: "Character: \(characterName)", action: nil, keyEquivalent: "")
        character.isEnabled = false
        menu.addItem(character)
        characterItem = character
        menu.addItem(.separator())
        let voiceMenu = NSMenu()
        for (title, key) in [("ElevenLabs (Jessica)", "elevenlabs"),
                             ("Microsoft Neural (Free)", "edge"),
                             ("macOS System Voice", "system")] {
            let item = NSMenuItem(title: title, action: #selector(pickVoiceProvider(_:)), keyEquivalent: "")
            item.representedObject = key
            item.target = self
            item.state = VoiceInput.provider == key ? .on : .off
            voiceMenu.addItem(item)
        }
        let skinsMenu = NSMenu()
        for theme in SkinTheme.all {
            let item = NSMenuItem(title: theme.displayName, action: #selector(pickSkin(_:)), keyEquivalent: "")
            item.representedObject = theme.id
            item.state = theme.id == SkinTheme.currentID ? .on : .off
            skinsMenu.addItem(item)
        }
        skinsMenu.addItem(.separator())
        skinsMenu.addItem(NSMenuItem(title: "Open Skins Folder…",
                                     action: #selector(openSkinsFolder), keyEquivalent: ""))
        skinsMenu.addItem(NSMenuItem(title: "Reload Skins",
                                     action: #selector(reloadSkins), keyEquivalent: ""))
        skinsMenu.items.forEach { $0.target = self }
        let skinsRoot = NSMenuItem(title: "Skin", action: nil, keyEquivalent: "")
        menu.addItem(skinsRoot)
        menu.setSubmenu(skinsMenu, for: skinsRoot)
        self.skinsMenu = skinsMenu
        let voiceRoot = NSMenuItem(title: "Voice", action: nil, keyEquivalent: "")
        menu.addItem(voiceRoot)
        menu.setSubmenu(voiceMenu, for: voiceRoot)
        voiceProviderMenu = voiceMenu

        let elevenItem = NSMenuItem(title: elevenLabsMenuTitle(), action: #selector(setElevenKey), keyEquivalent: "")
        menu.addItem(elevenItem)
        let anthropicItem = NSMenuItem(title: "Anthropic API Key…", action: #selector(setAnthropicKey), keyEquivalent: "")
        menu.addItem(anthropicItem)
        menu.addItem(NSMenuItem(title: "Test Claude Brain", action: #selector(testClaude), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "What Rusty Remembers…", action: #selector(showMemory), keyEquivalent: ""))
        let hotKeyItem = NSMenuItem(title: "", action: #selector(changeHotKey), keyEquivalent: "")
        menu.addItem(hotKeyItem)
        self.hotKeyItem = hotKeyItem
        refreshHotKeyItem()
        elevenLabsItem = elevenItem
        let wakeItem = NSMenuItem(title: "“Hey Rusty” Wake Word", action: #selector(toggleWake(_:)), keyEquivalent: "")
        wakeItem.state = (UserDefaults.standard.object(forKey: "wakeWord") == nil
                          || UserDefaults.standard.bool(forKey: "wakeWord")) ? .on : .off
        menu.addItem(wakeItem)
        let spoken = NSMenuItem(title: "Spoken Replies", action: #selector(toggleSpoken), keyEquivalent: "")
        spoken.state = (UserDefaults.standard.object(forKey: "spokenReplies") == nil
                        || UserDefaults.standard.bool(forKey: "spokenReplies")) ? .on : .off
        menu.addItem(spoken)
        let sounds = NSMenuItem(title: "Chime Sounds", action: #selector(toggleSounds(_:)), keyEquivalent: "")
        sounds.state = SoundFX.enabled ? .on : .off
        menu.addItem(sounds)
        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let assistant = NSMenuItem(title: "Assistant…", action: #selector(showAssistant), keyEquivalent: " ")
        assistant.keyEquivalentModifierMask = [.option]
        menu.addItem(assistant)
        menu.addItem(NSMenuItem(title: "Choose Character…", action: #selector(chooseCharacter), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Use Built-In Rusty", action: #selector(useBuiltin), keyEquivalent: ""))
        menu.addItem(.separator())
        let enable = NSMenuItem(title: "Enable Window Senses (Accessibility)…",
                                action: #selector(enableSenses), keyEquivalent: "")
        menu.addItem(enable)
        let fda = NSMenuItem(title: "", action: #selector(openFullDiskAccess), keyEquivalent: "")
        menu.addItem(fda)
        fullDiskItem = fda
        refreshFullDiskItem()
        menu.addItem(NSMenuItem(title: "About WindowPet", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit WindowPet", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
        sensesItem = senses
        brainItem = brain
        enableItem = enable
        engine.onStatus = { [weak info, weak self] text in
            info?.title = text
            self?.refreshSensesItem()
        }
        refreshSensesItem()
    }

    private var sensesItem: NSMenuItem?
    private var brainItem: NSMenuItem?
    private var characterItem: NSMenuItem?
    private var enableItem: NSMenuItem?
    private var fullDiskItem: NSMenuItem?
    private var grantPollTimer: DispatchSourceTimer?
    /// Held so the AX-helper window's ticker outlives the call that made it.
    private var helperTicker: DispatchSourceTimer?

    private func refreshFullDiskItem() {
        fullDiskItem?.title = FullDiskAccess.granted
            ? "Full Disk Access: On"
            : "Grant Full Disk Access…"
        fullDiskItem?.isEnabled = !FullDiskAccess.granted
    }

    @objc private func openFullDiskAccess() {
        FullDiskAccess.openSettings()
        commandBar?.systemNote("Find WindowPet in the list and switch it on, then relaunch. This lets Rusty reach protected files when you ask.")
    }

    private func refreshSensesItem() {
        usageItem?.title = UsageMeter.shared.summary
        if engine.tier2.enabled {
            let n = engine.tier2.states.count
            sensesItem?.title = "Window Senses: On, watching \(n) app\(n == 1 ? "" : "s")"
            enableItem?.isHidden = true
        } else {
            sensesItem?.title = "Window Senses: Geometry Only"
            enableItem?.isHidden = false
        }
    }

    /// User-initiated Accessibility onboarding: fire the system prompt, then
    /// poll for the grant — there is no notification for it, and the app must
    /// pick it up without a restart.
    @objc private func enableSenses() {
        AXPermission.requestWithPrompt()
        grantPollTimer?.cancel()
        var polls = 0
        let poller = DispatchSource.makeTimerSource(queue: .main)
        poller.schedule(deadline: .now() + 2, repeating: 2)
        poller.setEventHandler { [weak self] in
            guard let self else { poller.cancel(); return }
            polls += 1
            if self.engine.tier2.enableIfTrusted() {
                poller.cancel()
                if let pid = self.engine.currentPlatformPID {
                    self.engine.tier2.attach(to: pid, protecting: pid)
                }
                self.refreshSensesItem()
            } else if polls > 180 { // give up after ~6 min
                poller.cancel()
            }
        }
        poller.resume()
        grantPollTimer = poller
    }

    /// Character manager: point at any shimeji-ee pack directory; hot-swaps
    /// live and persists across launches.
    @objc private func chooseCharacter() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a Shimeji character pack (a folder containing conf/actions.xml and img/)"
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            if let loaded = ShimejiImporter.load(packAt: url) {
                self.engine.applySprites(loaded.set, name: loaded.name)
                UserDefaults.standard.set(url.path, forKey: "characterPath")
                self.characterName = "\(loaded.name) (shimeji)"
                self.characterItem?.title = "Character: \(self.characterName)"
            } else {
                let alert = NSAlert()
                alert.messageText = "Not a loadable Shimeji pack"
                alert.informativeText = "Expected conf/actions.xml (shimeji-ee English schema) and an img/ folder of PNG frames."
                alert.runModal()
            }
        }
    }

    @objc private func useBuiltin() {
        engine.applySprites(SpriteSet(), name: "Rusty")
        UserDefaults.standard.removeObject(forKey: "characterPath")
        characterName = "Rusty (built-in)"
        characterItem?.title = "Character: \(characterName)"
    }

    @objc private func showAssistant() { commandBar?.show() }

    private var elevenLabsItem: NSMenuItem?
    private var voiceProviderMenu: NSMenu?

    @objc private func pickVoiceProvider(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        UserDefaults.standard.set(key, forKey: "voiceProvider")
        voiceProviderMenu?.items.forEach {
            $0.state = ($0.representedObject as? String) == key ? .on : .off
        }
    }

    private func elevenLabsMenuTitle() -> String { "ElevenLabs API Key…" }

    /// The key is typed directly into the app (secure field) and stored
    /// locally — it never passes through anything else.
    @objc private func setElevenKey() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "ElevenLabs API Key"
        alert.informativeText = "Stored locally in this app's preferences. Leave empty to remove and use the system voice. Only Rusty's short replies are sent to ElevenLabs."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "xi-…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let key = field.stringValue.trimmingCharacters(in: .whitespaces)
            if key.isEmpty {
                UserDefaults.standard.removeObject(forKey: "elevenLabsKey")
            } else {
                UserDefaults.standard.set(key, forKey: "elevenLabsKey")
            }
            elevenLabsItem?.title = elevenLabsMenuTitle()
        }
    }

    private var clipboardHistoryItem: NSMenuItem?
    private var mcpItem: NSMenuItem?
    private var quietHoursItem: NSMenuItem?
    private var dictation: Dictation?
    private var quietHours: QuietHours?

    /// One door for everything Rusty says without being asked. It always
    /// reaches the panel; whether it is spoken depends on the moment.
    private func announce(_ text: String, spoken: Bool) {
        guard let quiet = quietHours else {
            commandBar?.announce(text)
            return
        }
        let decision = quiet.offer(text)
        commandBar?.announce(decision.show, speak: spoken && decision.speak != nil)
    }

    private func mcpMenuTitle() -> String {
        let host = AssistantExecutor.shared.mcp
        let names = host.connectedNames
        if names.isEmpty {
            return FileManager.default.fileExists(atPath: MCPHost.configURL.path)
                ? "Tool servers: none connected"
                : "Tool servers: none configured"
        }
        let count = ClaudeAgent.mcpTools.count
        return "Tool servers: \(names.joined(separator: ", ")) (\(count) "
            + "\(count == 1 ? "tool" : "tools"))"
    }

    @objc private func toggleClipboardHistory() {
        let clipboard = AssistantExecutor.shared.clipboard
        clipboard.isEnabled.toggle()
        clipboardHistoryItem?.state = clipboard.isEnabled ? .on : .off
        commandBar?.systemNote(clipboard.isEnabled
            ? "I will remember what you copy while I am running. Nothing is written to disk, and anything shaped like a password or a key is skipped."
            : "Stopped remembering what you copy, and forgot what I had.")
    }

    @objc private func toggleQuietHours() {
        let on = !(quietHours?.isEnabled ?? true)
        UserDefaults.standard.set(on, forKey: "quietHours")
        quietHoursItem?.state = on ? .on : .off
        if !on { quietHours?.clear() }
        commandBar?.systemNote(on
            ? "I will hold anything I want to say while Focus is on, your microphone is in use, or the screen is locked, and say it when the moment passes."
            : "I will speak up whenever I have something, Focus or not.")
    }

    @objc private func changeDictationHotKey() {
        let recorder = HotKeyRecorder()
        hotKeyRecorder = recorder
        recorder.record(current: HotKeyStore.dictation) { [weak self] binding in
            guard let self else { return }
            self.hotKeyRecorder = nil
            guard let binding else { return }
            guard !HotKeyStore.collides(binding, with: .dictate) else {
                self.commandBar?.systemNote("That is already the shortcut for summoning me. Pick a different one.")
                return
            }
            HotKeyStore.save(binding, for: .dictate)
            self.commandBar?.applyDictationHotKey(binding)
            self.commandBar?.systemNote("Hold \(binding.displayName) and speak, and the words go into whatever app is in front. Nothing is sent anywhere and nothing is spent.")
        }
    }

    @objc private func clearClipboardHistory() {
        AssistantExecutor.shared.clipboard.clear()
        commandBar?.systemNote("Forgot the copied clips.")
    }

    /// Opens mcp.json in the user's editor, writing a commented example first
    /// if there is nothing there yet. Editing a config by hand is the right
    /// interface for this: it is a list of commands to run.
    @objc private func editMCPConfig() {
        let url = MCPHost.configURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Data(MCPConfig.example.utf8).write(to: url, options: .atomic)
        }
        NSWorkspace.shared.open(url)
        commandBar?.systemNote("Opened mcp.json. Add a server, save, then choose Reconnect Tool Servers.")
    }

    @objc private func reloadMCP() {
        let host = AssistantExecutor.shared.mcp
        host.startAll()
        ClaudeAgent.mcpTools = host.toolDefinitions
        mcpItem?.title = mcpMenuTitle()
        let report = host.startupReport
        commandBar?.systemNote(report.isEmpty
            ? "No tool servers are configured. Choose Edit Tool Servers to add one."
            : report.joined(separator: "; "))
    }

    /// The ceiling on what Rusty may spend per day. Enforced before every
    /// model call, so raising it here is the only way past a stop.
    @objc private func setSpendLimit() {
        NSApp.activate()
        let meter = UsageMeter.shared
        let alert = NSAlert()
        alert.messageText = "Daily Spend Limit"
        alert.informativeText = "The most Rusty may spend on thinking in one day. He stops before every model call once it is reached, and the count resets at midnight. Type a dollar amount, or \"none\" for no ceiling.\n\n\(meter.summary)"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = meter.limit <= BudgetPolicy.unlimited
            ? "none" : String(format: "%.2f", meter.limit)
        field.placeholderString = "5.00"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let parsed = BudgetPolicy.parseLimit(field.stringValue) else {
            let complaint = NSAlert()
            complaint.messageText = "That is not an amount"
            complaint.informativeText = "Type a number like 5 or 12.50, or \"none\" to remove the ceiling. The limit is unchanged."
            complaint.runModal()
            return
        }
        meter.limit = parsed
        usageItem?.title = meter.summary
    }

    /// Same local-only handling as the ElevenLabs key: secure field, stored
    /// in preferences, never displayed back.
    @objc private func setAnthropicKey() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Anthropic API Key"
        alert.informativeText = "Unlocks the Claude brain for Rusty's answers. Stored locally in this app's preferences; only your command text and a one-line context summary are sent to Anthropic. Leave empty to remove and use the on-device brain."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "sk-ant-…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let key = field.stringValue.trimmingCharacters(in: .whitespaces)
            if key.isEmpty {
                UserDefaults.standard.removeObject(forKey: "anthropicKey")
            } else {
                UserDefaults.standard.set(key, forKey: "anthropicKey")
            }
            brainItem?.title = "Brain: \(AssistantBrain.brainDescription)"
        }
    }

    private var skinsMenu: NSMenu?

    @objc private func pickSkin(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        UserDefaults.standard.set(id, forKey: "skin")
        UserDefaults.standard.removeObject(forKey: "characterPath")
        let theme = SkinTheme.current
        engine.applySprites(SpriteSet(skin: SkinTheme.currentSpriteID),
                            name: "Rusty (\(theme.displayName))")
        characterName = "Rusty (\(theme.displayName))"
        characterItem?.title = "Character: \(characterName)"
        commandBar?.retint()
        stage.retintBubble()
        skinsMenu?.items.forEach {
            $0.state = ($0.representedObject as? String) == id ? .on : .off
        }
    }

    @objc private func toggleSounds(_ sender: NSMenuItem) {
        let now = !SoundFX.enabled
        UserDefaults.standard.set(now, forKey: "uiSounds")
        sender.state = now ? .on : .off
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            commandBar?.systemNote("Couldn't change the login setting (\(error.localizedDescription)). This works from the installed app, not swift run.")
        }
        sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func openSkinsFolder() {
        let folder = CustomSkins.ensureFolder()
        NSWorkspace.shared.open(folder)
        let problems = CustomSkins.problems()
        if !problems.isEmpty {
            commandBar?.systemNote("Skipped: " + problems.joined(separator: "; "))
        }
    }

    /// Rebuilds the menu so newly added skin files show up without a relaunch.
    @objc private func reloadSkins() {
        CustomSkins.reload()
        statusItem.map { NSStatusBar.system.removeStatusItem($0) }
        statusItem = nil
        installStatusItem()
        let problems = CustomSkins.problems()
        commandBar?.systemNote(problems.isEmpty
            ? "Skins reloaded."
            : "Skins reloaded. Skipped: " + problems.joined(separator: "; "))
    }

    /// Memory is the user's, so it is inspectable and erasable in one place.
    @objc private func showMemory() {
        NSApp.activate()
        let memory = PetMemoryStore.load()
        let alert = NSAlert()
        alert.messageText = "What Rusty Remembers"
        if memory.facts.isEmpty {
            alert.informativeText = "Nothing yet. Tell him a preference and he'll keep it."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Reveal File")
        } else {
            alert.informativeText = memory.facts
                .map { "• \($0.text)" }
                .joined(separator: "\n")
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Reveal File")
            alert.addButton(withTitle: "Forget Everything")
        }
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([PetMemoryStore.fileURL])
        } else if response == .alertThirdButtonReturn {
            var cleared = memory
            cleared.forgetEverything()
            PetMemoryStore.save(cleared)
        }
    }

    private var usageItem: NSMenuItem?
    private var hotKeyItem: NSMenuItem?
    private var hotKeyRecorder: HotKeyRecorder?

    private func refreshHotKeyItem() {
        hotKeyItem?.title = "Shortcut: \(HotKeyStore.current.displayName)…"
    }

    /// Lets the user rebind the summon shortcut, which is also how they get
    /// out of a collision with another app that grabbed the same combo.
    @objc private func changeHotKey() {
        let recorder = HotKeyRecorder()
        hotKeyRecorder = recorder
        recorder.record(current: HotKeyStore.current) { [weak self] binding in
            guard let self else { return }
            self.hotKeyRecorder = nil
            guard let binding else { return }
            HotKeyStore.save(binding)
            self.commandBar?.applyHotKey(binding)
            self.refreshHotKeyItem()
            self.commandBar?.systemNote("Shortcut is now \(binding.displayName).")
        }
    }

    @objc private func testClaude() {
        commandBar?.systemNote("Testing the Claude brain…")
        Task {
            let verdict = await ClaudeRouter.selfTest()
            await MainActor.run { [weak self] in
                self?.commandBar?.systemNote(verdict)
                self?.brainItem?.title = "Brain: \(AssistantBrain.brainDescription)"
            }
        }
    }

    @objc private func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string: "A little windup robot who lives on your screen, rides your windows, and runs your computer when you ask.",
                attributes: [.font: NSFont.systemFont(ofSize: 11)]),
        ])
    }

    /// First launch: one warm hello that explains the two permissions that
    /// matter, instead of a wall of system prompts with no context.
    private func showOnboardingIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "onboarded") else { return }
        UserDefaults.standard.set(true, forKey: "onboarded")
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Meet Rusty"
        alert.informativeText = """
        He walks along your windows, and he's also a full assistant: tap Option-Space and ask him anything, hold it to talk, or just say "hey rusty".

        A few permissions make him whole. Accessibility lets him ride and slide your windows. Microphone and Speech Recognition make voice work; recognition stays on this Mac. Full Disk Access (menu bar, Grant Full Disk Access) lets him reach protected files when you ask. Anything needing an administrator asks for your password first.

        Bring your own Anthropic API key (menu bar, Anthropic API Key) to give him his smartest brain.
        """
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Start")
        if alert.runModal() == .alertFirstButtonReturn {
            enableSenses()
        }
    }

    @objc private func toggleWake(_ sender: NSMenuItem) {
        let newState = !(wake?.enabled ?? false)
        wake?.setEnabled(newState)
        sender.state = newState ? .on : .off
    }

    @objc private func toggleSpoken(_ sender: NSMenuItem) {
        let now = !(UserDefaults.standard.object(forKey: "spokenReplies") == nil
                    || UserDefaults.standard.bool(forKey: "spokenReplies"))
        UserDefaults.standard.set(now, forKey: "spokenReplies")
        sender.state = now ? .on : .off
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
