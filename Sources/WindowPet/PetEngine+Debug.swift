import AppKit
import QuartzCore
import WindowPetCore

/// The engine's inspection surface: the read-only state TestRig asserts on and
/// the hooks `--diag`, `--rig`, and `--bench` drive it with. Split out from the
/// engine proper so the production behavior and the test scaffolding are not
/// interleaved in one file.
extension PetEngine {

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
        place(at: CGPoint(x: (f.minX + f.maxX) / 2, y: f.topY + 140))
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

    var isGrabbed: Bool {
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
}
