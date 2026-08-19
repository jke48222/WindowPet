import CoreGraphics

/// Coordinate math for placing the pet, kept pure so it can be unit-tested
/// without a window server.
///
/// The one trap this file exists to contain: `CGWindowListCopyWindowInfo`
/// reports bounds in *global display* coordinates — origin at the TOP-LEFT of
/// the primary display, Y increasing DOWNWARD. AppKit windows live in a global
/// space with origin at the BOTTOM-LEFT of the primary display, Y increasing
/// UPWARD. Both spaces span all displays, so one flip against the primary
/// screen's height converts correctly everywhere, including secondary displays
/// with negative coordinates.
public enum Geometry {

    /// Convert a CGWindowList rect (top-left origin) to AppKit space
    /// (bottom-left origin). `primaryScreenHeight` is the height of
    /// `NSScreen.screens[0]` — the screen whose AppKit origin is (0, 0) —
    /// NOT `NSScreen.main` (that's just the focused screen).
    public static func appKitRect(fromCGGlobal r: CGRect, primaryScreenHeight h: CGFloat) -> CGRect {
        CGRect(x: r.origin.x, y: h - r.origin.y - r.height, width: r.width, height: r.height)
    }

    /// Where a freshly-acquired pet perches: a bit right of center reads more
    /// like a creature choosing a spot than dead-center does.
    public static func initialPerch(windowWidth: CGFloat, petWidth: CGFloat) -> CGFloat {
        clampPerch(windowWidth * 0.62 - petWidth / 2, windowWidth: windowWidth, petWidth: petWidth)
    }

    /// Perch is stored as the pet's left-edge offset from the window's left
    /// edge, clamped so the pet never hangs off either end of the title bar —
    /// this is what keeps it sane during resizes.
    public static func clampPerch(_ x: CGFloat, windowWidth: CGFloat, petWidth: CGFloat) -> CGFloat {
        let margin: CGFloat = 8
        let maxX = max(margin, windowWidth - petWidth - margin)
        return min(max(x, margin), maxX)
    }

    /// Panel origin from the pet's physics anchor (feet-bottom-center).
    /// Rounded to whole points: the window server snaps origins anyway, and
    /// integral placement keeps computed and actual positions identical.
    public static func originFromAnchor(_ anchor: CGPoint, petSize: CGSize,
                                        footOverlap: CGFloat) -> CGPoint {
        CGPoint(x: (anchor.x - petSize.width / 2).rounded(),
                y: (anchor.y - footOverlap).rounded())
    }

    /// Panel origin (AppKit space) for a pet standing on the window's top edge.
    /// `footOverlap` sinks the feet a few points into the title bar so the pet
    /// reads as standing ON the window rather than hovering above it.
    public static func petOrigin(windowFrame ak: CGRect, perchOffsetX: CGFloat,
                                 petSize: CGSize, footOverlap: CGFloat) -> CGPoint {
        let x = ak.minX + clampPerch(perchOffsetX, windowWidth: ak.width, petWidth: petSize.width)
        // Whole points: the window server snaps panel origins anyway, and
        // integral placement keeps the sprite crisp. Rounding here keeps
        // computed and actual positions identical (the rig asserts on it).
        return CGPoint(x: x.rounded(), y: (ak.maxY - footOverlap).rounded())
    }
}
