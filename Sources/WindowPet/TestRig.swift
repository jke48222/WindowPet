import AppKit
import WindowPetCore

/// Autonomous end-to-end verification, zero permissions, structured as a
/// SEQUENTIAL STEP RUNNER: every step performs an action and then polls a
/// condition (0.1 s) until it holds or times out. Nothing asserts against
/// wall-clock choreography, so load spikes on a live machine turn into waits
/// instead of flakes.
///
/// Parts: B window terrain · A floor/touch/climb · C Tier-2 AX events ·
/// D behavior brain · E reactions.
/// Drives the app from the main run loop, so it shares the UI isolation.
@MainActor
final class TestRig {

    private let engine: PetEngine
    private let stage: OverlayStage
    private var winA: NSWindow!
    private var winB: NSWindow!
    private var winD: NSWindow!
    private var winE: NSWindow!
    private var winS: NSWindow!
    private var winG: NSWindow!
    private var winI: NSWindow!
    private var winH: NSWindow!
    private var moveHelper: Process?
    private var spamHelper: Process?
    private var moveDone = false
    /// Holds the drag-glide ticker so it outlives the step that starts it.
    private var dragGlide: DispatchSourceTimer?
    private var lastStatus = ""

    private var xMark: CGFloat = 0
    private var climbY0: CGFloat = 0
    private var axEventsAtProbe = 0

    private var shimejiResult: (set: SpriteSet, name: String)?
    private var checks = 0
    private var failures: [String] = []

    private var steps: [(name: String?, timeout: TimeInterval,
                         action: () -> Void, until: (() -> Bool)?)] = []

    init(engine: PetEngine, stage: OverlayStage) {
        self.engine = engine
        self.stage = stage
    }

    private func makeWindow(_ rect: CGRect, title: String) -> NSWindow {
        let w = NSWindow(contentRect: rect, styleMask: [.borderless],
                         backing: .buffered, defer: false)
        w.title = title
        w.backgroundColor = NSColor.systemTeal.withAlphaComponent(0.35)
        w.isReleasedWhenClosed = false
        w.orderFrontRegardless()
        return w
    }

    private func mapped(_ w: NSWindow?) -> Bool {
        guard let w else { return false }
        return Tier1.window(byID: CGWindowID(exactly: w.windowNumber) ?? 0)?.isOnScreen ?? false
    }

    private func id(of w: NSWindow) -> CGWindowID {
        CGWindowID(exactly: w.windowNumber) ?? 0
    }

    // MARK: - Step machinery

    private func step(_ name: String? = nil, timeout: TimeInterval = 4,
                      action: @escaping () -> Void = {},
                      until: (() -> Bool)? = nil) {
        steps.append((name, timeout, action, until))
    }

    /// Instant assertion evaluated in order with the steps.
    private func assertNow(_ name: String, _ cond: @escaping () -> Bool) {
        step(name, timeout: 0.8, until: cond)
    }

    private func runStep(_ i: Int) {
        guard i < steps.count else { finish(); return }
        let s = steps[i]
        s.action()
        guard let until = s.until else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.runStep(i + 1) }
            return
        }
        let deadline = Date().addingTimeInterval(s.timeout)
        func poll() {
            if until() {
                if let n = s.name { self.check(n, true) }
                self.runStep(i + 1)
                return
            }
            if Date() > deadline {
                self.check(s.name ?? "step \(i) wait", false)
                self.runStep(i + 1)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll)
        }
        poll()
    }

    private func check(_ name: String, _ ok: Bool) {
        checks += 1
        print("rig: \(ok ? "PASS" : "FAIL") — \(name)")
        if !ok { failures.append(name) }
    }

    private func onTop(of w: NSWindow) -> Bool {
        abs(engine.anchor.y - w.frame.maxY) <= 1.5
            && engine.anchor.x >= w.frame.minX - 2
            && engine.anchor.x <= w.frame.maxX + 2
    }

    private func spriteOnAnchor() -> Bool {
        let rect = stage.spriteGlobalRect
        let feet = CGPoint(x: rect.midX, y: rect.minY + PetEngine.footOverlap)
        return hypot(feet.x - engine.anchor.x, feet.y - engine.anchor.y) <= 1.0
    }

    // MARK: - Scenario

    func run() {
        engine.autonomy = false
        engine.greetingEnabled = false
        engine.onStatus = { [weak self] text in self?.lastStatus = text }
        engine.allowOwnWindows = true
        engine.debugForcePID = ProcessInfo.processInfo.processIdentifier
        engine.world.restrictPID = ProcessInfo.processInfo.processIdentifier

        DispatchQueue.main.asyncAfter(deadline: .now() + 150) {
            print("RIG FAIL timeout — scenario did not complete")
            exit(2)
        }

        buildScenario()
        runStep(0)
    }

    private func buildScenario() {
        // ---- Part B: window terrain ----
        step("rig windows mapped on screen", timeout: 6, action: {
            self.winA = self.makeWindow(CGRect(x: 200, y: 150, width: 700, height: 300), title: "Rig A")
            self.winB = self.makeWindow(CGRect(x: 350, y: 560, width: 500, height: 260), title: "Rig B")
        }, until: { self.mapped(self.winA) && self.mapped(self.winB) })

        step("spawned onto B", timeout: 6, action: { self.engine.start() },
             until: { self.engine.stateName == "standing" && self.engine.currentWindowID == self.id(of: self.winB) })
        assertNow("sprites loaded (18 frames)") { self.engine.spriteFrameCount >= 17 }
        assertNow("perched on B's title bar") { self.onTop(of: self.winB) }
        assertNow("pet visible") { self.stage.isPetVisible }
        assertNow("sprite feet on anchor") { self.spriteOnAnchor() }

        step("falling after B closed", timeout: 2, action: {
            self.xMark = self.engine.anchor.x
            self.winB.close()
        }, until: { self.engine.stateName == "falling" })
        step("landed on A", timeout: 4,
             until: { self.engine.stateName == "standing" && self.engine.currentWindowID == self.id(of: self.winA) })
        assertNow("standing on A's title bar") { self.onTop(of: self.winA) }
        assertNow("fell straight down") { abs(self.engine.anchor.x - self.xMark) <= 8 }

        step("walking after debugWalk", timeout: 2, action: {
            self.xMark = self.engine.anchor.x
            self.engine.debugWalk(dir: 1, duration: 1.0)
        }, until: { self.engine.stateName == "walking" })
        step("standing after walk", timeout: 4,
             until: { self.engine.stateName == "standing" })
        assertNow("walk distance ≈ 55pt") { abs((self.engine.anchor.x - self.xMark) - 55) <= 16 }
        assertNow("stayed on A through the walk") { self.onTop(of: self.winA) }

        step("D mapped", timeout: 4, action: {
            self.winD = self.makeWindow(CGRect(x: 300, y: 640, width: 420, height: 240), title: "Rig D")
        }, until: { self.mapped(self.winD) })
        step("leaping toward D", timeout: 2,
             action: { self.engine.debugLeap(toWindowID: self.id(of: self.winD)) },
             until: { self.engine.stateName == "leaping" })
        step("landed on D", timeout: 4,
             until: { self.engine.stateName == "standing" && self.engine.currentWindowID == self.id(of: self.winD) })
        assertNow("perched on D") { self.onTop(of: self.winD) }

        step("evicted from D after occlusion", timeout: 4, action: {
            self.winE = self.makeWindow(CGRect(x: 250, y: 700, width: 560, height: 240), title: "Rig E")
        }, until: { self.engine.currentWindowID != self.id(of: self.winD) })
        step("fell back to A", timeout: 5,
             until: { self.engine.stateName == "standing" && self.engine.currentWindowID == self.id(of: self.winA) })

        step("rode A during drag (Δx = 220pt)", timeout: 5, action: {
            self.xMark = self.engine.anchor.x
            self.moveDone = false
            let start = self.winA.frame.origin
            let t0 = Date()
            // A main-queue dispatch timer rather than Timer: its handler keeps
            // main-actor isolation, so the window and the done flag are only
            // ever touched from one place.
            let glide = DispatchSource.makeTimerSource(queue: .main)
            glide.schedule(deadline: .now(), repeating: 1.0 / 60.0)
            glide.setEventHandler {
                let p = min(1, Date().timeIntervalSince(t0) / 1.0)
                self.winA.setFrameOrigin(CGPoint(x: start.x + 220 * p, y: start.y))
                if p >= 1 {
                    glide.cancel()
                    self.moveDone = true
                }
            }
            glide.resume()
            self.dragGlide = glide
        }, until: { self.moveDone && abs((self.engine.anchor.x - self.xMark) - 220) <= 3 })
        assertNow("still on A after the ride") { self.onTop(of: self.winA) }
        assertNow("sprite feet on anchor (post-ride)") { self.spriteOnAnchor() }

        // ---- Part A: floor, hole, climb, grab/throw ----
        step("standing on the floor", timeout: 5, action: {
            self.winA.close(); self.winD.close(); self.winE.close()
            self.engine.debugTeleportToFloor()
        }, until: {
            self.engine.stateName == "standing" && self.engine.currentWindowID == nil
                && abs(self.engine.anchor.y - (NSScreen.screens.first?.visibleFrame.minY ?? 0)) <= 1.5
        })
        assertNow("sprite feet on anchor (floor)") { self.spriteOnAnchor() }
        step(action: {
            let c = self.stage.spriteGlobalRect
            self.check("hole opens over creature pixels",
                       self.engine.debugHole(at: CGPoint(x: c.midX, y: c.midY + 8)))
            self.check("panel accepts events while hole open", self.stage.holeIsOpen)
            self.check("no hole between the feet",
                       !self.engine.debugHole(at: CGPoint(x: c.midX, y: c.minY + 3)))
            self.check("no hole in empty air",
                       !self.engine.debugHole(at: CGPoint(x: c.midX + 300, y: c.midY + 200)))
            self.check("panel click-through when hole closed", !self.stage.holeIsOpen)
        })

        step("climbing the left wall", timeout: 3, action: {
            self.climbY0 = self.engine.anchor.y
            let floor = NSScreen.screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1512, height: 950)
            self.engine.debugClimb(side: -1, targetY: floor.minY + 140)
        }, until: { self.engine.stateName == "climbing" })
        step("moved up the wall, rotated", timeout: 4, until: {
            self.engine.anchor.y > self.climbY0 + 18 && self.engine.currentRotationDegrees == -90
                && abs(self.engine.anchor.x - ((NSScreen.screens.first?.visibleFrame.minX ?? 0) + 4)) <= 1.5
        })
        step("back on the floor after wall leap", timeout: 8, until: {
            self.engine.stateName == "standing" && self.engine.currentWindowID == nil
                && self.engine.currentRotationDegrees == 0
        })

        step("grabbed", timeout: 2, action: {
            let c = self.stage.spriteGlobalRect
            self.engine.debugGrab(at: CGPoint(x: c.midX, y: c.midY))
        }, until: { self.engine.stateName == "grabbed" })
        assertNow("link paused while held") { !self.engine.displayLinkActive }
        step("followed the drag", timeout: 2, action: {
            self.engine.debugDrag(to: CGPoint(x: 500, y: 500))
            self.engine.debugDrag(to: CGPoint(x: 560, y: 540))
        }, until: { abs(self.engine.anchor.x - 560) <= 1.5 })
        step("thrown → ballistic", timeout: 2,
             action: { self.engine.debugRelease(velocity: CGPoint(x: 350, y: 450)) },
             until: { self.engine.stateName == "leaping" || self.engine.stateName == "falling" })
        step("landed after throw, carried right", timeout: 5, until: {
            self.engine.stateName == "standing" && self.engine.anchor.x > 600
        })

        // ---- Part C: Tier-2 AX events (cross-process) ----
        step(action: {
            guard AXPermission.trusted else {
                print("rig: NOTE — Accessibility not granted; Tier-2 live phases skipped")
                return
            }
            let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            let p = Process()
            p.executableURL = exe
            p.arguments = ["--helper-window"]
            try? p.run()
            self.moveHelper = p
        })
        step("tier2 attached to helper", timeout: 4, action: {
            if let pid = self.moveHelper?.processIdentifier {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.engine.debugTier2Attach(pid: pid_t(pid))
                }
            }
        }, until: {
            guard let pid = self.moveHelper?.processIdentifier else { return true } // skipped
            let st = self.engine.debugTier2State(pid: pid_t(pid))
            if st.attached { self.axEventsAtProbe = st.eventsSeen }
            return st.attached && !st.degraded
        })
        step("AX window-moved events received", timeout: 6, until: {
            guard let pid = self.moveHelper?.processIdentifier else { return true }
            return self.engine.debugTier2State(pid: pid_t(pid)).eventsSeen - self.axEventsAtProbe >= 3
        })
        assertNow("engine wake pipeline fired") {
            self.moveHelper == nil || self.engine.debugTier2WakeCount >= 1
        }

        // ---- Part D: behavior brain ----
        step("S and G mapped", timeout: 6, action: {
            self.winS = self.makeWindow(CGRect(x: 650, y: 350, width: 300, height: 60), title: "Rig S")
            self.winG = self.makeWindow(CGRect(x: 700, y: 640, width: 420, height: 100), title: "Rig G")
        }, until: { self.mapped(self.winS) && self.mapped(self.winG) })
        step("back on the floor for travel", timeout: 5,
             action: { self.engine.debugTeleportToFloor() },
             until: { self.engine.stateName == "standing" && self.engine.currentWindowID == nil })
        step("travel planned multi-step", timeout: 2, action: {
            self.engine.debugResetBrain(seed: 99, needs: NeedsVector(
                energy: 0.95, curiosity: 1.0, attention: 1.0, boredom: 0.9))
            self.engine.debugTravel(to: self.id(of: self.winG))
        }, until: { self.engine.debugLastPlanCount >= 2 && self.engine.debugTravelActive })
        step("arrived on G via planned route", timeout: 10,
             until: { self.engine.currentWindowID == self.id(of: self.winG) && self.engine.stateName == "standing" })
        assertNow("perched on G") { self.onTop(of: self.winG) }

        step("exhaustion → sleeping", timeout: 3, action: {
            self.engine.debugSetNeeds(NeedsVector(energy: 0.05, curiosity: 0.2,
                                                  attention: 0.2, boredom: 0.2))
            self.engine.debugDecideNow()
        }, until: { self.engine.isSleeping && self.engine.debugAnimKind == "sleep" })
        step("link paused while sleeping", timeout: 3,
             until: { !self.engine.displayLinkActive })
        step("recharged → awake", timeout: 3, action: {
            self.engine.debugSetNeeds(NeedsVector(energy: 0.95))
            self.engine.debugDecideNow()
        }, until: { !self.engine.isSleeping && self.engine.debugAnimKind != "sleep" })

        // ---- Part E: reactions ----
        step("immersion → retreated to floor and napping", timeout: 16, action: {
            let f = NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 1512, height: 982)
            self.winI = self.makeWindow(f, title: "Rig I (fullscreen)")
        }, until: {
            self.engine.immersionActive && self.engine.isSleeping
                && self.engine.currentWindowID == nil
        })
        assertNow("immersion status") { self.lastStatus.contains("Shh") }
        step("immersion ended → awake", timeout: 6,
             action: { self.winI.close() },
             until: { !self.engine.immersionActive && !self.engine.isSleeping })

        step("celebration hop + status", timeout: 3, action: {
            self.engine.debugSimulateAppQuit(bundleID: "com.hnc.Discord", name: "Discord")
        }, until: { self.lastStatus.contains("🎉") })
        step("celebration finished", timeout: 5,
             until: { self.engine.stateName == "standing" })

        step("greeting satisfied attention", timeout: 3, action: {
            self.engine.debugSimulateUserReturn(awaySeconds: 200)
        }, until: {
            self.lastStatus.contains("Welcome back") && self.engine.debugNeeds.attention <= 0.01
        })
        step("settled after greeting", timeout: 5,
             until: { self.engine.stateName == "standing" })

        step(action: {
            guard AXPermission.trusted else { return }
            let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            let p = Process()
            p.executableURL = exe
            p.arguments = ["--helper-title-spam"]
            try? p.run()
            self.spamHelper = p
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.engine.debugTier2Attach(pid: pid_t(p.processIdentifier))
            }
        })
        step("title-change rate sensed", timeout: 8, until: {
            guard let pid = self.spamHelper?.processIdentifier else { return true }
            return self.engine.debugTitleRate(pid: pid_t(pid)) >= 0.8
        })

        step("back on G for agitation", timeout: 10,
             action: { self.engine.debugTravel(to: self.id(of: self.winG)) },
             until: { self.engine.currentWindowID == self.id(of: self.winG) && self.engine.stateName == "standing" })
        step("agitated pacing on the hot window", timeout: 5, action: {
            self.engine.debugBumpTitleRate(pid: ProcessInfo.processInfo.processIdentifier, hits: 6)
        }, until: { self.engine.stateName == "walking" && self.lastStatus.contains("👀") })

        // Ceiling hang: a window whose top edge is too close to the screen
        // top for the body to fit upright → he flips and dangles.
        step("hanging upside down at a screen-top edge", timeout: 8, action: {
            let vf = NSScreen.screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1512, height: 944)
            let top = min(vf.maxY, (NSScreen.screens.first?.frame.maxY ?? 982)
                          - (NSScreen.screens.first?.safeAreaInsets.top ?? 38))
            self.winH = self.makeWindow(CGRect(x: 340, y: top - 170, width: 420, height: 160),
                                        title: "Rig H")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.engine.debugTravel(to: self.id(of: self.winH))
            }
        }, until: {
            self.engine.currentWindowID == self.id(of: self.winH)
                && self.engine.currentRotationDegrees == 180
        })
        step("upright again after the high window closes", timeout: 8, action: {
            self.winH.close()
        }, until: {
            self.engine.stateName == "standing"
                && self.engine.currentWindowID != self.id(of: self.winH)
                && self.engine.currentRotationDegrees == 0
        })

        // ---- Part F: Shimeji pack import + live hot-swap ----
        step("synthetic shimeji pack imported", timeout: 5, action: {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("rig-shimeji-\(ProcessInfo.processInfo.processIdentifier)")
            let fm = FileManager.default
            try? fm.createDirectory(at: dir.appendingPathComponent("conf"),
                                    withIntermediateDirectories: true)
            try? fm.createDirectory(at: dir.appendingPathComponent("img"),
                                    withIntermediateDirectories: true)
            let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <Mascot xmlns="http://www.group-finity.com/Mascot">
              <ActionList>
                <Action Name="Stand" Type="Stay" BorderType="Floor">
                  <Animation><Pose Image="/shime1.png" ImageAnchor="64,128" Velocity="0,0" Duration="250" /></Animation>
                </Action>
                <Action Name="Walk" Type="Move" BorderType="Floor">
                  <Animation>
                    <Pose Image="/shime1.png" Velocity="-2,0" Duration="6" />
                    <Pose Image="/shime2.png" Velocity="-2,0" Duration="6" />
                    <Pose Image="/shime3.png" Velocity="-2,0" Duration="6" />
                  </Animation>
                </Action>
                <Action Name="Falling" Type="Embedded" Class="com.group_finity.mascot.action.Fall">
                  <Animation><Pose Image="/shime4.png" Duration="4" /></Animation>
                </Action>
                <Action Name="Bouncing" Type="Embedded" Class="com.group_finity.mascot.action.Bouncing">
                  <Animation>
                    <Pose Image="/shime18.png" Duration="2" />
                    <Pose Image="/shime19.png" Duration="2" />
                  </Animation>
                </Action>
                <Action Name="Pinched" Type="Embedded" Class="com.group_finity.mascot.action.Dragged">
                  <Animation><Pose Image="/shime5.png" Duration="2" /></Animation>
                </Action>
              </ActionList>
            </Mascot>
            """
            try? xml.data(using: .utf8)?.write(to: dir.appendingPathComponent("conf/actions.xml"))
            for (name, hue) in [("shime1", 0.05), ("shime2", 0.30), ("shime3", 0.55),
                                ("shime4", 0.80), ("shime18", 0.12), ("shime19", 0.62),
                                ("shime5", 0.40)] {
                let img = NSImage(size: NSSize(width: 128, height: 128))
                img.lockFocus()
                NSColor(calibratedHue: hue, saturation: 0.7, brightness: 0.9, alpha: 1).setFill()
                NSBezierPath(ovalIn: CGRect(x: 6, y: 6, width: 116, height: 116)).fill()
                img.unlockFocus()
                if let tiff = img.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: dir.appendingPathComponent("img/\(name).png"))
                }
            }
            self.shimejiResult = ShimejiImporter.load(packAt: dir)
        }, until: { self.shimejiResult != nil })
        step(action: {
            guard let (set, name) = self.shimejiResult else { return }
            self.check("pack name from directory", name.hasPrefix("rig-shimeji"))
            self.check("walk has 3 frames", set.anims[.walk]?.frames.count == 3)
            self.check("land (Bouncing) has 2 frames", set.anims[.land]?.frames.count == 2)
            self.check("jump mapped from Pinched", set.anims[.jump]?.frames.count == 1)
            self.check("sleep fell back to idle", set.anims[.sleep]?.frames.count == 1)
            self.check("imported art faces left", set.facesLeft)
            let d = set.anims[.walk]?.durations.first ?? 0
            self.check("tick durations mapped (6 ticks → 0.24s)", abs(d - 0.24) < 0.001)
        })
        step("hot-swapped character, pet alive", timeout: 3, action: {
            if let (set, _) = self.shimejiResult {
                self.engine.applySprites(set, name: "rig-shimeji")
            }
        }, until: {
            self.stage.isPetVisible && self.spriteOnAnchor()
                && self.engine.spriteFrameCount == 10
        })
        step(action: {
            let c = self.stage.spriteGlobalRect
            self.check("hole works on imported art (center)",
                       self.engine.debugHole(at: CGPoint(x: c.midX, y: c.midY)))
            self.check("hole shut at imported art corner",
                       !self.engine.debugHole(at: CGPoint(x: c.minX + 2, y: c.minY + 2)))
        })
        step("swapped back to Rusty", timeout: 3, action: {
            self.engine.applySprites(SpriteSet(), name: "Rusty")
        }, until: { self.engine.spriteFrameCount >= 17 && self.stage.isPetVisible })

        step("speech bubble shows", timeout: 2, action: {
            self.engine.debugSay("Beep! Bubble check.", hold: 1.2)
        }, until: { self.stage.bubbleVisible && self.stage.debugBubbleText.contains("Beep") })
        step("speech bubble auto-hides", timeout: 4,
             until: { !self.stage.bubbleVisible })

        step("speech bubble auto-hides after assistant checks", timeout: 4,
             until: { !self.stage.bubbleVisible })

        runAssistantChecks()

        step("quiesced (link paused, agitation decayed)", timeout: 14, until: {
            self.engine.stateName == "standing" && !self.engine.displayLinkActive
        })
    }

    /// Part G: the assistant surface. Everything here runs offline against
    /// the real objects (no API calls), covering the pieces that used to have
    /// unit tests but no end-to-end proof inside a running app: the panel's
    /// lifecycle, the gating that protects destructive verbs, memory
    /// persistence, and the streaming accumulator feeding real rows.
    private func runAssistantChecks() {
        let bar = CommandBar()

        step("assistant panel opens and closes", timeout: 3, action: {
            bar.show()
        }, until: { bar.isVisible })
        step(action: {
            bar.dismiss()
            self.check("panel dismissed", !bar.isVisible)
        })

        step("voice transcript lands in the panel", timeout: 3, action: {
            bar.beginVoice()
            bar.voiceTranscript("open saf")
            bar.voiceTranscript("open safari")
        }, until: { bar.isVisible && bar.debugTranscript.contains("open safari") })

        step("empty capture ends quietly, no error row", timeout: 3, action: {
            bar.endVoiceQuietly()
        }, until: { !bar.debugTranscript.contains("open safari") })

        step(action: {
            bar.dismiss()
            // Destructive verbs must never execute straight from a tool call.
            self.check("quit is gated",
                       AssistantRouting.action(verb: "quit", argument: "Finder")!.needsConfirmation)
            self.check("admin is gated",
                       AssistantRouting.action(verb: "run_admin", argument: "whoami")!.needsConfirmation)
            self.check("destructive script is gated",
                       AssistantRouting.action(verb: "run_applescript",
                                               argument: "do shell script \"rm -rf x\"")!.needsConfirmation)
            self.check("harmless script is not gated",
                       !AssistantRouting.action(verb: "run_applescript",
                                                argument: "display notification \"hi\"")!.needsConfirmation)
            self.check("bad url refused",
                       AssistantRouting.action(verb: "open_url", argument: "javascript:alert(1)") == nil)
        })

        step(action: {
            // Memory has to survive a real write and read from disk.
            let original = PetMemoryStore.load()
            var probe = PetMemory()
            probe.remember("rig probe fact about tin robots")
            PetMemoryStore.save(probe)
            let reloaded = PetMemoryStore.load()
            self.check("memory persists to disk",
                       reloaded.facts.contains { $0.text.contains("rig probe fact") })
            self.check("memory reaches the prompt",
                       reloaded.promptBlock.contains("rig probe fact"))
            PetMemoryStore.save(original)  // leave the user's memory untouched
            self.check("rig restored real memory",
                       PetMemoryStore.load().facts.count == original.facts.count)
        })

        step(action: {
            // The streaming path assembles a usable turn from raw SSE lines.
            let acc = StreamAccumulator()
            var streamed = ""
            acc.onTextDelta = { streamed += $0 }
            acc.consume(line: #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#)
            acc.consume(line: #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"All set."}}"#)
            acc.consume(line: #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#)
            self.check("stream emitted deltas live", streamed == "All set.")
            if case .turn(let turn) = acc.finish() {
                self.check("stream assembled a finished turn", turn.text == "All set.")
            } else {
                self.check("stream assembled a finished turn", false)
            }
        })

        step(action: {
            let binding = HotKeyStore.current
            self.check("summon shortcut is valid", binding.isValid)
            self.check("shortcut has a readable name", !binding.displayName.isEmpty)
        })

        // The awareness verbs, against the real window server. The unit tests
        // cover the policy; these prove the bridge to AppKit is wired.
        step(action: {
            let snapshots = WindowInventory.snapshots()
            // The rig's own windows are up by now, so this is never empty, and
            // it must never contain our own overlay.
            self.check("sees the real windows", !snapshots.isEmpty)
            self.check("never lists its own overlay",
                       !snapshots.contains { $0.app == "WindowPet" })
            // The rig's own props are ordinary windows, so they must show up:
            // an inventory that quietly saw nothing would pass the check above
            // for the wrong reason.
            self.check("sees the rig's own prop windows",
                       snapshots.contains { $0.frame.width >= 120 })
            self.check("every window has a real app name",
                       snapshots.allSatisfy { !$0.app.isEmpty })
            let report = WindowInventory.report()
            self.check("window report is a readable sentence",
                       report.contains("window") && !report.contains("Optional"))
        })

        step(action: {
            // A layout captured from the screen as it stands must round-trip
            // through disk unchanged.
            let captured = WindowArranger.capture()
            self.check("captured a layout from the real screen", !captured.isEmpty)
            let existing = LayoutStore.load()
            LayoutStore.store(WindowLayout(name: "rig probe layout", placements: captured))
            let reloaded = LayoutStore.named("rig probe layout")
            self.check("layout persists to disk", reloaded?.placements == captured)
            self.check("layout found by partial name", LayoutStore.named("rig probe") != nil)
            LayoutStore.save(existing)  // leave the user's layouts untouched
            self.check("rig restored real layouts", LayoutStore.load().count == existing.count)
        })

        step(action: {
            // The clipboard history records, filters and recalls, using the
            // real pasteboard. Whatever was on it is put back afterwards.
            let clipboard = AssistantExecutor.shared.clipboard
            let restore = NSPasteboard.general.string(forType: .string)
            clipboard.clear()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("rig probe clip about tin robots", forType: .string)
            self.pasteboardSettled = false
            // The poller runs twice a second; give it a beat to notice.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.pasteboardSettled = true }
            self.clipboardRestore = restore
        })
        step("clipboard history recorded a real copy", timeout: 4,
             until: { self.pasteboardSettled
                 && AssistantExecutor.shared.clipboard.clips.contains {
                     $0.contains("rig probe clip") } })

        step(action: {
            let clipboard = AssistantExecutor.shared.clipboard
            // A key copied out of a password manager must never be kept.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("sk-ant-api03-rigprobenotasecretreally", forType: .string)
            self.pasteboardSettled = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.pasteboardSettled = true }
            _ = clipboard
        })
        step("secret-shaped clip was never stored", timeout: 4,
             until: { self.pasteboardSettled
                 && !AssistantExecutor.shared.clipboard.clips.contains { $0.hasPrefix("sk-ant") } })

        step(action: {
            let clipboard = AssistantExecutor.shared.clipboard
            let recalled = clipboard.recall("tin robots")
            self.check("recalled a clip back onto the clipboard", recalled.ok)
            self.check("the clipboard actually holds it",
                       NSPasteboard.general.string(forType: .string)?.contains("tin robots") == true)
            clipboard.clear()
            NSPasteboard.general.clearContents()
            if let restore = self.clipboardRestore {
                NSPasteboard.general.setString(restore, forType: .string)
            }
            self.check("rig left the clipboard as it found it",
                       NSPasteboard.general.string(forType: .string) == self.clipboardRestore)
        })

        step(action: {
            // A watch on a running app: set, listed, then cancelled. Firing is
            // covered by the WatchPolicy unit tests; this proves the registry
            // and the app lookup work against real processes.
            let watches = AssistantExecutor.shared.watches
            watches.clear()
            let started = watches.watch(app: "Finder", reason: "the rig",
                                        now: CACurrentMediaTime())
            self.check("watch started on a running app", started.hasPrefix("Watching"))
            self.check("watch appears in the listing", watches.listing().contains("Finder"))
            let missing = watches.watch(app: "An App That Is Not Running",
                                        reason: "", now: CACurrentMediaTime())
            self.check("watching something absent is refused",
                       !missing.hasPrefix("Watching"))
            self.check("stopping a watch reports it",
                       watches.stop(matching: "Finder").contains("Stopped"))
            self.check("nothing left watching", watches.active.isEmpty)
        })

        step(action: {
            // Standing asks survive a round trip through disk, and a firing
            // slot is decided by the same policy the unit tests cover.
            let runner = AssistantExecutor.shared.schedules
            let existing = ScheduleStore.load()
            let set = runner.add("every weekday at 9: rig probe request")
            self.check("standing ask accepted", set.hasPrefix("Set:"))
            self.check("standing ask is listed", runner.listing().contains("rig probe request"))
            self.check("standing ask persists to disk",
                       ScheduleStore.load().contains { $0.request == "rig probe request" })
            self.check("nonsense standing ask refused",
                       !runner.add("sometime maybe: do a thing").hasPrefix("Set:"))
            self.check("standing ask can be dropped",
                       runner.remove(matching: "rig probe").contains("Dropped"))
            ScheduleStore.save(existing)  // leave the user's schedule untouched
            self.check("rig restored real schedules",
                       ScheduleStore.load().count == existing.count)
        })

        step(action: {
            // A trick records only what actually ran, refuses to record the
            // admin verb, and survives a round trip through disk.
            let existing = TrickStore.load()
            AssistantExecutor.shared.recording = []
            _ = AssistantExecutor.executeChecked(.volume(.mute))
            _ = AssistantExecutor.executeChecked(.volume(.unmute))
            // Gated verbs are refused by the recorder, not silently kept.
            AssistantExecutor.noteForRecording("run_admin", "whoami")
            let steps = AssistantExecutor.shared.recording ?? []
            self.check("recording captured the steps that ran", steps.count == 2)
            self.check("recording refused the admin verb",
                       !steps.contains { $0.verb == "run_admin" })
            let saved = AssistantExecutor.executeChecked(.saveTrick("rig probe trick"))
            self.check("trick saved", saved.ok)
            self.check("trick persists to disk", TrickStore.named("rig probe trick") != nil)
            let ran = AssistantExecutor.executeChecked(.runTrick("rig probe trick"))
            self.check("trick replays its steps", ran.ok)
            self.check("unknown trick is refused",
                       !AssistantExecutor.executeChecked(.runTrick("no such trick")).ok)
            TrickStore.save(existing)  // leave the user's tricks untouched
            self.check("rig restored real tricks", TrickStore.load().count == existing.count)
        })

        step(action: {
            // Undo puts a window back where it actually was, at the size it
            // actually was, not at the nearest tidy slot.
            AssistantExecutor.shared.arrangements = ArrangementHistory()
            let nothing = AssistantExecutor.executeChecked(.undoArrangement)
            self.check("undo with nothing to undo says so",
                       nothing.result == ArrangementHistory.nothingToUndo())
            let before = self.winA.frame
            _ = AssistantExecutor.executeChecked(
                .placeWindows([WindowPlacement(app: "WindowPet", slot: .left)]))
            // Our own app is not arrangeable, so nothing moved and nothing was
            // recorded: an arrangement that moved nothing must not become an
            // undo step that silently does nothing.
            self.check("an arrangement that moved nothing is not an undo step",
                       !AssistantExecutor.shared.arrangements.canUndo)
            self.check("the rig's window was left alone", self.winA.frame == before)
        })

        step(action: {
            // The watch lamp is the promise made visible.
            self.stage.setWatching(true)
            self.check("watch lamp lights", self.stage.watchLampVisible)
            self.stage.setWatching(false)
            self.check("watch lamp goes out", !self.stage.watchLampVisible)
        })

        step(action: {
            // Scoped memory reaches the prompt only in its own app.
            let original = PetMemoryStore.load()
            var probe = PetMemory()
            probe.remember("rig probe global fact")
            probe.remember("rig probe scoped fact", scope: "Finder")
            PetMemoryStore.save(probe)
            let reloaded = PetMemoryStore.load()
            self.check("scope survives a write and read",
                       reloaded.facts.contains { $0.scope == "Finder" })
            self.check("scoped fact reaches the prompt in its app",
                       reloaded.promptBlock(inApp: "Finder").contains("rig probe scoped"))
            self.check("scoped fact stays out of other apps",
                       !reloaded.promptBlock(inApp: "Safari").contains("rig probe scoped"))
            self.check("global fact reaches every app",
                       reloaded.promptBlock(inApp: "Safari").contains("rig probe global"))
            PetMemoryStore.save(original)
            self.check("rig restored real memory again",
                       PetMemoryStore.load().facts.count == original.facts.count)
        })

        step(action: {
            // Reading a real file off disk, and refusing one that is not there.
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("rig-probe-\(UUID().uuidString).md")
            try? Data("# Rig probe\n\nA line about tin robots.".utf8).write(to: url)
            switch FileReader.read(path: url.path) {
            case .success(let reading):
                self.check("read a text file off disk",
                           reading.text?.contains("tin robots") == true)
                self.check("named the file it read", reading.name == url.lastPathComponent)
            case .failure:
                self.check("read a text file off disk", false)
                self.check("named the file it read", false)
            }
            try? FileManager.default.removeItem(at: url)
            switch FileReader.read(path: url.path) {
            case .success: self.check("a missing file is refused, not invented", false)
            case .failure(let refusal):
                self.check("a missing file is refused, not invented",
                           refusal.message.contains("no file"))
            }
        })
    }

    /// Scratch state for the clipboard steps, which have to wait out a poll.
    private var pasteboardSettled = false
    private var clipboardRestore: String?

    private func finish() {
        if failures.isEmpty {
            print("RIG PASS \(checks)/\(checks)")
            exit(0)
        } else {
            print("RIG FAIL \(checks - failures.count)/\(checks) — failed: \(failures.joined(separator: "; "))")
            exit(1)
        }
    }
}
