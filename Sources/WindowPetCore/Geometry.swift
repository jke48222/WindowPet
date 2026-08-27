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

/// Which display a piece of UI belongs on, expressed as pure math over a list
/// of screen frames so it can be tested without a window server.
///
/// AppKit's `NSScreen.main` is "the screen with the key window", which on a
/// multi-display Mac is regularly not the screen the person is looking at. It
/// is only ever the last resort here.
public enum DisplayChoice {

    /// Index of the frame containing `point`, if any.
    public static func index(containing point: CGPoint, in frames: [CGRect]) -> Int? {
        frames.firstIndex { $0.contains(point) }
    }

    /// Index of the display a piece of UI belongs on. Preference order: the
    /// display holding `preferred` (a pinned panel origin, the pet's feet),
    /// then the display under the pointer, then `fallback` (the key screen),
    /// then the primary. Returns nil only when there are no displays at all.
    public static func index(preferred: CGPoint?, mouse: CGPoint, fallback: Int?,
                             in frames: [CGRect]) -> Int? {
        if frames.isEmpty { return nil }
        if let preferred, let hit = index(containing: preferred, in: frames) { return hit }
        if let hit = index(containing: mouse, in: frames) { return hit }
        if let fallback, frames.indices.contains(fallback) { return fallback }
        return 0
    }

    /// Index of the display a window occupies. A window can straddle two
    /// displays, so the winner is the one covering the most of it, which is
    /// the rule macOS itself uses for deciding where a window "is".
    public static func index(overlapping rect: CGRect, in frames: [CGRect]) -> Int? {
        var best: (index: Int, area: CGFloat)?
        for (index, frame) in frames.enumerated() {
            let overlap = frame.intersection(rect)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { continue }
            let area = overlap.width * overlap.height
            if area > (best?.area ?? 0) { best = (index, area) }
        }
        return best?.index
    }

    /// Clamps a panel of `size` fully inside `frame`, keeping `inset` of
    /// breathing room. This is what brings a panel back when the display it
    /// was dragged onto is unplugged: without it the origin still points into
    /// coordinates no display covers any more.
    public static func clamp(origin: CGPoint, size: CGSize, into frame: CGRect,
                             inset: CGFloat) -> CGPoint {
        // A panel larger than the display pins to the near corner rather than
        // inverting the clamp and landing off the far edge.
        let maxX = max(frame.minX + inset, frame.maxX - inset - size.width)
        let maxY = max(frame.minY + inset, frame.maxY - inset - size.height)
        return CGPoint(x: min(max(origin.x, frame.minX + inset), maxX),
                       y: min(max(origin.y, frame.minY + inset), maxY))
    }
}
