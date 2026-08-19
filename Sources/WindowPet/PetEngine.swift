import AppKit
import QuartzCore
import WindowPetCore

/// Stage-2 brain, complete: the pet is a physical creature in a world made of
/// window tops, screen floors, and screen-edge walls. Hardcoded FSM (GOBT is
/// S4):
///
///   falling ─lands→ landing ─→ standing ─timer→ walking ─edge→ climbing
///      ↑                          │ closed/minimized/occluded    │ leap-off
///      ├──────────────────────────┴ app switch → leaping ────────┘
///      └ mouse: grab anywhere → drag → release throws it (ballistic)
///
/// Clocking: CADisplayLink only while something moves — 60 fps falls/leaps/
/// drag-riding, 30 fps walks/climbs, paused when settled and during mouse
/// grabs (event-driven). Watch timer 10 Hz → 4 Hz deep idle; 0.5 s ambient
/// breathing. Energy budgets (<0.3% idle, <3% active) are the product
/// constraint.
final class PetEngine: NSObject {

    static let petSize = CGSize(width: 64, height: 64)
    static let footOverlap: CGFloat = 5
    static let climbSpeed: CGFloat = 45

    enum PlatformRef: Equatable {
        case window(CGWindowID)
        case floor
    }

    private enum State {
        case falling(vy: CGFloat)
        case leaping(vx: CGFloat, vy: CGFloat, endAt: TimeInterval)
        case landing(PlatformRef, offsetX: CGFloat, until: TimeInterval)
        case standing(PlatformRef, offsetX: CGFloat)
        case walking(PlatformRef, dir: CGFloat, until: TimeInterval)
        case climbing(side: CGFloat, targetY: CGFloat) // side: -1 left wall, +1 right
        case grabbed
        case suspended
    }

    // MARK: - Wiring

    private let stage: OverlayStage
    private let sprites = SpriteSet()
    let world = WorldModel()
    let tier2 = Tier2Manager()
    private let clock = AnimationClock()
    private let verbose: Bool
    private let startedAt = Date()

    var autonomy = true
    var allowOwnWindows = false
    var debugForcePID: pid_t?
    var onStatus: ((String) -> Void)?

    private var state: State = .falling(vy: 0)
    private(set) var anchor: CGPoint = .zero
    private(set) var currentPlatformPID: pid_t?
    private var lastWindowFrame: CGRect?
    private(set) var debugTier2WakeCount = 0

    private var link: CADisplayLink?
    private var lastStepAt: TimeInterval = 0
    private var lastMotionAt: TimeInterval = 0
    private var lastAuditAt: TimeInterval = 0
    private var lastStructuralNudgeAt: TimeInterval = 0
    private var watchTimer: DispatchSourceTimer?
    private var watchInterval: TimeInterval = -1
    private var ambientTimer: DispatchSourceTimer?
    private var nextBehaviorAt: TimeInterval = .infinity
    private var nextBlinkAt: TimeInterval = 0
    private var pendingActivation: (pid: pid_t, at: TimeInterval)?

    // Mouse interaction.
    private var mouseMonitors: [Any] = []
    private var grabStartedAt: TimeInterval = 0
    private var grabStartPoint: CGPoint = .zero
    private var preGrabStanding: (PlatformRef, CGFloat)?
    private var dragSamples: [(t: TimeInterval, p: CGPoint)] = []

    init(stage: OverlayStage, verbose: Bool) {
        self.stage = stage
        self.verbose = verbose
        super.init()
    }

    // MARK: - Debug/testing surface (used by TestRig and --diag)

    var stateName: String {
        switch state {
        case .falling: return "falling"
        case .leaping: return "leaping"
        case .landing: return "landing"
        case .standing: return "standing"
        case .walking: return "walking"
        case .climbing: return "climbing"
        case .grabbed: return "grabbed"
        case .suspended: return "suspended"
        }
    }
    var currentWindowID: CGWindowID? {
        switch state {
        case .standing(.window(let id), _), .walking(.window(let id), _, _),
             .landing(.window(let id), _, _):
            return id
        default:
            return nil
        }
    }
    var displayLinkActive: Bool { link.map { !$0.isPaused } ?? false }
    var spriteFrameCount: Int { sprites.loadedFrameCount }
    var currentRotationDegrees: CGFloat { stage.rotationDegrees }

    func debugWalk(dir: CGFloat, duration: TimeInterval) {
        guard case .standing(let ref, _) = state else { return }
        beginWalk(on: ref, dir: dir, duration: duration)
    }

    func debugLeap(toWindowID id: CGWindowID) {
        let now = CACurrentMediaTime()
        world.refresh(now: now)
        guard let win = world.cachedWindow(id: id) else {
            log("debugLeap: window \(id) not in world yet")
            return
        }
        leap(to: win, at: now)
    }

    func debugTeleportToFloor() {
        let now = CACurrentMediaTime()
        world.refresh(now: now)
        let f = world.floorPlatform(atX: anchor.x)
        anchor = CGPoint(x: (f.minX + f.maxX) / 2, y: f.topY + 140)
        enterFalling(vy: 0, at: now)
    }

    func debugClimb(side: CGFloat, targetY: CGFloat) {
        let now = CACurrentMediaTime()
        world.refresh(now: now)
        beginClimb(side: side, targetY: targetY, at: now)
    }

    func debugGrab(at p: CGPoint) { grab(at: p) }
    func debugDrag(to p: CGPoint) { drag(to: p) }
    func debugRelease(velocity v: CGPoint) {
        guard case .grabbed = state else { return }
        release(at: anchor, velocity: v)
    }
    func debugHole(at p: CGPoint) -> Bool {
        stage.updateHole(mouse: p, forceOpen: isGrabbed)
    }

    private var isGrabbed: Bool {
        if case .grabbed = state { return true }
        return false
    }

    func debugTier2Attach(pid: pid_t) { tier2.attach(to: pid) }
    func debugTier2State(pid: pid_t) -> (attached: Bool, eventsSeen: Int, degraded: Bool) {
        let st = tier2.states[pid]
        return (tier2.isAttached(pid), st?.eventsSeen ?? 0, st?.degraded ?? false)
    }

    // MARK: - Lifecycle

    func start() {
        let l = stage.displayLinkSourceView.displayLink(target: self, selector: #selector(stepLink(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 60, preferred: 60)
        l.add(to: .main, forMode: .common)
        l.isPaused = true
        link = l

        if tier2.enableIfTrusted() {
            log("tier 2 enabled (Accessibility trusted)")
        } else {
            log("tier 2 waiting for Accessibility — Tier 1 carries everything")
        }
        tier2.onActivity = { [weak self] pid, note in self?.tier2Activity(pid: pid, note: note) }

        stage.onGrab = { [weak self] p in self?.grab(at: p) }
        stage.onDrag = { [weak self] p in self?.drag(to: p) }
        stage.onRelease = { [weak self] p in self?.mouseReleased(at: p) }

        // The hole follows the cursor. Global monitor covers movement over
        // other apps (which is almost always — the panels are click-through);
        // the local one covers movement over our own open hole. Mouse-moved
        // monitors need no TCC permission, and the handler is a rect test.
        mouseMonitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.refreshHole()
        } as Any)
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] e in
            self?.refreshHole()
            return e
        }) {
            mouseMonitors.append(local)
        }

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                       object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            self.pendingActivation = (app.processIdentifier, CACurrentMediaTime())
        }
        ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                       object: nil, queue: .main) { [weak self] _ in
            self?.world.refresh(now: CACurrentMediaTime())
        }
        ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                       object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            self?.tier2.detach(pid: app.processIdentifier)
        }
        ws.addObserver(forName: NSWorkspace.willSleepNotification,
                       object: nil, queue: .main) { [weak self] _ in self?.suspend() }
        ws.addObserver(forName: NSWorkspace.didWakeNotification,
                       object: nil, queue: .main) { [weak self] _ in self?.resume() }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                        object: nil, queue: .main) { [weak self] _ in self?.suspend() }
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                        object: nil, queue: .main) { [weak self] _ in self?.resume() }

        startAmbientTimer()
        spawn()
        retuneWatchTimer(force: true)
    }

    private func spawn() {
        let now = CACurrentMediaTime()
        world.refresh(now: now)
        let screenTop = (NSScreen.screens.first?.frame.maxY ?? 982) - 10
        if let win = world.frontTopWindow(forcePID: debugForcePID, allowOwn: allowOwnWindows) {
            let perch = Geometry.initialPerch(windowWidth: win.frame.width,
                                              petWidth: Self.petSize.width)
            anchor = CGPoint(x: win.frame.minX + perch + Self.petSize.width / 2,
                             y: min(win.frame.maxY + 260, screenTop))
        } else {
            let f = world.floorPlatform(atX: NSScreen.screens.first?.frame.midX ?? 700)
            anchor = CGPoint(x: (f.minX + f.maxX) / 2, y: screenTop)
        }
        enterFalling(vy: 0, at: now)
        applyAnchor()
    }

    private func suspend() {
        guard stateName != "suspended" else { return }
        state = .suspended
        link?.isPaused = true
        watchTimer?.cancel(); watchTimer = nil; watchInterval = -1
        ambientTimer?.cancel(); ambientTimer = nil
        stage.hideAll()
        log("suspended (sleep/lock)")
    }

    private func resume() {
        guard case .suspended = state else { return }
        log("resumed — respawning")
        stage.showAll()
        startAmbientTimer()
        spawn()
        retuneWatchTimer(force: true)
    }

    // MARK: - Mouse interaction

    private func refreshHole() {
        stage.updateHole(mouse: NSEvent.mouseLocation, forceOpen: isGrabbed)
    }

    private func grab(at p: CGPoint) {
        guard stateName != "suspended" else { return }
        let now = CACurrentMediaTime()
        grabStartedAt = now
        grabStartPoint = p
        if case .standing(let ref, let off) = state {
            preGrabStanding = (ref, off)
        } else {
            preGrabStanding = nil
        }
        state = .grabbed
        stage.setPose(rotationDegrees: 0, facing: stage.facing)
        clock.play(.jump, from: sprites, at: now).map(stage.show) // dangle, pupils up
        setLinkPaused(true, now: now) // event-driven while held
        dragSamples = [(now, p)]
        stage.updateHole(mouse: p, forceOpen: true)
        status("Picked up!")
        log("→ grabbed at \(fmt(p))")
    }

    private func drag(to p: CGPoint) {
        guard case .grabbed = state else { return }
        let now = CACurrentMediaTime()
        dragSamples.append((now, p))
        if dragSamples.count > 8 { dragSamples.removeFirst() }
        // Hold the pet by its body: feet hang below the cursor.
        anchor = CGPoint(x: p.x, y: p.y - Self.petSize.height / 2 + Self.footOverlap)
        applyAnchor()
    }

    private func mouseReleased(at p: CGPoint) {
        guard case .grabbed = state else { return }
        let now = CACurrentMediaTime()
        let dt = now - grabStartedAt
        let moved = hypot(p.x - grabStartPoint.x, p.y - grabStartPoint.y)
        if dt < 0.28, moved < 5 {
            boop(at: now)
            return
        }
        // Throw velocity from the last ~90 ms of drag.
        var v = CGPoint.zero
        if let past = dragSamples.first(where: { now - $0.t <= 0.12 }) ?? dragSamples.first,
           now - past.t > 0.005 {
            let span = CGFloat(now - past.t)
            v = CGPoint(x: (p.x - past.p.x) / span, y: (p.y - past.p.y) / span)
        }
        release(at: p, velocity: v)
    }

    private func release(at p: CGPoint, velocity v: CGPoint) {
        let now = CACurrentMediaTime()
        let vx = min(max(v.x, -900), 900)
        let vy = min(max(v.y, -600), 1100)
        preGrabStanding = nil
        world.refresh(now: now)
        if abs(vx) < 40, abs(vy) < 40 {
            enterFalling(vy: 0, at: now)
        } else {
            state = .leaping(vx: vx, vy: vy, endAt: now + 3.0)
            stage.setPose(rotationDegrees: 0, facing: vx < 0 ? -1 : 1)
            clock.play(vy > 60 ? .jump : .fall, from: sprites, at: now).map(stage.show)
            lastMotionAt = now
            setLinkRate(preferred: 60)
            setLinkPaused(false, now: now)
            status("Wheee!")
            log("→ thrown v=(\(Int(vx)), \(Int(vy)))")
        }
        refreshHole()
    }

    /// A quick click, not a drag: a happy squash, then back to what it was
    /// doing. Petting must never relocate the creature.
    private func boop(at now: TimeInterval) {
        clock.play(.land, from: sprites, at: now).map(stage.show)
        if let (ref, off) = preGrabStanding {
            state = .standing(ref, offsetX: off)
            nextBehaviorAt = autonomy ? now + .random(in: 4...9) : nextBehaviorAt
        } else {
            enterFalling(vy: 0, at: now)
            return
        }
        status("🐾 boop")
        log("→ booped")
        refreshHole()
    }

    // MARK: - Tier 2 events

    /// An AX event arrived about `pid`. Never trusted for geometry — it only
    /// accelerates what the watch timer would notice within 100 ms anyway:
    /// instant motion wake for the ridden window, instant audit for anything
    /// structural (created/focused/minimized).
    private func tier2Activity(pid: pid_t, note: String) {
        debugTier2WakeCount += 1
        guard stateName != "suspended", !isGrabbed else { return }
        let now = CACurrentMediaTime()
        if case .standing(let ref, let offsetX) = state,
           case .window = ref,
           pid == currentPlatformPID {
            if note == kAXWindowMovedNotification || note == kAXWindowResizedNotification {
                if !displayLinkActive {
                    lastMotionAt = now
                    setLinkRate(preferred: 60)
                    setLinkPaused(false, now: now)
                    log("tier2 wake: \(note)")
                }
                follow(ref, offsetX: offsetX, now: now)
            } else if now - lastStructuralNudgeAt > 1.0 {
                // Busy Electron renderers can spam structural events; nudge
                // the audit forward at most once a second.
                lastStructuralNudgeAt = now
                lastAuditAt = 0
            }
        }
    }

    // MARK: - Transitions

    private func enterFalling(vy: CGFloat, at now: TimeInterval) {
        state = .falling(vy: vy)
        lastWindowFrame = nil
        world.refresh(now: now)
        stage.setPose(rotationDegrees: 0, facing: stage.facing)
        clock.play(.fall, from: sprites, at: now).map(stage.show)
        lastMotionAt = now
        setLinkRate(preferred: 60)
        setLinkPaused(false, now: now)
        status("Falling…")
        log("→ falling from \(fmt(anchor))")
    }

    private func leap(to win: WorldModel.WinAK, at now: TimeInterval) {
        switch state {
        case .standing, .walking: break
        default: return
        }
        if case .standing(.window(win.id), _) = state { return }
        let perch = Geometry.initialPerch(windowWidth: win.frame.width,
                                          petWidth: Self.petSize.width)
        let target = CGPoint(x: win.frame.minX + perch + Self.petSize.width / 2,
                             y: win.frame.maxY)
        let sol = PetPhysics.leapSolution(from: anchor, to: target)
        state = .leaping(vx: sol.vx, vy: sol.vy, endAt: now + Double(sol.duration))
        stage.setPose(rotationDegrees: 0, facing: sol.vx < 0 ? -1 : 1)
        clock.play(.jump, from: sprites, at: now).map(stage.show)
        lastMotionAt = now
        setLinkRate(preferred: 60)
        setLinkPaused(false, now: now)
        status("Leaping…")
        log("→ leaping to window \(win.id) target=\(fmt(target)) T=\(String(format: "%.2f", sol.duration))")
    }

    private func land(on platform: Platform, at now: TimeInterval) {
        anchor.y = platform.topY
        anchor.x = min(max(anchor.x, platform.minX + 4), platform.maxX - 4)
        let ref: PlatformRef
        let offset: CGFloat
        switch platform.kind {
        case .window(let id):
            ref = .window(id)
            offset = anchor.x - (world.cachedWindow(id: id)?.frame.minX ?? platform.minX)
        case .floor:
            ref = .floor
            offset = anchor.x - platform.minX
        }
        state = .landing(ref, offsetX: offset, until: now + 0.17)
        stage.setPose(rotationDegrees: 0, facing: stage.facing)
        clock.play(.land, from: sprites, at: now).map(stage.show)
        lastMotionAt = now
        applyAnchor()
        log("→ landed on \(ref) at \(fmt(anchor))")
    }

    private func enterStanding(_ ref: PlatformRef, offsetX: CGFloat, at now: TimeInterval) {
        state = .standing(ref, offsetX: offsetX)
        clock.play(.idle, from: sprites, at: now).map(stage.show)
        nextBlinkAt = now + .random(in: 3...8)
        nextBehaviorAt = autonomy ? now + .random(in: 4...9) : .infinity
        switch ref {
        case .window(let id):
            lastWindowFrame = world.liveWindowFrame(id: id)
            let pid = world.cachedWindow(id: id)?.ownerPID
            currentPlatformPID = pid
            if let pid { tier2.attach(to: pid, protecting: pid) }
            let name = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
            status("Riding: \(name ?? "a window")")
        case .floor:
            lastWindowFrame = nil
            currentPlatformPID = nil
            status("On the desktop")
        }
        log("→ standing on \(ref)")
    }

    private func beginWalk(on ref: PlatformRef, dir: CGFloat, duration: TimeInterval) {
        let now = CACurrentMediaTime()
        state = .walking(ref, dir: dir, until: now + duration)
        stage.setPose(rotationDegrees: 0, facing: dir < 0 ? -1 : 1)
        clock.play(.walk, from: sprites, at: now).map(stage.show)
        lastMotionAt = now
        setLinkRate(preferred: 30)
        setLinkPaused(false, now: now)
        log("→ walking dir=\(dir > 0 ? "→" : "←") for \(String(format: "%.1f", duration))s")
    }

    private func beginClimb(side: CGFloat, targetY: CGFloat, at now: TimeInterval) {
        let f = world.floorPlatform(atX: anchor.x)
        anchor.x = side < 0 ? f.minX : f.maxX
        state = .climbing(side: side, targetY: targetY)
        stage.setPose(rotationDegrees: side < 0 ? -90 : 90, facing: 1)
        clock.play(.walk, from: sprites, at: now).map(stage.show)
        lastMotionAt = now
        setLinkRate(preferred: 30)
        setLinkPaused(false, now: now)
        status("Climbing…")
        log("→ climbing \(side < 0 ? "left" : "right") wall to y=\(Int(targetY))")
    }

    // MARK: - Display-link step

    @objc private func stepLink(_ sender: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(max(now - lastStepAt, 0), 0.05))
        lastStepAt = now
        step(dt: dt, now: now)
        clock.tick(at: now).map(stage.show)
        refreshHole() // the sprite may have moved under a stationary cursor
    }

    private func step(dt: CGFloat, now: TimeInterval) {
        switch state {

        case .falling(let vy):
            world.refreshIfStale(now: now, maxAge: 0.12)
            let s = PetPhysics.fallStep(y: anchor.y, vy: vy, dt: dt)
            if let hit = Terrain.landingPlatform(in: world.platforms, x: anchor.x,
                                                 fromY: anchor.y, toY: s.y) {
                land(on: hit, at: now)
            } else if s.y < (world.floors.map(\.minY).min() ?? 0) - 300 {
                let f = world.floorPlatform(atX: anchor.x)
                anchor.x = min(max(anchor.x, f.minX + 4), f.maxX - 4)
                anchor.y = f.topY + 1
                land(on: f, at: now)
            } else {
                anchor.y = s.y
                state = .falling(vy: s.vy)
                applyAnchor()
            }
            lastMotionAt = now

        case .leaping(let vx, let vy, let endAt):
            world.refreshIfStale(now: now, maxAge: 0.12)
            let f = world.floorPlatform(atX: anchor.x)
            var newVx = vx
            var x = anchor.x + vx * dt
            if x < f.minX + 4 { x = f.minX + 4; newVx = 0 }   // thudded into a wall
            if x > f.maxX - 4 { x = f.maxX - 4; newVx = 0 }
            anchor.x = x
            let s = PetPhysics.fallStep(y: anchor.y, vy: vy, dt: dt)
            if s.vy < 0 {
                clock.play(.fall, from: sprites, at: now).map(stage.show)
                if let hit = Terrain.landingPlatform(in: world.platforms, x: anchor.x,
                                                     fromY: anchor.y, toY: s.y) {
                    land(on: hit, at: now)
                    return
                }
            }
            anchor.y = s.y
            state = now >= endAt ? .falling(vy: s.vy)
                                 : .leaping(vx: newVx, vy: s.vy, endAt: endAt)
            applyAnchor()
            lastMotionAt = now

        case .landing(let ref, let offsetX, let until):
            follow(ref, offsetX: offsetX, now: now)
            if now >= until { enterStanding(ref, offsetX: offsetX, at: now) }

        case .standing(let ref, let offsetX):
            follow(ref, offsetX: offsetX, now: now)
            finishReactionAnims(now: now)
            if now - lastMotionAt > RatePolicy.motionHoldSeconds {
                setLinkPaused(true, now: now)
            }

        case .walking(let ref, let dir, let until):
            walkStep(ref: ref, dir: dir, until: until, dt: dt, now: now)

        case .climbing(let side, let targetY):
            anchor.y += Self.climbSpeed * dt
            applyAnchor()
            lastMotionAt = now
            if anchor.y >= targetY {
                // Kick off the wall into the room — a little backflip exit.
                stage.setPose(rotationDegrees: 0, facing: side < 0 ? 1 : -1)
                clock.play(.jump, from: sprites, at: now).map(stage.show)
                state = .leaping(vx: -side * .random(in: 130...220), vy: 300, endAt: now + 2.5)
                setLinkRate(preferred: 60)
                log("→ leaping off the wall")
            }

        case .grabbed, .suspended:
            break
        }
    }

    /// Non-looping reaction animations (boop squash, blink) drift back to
    /// idle once finished, whichever clock notices first.
    private func finishReactionAnims(now: TimeInterval) {
        if clock.finished, clock.currentKind == .land || clock.currentKind == .blink {
            clock.play(.idle, from: sprites, at: now).map(stage.show)
        }
    }

    private func follow(_ ref: PlatformRef, offsetX: CGFloat, now: TimeInterval) {
        guard case .window(let id) = ref else { return }
        guard let frame = world.liveWindowFrame(id: id) else {
            enterFalling(vy: 0, at: now)
            return
        }
        let clamped = min(max(offsetX, 4), max(4, frame.width - 4))
        let next = CGPoint(x: frame.minX + clamped, y: frame.maxY)
        if next != anchor {
            anchor = next
            lastMotionAt = now
            applyAnchor()
            if let pid = currentPlatformPID { tier2.notedTier1Motion(pid: pid) }
        }
        lastWindowFrame = frame
    }

    private func walkStep(ref: PlatformRef, dir: CGFloat, until: TimeInterval,
                          dt: CGFloat, now: TimeInterval) {
        let topY: CGFloat
        let kind: Platform.Kind
        switch ref {
        case .window(let id):
            guard let frame = world.liveWindowFrame(id: id) else {
                enterFalling(vy: 0, at: now)
                return
            }
            topY = frame.maxY
            kind = .window(id)
            lastWindowFrame = frame
        case .floor:
            let f = world.floorPlatform(atX: anchor.x)
            topY = f.topY
            kind = .floor
        }
        world.refreshIfStale(now: now, maxAge: ref == .floor ? 1.0 : 0.25)
        guard let seg = world.segment(of: kind, atX: anchor.x) else {
            enterFalling(vy: 0, at: now)
            return
        }
        var x = anchor.x + dir * PetPhysics.walkSpeed * dt
        var newDir = dir
        let lo = seg.minX + Self.petSize.width / 2 - 8
        let hi = seg.maxX - Self.petSize.width / 2 + 8
        if x <= lo || x >= hi {
            if ref == .floor {
                // Floor edges are screen edges: sometimes climb the wall.
                if autonomy && CGFloat.random(in: 0...1) < 0.5 {
                    let f = world.floorPlatform(atX: anchor.x)
                    let h = (NSScreen.screens.first { $0.visibleFrame.minY == f.topY }?
                        .visibleFrame.height) ?? 800
                    beginClimb(side: dir < 0 ? -1 : 1,
                               targetY: f.topY + h * .random(in: 0.3...0.72), at: now)
                    return
                }
            } else if autonomy && CGFloat.random(in: 0...1) < 0.30 {
                anchor.x = x + dir * 10 // stroll right off the edge
                enterFalling(vy: 0, at: now)
                return
            }
            x = min(max(x, lo), hi)
            newDir = -dir
            stage.setPose(rotationDegrees: 0, facing: newDir < 0 ? -1 : 1)
        }
        anchor = CGPoint(x: x, y: topY)
        applyAnchor()
        lastMotionAt = now
        if now >= until {
            let offset: CGFloat
            if case .window(let id) = ref {
                offset = anchor.x - (world.liveWindowFrame(id: id)?.minX ?? seg.minX)
            } else {
                offset = anchor.x - seg.minX
            }
            enterStanding(ref, offsetX: offset, at: now)
        } else if newDir != dir {
            state = .walking(ref, dir: newDir, until: until)
        }
    }

    // MARK: - Watch timer

    private func watchTick() {
        let now = CACurrentMediaTime()

        if let p = pendingActivation, now - p.at >= 0.4 {
            pendingActivation = nil
            world.refresh(now: now)
            if let win = world.frontTopWindow(forcePID: debugForcePID, allowOwn: allowOwnWindows),
               win.ownerPID == p.pid || debugForcePID != nil {
                tier2.attach(to: win.ownerPID, protecting: currentPlatformPID)
                leap(to: win, at: now)
            }
        }

        switch state {
        case .standing(let ref, let offsetX):
            if !displayLinkActive {
                if case .window(let id) = ref {
                    guard let frame = world.liveWindowFrame(id: id) else {
                        enterFalling(vy: 0, at: now)
                        break
                    }
                    if frame != lastWindowFrame {
                        lastMotionAt = now
                        setLinkRate(preferred: 60)
                        setLinkPaused(false, now: now)
                        follow(ref, offsetX: offsetX, now: now)
                    }
                }
            }
            if now - lastAuditAt > 1.0 {
                lastAuditAt = now
                if case .window(let id) = ref {
                    world.refresh(now: now)
                    if !world.isExposed(windowID: id, atX: anchor.x) {
                        enterFalling(vy: 0, at: now)
                        break
                    }
                }
            }
            if autonomy && now >= nextBehaviorAt {
                startAutonomousBehavior(from: ref, at: now)
            }

        case .suspended, .falling, .leaping, .landing, .walking, .climbing, .grabbed:
            break
        }

        refreshHole() // catches cursor parked while the pet wanders under it
        retuneWatchTimer()
    }

    private func startAutonomousBehavior(from ref: PlatformRef, at now: TimeInterval) {
        nextBehaviorAt = now + .random(in: 4...9)
        switch ref {
        case .floor:
            world.refresh(now: now)
            if CGFloat.random(in: 0...1) < 0.5,
               let win = world.frontTopWindow(forcePID: debugForcePID, allowOwn: allowOwnWindows) {
                leap(to: win, at: now)
            } else {
                beginWalk(on: ref, dir: Bool.random() ? 1 : -1,
                          duration: .random(in: 1.5...3.5))
            }
        case .window:
            beginWalk(on: ref, dir: Bool.random() ? 1 : -1,
                      duration: .random(in: 1.5...3.5))
        }
    }

    // MARK: - Ambient timer

    private func startAmbientTimer() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.ambientTick() }
        t.resume()
        ambientTimer = t
    }

    private func ambientTick() {
        guard !displayLinkActive, case .standing = state else { return }
        let now = CACurrentMediaTime()
        finishReactionAnims(now: now)
        if clock.currentKind == .idle && now >= nextBlinkAt {
            nextBlinkAt = now + .random(in: 3...8)
            clock.play(.blink, from: sprites, at: now).map(stage.show)
        }
        clock.tick(at: now).map(stage.show)
    }

    // MARK: - Clock management

    private func setLinkRate(preferred: Float) {
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 60,
                                                         preferred: preferred)
    }

    private func setLinkPaused(_ paused: Bool, now: TimeInterval) {
        guard let link, link.isPaused != paused else { return }
        if !paused { lastStepAt = now }
        link.isPaused = paused
        retuneWatchTimer()
    }

    private func retuneWatchTimer(force: Bool = false) {
        let now = CACurrentMediaTime()
        let interval: TimeInterval
        if displayLinkActive {
            interval = 0.25
        } else if case .standing(.window, _) = state {
            interval = RatePolicy.interval(hasTarget: true, sinceMotion: now - lastMotionAt)
        } else {
            interval = 0.5
        }
        guard force || abs(interval - watchInterval) > 0.0001 else { return }
        watchTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        let leeway: DispatchTimeInterval = interval < 0.05 ? .milliseconds(2) : .milliseconds(25)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: leeway)
        t.setEventHandler { [weak self] in self?.watchTick() }
        t.resume()
        watchTimer = t
        watchInterval = interval
    }

    // MARK: - Output

    private func applyAnchor() {
        stage.place(anchor: anchor)
    }

    private func status(_ s: String) { onStatus?(s) }

    private func fmt(_ p: CGPoint) -> String {
        String(format: "(%.0f, %.0f)", p.x, p.y)
    }

    private func log(_ msg: String) {
        guard verbose else { return }
        print(String(format: "[%7.3f] %@", Date().timeIntervalSince(startedAt), msg))
    }
}
