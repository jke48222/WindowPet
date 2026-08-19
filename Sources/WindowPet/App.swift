import AppKit

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

final class AppDelegate: NSObject, NSApplicationDelegate {

    enum Mode {
        case pet                    // normal: ambient companion
        case diag(TimeInterval)     // verbose logs for N seconds, then exit
        case testRig                // self-driving end-to-end check, exits 0/1
        case helperWindow           // rig prop: opens a titled window, wiggles it, exits
    }

    private var mode: Mode = .pet
    private var stage: OverlayStage!
    private var engine: PetEngine!
    private var statusItem: NSStatusItem?
    private var rig: TestRig?

    func applicationDidFinishLaunching(_ notification: Notification) {
        mode = Self.parseMode(CommandLine.arguments)

        // Rig prop: a separate process whose window the rig's Tier-2 observer
        // watches — real cross-process AX events, no engine, no panels.
        if case .helperWindow = mode {
            NSApp.setActivationPolicy(.accessory)
            runHelperWindow()
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
        case .diag, .testRig, .helperWindow: verbose = true
        }
        engine = PetEngine(stage: stage, verbose: verbose)

        switch mode {
        case .pet:
            installStatusItem()
            engine.start()
        case .diag(let seconds):
            print("diag: running for \(Int(seconds))s (Tier 1 only, bounds-only, no permissions)")
            print("diag: sprite frames loaded = \(engine.spriteFrameCount)")
            print("diag: accessibility trusted = \(AXPermission.trusted)")
            if let front = NSWorkspace.shared.frontmostApplication {
                print("diag: frontmost app = \(front.localizedName ?? "?") pid=\(front.processIdentifier)")
            }
            engine.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                print("diag: final state = \(self?.engine.stateName ?? "?")")
                for line in self?.engine.tier2.summaryLines ?? [] { print("diag: tier2 — \(line)") }
                print("diag: done")
                exit(0)
            }
        case .testRig:
            rig = TestRig(engine: engine, stage: stage)
            rig?.run()
        case .helperWindow:
            break // handled above
        }
    }

    private func runHelperWindow() {
        let w = NSWindow(contentRect: CGRect(x: 320, y: 320, width: 420, height: 260),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "WindowPet AX helper"
        w.isReleasedWhenClosed = false
        w.orderFrontRegardless()
        // Wiggle for ~3.5 s so an observer of this pid sees kAXWindowMoved
        // events, then exit.
        var step = 0
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { timer in
            step += 1
            w.setFrameOrigin(CGPoint(x: 320 + CGFloat(step % 40) * 3, y: 320))
            if step > 105 {
                timer.invalidate()
                exit(0)
            }
        }
    }

    private static func parseMode(_ args: [String]) -> Mode {
        if args.contains("--helper-window") { return .helperWindow }
        if args.contains("--testrig") { return .testRig }
        if let i = args.firstIndex(of: "--diag") {
            let seconds = (i + 1 < args.count ? TimeInterval(args[i + 1]) : nil) ?? 6
            return .diag(seconds)
        }
        return .pet
    }

    // MARK: - Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🐾"
        let menu = NSMenu()
        let info = NSMenuItem(title: "Waking up…", action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        let senses = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        senses.isEnabled = false
        menu.addItem(senses)
        menu.addItem(.separator())
        let enable = NSMenuItem(title: "Enable window senses (Accessibility)…",
                                action: #selector(enableSenses), keyEquivalent: "")
        menu.addItem(enable)
        menu.addItem(NSMenuItem(title: "Quit WindowPet", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
        sensesItem = senses
        enableItem = enable
        engine.onStatus = { [weak info, weak self] text in
            info?.title = text
            self?.refreshSensesItem()
        }
        refreshSensesItem()
    }

    private var sensesItem: NSMenuItem?
    private var enableItem: NSMenuItem?
    private var grantPollTimer: Timer?

    private func refreshSensesItem() {
        if engine.tier2.enabled {
            let n = engine.tier2.states.count
            sensesItem?.title = "Senses: Tier 1 + AX (\(n) app\(n == 1 ? "" : "s") observed)"
            enableItem?.isHidden = true
        } else {
            sensesItem?.title = "Senses: Tier 1 only (geometry)"
            enableItem?.isHidden = false
        }
    }

    /// User-initiated Accessibility onboarding: fire the system prompt, then
    /// poll for the grant — there is no notification for it, and the app must
    /// pick it up without a restart.
    @objc private func enableSenses() {
        AXPermission.requestWithPrompt()
        grantPollTimer?.invalidate()
        var polls = 0
        grantPollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            polls += 1
            if self.engine.tier2.enableIfTrusted() {
                t.invalidate()
                if let pid = self.engine.currentPlatformPID {
                    self.engine.tier2.attach(to: pid, protecting: pid)
                }
                self.refreshSensesItem()
            } else if polls > 180 { // give up after ~6 min
                t.invalidate()
            }
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
