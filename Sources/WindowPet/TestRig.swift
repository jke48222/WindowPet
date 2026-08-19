import AppKit
import WindowPetCore

/// Autonomous end-to-end verification, zero permissions. Two parts:
///
/// Part A (always runs): window-independent physics on real screen terrain —
/// floor landing, sprite/anchor coherence, wall climbing with rotation,
/// grab/drag/throw, the alpha-mask hole, clock quiescence.
///
/// Part B (canary-gated): window terrain — spawn/close/fall/walk/leap/
/// occlusion/riding, using titled windows in THIS process. Some environments
/// (fullscreen video, Focus contexts) suppress background titled windows;
/// the canary detects that and Part B is skipped loudly instead of failing
/// misleadingly.
final class TestRig {

    private let engine: PetEngine
    private let stage: OverlayStage
    private var winA: NSWindow!
    private var winB: NSWindow!
    private var winD: NSWindow!
    private var winE: NSWindow!
    private var moveTimer: Timer?

    private var checks = 0
    private var failures: [String] = []
    private var skippedWindowPhases = false
    private var skippedAXPhases = false
    private var helper: Process?
    private var axEventsAtProbe = 0
    private var xBeforeClose: CGFloat = 0
    private var xBeforeWalk: CGFloat = 0
    private var anchorBeforeRide: CGFloat = 0
    private var climbY0: CGFloat = 0

    init(engine: PetEngine, stage: OverlayStage) {
        self.engine = engine
        self.stage = stage
    }

    /// Borderless: environments that suppress background TITLED windows
    /// (fullscreen video, Focus contexts) still map borderless layer-0
    /// windows, so the rig's terrain works everywhere. Physics only reads
    /// frames — a title bar adds nothing. Tinted so a watching human can see
    /// the test happening.
    private func makeWindow(_ rect: CGRect, title: String) -> NSWindow {
        let w = NSWindow(contentRect: rect,
                         styleMask: [.borderless],
                         backing: .buffered, defer: false)
        w.title = title
        w.backgroundColor = NSColor.systemTeal.withAlphaComponent(0.35)
        w.isReleasedWhenClosed = false
        w.orderFrontRegardless()
        return w
    }

    func run() {
        engine.autonomy = false
        engine.allowOwnWindows = true
        engine.debugForcePID = ProcessInfo.processInfo.processIdentifier
        engine.world.restrictPID = ProcessInfo.processInfo.processIdentifier

        DispatchQueue.main.asyncAfter(deadline: .now() + 40) {
            print("RIG FAIL timeout — scenario did not complete")
            exit(2)
        }

        let canary = makeWindow(CGRect(x: 60, y: 60, width: 220, height: 140), title: "Rig canary")
        after(0.45) {
            let mapped = Tier1.window(byID: CGWindowID(exactly: canary.windowNumber) ?? 0)?.isOnScreen ?? false
            canary.close()
            if mapped {
                self.runWindowPhases() // Part B, then Part A
            } else {
                self.skippedWindowPhases = true
                print("rig: NOTE — window server suppresses background titled windows; running floor phases only")
                self.engine.start()
                self.after(0.2) { self.runFloorPhases(at: 0.4) }
            }
        }
    }

    // MARK: - Part B: window terrain

    private func runWindowPhases() {
        winA = makeWindow(CGRect(x: 200, y: 150, width: 700, height: 300), title: "Rig A")
        winB = makeWindow(CGRect(x: 350, y: 560, width: 500, height: 260), title: "Rig B")
        NSApp.activate()

        after(0.3) { self.engine.start() }

        after(1.7) {
            self.check("sprites loaded (\(self.engine.spriteFrameCount) frames)",
                       self.engine.spriteFrameCount >= 15)
            self.check("spawned onto B (state=\(self.engine.stateName))",
                       self.engine.stateName == "standing" && self.engine.currentWindowID == self.id(of: self.winB))
            self.checkAnchorOnTop(of: self.winB, "perched on B's title bar")
            self.check("pet visible", self.stage.isPetVisible)
            self.checkSpriteMatchesAnchor()
        }
        after(1.9) {
            self.xBeforeClose = self.engine.anchor.x
            self.winB.close()
        }
        after(2.08) {
            self.check("falling after B closed (state=\(self.engine.stateName))",
                       self.engine.stateName == "falling")
        }
        after(3.2) {
            self.check("landed on A (state=\(self.engine.stateName))",
                       self.engine.stateName == "standing" && self.engine.currentWindowID == self.id(of: self.winA))
            self.checkAnchorOnTop(of: self.winA, "standing on A's title bar")
            self.check("fell straight down",
                       abs(self.engine.anchor.x - self.xBeforeClose) <= 8)
        }
        after(3.4) {
            self.xBeforeWalk = self.engine.anchor.x
            self.engine.debugWalk(dir: 1, duration: 1.0)
        }
        after(3.9) {
            self.check("walking (state=\(self.engine.stateName))", self.engine.stateName == "walking")
            self.check("moved right while walking", self.engine.anchor.x > self.xBeforeWalk + 15)
            self.checkAnchorOnTop(of: self.winA, "stayed on the edge mid-walk")
        }
        after(4.7) {
            let dx = self.engine.anchor.x - self.xBeforeWalk
            self.check(String(format: "walk distance %.0fpt ≈ 55pt", dx), abs(dx - 55) <= 14)
            self.check("standing after walk", self.engine.stateName == "standing")
        }
        after(4.9) {
            self.winD = self.makeWindow(CGRect(x: 300, y: 640, width: 420, height: 240), title: "Rig D")
        }
        after(5.2) {
            self.engine.debugLeap(toWindowID: self.id(of: self.winD))
        }
        after(5.35) {
            self.check("leaping (state=\(self.engine.stateName))", self.engine.stateName == "leaping")
        }
        after(6.3) {
            self.check("landed on D (state=\(self.engine.stateName))",
                       self.engine.stateName == "standing" && self.engine.currentWindowID == self.id(of: self.winD))
            self.checkAnchorOnTop(of: self.winD, "perched on D after leap")
        }
        after(6.5) {
            self.winE = self.makeWindow(CGRect(x: 250, y: 700, width: 560, height: 240), title: "Rig E")
        }
        after(8.2) {
            self.check("evicted from D after occlusion", self.engine.currentWindowID != self.id(of: self.winD))
        }
        after(9.0) {
            self.check("fell back to A (state=\(self.engine.stateName))",
                       self.engine.stateName == "standing" && self.engine.currentWindowID == self.id(of: self.winA))
            self.checkAnchorOnTop(of: self.winA, "standing on A again")
        }
        after(9.2) {
            self.anchorBeforeRide = self.engine.anchor.x
            let start = self.winA.frame.origin
            let t0 = Date()
            self.moveTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                let p = min(1, Date().timeIntervalSince(t0) / 1.0)
                self.winA.setFrameOrigin(CGPoint(x: start.x + 220 * p, y: start.y))
                if p >= 1 { timer.invalidate() }
            }
        }
        after(10.7) {
            let dx = self.engine.anchor.x - self.anchorBeforeRide
            self.check(String(format: "rode A during drag (Δx %.0fpt ≈ 220pt)", dx), abs(dx - 220) <= 3)
            self.checkAnchorOnTop(of: self.winA, "still on A's title bar after ride")
            self.checkSpriteMatchesAnchor()
        }
        after(11.2) {
            self.winA.close()
            self.winD.close()
            self.winE.close()
            self.runFloorPhases(at: 11.6)
        }
    }

    // MARK: - Part A: floor, climbing, grabbing, the hole

    private func runFloorPhases(at t0: TimeInterval) {
        let base = t0

        after(base) { self.engine.debugTeleportToFloor() }
        after(base + 1.2) {
            let floorY = NSScreen.screens.first?.visibleFrame.minY ?? 0
            self.check("standing on the floor (state=\(self.engine.stateName))",
                       self.engine.stateName == "standing" && self.engine.currentWindowID == nil)
            self.check(String(format: "anchor on floor (y=%.0f, floor=%.0f)", self.engine.anchor.y, floorY),
                       abs(self.engine.anchor.y - floorY) <= 1.5)
            self.checkSpriteMatchesAnchor()
        }

        // The hole: over creature pixels vs gaps vs empty air.
        after(base + 1.4) {
            let c = self.stage.spriteGlobalRect
            let bodyPoint = CGPoint(x: c.midX, y: c.midY + 8)          // upper body: opaque
            let gapPoint = CGPoint(x: c.midX, y: c.minY + 3)           // between the feet: transparent
            let farPoint = CGPoint(x: c.midX + 300, y: c.midY + 200)   // empty air
            self.check("hole opens over creature pixels", self.engine.debugHole(at: bodyPoint))
            self.check("panel accepts events while hole open", self.stage.holeIsOpen)
            self.check("no hole between the feet (alpha gap)", !self.engine.debugHole(at: gapPoint))
            self.check("no hole in empty air", !self.engine.debugHole(at: farPoint))
            self.check("panel click-through when hole closed", !self.stage.holeIsOpen)
        }

        // Climbing: up the left wall, rotated, then leaps off and lands.
        // 140 pt at 45 pt/s ≈ 3.1 s of climb, then ~1 s of leap-off + landing.
        after(base + 1.7) {
            self.climbY0 = self.engine.anchor.y
            let floor = NSScreen.screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1512, height: 950)
            self.engine.debugClimb(side: -1, targetY: floor.minY + 140)
        }
        after(base + 2.6) {
            let floor = NSScreen.screens.first?.visibleFrame ?? .zero
            self.check("climbing (state=\(self.engine.stateName))", self.engine.stateName == "climbing")
            self.check(String(format: "on the left wall (x=%.0f)", self.engine.anchor.x),
                       abs(self.engine.anchor.x - floor.minX) <= 1.5)
            self.check("moved upward while climbing", self.engine.anchor.y > self.climbY0 + 25)
            self.check(String(format: "sprite rotated for wall (%.0f°)", self.engine.currentRotationDegrees),
                       self.engine.currentRotationDegrees == -90)
        }
        after(base + 7.4) {
            self.check("back on the floor after wall leap (state=\(self.engine.stateName))",
                       self.engine.stateName == "standing" && self.engine.currentWindowID == nil)
            self.check("sprite upright again", self.engine.currentRotationDegrees == 0)
        }

        // Grab, drag, throw.
        after(base + 7.6) {
            let c = self.stage.spriteGlobalRect
            self.engine.debugGrab(at: CGPoint(x: c.midX, y: c.midY))
        }
        after(base + 7.8) {
            self.check("grabbed (state=\(self.engine.stateName))", self.engine.stateName == "grabbed")
            self.check("link paused while held (event-driven)", !self.engine.displayLinkActive)
            self.engine.debugDrag(to: CGPoint(x: 500, y: 500))
            self.engine.debugDrag(to: CGPoint(x: 560, y: 540))
        }
        after(base + 8.0) {
            self.check(String(format: "followed the drag (x=%.0f)", self.engine.anchor.x),
                       abs(self.engine.anchor.x - 560) <= 1.5)
            self.engine.debugRelease(velocity: CGPoint(x: 350, y: 450))
        }
        after(base + 8.15) {
            self.check("thrown → ballistic (state=\(self.engine.stateName))",
                       self.engine.stateName == "leaping" || self.engine.stateName == "falling")
        }
        after(base + 10.4) {
            self.check("landed after throw (state=\(self.engine.stateName))",
                       self.engine.stateName == "standing")
            self.check("throw carried it right", self.engine.anchor.x > 600)
        }

        // Part C: Tier 2 — real cross-process AX events from a helper
        // process wiggling a titled window. (Titled is fine here: AX trees
        // don't care about on-screen suppression.)
        after(base + 10.8) {
            guard AXPermission.trusted else {
                self.skippedAXPhases = true
                print("rig: NOTE — Accessibility not granted; Tier-2 live phases skipped")
                return
            }
            let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            let proc = Process()
            proc.executableURL = exe
            proc.arguments = ["--helper-window"]
            do {
                try proc.run()
                self.helper = proc
            } catch {
                self.check("helper process launched", false)
            }
        }
        after(base + 11.5) {
            guard !self.skippedAXPhases, let pid = self.helper?.processIdentifier else { return }
            self.engine.debugTier2Attach(pid: pid_t(pid))
        }
        after(base + 12.0) {
            guard !self.skippedAXPhases, let pid = self.helper?.processIdentifier else { return }
            let st = self.engine.debugTier2State(pid: pid_t(pid))
            self.check("tier2 attached to helper", st.attached)
            self.check("helper not degraded at attach", !st.degraded)
            self.axEventsAtProbe = st.eventsSeen
        }
        after(base + 13.6) {
            guard !self.skippedAXPhases, let pid = self.helper?.processIdentifier else { return }
            let st = self.engine.debugTier2State(pid: pid_t(pid))
            let delta = st.eventsSeen - self.axEventsAtProbe
            self.check("AX window-moved events received (\(delta) in 1.6s)", delta >= 3)
            self.check("engine wake pipeline fired (\(self.engine.debugTier2WakeCount) wakes)",
                       self.engine.debugTier2WakeCount >= 1)
            self.helper?.terminate()
        }

        // Quiescence.
        after(base + 14.6) {
            self.check("display link paused after settling", !self.engine.displayLinkActive)
            self.finish()
        }
    }

    // MARK: - Checks

    private func id(of w: NSWindow) -> CGWindowID {
        CGWindowID(exactly: w.windowNumber) ?? 0
    }

    private func checkAnchorOnTop(of w: NSWindow, _ name: String) {
        let dy = abs(engine.anchor.y - w.frame.maxY)
        check(String(format: "%@ (Δy %.2fpt)", name, dy), dy <= 1.5)
        let onSpan = engine.anchor.x >= w.frame.minX - 2 && engine.anchor.x <= w.frame.maxX + 2
        check("\(name): within window span", onSpan)
    }

    /// The sprite's feet must sit exactly on the physics anchor.
    private func checkSpriteMatchesAnchor() {
        let rect = stage.spriteGlobalRect
        let feet = CGPoint(x: rect.midX, y: rect.minY + PetEngine.footOverlap)
        let d = hypot(feet.x - engine.anchor.x, feet.y - engine.anchor.y)
        check(String(format: "sprite feet on anchor (err %.2fpt)", d), d <= 1.0)
    }

    private func check(_ name: String, _ ok: Bool) {
        checks += 1
        print("rig: \(ok ? "PASS" : "FAIL") — \(name)")
        if !ok { failures.append(name) }
    }

    private func finish() {
        var notes: [String] = []
        if skippedWindowPhases { notes.append("window phases SKIPPED — suppressive environment") }
        if skippedAXPhases { notes.append("AX phases SKIPPED — no Accessibility") }
        let suffix = notes.isEmpty ? "" : " (\(notes.joined(separator: "; ")))"
        if failures.isEmpty {
            print("RIG PASS \(checks)/\(checks)\(suffix)")
            exit(0)
        } else {
            print("RIG FAIL \(checks - failures.count)/\(checks)\(suffix) — failed: \(failures.joined(separator: "; "))")
            exit(1)
        }
    }

    private func after(_ s: TimeInterval, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: block)
    }
}
