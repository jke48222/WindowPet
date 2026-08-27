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
    /// The drawn body is inset inside the sprite canvas (art padding). Edge
    /// clamps use the VISIBLE body edge so his metal touches screen edges
    /// exactly; the transparent canvas may overhang harmlessly.
    static let bodyInsetX: CGFloat = 13
    static var bodyHalfWidth: CGFloat { petSize.width / 2 - bodyInsetX }
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
        case walking(PlatformRef, dir: CGFloat, until: TimeInterval, targetX: CGFloat?)
        case climbing(side: CGFloat, targetY: CGFloat) // side: -1 left wall, +1 right
        case grabbed
        case suspended
    }

    // MARK: - Wiring

    private let stage: OverlayStage
    private var sprites: SpriteSet
    let world = WorldModel()
    let tier2 = Tier2Manager()
    private var brain = BehaviorBrain(seed: UInt64(Date().timeIntervalSince1970 * 1000))
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
    private var lastBrainAdvanceAt: TimeInterval = 0
    private(set) var isSleeping = false
    private var travelPlan: [Planner.Step] = []
    private var travelTargetWindow: CGWindowID?
    private var travelReplanUsed = false
    private var pendingClimbSide: CGFloat?
    private var pendingNapAtX: CGFloat?
    private var climbedRecently = false
    var reactionsEnabled = true
    var greetingEnabled = true
    private(set) var immersionActive = false
    private var celebrationHops = 0
    private var lastUserInputAt: TimeInterval = 0
    private var userAway = false
    private var paceDir: CGFloat = 1
    private var nextPaceAt: TimeInterval = 0
    private var lastAgitationTravelAt: TimeInterval = 0
    private var lastActivationLeapAt: TimeInterval = 0
    private var offscreenSince: TimeInterval = 0
    private var statusHoldUntil: TimeInterval = 0
    private var lastVisitedWindow: CGWindowID?
    private(set) var debugLastPlanCount = 0
    private var nextBlinkAt: TimeInterval = 0
    private var nextFidgetAt: TimeInterval = 0
    private(set) var focusCalm = false
    private var pendingActivation: (pid: pid_t, at: TimeInterval)?

    // Mouse interaction.
    private var mouseMonitors: [Any] = []
    private var grabStartedAt: TimeInterval = 0
    private var grabStartPoint: CGPoint = .zero
    private var preGrabStanding: (PlatformRef, CGFloat)?
    private var dragSamples: [(t: TimeInterval, p: CGPoint)] = []

    init(stage: OverlayStage, verbose: Bool, sprites: SpriteSet = SpriteSet()) {
        self.stage = stage
        self.verbose = verbose
        self.sprites = sprites
        super.init()
        stage.facingSign = sprites.facesLeft ? -1 : 1
    }

    /// Hot-swap the character (Shimeji import, character manager). The pet
    /// keeps doing whatever it was doing in the new skin.
    func applySprites(_ set: SpriteSet, name: String) {
        sprites = set
        stage.facingSign = set.facesLeft ? -1 : 1
        let now = CACurrentMediaTime()
        let kind = clock.currentKind ?? .idle
        clock.reset()
        clock.play(kind == .blink ? .idle : kind, from: set, at: now).map(stage.show)
        log("character swapped → \(name) (\(set.loadedFrameCount) frames)")
    }

    var spriteFacesLeft: Bool { sprites.facesLeft }

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
        case .standing(.window(let id), _), .walking(.window(let id), _, _, _),
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
    func debugResetBrain(seed: UInt64, needs: NeedsVector) {
        brain = BehaviorBrain(seed: seed, needs: needs)
    }
    func debugSetNeeds(_ n: NeedsVector) { brain.setNeeds(n) }
    var debugNeeds: NeedsVector { brain.needs }
    var debugAnimKind: String { clock.currentKindName }
    var debugTravelActive: Bool { travelTargetWindow != nil || !travelPlan.isEmpty }
    func debugDecideNow() {
        let now = CACurrentMediaTime()
        if case .standing(let ref, _) = state { behave(from: ref, at: now) }
    }
    func debugTravel(to id: CGWindowID) {
        let now = CACurrentMediaTime()
        switch state {
        case .standing(let ref, _):
            startTravel(to: id, from: ref, at: now)
        case .walking(let ref, _, _, _):
            // Plan is stored; the first step executes when this walk ends.
            startTravel(to: id, from: ref, at: now)
        default:
            return
        }
    }
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
            self?.noteUserInput()
            self?.refreshHole()
        } as Any)
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] e in
            self?.noteUserInput()
            self?.refreshHole()
            return e
        }) {
            mouseMonitors.append(local)
        }
        lastUserInputAt = CACurrentMediaTime()

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
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            self.tier2.detach(pid: app.processIdentifier)
            if self.reactionsEnabled,
               ReactionPolicy.isDistraction(bundleID: app.bundleIdentifier) {
                self.celebrate(appName: app.localizedName ?? "that app")
            }
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

    private func spawn(attempt: Int = 0) {
        let now = CACurrentMediaTime()
        world.refresh(now: now)
        let screenTop = stage.clampTop(forAnchor: CGPoint(
            x: NSScreen.screens.first?.frame.midX ?? 700,
            y: (NSScreen.screens.first?.frame.midY ?? 500))) - Self.petSize.height
        if let win = world.frontTopWindow(forcePID: debugForcePID, allowOwn: allowOwnWindows) {
            let perch = Geometry.initialPerch(windowWidth: win.frame.width,
                                              petWidth: Self.petSize.width)
            anchor = CGPoint(x: win.frame.minX + perch + Self.petSize.width / 2,
                             y: min(win.frame.maxY + 260, screenTop))
        } else if attempt < 2 {
            // The window server registers windows asynchronously; at login or
            // right after launch the front app's windows may not be listed
            // yet. Wait a beat rather than defaulting to the floor.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.spawn(attempt: attempt + 1)
            }
            return
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
        if isSleeping { engineWake(at: now) }
        brain.applyEvent(.touched)
        travelPlan = []
        travelTargetWindow = nil
        pendingClimbSide = nil
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
            brain.applyEvent(.thrown)
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
        status("boop!")
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
        if isSleeping { engineWake(at: now) }
        brain.applyEvent(.knockedOff)
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
        if case .standing(.window(win.id), _) = state { return }
        let perch = Geometry.initialPerch(windowWidth: win.frame.width,
                                          petWidth: Self.petSize.width)
        leapToPoint(CGPoint(x: win.frame.minX + perch + Self.petSize.width / 2,
                            y: win.frame.maxY), at: now)
    }

    private func leapToPoint(_ target: CGPoint, at now: TimeInterval) {
        switch state {
        case .standing, .walking: break
        default: return
        }
        let sol = PetPhysics.leapSolution(from: anchor, to: target)
        state = .leaping(vx: sol.vx, vy: sol.vy, endAt: now + Double(sol.duration))
        stage.setPose(rotationDegrees: 0, facing: sol.vx < 0 ? -1 : 1)
        clock.play(.jump, from: sprites, at: now).map(stage.show)
        lastMotionAt = now
        setLinkRate(preferred: 60)
        setLinkPaused(false, now: now)
        status("Leaping…")
        log("→ leaping to \(fmt(target)) T=\(String(format: "%.2f", sol.duration))")
    }

    private func land(on platform: Platform, at now: TimeInterval) {
        anchor.y = platform.topY
        // Rest fully on the platform — a 4pt margin left half the body
        // hanging past screen/window edges.
        let margin = min(Self.bodyHalfWidth, max(4, (platform.width - 8) / 2))
        anchor.x = min(max(anchor.x, platform.minX + margin), platform.maxX - margin)
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
        stage.setPose(rotationDegrees: standRotation(at: anchor), facing: stage.facing)
        clock.play(.land, from: sprites, at: now).map(stage.show)
        lastMotionAt = now
        applyAnchor()
        log("→ landed on \(ref) at \(fmt(anchor))")
    }

    private func enterStanding(_ ref: PlatformRef, offsetX: CGFloat, at now: TimeInterval) {
        state = .standing(ref, offsetX: offsetX)
        clock.play(.idle, from: sprites, at: now).map(stage.show)
        nextBlinkAt = now + .random(in: 3...8)
        nextFidgetAt = now + .random(in: 6...14)
        nextBehaviorAt = autonomy ? now + 2.2 : .infinity
        switch ref {
        case .window(let id):
            lastWindowFrame = world.liveWindowFrame(id: id)
            let pid = world.cachedWindow(id: id)?.ownerPID
            currentPlatformPID = pid
            if let pid { tier2.attach(to: pid, protecting: pid) }
        case .floor:
            lastWindowFrame = nil
            currentPlatformPID = nil
        }
        stage.setPose(rotationDegrees: standRotation(at: anchor), facing: stage.facing)
        standingStatus(ref)
        log("→ standing on \(ref)")
        if climbedRecently {
            climbedRecently = false
            brain.applyEvent(.climbed)
        }
        if celebrationHops > 0 {
            celebrationHops -= 1
            if celebrationHops > 0 {
                paceDir *= -1
                hop(at: now)
                return
            }
        }
        if travelTargetWindow != nil || !travelPlan.isEmpty || pendingClimbSide != nil
            || pendingNapAtX != nil {
            advanceTravel(from: ref, at: now)
        }
    }

    private func standingStatus(_ ref: PlatformRef) {
        if immersionActive {
            status("Shh, you're watching something")
            return
        }
        if CACurrentMediaTime() < statusHoldUntil { return }
        switch ref {
        case .window(let id):
            let pid = world.cachedWindow(id: id)?.ownerPID
            let name = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
            status("Riding: \(name ?? "a window")")
        case .floor:
            status("On the desktop")
        }
    }

    private func beginWalk(on ref: PlatformRef, dir: CGFloat, duration: TimeInterval,
                           targetX: CGFloat? = nil) {
        let now = CACurrentMediaTime()
        state = .walking(ref, dir: dir, until: now + duration, targetX: targetX)
        stage.setPose(rotationDegrees: standRotation(at: anchor), facing: dir < 0 ? -1 : 1)
        clock.play(.walk, from: sprites, at: now).map(stage.show)
        lastMotionAt = now
        setLinkRate(preferred: 30)
        setLinkPaused(false, now: now)
        log("→ walking dir=\(dir > 0 ? "→" : "←") for \(String(format: "%.1f", duration))s")
    }

    private func beginClimb(side: CGFloat, targetY: CGFloat, at now: TimeInterval) {
        let f = world.floorPlatform(atX: anchor.x)
        // The rotated body's feet-side inset is ~4pt: put the visible feet
        // exactly on the screen edge.
        anchor.x = side < 0 ? f.minX + 4 : f.maxX - 4
        state = .climbing(side: side, targetY: targetY)
        climbedRecently = true
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
            // Stay over the floor while falling: a step-off past the screen
            // edge (x beyond the floor span) would otherwise miss the floor
            // and sink below the screen before the failsafe caught it.
            let f = world.floorPlatform(atX: anchor.x)
            anchor.x = min(max(anchor.x, f.minX + Self.bodyHalfWidth),
                           f.maxX - Self.bodyHalfWidth)
            var s = PetPhysics.fallStep(y: anchor.y, vy: vy, dt: dt)
            s = ceilingClamp(s)
            if let hit = Terrain.landingPlatform(in: world.platforms, x: anchor.x,
                                                 fromY: anchor.y, toY: s.y) {
                land(on: hit, at: now)
            } else if s.y < (world.floors.map(\.minY).min() ?? 0) - 40 {
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
            let wallMargin = Self.bodyHalfWidth
            if x < f.minX + wallMargin { x = f.minX + wallMargin; newVx = 0 } // thud
            if x > f.maxX - wallMargin { x = f.maxX - wallMargin; newVx = 0 }
            anchor.x = x
            var s = PetPhysics.fallStep(y: anchor.y, vy: vy, dt: dt)
            s = ceilingClamp(s) // throws bonk on the menu-bar line, never exit the top
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

        case .walking(let ref, let dir, let until, let targetX):
            walkStep(ref: ref, dir: dir, until: until, targetX: targetX, dt: dt, now: now)

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
        if clock.finished,
           [.land, .blink, .lookAround, .fidget].contains(clock.currentKind) {
            clock.play(.idle, from: sprites, at: now).map(stage.show)
        }
    }

    /// Nothing ever leaves the top of the screen: airborne arcs stop at the
    /// menu-bar/notch line (a little ceiling bonk) instead of arcing out.
    private func ceilingClamp(_ s: (y: CGFloat, vy: CGFloat)) -> (y: CGFloat, vy: CGFloat) {
        // Anchor may reach the menu-bar/notch line itself — landings there
        // become ceiling hangs (body below the line), and the render layer
        // keeps upright transients pushed fully on-screen.
        let maxY = stage.clampTop(forAnchor: anchor)
        if s.y > maxY { return (maxY, min(s.vy, 0)) }
        return s
    }

    /// Upright, or hanging upside down when the edge is too close to the
    /// screen top (menu bar / notch band) for the body to fit above it.
    private func standRotation(at a: CGPoint) -> CGFloat {
        let bodyTop = a.y + Self.petSize.height - Self.footOverlap
        return bodyTop > stage.clampTop(forAnchor: a) ? 180 : 0
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
            stage.setPose(rotationDegrees: standRotation(at: anchor), facing: stage.facing)
            applyAnchor()
            if let pid = currentPlatformPID { tier2.notedTier1Motion(pid: pid) }
        }
        lastWindowFrame = frame
    }

    private func walkStep(ref: PlatformRef, dir: CGFloat, until: TimeInterval,
                          targetX: CGFloat?, dt: CGFloat, now: TimeInterval) {
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
        if let t = targetX, (dir > 0 && x >= t) || (dir < 0 && x <= t) {
            anchor = CGPoint(x: min(max(t, seg.minX + 4), seg.maxX - 4), y: topY)
            applyAnchor()
            let offset: CGFloat
            if case .window(let id) = ref {
                offset = anchor.x - (world.liveWindowFrame(id: id)?.minX ?? seg.minX)
            } else {
                offset = anchor.x - seg.minX
            }
            enterStanding(ref, offsetX: offset, at: now)
            return
        }
        var newDir = dir
        let lo = seg.minX + Self.bodyHalfWidth
        let hi = seg.maxX - Self.bodyHalfWidth
        if x <= lo || x >= hi {
            if ref == .floor {
                // Floor edges are screen edges: sometimes climb the wall.
                if autonomy && travelPlan.isEmpty && targetX == nil && CGFloat.random(in: 0...1) < 0.5 {
                    let f = world.floorPlatform(atX: anchor.x)
                    let h = (NSScreen.screens.first { $0.visibleFrame.minY == f.topY }?
                        .visibleFrame.height) ?? 800
                    beginClimb(side: dir < 0 ? -1 : 1,
                               targetY: f.topY + h * .random(in: 0.3...0.72), at: now)
                    return
                }
            } else if autonomy && travelPlan.isEmpty && targetX == nil
                        && CGFloat.random(in: 0...1) < 0.30 {
                anchor.x = x + dir * 10 // stroll right off the edge
                enterFalling(vy: 0, at: now)
                return
            }
            x = min(max(x, lo), hi)
            newDir = -dir
            stage.setPose(rotationDegrees: standRotation(at: anchor), facing: newDir < 0 ? -1 : 1)
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
            state = .walking(ref, dir: newDir, until: until, targetX: targetX)
        }
    }

    // MARK: - Watch timer

    private func watchTick() {
        let now = CACurrentMediaTime()

        // Needs drift with what the pet is actually doing.
        if lastBrainAdvanceAt == 0 { lastBrainAdvanceAt = now }
        let bdt = now - lastBrainAdvanceAt
        if bdt >= 0.2 {
            lastBrainAdvanceAt = now
            let activity: BehaviorBrain.Activity =
                isSleeping ? .sleeping : (stateName == "standing" ? .idle : .moving)
            brain.advance(dt: bdt, activity: activity)
        }

        if let p = pendingActivation, now - p.at >= 0.4 {
            pendingActivation = nil
            // Chasing the newly active app is an autonomous whim — it must
            // yield to sleep, immersion retreats, and in-flight errands, and
            // never fire at all when autonomy is off.
            // Cooldown + motivation gate: chasing every cmd-tab made the pet
            // exhausting to share a screen with. It follows an app switch at
            // most every couple of minutes, and only when it actually cares.
            if autonomy, !isSleeping, !immersionActive, !focusCalm,
               travelPlan.isEmpty, pendingNapAtX == nil,
               now - lastActivationLeapAt > 120,
               brain.needs.attention > 0.45 || brain.needs.curiosity > 0.65 {
                world.refresh(now: now)
                if let win = world.frontTopWindow(forcePID: debugForcePID, allowOwn: allowOwnWindows),
                   win.ownerPID == p.pid || debugForcePID != nil {
                    lastActivationLeapAt = now
                    tier2.attach(to: win.ownerPID, protecting: currentPlatformPID)
                    leap(to: win, at: now)
                }
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
            if autonomy, travelPlan.isEmpty, now >= nextBehaviorAt {
                behave(from: ref, at: now)
            }

        case .suspended, .falling, .leaping, .landing, .walking, .climbing, .grabbed:
            break
        }

        if reactionsEnabled { reactionsTick(at: now) }
        visibilityWatchdog(at: now)
        refreshHole() // catches cursor parked while the pet wanders under it
        retuneWatchTimer()
    }

    /// Last-resort guarantee: a resting pet must be visible. If its sprite is
    /// mostly off every screen for a few seconds (weird geometry, display
    /// changes), drop it back onto the floor rather than losing it.
    private func visibilityWatchdog(at now: TimeInterval) {
        switch state {
        case .standing, .walking: break
        default:
            offscreenSince = 0
            return
        }
        let rect = stage.spriteGlobalRect
        let visible = NSScreen.screens.reduce(CGFloat(0)) { acc, screen in
            let i = rect.intersection(screen.frame)
            return acc + (i.isNull ? 0 : i.width * i.height)
        }
        let fraction = visible / max(1, rect.width * rect.height)
        if fraction < 0.3 {
            if offscreenSince == 0 {
                offscreenSince = now
            } else if now - offscreenSince > 2.5 {
                offscreenSince = 0
                log("visibility watchdog: relocating from \(fmt(anchor))")
                let f = world.floorPlatform(atX: anchor.x)
                anchor.x = min(max(anchor.x, f.minX + 60), f.maxX - 60)
                anchor.y = min(anchor.y, f.topY + 400)
                enterFalling(vy: 0, at: now)
            }
        } else {
            offscreenSince = 0
        }
    }

    // MARK: - Reactions (S6): every one derives from observable system state.

    private func noteUserInput() {
        let now = CACurrentMediaTime()
        let away = now - lastUserInputAt
        lastUserInputAt = now
        if userAway {
            userAway = false
            if greetingEnabled && reactionsEnabled
                && ReactionPolicy.isReturnGreeting(awaySeconds: away) {
                greet(afterAway: away)
            }
        }
    }

    private func reactionsTick(at now: TimeInterval) {
        if !userAway && now - lastUserInputAt > ReactionPolicy.awayThreshold {
            userAway = true // greeting fires when input resumes
        }

        // Immersion: user is watching something fullscreen — get out of the
        // way and nap until it ends. Needs a reasonably fresh window cache
        // even while asleep on the floor (nothing else refreshes it then).
        world.refreshIfStale(now: now, maxAge: isSleeping ? 3.0 : 1.5)
        if true {
            let immersed = world.immersionWindow() != nil
            if immersed && !immersionActive {
                immersionActive = true
                startImmersionRetreat(at: now)
            } else if !immersed && immersionActive {
                immersionActive = false
                pendingNapAtX = nil
                if isSleeping { engineWake(at: now) }
                log("immersion ended — back to normal")
            }
        }
        if immersionActive {
            focusCalm = false
            return // stay settled; no other reactions
        }
        focusCalm = world.maximizedFrontWindow() != nil

        // Agitation: an observed app is retitling rapidly (build, progress).
        guard case .standing(let ref, _) = state, !isSleeping, travelPlan.isEmpty,
              !focusCalm else { return }
        if let hot = tier2.hottestTitleApp(at: now) {
            if currentPlatformPID == hot.pid {
                if now >= nextPaceAt {
                    nextPaceAt = now + 0.9
                    paceDir *= -1
                    beginWalk(on: ref, dir: paceDir, duration: .random(in: 0.5...0.8))
                    let name = NSRunningApplication(processIdentifier: hot.pid)?.localizedName ?? "an app"
                    holdStatus("👀 something's happening in \(name)", for: 1.5)
                }
            } else if now - lastAgitationTravelAt > 8,
                      let win = world.windows.first(where: { $0.ownerPID == hot.pid }) {
                lastAgitationTravelAt = now
                startTravel(to: win.id, from: ref, at: now)
            }
        }
    }

    private func startImmersionRetreat(at now: TimeInterval) {
        log("immersion detected — retreating to the floor")
        holdStatus("Shh, you're watching something", for: 4)
        travelTargetWindow = nil
        travelReplanUsed = false
        let floor = world.floorPlatform(atX: anchor.x)
        // Nap a short shuffle toward the nearest screen edge — out of the
        // way without a cross-screen trek.
        let towardEdge: CGFloat = (anchor.x - floor.minX < floor.maxX - anchor.x) ? -60 : 60
        pendingNapAtX = min(max(anchor.x + towardEdge, floor.minX + 40), floor.maxX - 40)
        if case .standing(let ref, _) = state, ref != .floor {
            travelPlan = Planner.plan(fromKind: platformKind(of: ref), fromX: anchor.x,
                                      to: .floor, platforms: world.platforms) ?? []
            if travelPlan.isEmpty {
                anchor.x += 12
                enterFalling(vy: 0, at: now)
            } else {
                runNextPlanStep(at: now)
            }
        }
        // Already on the floor: advanceTravel picks up pendingNapAtX below.
        if case .standing(.floor, _) = state {
            advanceTravel(from: .floor, at: now)
        }
    }

    /// A small joyful hop in place (celebrations, greetings).
    private func hop(at now: TimeInterval) {
        switch state {
        case .standing, .walking: break
        default: return
        }
        state = .leaping(vx: paceDir * 24, vy: 300, endAt: now + 1.4)
        clock.play(.jump, from: sprites, at: now).map(stage.show)
        lastMotionAt = now
        setLinkRate(preferred: 60)
        setLinkPaused(false, now: now)
    }

    private func greet(afterAway away: TimeInterval) {
        let now = CACurrentMediaTime()
        guard stateName == "standing" || isSleeping else { return }
        if isSleeping { engineWake(at: now) }
        brain.applyEvent(.userReturned)
        celebrationHops = 1
        hop(at: now)
        holdStatus("Welcome back!")
        log(String(format: "→ greeting (away %.0fs)", away))
    }

    private func celebrate(appName: String) {
        let now = CACurrentMediaTime()
        guard !immersionActive else { return }
        if isSleeping { engineWake(at: now) }
        brain.applyEvent(.celebrated)
        celebrationHops = 2
        hop(at: now)
        holdStatus("🎉 \(appName) closed!")
        log("→ celebrating \(appName) closing")
    }

    func debugTitleRate(pid: pid_t) -> Double {
        tier2.titleRate(pid: pid, at: CACurrentMediaTime())
    }
    func debugBumpTitleRate(pid: pid_t, hits: Int) {
        tier2.debugBumpTitleRate(pid: pid, hits: hits)
    }

    /// Grounded context for the assistant's routing model — the pet's actual
    /// situational awareness (local names only; nothing permission-gated).
    func assistantContext() -> String {
        var parts: [String] = []
        if let front = NSWorkspace.shared.frontmostApplication?.localizedName {
            parts.append("frontmost app: \(front)")
        }
        switch state {
        case .standing(.window, _), .walking(.window, _, _, _):
            if let pid = currentPlatformPID,
               let name = NSRunningApplication(processIdentifier: pid)?.localizedName {
                parts.append("Rusty is standing on the \(name) window")
            }
        default:
            parts.append("Rusty is on the desktop floor")
        }
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName)
            .prefix(8)
        parts.append("open apps: \(running.joined(separator: ", "))")
        if isSleeping { parts.append("Rusty was napping") }
        return parts.joined(separator: "; ")
    }

    /// Speak: bubble by the pet + status mirror.
    func say(_ text: String, for seconds: TimeInterval = 4) {
        let clean = AssistantRouting.sanitizeReply(text)
        guard !clean.isEmpty else { return }
        stage.say(clean, for: seconds)
        holdStatus("💬 \(clean)", for: seconds)
    }

    func debugSay(_ text: String, hold: TimeInterval) { stage.say(text, for: hold) }

    /// "Hey Rusty" — perk up: wake if napping, look attentive, note the
    /// attention.
    func assistantSummoned() {
        let now = CACurrentMediaTime()
        if isSleeping { engineWake(at: now) }
        brain.applyEvent(.touched)
        if case .standing = state {
            clock.play(.lookAround, from: sprites, at: now).map(stage.show)
        }
    }

    /// The assistant executed something — a little acknowledgment hop.
    func assistantDidAct(result: String) {
        let now = CACurrentMediaTime()
        if isSleeping { engineWake(at: now) }
        holdStatus(result, for: 3)
        if case .standing = state {
            celebrationHops = 1
            hop(at: now)
        }
    }

    func debugSimulateAppQuit(bundleID: String, name: String) {
        guard ReactionPolicy.isDistraction(bundleID: bundleID) else { return }
        celebrate(appName: name)
    }

    func debugSimulateUserReturn(awaySeconds: TimeInterval) {
        guard ReactionPolicy.isReturnGreeting(awaySeconds: awaySeconds) else { return }
        greet(afterAway: awaySeconds)
    }

    // MARK: - GOBT behavior layer: the brain decides, the engine executes.

    private func behave(from ref: PlatformRef, at now: TimeInterval) {
        if immersionActive {
            // Settled for the duration — only the nap machinery runs.
            nextBehaviorAt = now + 2
            return
        }
        world.refreshIfStale(now: now, maxAge: 1.0)
        let front = world.frontTopWindow(forcePID: debugForcePID, allowOwn: allowOwnWindows)
        let ctx = BehaviorBrain.Context(
            onFloor: ref == .floor,
            currentWindowID: currentWindowID,
            frontWindowID: front?.id,
            otherWindowIDs: world.windows.map(\.id),
            calm: focusCalm)
        execute(brain.decide(context: ctx), from: ref, at: now)
    }

    private func execute(_ choice: BehaviorBrain.Choice, from ref: PlatformRef,
                         at now: TimeInterval) {
        switch choice {
        case .sit(let d):
            nextBehaviorAt = now + d
        case .stroll(let d):
            nextBehaviorAt = now + d + 2
            beginWalk(on: ref, dir: Bool.random() ? 1 : -1, duration: d)
        case .stepOff:
            startStepOffPlan(from: ref, at: now)
        case .travelTo(let id):
            startTravel(to: CGWindowID(id), from: ref, at: now)
        case .climbWall:
            startClimbPlan(at: now)
        case .sleep:
            engineSleep(at: now)
        case .wake:
            engineWake(at: now)
            nextBehaviorAt = now + 0.8
        }
    }

    private func platformKind(of ref: PlatformRef) -> Platform.Kind {
        switch ref {
        case .window(let id): return .window(id)
        case .floor: return .floor
        }
    }

    private func startTravel(to id: CGWindowID, from ref: PlatformRef, at now: TimeInterval) {
        world.refresh(now: now)
        guard let win = world.cachedWindow(id: id) else {
            brain.applyEvent(.travelFailed)
            nextBehaviorAt = now + 1
            return
        }
        travelTargetWindow = id
        travelReplanUsed = false
        if let steps = Planner.plan(fromKind: platformKind(of: ref), fromX: anchor.x,
                                    to: .window(id), platforms: world.platforms) {
            travelPlan = steps
            debugLastPlanCount = steps.count
            let name = NSRunningApplication(processIdentifier: win.ownerPID)?.localizedName ?? "a window"
            status("Curious about \(name)")
            log("travel plan (\(steps.count) steps) → window \(id)")
            runNextPlanStep(at: now)
        } else {
            // No ranged route — direct cartoon leap so reachability never
            // regresses below stage-2 behavior.
            travelPlan = []
            debugLastPlanCount = 1
            let perch = Geometry.initialPerch(windowWidth: win.frame.width,
                                              petWidth: Self.petSize.width)
            leapToPoint(CGPoint(x: win.frame.minX + perch + Self.petSize.width / 2,
                                y: win.frame.maxY), at: now)
        }
    }

    private func runNextPlanStep(at now: TimeInterval) {
        guard case .standing(let ref, _) = state else { return }
        guard !travelPlan.isEmpty else {
            advanceTravel(from: ref, at: now)
            return
        }
        let step = travelPlan.removeFirst()
        switch step {
        case .walkTo(let x):
            if abs(x - anchor.x) < 6 {
                runNextPlanStep(at: now)
                return
            }
            let dir: CGFloat = x >= anchor.x ? 1 : -1
            let dur = TimeInterval(abs(x - anchor.x) / PetPhysics.walkSpeed) + 1.5
            beginWalk(on: ref, dir: dir, duration: dur, targetX: x)
        case .leapTo(let kind, let x):
            world.refresh(now: now)
            switch kind {
            case .window(let id):
                guard let win = world.cachedWindow(id: id) else {
                    travelPlan = [] // vanished mid-plan; replan or fail below
                    advanceTravel(from: ref, at: now)
                    return
                }
                leapToPoint(CGPoint(x: x, y: win.frame.maxY), at: now)
            case .floor:
                let f = world.floorPlatform(atX: x)
                leapToPoint(CGPoint(x: x, y: f.topY), at: now)
            }
        case .stepOffTo(let x):
            anchor.x = x
            enterFalling(vy: 0, at: now)
        }
    }

    private func advanceTravel(from ref: PlatformRef, at now: TimeInterval) {
        if let target = travelTargetWindow, case .window(let id) = ref, id == target {
            finishTravel(success: true, at: now)
            return
        }
        if !travelPlan.isEmpty {
            runNextPlanStep(at: now)
            return
        }
        if let napX = pendingNapAtX, ref == .floor {
            travelPlan = [] // reaching the floor is what mattered; drop the rest
            if abs(anchor.x - napX) > 8 {
                let dir: CGFloat = napX >= anchor.x ? 1 : -1
                beginWalk(on: ref, dir: dir,
                          duration: TimeInterval(abs(napX - anchor.x) / PetPhysics.walkSpeed) + 1,
                          targetX: napX)
            } else {
                pendingNapAtX = nil
                engineSleep(at: now)
            }
            return
        }
        if let side = pendingClimbSide {
            pendingClimbSide = nil
            guard ref == .floor else {
                nextBehaviorAt = now + 1
                return
            }
            let f = world.floorPlatform(atX: anchor.x)
            let h = (NSScreen.screens.first { $0.visibleFrame.minY == f.topY }?
                .visibleFrame.height) ?? 800
            beginClimb(side: side, targetY: f.topY + h * .random(in: 0.3...0.72), at: now)
            return
        }
        if let target = travelTargetWindow {
            if !travelReplanUsed {
                travelReplanUsed = true
                world.refresh(now: now)
                if let steps = Planner.plan(fromKind: platformKind(of: ref), fromX: anchor.x,
                                            to: .window(target), platforms: world.platforms) {
                    travelPlan = steps
                    runNextPlanStep(at: now)
                    return
                }
            }
            finishTravel(success: false, at: now)
        }
    }

    private func finishTravel(success: Bool, at now: TimeInterval) {
        if success, let target = travelTargetWindow {
            brain.applyEvent(.arrivedAtWindow(new: target != lastVisitedWindow))
            lastVisitedWindow = target
            log("travel complete → window \(target)")
        } else if travelTargetWindow != nil {
            brain.applyEvent(.travelFailed)
            log("travel failed")
        }
        travelTargetWindow = nil
        travelPlan = []
        travelReplanUsed = false
        nextBehaviorAt = now + 1.5
    }

    private func startStepOffPlan(from ref: PlatformRef, at now: TimeInterval) {
        guard case .window = ref,
              let seg = world.segment(of: platformKind(of: ref), atX: anchor.x) else {
            nextBehaviorAt = now + 1
            return
        }
        let toLeft = anchor.x - seg.minX <= seg.maxX - anchor.x
        let inner: CGFloat = toLeft ? seg.minX + Self.bodyHalfWidth
                                    : seg.maxX - Self.bodyHalfWidth
        let outer: CGFloat = toLeft ? seg.minX - 12 : seg.maxX + 12
        travelPlan = [.walkTo(x: inner), .stepOffTo(x: outer)]
        runNextPlanStep(at: now)
    }

    private func startClimbPlan(at now: TimeInterval) {
        let f = world.floorPlatform(atX: anchor.x)
        let side: CGFloat = (anchor.x - f.minX < f.maxX - anchor.x) ? -1 : 1
        let inner: CGFloat = side < 0 ? f.minX + Self.bodyHalfWidth
                                      : f.maxX - Self.bodyHalfWidth
        pendingClimbSide = side
        if abs(inner - anchor.x) < 6 {
            advanceTravel(from: .floor, at: now)
        } else {
            travelPlan = [.walkTo(x: inner)]
            runNextPlanStep(at: now)
        }
    }

    // MARK: - Sleep mode

    private func engineSleep(at now: TimeInterval) {
        nextBehaviorAt = now + 1.0
        guard !isSleeping else { return }
        isSleeping = true
        startAmbientTimer(interval: 1.2) // sleep frames are 1.15s; tick slower
        clock.play(.sleep, from: sprites, at: now).map(stage.show)
        status(immersionActive ? "Shh, you're watching something" : "Recharging")
        log(String(format: "→ sleeping (energy %.2f)", brain.needs.energy))
    }

    private func engineWake(at now: TimeInterval) {
        guard isSleeping else { return }
        isSleeping = false
        startAmbientTimer()
        clock.play(.idle, from: sprites, at: now).map(stage.show)
        if case .standing(let ref, _) = state { standingStatus(ref) }
        log(String(format: "→ awake (energy %.2f)", brain.needs.energy))
    }

    // MARK: - Ambient timer

    private func startAmbientTimer(interval: TimeInterval = 0.5) {
        ambientTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(150))
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
        } else if clock.currentKind == .idle && now >= nextFidgetAt {
            // Idle micro-fidgets: alive without relocating him.
            nextFidgetAt = now + .random(in: 9...22)
            clock.play(Bool.random() ? .lookAround : .fidget, from: sprites, at: now)
                .map(stage.show)
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

    /// A reaction status that routine transitions must not stomp for a bit.
    private func holdStatus(_ s: String, for seconds: TimeInterval = 2.5) {
        statusHoldUntil = CACurrentMediaTime() + seconds
        onStatus?(s)
    }

    private func fmt(_ p: CGPoint) -> String {
        String(format: "(%.0f, %.0f)", p.x, p.y)
    }

    private func log(_ msg: String) {
        guard verbose else { return }
        print(String(format: "[%7.3f] %@", Date().timeIntervalSince(startedAt), msg))
    }
}
