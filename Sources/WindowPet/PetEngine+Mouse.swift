import AppKit
import QuartzCore
import WindowPetCore

/// Direct manipulation: the click-through hole that follows the cursor, and
/// picking Rusty up, flinging him, and putting him down.
extension PetEngine {

    func refreshHole() {
        stage.updateHole(mouse: NSEvent.mouseLocation, forceOpen: isGrabbed)
    }

    func grab(at p: CGPoint) {
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

    func drag(to p: CGPoint) {
        guard case .grabbed = state else { return }
        let now = CACurrentMediaTime()
        dragSamples.append((now, p))
        if dragSamples.count > 8 { dragSamples.removeFirst() }
        // Hold the pet by its body: feet hang below the cursor.
        place(at: CGPoint(x: p.x, y: p.y - Self.petSize.height / 2 + Self.footOverlap))
        applyAnchor()
    }

    func mouseReleased(at p: CGPoint) {
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

    func release(at p: CGPoint, velocity v: CGPoint) {
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
    func boop(at now: TimeInterval) {
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
}
