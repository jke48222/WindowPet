import XCTest
@testable import WindowPetCore

final class PhysicsTests: XCTestCase {

    func testFallStepIntegratesGravityAndClampsTerminal() {
        var y: CGFloat = 1000, vy: CGFloat = 0
        (y, vy) = PetPhysics.fallStep(y: y, vy: vy, dt: 0.1)
        XCTAssertEqual(vy, -240, accuracy: 0.001)          // g·dt
        XCTAssertEqual(y, 1000 - 12, accuracy: 0.001)      // ½·g·dt²
        for _ in 0..<50 { (y, vy) = PetPhysics.fallStep(y: y, vy: vy, dt: 0.1) }
        XCTAssertEqual(vy, -PetPhysics.terminalVelocity)   // clamped
    }

    /// The leap solver's launch velocity, integrated with the same fallStep
    /// the engine uses, must arrive at the target (up-leaps and hops down).
    func testLeapSolutionLandsOnTarget() {
        for target in [CGPoint(x: 700, y: 600), CGPoint(x: 100, y: 150), CGPoint(x: 420, y: 300)] {
            let from = CGPoint(x: 400, y: 300)
            let sol = PetPhysics.leapSolution(from: from, to: target)
            var p = from, vy = sol.vy
            var t: CGFloat = 0
            while t < sol.duration {
                let dt = min(CGFloat(1.0 / 120.0), sol.duration - t)
                p.x += sol.vx * dt
                let s = PetPhysics.fallStep(y: p.y, vy: vy, dt: dt)
                p.y = s.y; vy = s.vy
                t += dt
            }
            XCTAssertEqual(p.x, target.x, accuracy: 1.5, "x for \(target)")
            XCTAssertEqual(p.y, target.y, accuracy: 1.5, "y for \(target)")
        }
    }

    func testLeapDurationScalesWithDistanceWithinBounds() {
        let short = PetPhysics.leapSolution(from: .zero, to: CGPoint(x: 40, y: 0))
        let far = PetPhysics.leapSolution(from: .zero, to: CGPoint(x: 4000, y: 0))
        XCTAssertEqual(short.duration, 0.38)
        XCTAssertEqual(far.duration, 0.85)
    }
}
