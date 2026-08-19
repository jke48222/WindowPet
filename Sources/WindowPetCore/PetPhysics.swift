import CoreGraphics

/// Cartoon physics constants + pure integration steps. AppKit convention
/// throughout: y increases UPWARD, so gravity subtracts from vy and a falling
/// pet has vy < 0. The pet's "anchor" is its feet-bottom-center point.
public enum PetPhysics {
    public static let gravity: CGFloat = 2400        // pt/s² — snappy, not floaty
    public static let terminalVelocity: CGFloat = 1500
    public static let walkSpeed: CGFloat = 55        // pt/s — a stroll

    /// One gravity step (trapezoidal — exact for constant acceleration).
    public static func fallStep(y: CGFloat, vy: CGFloat, dt: CGFloat) -> (y: CGFloat, vy: CGFloat) {
        let v2 = max(vy - gravity * dt, -terminalVelocity)
        return (y + (vy + v2) / 2 * dt, v2)
    }

    /// Ballistic launch velocity that carries the anchor from `from` to `to`
    /// in a duration scaled to the distance. Works for hops down as well as
    /// leaps up (vy just comes out smaller or negative).
    public static func leapSolution(from: CGPoint, to: CGPoint)
        -> (vx: CGFloat, vy: CGFloat, duration: CGFloat) {
        let d = hypot(to.x - from.x, to.y - from.y)
        let T = min(max(d / 700, 0.38), 0.85)
        let vx = (to.x - from.x) / T
        let vy = ((to.y - from.y) + 0.5 * gravity * T * T) / T
        return (vx, vy, T)
    }
}
