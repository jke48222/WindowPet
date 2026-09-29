import AppKit
import QuartzCore
import WindowPetCore

/// Reactions, every one of which derives from observable system state rather
/// than a timer firing at random: input idleness, battery, a distracting app
/// quitting, coming back to the machine.
extension PetEngine {

    /// The pointer moved: definitely input, right now. Lets the greeting
    /// land the moment the user reaches for the mouse instead of on the next
    /// watch tick.
    func noteUserInput() {
        presenceSample(idle: 0, at: CACurrentMediaTime())
    }

    /// Seconds since the last input of any kind in this login session: keys,
    /// scrolling, trackpad, pointer and clicks. The system keeps this clock;
    /// reading it needs no permission and sees no content.
    static func systemIdleSeconds() -> TimeInterval {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    /// Presence from the system idle clock. Away means no input of any kind
    /// for the threshold, so typing or scrolling without touching the pointer
    /// never counts as leaving. Return is the idle clock going back.
    func presenceSample(idle: TimeInterval, at now: TimeInterval) {
        // Typing a password at the lock screen is not coming back to Rusty.
        // resume() accounts for the time away instead.
        guard stateName != "suspended" else { return }
        let previous = lastIdleSample
        lastIdleSample = idle
        lastUserInputAt = now - idle
        if userAway {
            guard ReactionPolicy.inputResumed(previousIdle: previous, idle: idle) else { return }
            userAway = false
            // The idle clock just before this input is how long they were gone.
            let away = previous
            if greetingEnabled && reactionsEnabled
                && ReactionPolicy.isReturnGreeting(awaySeconds: away) {
                greet(afterAway: away)
            }
        } else if ReactionPolicy.isAway(idleSeconds: idle) {
            userAway = true // greeting fires when input resumes
        }
    }

    /// How long a greeting that came due mid-fall may wait for a landing.
    static let pendingGreetingWindow: TimeInterval = 10

    /// Called on resume, before anything samples the idle clock again. The
    /// time away is the idle clock at suspend plus the wall-clock time spent
    /// locked or asleep. Past the threshold, the user counts as away with
    /// that much idle behind them, so the next input (the first pointer
    /// move, or the unlock itself) is what earns "Welcome back!".
    func notePresenceAcrossSuspend() {
        guard let since = suspendedAtWall else { return }
        suspendedAtWall = nil
        let away = ReactionPolicy.awayAcrossSuspend(idleAtSuspend: idleAtSuspend,
                                                    suspendedFor: Date().timeIntervalSince(since))
        if ReactionPolicy.isAway(idleSeconds: away) {
            userAway = true
            lastIdleSample = away
        }
    }

    func reactionsTick(at now: TimeInterval) {
        presenceSample(idle: Self.systemIdleSeconds(), at: now)

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
              !focusCalm, MotionPolicy.allows(.travel, reduceMotion: reduceMotion) else { return }
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

    func startImmersionRetreat(at now: TimeInterval) {
        log("immersion detected — retreating to the floor")
        holdStatus("Shh, you're watching something", for: 4)
        travelTargetWindow = nil
        travelReplanUsed = false
        let floor = world.floorPlatform(under: anchor)
        // Nap a short shuffle toward the nearest screen edge — out of the
        // way without a cross-screen trek.
        let towardEdge: CGFloat = (anchor.x - floor.minX < floor.maxX - anchor.x) ? -60 : 60
        pendingNapAtX = min(max(anchor.x + towardEdge, floor.minX + 40), floor.maxX - 40)
        if case .standing(let ref, _) = state, ref != .floor {
            travelPlan = Planner.plan(fromKind: platformKind(of: ref), fromX: anchor.x, fromY: anchor.y,
                                      to: .floor, platforms: world.platforms) ?? []
            if travelPlan.isEmpty {
                place(at: CGPoint(x: anchor.x + 12, y: anchor.y))
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

    /// A small joyful hop in place (celebrations, greetings). With Reduce
    /// Motion on it is a squash where he stands instead: the same
    /// acknowledgment without leaving the ground.
    func hop(at now: TimeInterval) {
        switch state {
        case .standing, .walking: break
        default: return
        }
        if reduceMotion {
            celebrationHops = 0
            if case .standing = state {
                clock.play(.land, from: sprites, at: now).map(stage.show)
            }
            return
        }
        state = .leaping(vx: paceDir * 24, vy: 300, endAt: now + 1.4)
        clock.play(.jump, from: sprites, at: now).map(stage.show)
        lastMotionAt = now
        setLinkRate(preferred: 60)
        setLinkPaused(false, now: now)
    }

    func greet(afterAway away: TimeInterval) {
        let now = CACurrentMediaTime()
        guard stateName == "standing" || isSleeping else {
            // Mid-fall or mid-walk (just after an unlock he is still dropping
            // in): hold it for the landing rather than lose it.
            if stateName != "suspended" { pendingGreeting = (away, now) }
            return
        }
        pendingGreeting = nil
        if isSleeping { engineWake(at: now) }
        brain.applyEvent(.userReturned)
        celebrationHops = 1
        hop(at: now)
        holdStatus("Welcome back!")
        log(String(format: "→ greeting (away %.0fs)", away))
    }

    func celebrate(appName: String) {
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
}
