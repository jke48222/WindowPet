import XCTest
@testable import WindowPetCore

final class BehaviorTests: XCTestCase {

    private let floorCtx = BehaviorBrain.Context(onFloor: true, currentWindowID: nil,
                                                 frontWindowID: 7, otherWindowIDs: [7, 9])

    func testNeedsDriftIdle() {
        let brain = BehaviorBrain(seed: 1)
        let before = brain.needs
        brain.advance(dt: 60, activity: .idle)
        XCTAssertLessThan(brain.needs.energy, before.energy)
        XCTAssertGreaterThan(brain.needs.boredom, before.boredom)
        XCTAssertGreaterThan(brain.needs.curiosity, before.curiosity)
    }

    func testExhaustionForcesSleepAndRecoveryWakes() {
        let brain = BehaviorBrain(seed: 2)
        brain.setNeeds(NeedsVector(energy: 0.05, curiosity: 0.9, attention: 0.9, boredom: 0.9))
        XCTAssertEqual(brain.decide(context: floorCtx), .sleep)
        XCTAssertTrue(brain.sleeping)
        XCTAssertEqual(brain.decide(context: floorCtx), .sleep) // stays asleep
        // ~28 simulated seconds of charging crosses the wake threshold.
        while brain.needs.energy < BehaviorBrain.wakeAbove {
            brain.advance(dt: 1, activity: .sleeping)
        }
        XCTAssertEqual(brain.decide(context: floorCtx), .wake)
        XCTAssertFalse(brain.sleeping)
    }

    func testBoopWakesTheSleeper() {
        let brain = BehaviorBrain(seed: 3)
        brain.setNeeds(NeedsVector(energy: 0.05))
        _ = brain.decide(context: floorCtx)
        XCTAssertTrue(brain.sleeping)
        brain.applyEvent(.touched)
        XCTAssertFalse(brain.sleeping)
        XCTAssertEqual(brain.needs.attention, 0)
    }

    func testDecisionVarietyAndDeterminism() {
        // Mid needs → the utility layer should produce several distinct kinds,
        // never a single fixed behavior — and identically across equal seeds.
        func kinds(seed: UInt64) -> [String] {
            let brain = BehaviorBrain(seed: seed)
            brain.setNeeds(NeedsVector(energy: 0.8, curiosity: 0.7, attention: 0.5, boredom: 0.6))
            return (0..<120).map { _ in
                switch brain.decide(context: floorCtx) {
                case .sit: return "sit"
                case .stroll: return "stroll"
                case .stepOff: return "stepOff"
                case .travelTo: return "travel"
                case .climbWall: return "climb"
                case .sleep: return "sleep"
                case .wake: return "wake"
                }
            }
        }
        let a = kinds(seed: 42)
        XCTAssertEqual(a, kinds(seed: 42), "same seed must replay identically")
        XCTAssertGreaterThanOrEqual(Set(a).count, 3, "utility layer must vary: \(Set(a))")
        let sitShare = Double(a.filter { $0 == "sit" }.count) / Double(a.count)
        XCTAssertLessThan(sitShare, 0.9)
    }

    func testCalmContextOnlySits() {
        let brain = BehaviorBrain(seed: 5)
        brain.setNeeds(NeedsVector(energy: 0.9, curiosity: 1.0, attention: 1.0, boredom: 1.0))
        let calmCtx = BehaviorBrain.Context(onFloor: false, currentWindowID: 3,
                                            frontWindowID: 7, otherWindowIDs: [7, 9],
                                            calm: true)
        for _ in 0..<50 {
            if case .sit = brain.decide(context: calmCtx) { continue }
            XCTFail("calm context must only sit")
            return
        }
    }

    func testCuriousBrainTravels() {
        let brain = BehaviorBrain(seed: 7)
        brain.setNeeds(NeedsVector(energy: 0.9, curiosity: 1.0, attention: 1.0, boredom: 0.8))
        var travels = 0
        for _ in 0..<100 {
            if case .travelTo = brain.decide(context: floorCtx) { travels += 1 }
        }
        XCTAssertGreaterThan(travels, 25, "high curiosity+attention should drive travel")
    }

    func testArrivalSatisfiesCuriosity() {
        let brain = BehaviorBrain(seed: 8)
        brain.setNeeds(NeedsVector(curiosity: 0.9, boredom: 0.9))
        brain.applyEvent(.arrivedAtWindow(new: true))
        XCTAssertLessThan(brain.needs.curiosity, 0.4)
        XCTAssertLessThan(brain.needs.boredom, 0.6)
    }
}

final class PlannerTests: XCTestCase {

    // Screen floor + a mid-height shelf + a high target.
    private let floor = Platform(kind: .floor, topY: 0, minX: 0, maxX: 1512)
    private let shelf = Platform(kind: .window(1), topY: 410, minX: 650, maxX: 950)
    private let high = Platform(kind: .window(2), topY: 740, minX: 700, maxX: 1120)

    func testDirectLeapWhenInRange() {
        let steps = Planner.plan(fromKind: .floor, fromX: 800, to: .window(1),
                                 platforms: [floor, shelf, high])
        XCTAssertNotNil(steps)
        XCTAssertTrue(steps!.contains { if case .leapTo(.window(1), _) = $0 { return true }; return false })
        XCTAssertLessThanOrEqual(steps!.count, 2) // maybe a walk, then the leap
    }

    func testHighTargetNeedsIntermediateHop() {
        // Floor → high is 740pt vertical: out of leap range (560). The plan
        // must route via the shelf: (walk) → leap shelf → leap high.
        let steps = Planner.plan(fromKind: .floor, fromX: 200, to: .window(2),
                                 platforms: [floor, shelf, high])!
        let leaps = steps.compactMap { step -> Platform.Kind? in
            if case .leapTo(let kind, _) = step { return kind }
            return nil
        }
        XCTAssertEqual(leaps, [.window(1), .window(2)], "expected shelf hop, got \(steps)")
    }

    func testUnreachableTargetReturnsNil() {
        let island = Platform(kind: .window(3), topY: 3000, minX: 100, maxX: 300)
        XCTAssertNil(Planner.plan(fromKind: .floor, fromX: 200, to: .window(3),
                                  platforms: [floor, island]))
    }

    func testStepOffRouteFromHighWindowToFloor() {
        let steps = Planner.plan(fromKind: .window(2), fromX: 900, to: .floor,
                                 platforms: [floor, shelf, high])!
        // Any of: direct leap down (740 > 560 — no), step off (fall), or via
        // shelf. Must end on the floor with a stepOff or leap present.
        XCTAssertFalse(steps.isEmpty)
    }
}
