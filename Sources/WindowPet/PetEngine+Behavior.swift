import AppKit
import QuartzCore
import WindowPetCore

/// The behavior layer: the goal-oriented brain in WindowPetCore decides what
/// Rusty wants, and these methods turn a decision into a plan of concrete
/// steps the engine executes frame by frame.
extension PetEngine {

    func behave(from ref: PlatformRef, at now: TimeInterval) {
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

    func execute(_ choice: BehaviorBrain.Choice, from ref: PlatformRef,
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

    func platformKind(of ref: PlatformRef) -> Platform.Kind {
        switch ref {
        case .window(let id): return .window(id)
        case .floor: return .floor
        }
    }

    func startTravel(to id: CGWindowID, from ref: PlatformRef, at now: TimeInterval) {
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

    func runNextPlanStep(at now: TimeInterval) {
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
            place(at: CGPoint(x: x, y: anchor.y))
            enterFalling(vy: 0, at: now)
        }
    }

    func advanceTravel(from ref: PlatformRef, at now: TimeInterval) {
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

    func finishTravel(success: Bool, at now: TimeInterval) {
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

    func startStepOffPlan(from ref: PlatformRef, at now: TimeInterval) {
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

    func startClimbPlan(at now: TimeInterval) {
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
}
