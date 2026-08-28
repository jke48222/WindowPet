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
@MainActor
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

    enum State {
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

    let stage: OverlayStage
    var sprites: SpriteSet
    let world = WorldModel()
    let tier2 = Tier2Manager()
    var brain = BehaviorBrain(seed: UInt64(Date().timeIntervalSince1970 * 1000))
    let clock = AnimationClock()
    let verbose: Bool
    let startedAt = Date()

    var autonomy = true
    var allowOwnWindows = false
    var debugForcePID: pid_t?
    var onStatus: ((String) -> Void)?

    var state: State = .falling(vy: 0)
    private(set) var anchor: CGPoint = .zero

    /// Position stays `private(set)` so the physics in this file owns where
    /// Rusty is. The two places that legitimately move him from outside it,
    /// dragging him by hand and the rig placing him deliberately, come through
    /// this one named door instead of the setter being opened to the app.
    func place(at point: CGPoint) { anchor = point }

    /// Sends Rusty to stand on an app's window and show his watch lamp, so a
    /// watch is something you can see rather than a promise you take on faith.
    /// Best effort: if the app has no standable window right now he stays put
    /// and only the lamp comes on.
    func standWatch(overPID pid: pid_t) {
        stage.setWatching(true)
        guard let window = Tier1.topmostStandardWindow(ownedBy: pid) else { return }
        debugTravel(to: window.id)
    }

    func endWatch() {
        stage.setWatching(false)
    }
    private(set) var currentPlatformPID: pid_t?
    var lastWindowFrame: CGRect?
    private(set) var debugTier2WakeCount = 0

    var link: CADisplayLink?
    var lastStepAt: TimeInterval = 0
    var lastMotionAt: TimeInterval = 0
    var lastAuditAt: TimeInterval = 0
    var lastStructuralNudgeAt: TimeInterval = 0
    var watchTimer: DispatchSourceTimer?
    var watchInterval: TimeInterval = -1
    var ambientTimer: DispatchSourceTimer?
    var nextBehaviorAt: TimeInterval = .infinity
    var lastBrainAdvanceAt: TimeInterval = 0
    private(set) var isSleeping = false
    var travelPlan: [Planner.Step] = []
    var travelTargetWindow: CGWindowID?
    var travelReplanUsed = false
    var pendingClimbSide: CGFloat?
    var pendingNapAtX: CGFloat?
    var climbedRecently = false
    var reactionsEnabled = true
    var greetingEnabled = true
    /// True while a full-screen video or presentation is on. Read widely so
    /// nothing disturbs the user; set by the reaction layer.
    var immersionActive = false
    var celebrationHops = 0
    var lastUserInputAt: TimeInterval = 0
    var userAway = false
    var paceDir: CGFloat = 1
    var nextPaceAt: TimeInterval = 0
    var lastAgitationTravelAt: TimeInterval = 0
    var lastActivationLeapAt: TimeInterval = 0
    var offscreenSince: TimeInterval = 0
    var statusHoldUntil: TimeInterval = 0
    var lastVisitedWindow: CGWindowID?
    /// How many steps the last plan had. Read by the rig to prove the brain
    /// actually produced a plan; written only by the behavior layer.
    var debugLastPlanCount = 0
    var nextBlinkAt: TimeInterval = 0
    var nextFidgetAt: TimeInterval = 0
    /// True while the user is in a long stretch of steady typing. Same
    /// ownership: the reaction layer sets it, everything else reads it.
    var focusCalm = false
    var pendingActivation: (pid: pid_t, at: TimeInterval)?

    // Mouse interaction.
    var mouseMonitors: [Any] = []
    var grabStartedAt: TimeInterval = 0
    var grabStartPoint: CGPoint = .zero
    var preGrabStanding: (PlatformRef, CGFloat)?
    var dragSamples: [(t: TimeInterval, p: CGPoint)] = []

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

        // NotificationCenter hands its block back without an actor even when
        // the delivery queue is `.main`. Every observer below is registered on
        // the main queue, so assumeIsolated states what is already true rather
        // than hopping and reordering the callback behind a later frame.
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                       object: nil, queue: .main) { [weak self] note in
            // Pull the plain values out of the notification first: Notification
            // and NSRunningApplication are not Sendable, a process id is.
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated {
                self?.pendingActivation = (pid, CACurrentMediaTime())
            }
        }
        ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                       object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.world.refresh(now: CACurrentMediaTime()) }
        }
        ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                       object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            let pid = app.processIdentifier
            let bundleID = app.bundleIdentifier
            let name = app.localizedName ?? "that app"
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tier2.detach(pid: pid)
                if self.reactionsEnabled, ReactionPolicy.isDistraction(bundleID: bundleID) {
                    self.celebrate(appName: name)
                }
            }
        }
        ws.addObserver(forName: NSWorkspace.willSleepNotification,
                       object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspend() }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification,
                       object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                        object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspend() }
        }
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                        object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        }

        startAmbientTimer()
        spawn()
        retuneWatchTimer(force: true)
    }

    func spawn(attempt: Int = 0) {
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

    func suspend() {
        guard stateName != "suspended" else { return }
        state = .suspended
        link?.isPaused = true
        watchTimer?.cancel(); watchTimer = nil; watchInterval = -1
        ambientTimer?.cancel(); ambientTimer = nil
        stage.hideAll()
        log("suspended (sleep/lock)")
    }

    func resume() {
        guard case .suspended = state else { return }
        log("resumed — respawning")
        stage.showAll()
        startAmbientTimer()
        spawn()
        retuneWatchTimer(force: true)
    }

    // MARK: - Tier 2 events

    /// An AX event arrived about `pid`. Never trusted for geometry — it only
    /// accelerates what the watch timer would notice within 100 ms anyway:
    /// instant motion wake for the ridden window, instant audit for anything
    /// structural (created/focused/minimized).
    func tier2Activity(pid: pid_t, note: String) {
        debugTier2WakeCount += 1
        // A watch on this app rides the stream that is already flowing, so
        // "tell me when the build finishes" costs nothing extra. Frequency
        // only: the note's name, never a window title.
        AssistantExecutor.shared.watches.noteActivity(pid: pid, now: CACurrentMediaTime())
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

    func enterFalling(vy: CGFloat, at now: TimeInterval) {
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

    func leap(to win: WorldModel.WinAK, at now: TimeInterval) {
        if case .standing(.window(win.id), _) = state { return }
        let perch = Geometry.initialPerch(windowWidth: win.frame.width,
                                          petWidth: Self.petSize.width)
        leapToPoint(CGPoint(x: win.frame.minX + perch + Self.petSize.width / 2,
                            y: win.frame.maxY), at: now)
    }

    func leapToPoint(_ target: CGPoint, at now: TimeInterval) {
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

    func land(on platform: Platform, at now: TimeInterval) {
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

    func enterStanding(_ ref: PlatformRef, offsetX: CGFloat, at now: TimeInterval) {
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

    func standingStatus(_ ref: PlatformRef) {
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

    func beginWalk(on ref: PlatformRef, dir: CGFloat, duration: TimeInterval,
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

    func beginClimb(side: CGFloat, targetY: CGFloat, at now: TimeInterval) {
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

    func step(dt: CGFloat, now: TimeInterval) {
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
    func finishReactionAnims(now: TimeInterval) {
        if clock.finished,
           [.land, .blink, .lookAround, .fidget].contains(clock.currentKind) {
            clock.play(.idle, from: sprites, at: now).map(stage.show)
        }
    }

    /// Nothing ever leaves the top of the screen: airborne arcs stop at the
    /// menu-bar/notch line (a little ceiling bonk) instead of arcing out.
    func ceilingClamp(_ s: (y: CGFloat, vy: CGFloat)) -> (y: CGFloat, vy: CGFloat) {
        // Anchor may reach the menu-bar/notch line itself — landings there
        // become ceiling hangs (body below the line), and the render layer
        // keeps upright transients pushed fully on-screen.
        let maxY = stage.clampTop(forAnchor: anchor)
        if s.y > maxY { return (maxY, min(s.vy, 0)) }
        return s
    }

    /// Upright, or hanging upside down when the edge is too close to the
    /// screen top (menu bar / notch band) for the body to fit above it.
    func standRotation(at a: CGPoint) -> CGFloat {
        let bodyTop = a.y + Self.petSize.height - Self.footOverlap
        return bodyTop > stage.clampTop(forAnchor: a) ? 180 : 0
    }

    func follow(_ ref: PlatformRef, offsetX: CGFloat, now: TimeInterval) {
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

    func walkStep(ref: PlatformRef, dir: CGFloat, until: TimeInterval,
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

    func watchTick() {
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
    func visibilityWatchdog(at now: TimeInterval) {
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

    // MARK: - Sleep mode

    func engineSleep(at now: TimeInterval) {
        nextBehaviorAt = now + 1.0
        guard !isSleeping else { return }
        isSleeping = true
        startAmbientTimer(interval: 1.2) // sleep frames are 1.15s; tick slower
        clock.play(.sleep, from: sprites, at: now).map(stage.show)
        status(immersionActive ? "Shh, you're watching something" : "Recharging")
        log(String(format: "→ sleeping (energy %.2f)", brain.needs.energy))
    }

    func engineWake(at now: TimeInterval) {
        guard isSleeping else { return }
        isSleeping = false
        startAmbientTimer()
        clock.play(.idle, from: sprites, at: now).map(stage.show)
        if case .standing(let ref, _) = state { standingStatus(ref) }
        log(String(format: "→ awake (energy %.2f)", brain.needs.energy))
    }

    // MARK: - Ambient timer

    func startAmbientTimer(interval: TimeInterval = 0.5) {
        ambientTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(150))
        t.setEventHandler { [weak self] in self?.ambientTick() }
        t.resume()
        ambientTimer = t
    }

    func ambientTick() {
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

    func setLinkRate(preferred: Float) {
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 60,
                                                         preferred: preferred)
    }

    func setLinkPaused(_ paused: Bool, now: TimeInterval) {
        guard let link, link.isPaused != paused else { return }
        if !paused { lastStepAt = now }
        link.isPaused = paused
        retuneWatchTimer()
    }

    func retuneWatchTimer(force: Bool = false) {
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

    func applyAnchor() {
        stage.place(anchor: anchor)
    }

    func status(_ s: String) { onStatus?(s) }

    /// A reaction status that routine transitions must not stomp for a bit.
    func holdStatus(_ s: String, for seconds: TimeInterval = 2.5) {
        statusHoldUntil = CACurrentMediaTime() + seconds
        onStatus?(s)
    }

    func fmt(_ p: CGPoint) -> String {
        String(format: "(%.0f, %.0f)", p.x, p.y)
    }

    func log(_ msg: String) {
        guard verbose else { return }
        print(String(format: "[%7.3f] %@", Date().timeIntervalSince(startedAt), msg))
    }
}
