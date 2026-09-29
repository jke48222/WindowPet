import CoreGraphics
import Foundation

// Pure decisions the engine and the stage make about displays, the mouse
// hole, reduced motion and the speech bubble. Nothing here touches AppKit, so
// each piece is exercised with plain rectangles and numbers in
// DisplayGeometryTests. Presence lives in ReactionPolicy.

/// Multi-display geometry. Displays can sit beside one another, above one
/// another, or at any offset, so "the floor under Rusty" and "the ceiling over
/// Rusty" depend on both coordinates, never on x alone.
public enum DisplayGeometry {

    /// Index of the floor Rusty stands on or falls toward from `point`: among
    /// the floors whose span contains x, the highest one at or below the
    /// point. Stacked displays share x ranges, so matching on x alone put him
    /// on the wrong display's floor.
    ///
    /// When no floor spans x, the horizontally nearest floor wins; when he is
    /// below every floor that spans x (a failsafe case), the lowest of them.
    public static func floorIndex(under point: CGPoint, floors: [CGRect],
                           tolerance: CGFloat = 2) -> Int? {
        guard !floors.isEmpty else { return nil }
        let spanning = floors.indices.filter {
            floors[$0].minX <= point.x && point.x <= floors[$0].maxX
        }
        let candidates: [Int]
        if spanning.isEmpty {
            let gap: (CGRect) -> CGFloat = { r in
                point.x < r.minX ? r.minX - point.x : max(0, point.x - r.maxX)
            }
            let nearest = floors.indices.map { gap(floors[$0]) }.min() ?? 0
            candidates = floors.indices.filter { gap(floors[$0]) <= nearest + 0.5 }
        } else {
            candidates = spanning
        }
        let below = candidates.filter { floors[$0].minY <= point.y + tolerance }
        if let best = below.max(by: { floors[$0].minY < floors[$1].minY }) { return best }
        return candidates.min { floors[$0].minY < floors[$1].minY }
    }

    /// Index of the display region containing `point` (edges inclusive), or
    /// the nearest one.
    public static func regionIndex(containing point: CGPoint, regions: [CGRect]) -> Int? {
        guard !regions.isEmpty else { return nil }
        if let i = regions.firstIndex(where: { contains($0, point) }) { return i }
        return regions.indices.min { distance(point, regions[$0]) < distance(point, regions[$1]) }
    }

    /// Highest y an airborne anchor at `point` may reach. A menu bar is a
    /// ceiling only when no display sits directly on top of that one over
    /// this x; with a display above, the ceiling is that display's (and so
    /// on up the stack).
    ///
    /// `regions` are display rects (horizontal extent of the usable area,
    /// vertical extent of the full display); `clampTops[i]` is the menu-bar
    /// and notch line of region i.
    public static func ceiling(above point: CGPoint, regions: [CGRect],
                        clampTops: [CGFloat], fallback: CGFloat = 944) -> CGFloat {
        guard var i = regionIndex(containing: point, regions: regions),
              clampTops.indices.contains(i) else { return fallback }
        var visited: Set<Int> = [i]
        while let up = regions.indices.first(where: { j in
            !visited.contains(j)
                && abs(regions[j].minY - regions[i].maxY) <= 1
                && regions[j].minX <= point.x && point.x <= regions[j].maxX
        }) {
            visited.insert(up)
            i = up
        }
        return clampTops.indices.contains(i) ? clampTops[i] : fallback
    }

    /// One frame of horizontal airborne motion. Rusty may cross into any
    /// display that continues the desktop at his height; he stops ("thud")
    /// only at an edge with no display beyond it. Returns the new x and
    /// whether he hit a wall.
    ///
    /// `regions` are the displays' full frames and decide where the desktop
    /// continues. `walls[i]`, when given, is display i's usable area; its
    /// sides are where he thuds (a Dock on the side is a wall, as before).
    public static func airborneX(from x: CGFloat, to proposed: CGFloat, atY y: CGFloat,
                          margin: CGFloat, regions: [CGRect],
                          walls: [CGRect]? = nil) -> (x: CGFloat, hitWall: Bool) {
        guard !regions.isEmpty, proposed != x else { return (proposed, false) }
        let dir: CGFloat = proposed > x ? 1 : -1
        let leading = CGPoint(x: proposed + dir * margin, y: y)
        guard let i = regionIndex(containing: CGPoint(x: x, y: y), regions: regions) else {
            return (proposed, false)
        }
        let wall = walls.flatMap { $0.indices.contains(i) ? $0[i] : nil } ?? regions[i]
        // Still inside this display's walls: free flight.
        if wall.minX <= leading.x && leading.x <= wall.maxX { return (proposed, false) }
        // Past this display's wall, but another display continues the
        // desktop there: fly on into it.
        if regions.indices.contains(where: { $0 != i && contains(regions[$0], leading) }) {
            return (proposed, false)
        }
        let lo = wall.minX + margin, hi = wall.maxX - margin
        guard lo <= hi else { return (wall.midX, true) }
        return (min(max(proposed, lo), hi), true)
    }

    private static func contains(_ r: CGRect, _ p: CGPoint) -> Bool {
        r.minX <= p.x && p.x <= r.maxX && r.minY <= p.y && p.y <= r.maxY
    }

    private static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }
}

/// Which overlay panels accept mouse events. Exactly one panel, the one
/// drawing Rusty, may accept them, and only while the hole is open; every
/// other panel stays click-through.
public enum HolePolicy {
    public static func ignoresMouseEvents(open: Bool, currentIndex: Int, count: Int) -> [Bool] {
        (0..<max(0, count)).map { !(open && $0 == currentIndex) }
    }

    /// The flags must be rewritten when the hole opens or closes, and also
    /// when Rusty is on another display than the one they were written for.
    /// The exception is a grab in flight: its drag events belong to the
    /// panel that took the mouse-down, which keeps them until release, so the
    /// flags follow him to the new display once he is let go.
    public static func needsReapply(open: Bool, appliedOpen: Bool,
                             currentIndex: Int, appliedIndex: Int?,
                             grabInFlight: Bool) -> Bool {
        if open != appliedOpen || appliedIndex == nil { return true }
        return appliedIndex != currentIndex && !grabInFlight
    }
}

/// What Rusty may do on his own when the user has asked macOS to reduce
/// motion. He still rides a window the user drags and falls when one closes
/// (motion the user caused), but he does not wander, travel, climb or hop on
/// his own initiative.
public enum MotionPolicy {
    public enum Whim: Equatable, Sendable {
        case sit, stroll, stepOff, travel, climb, sleep, wake
    }

    public static func allows(_ whim: Whim, reduceMotion: Bool) -> Bool {
        guard reduceMotion else { return true }
        switch whim {
        case .sit, .sleep, .wake: return true
        case .stroll, .stepOff, .travel, .climb: return false
        }
    }
}

/// Fits text into the speech bubble. When the text is too tall, the head is
/// dropped and the tail kept: a growing transcript must keep showing its
/// newest words, which are the ones being spoken.
public enum BubbleFit {
    public static let ellipsis = "…"

    /// `height` measures a candidate string at the bubble's fixed width.
    /// Returns `text` when it fits, else "…" plus the longest suffix that
    /// fits, starting at a word boundary when one is close.
    public static func tail(of text: String, maxHeight: CGFloat,
                     height: (String) -> CGFloat) -> String {
        guard height(text) > maxHeight else { return text }
        let chars = Array(text)
        // Binary search the longest suffix length that fits.
        var lo = 0, hi = chars.count
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            let candidate = ellipsis + String(chars[(chars.count - mid)...])
            if height(candidate) <= maxHeight { lo = mid } else { hi = mid - 1 }
        }
        guard lo > 0 else { return ellipsis }
        var start = chars.count - lo
        // Start on a word boundary if one is within a few characters, so the
        // bubble does not open on half a word.
        if start > 0, !chars[start - 1].isWhitespace {
            let limit = min(chars.count, start + 16)
            if let space = (start..<limit).first(where: { chars[$0].isWhitespace }),
               space + 1 < chars.count {
                start = space + 1
            }
        }
        return ellipsis + String(chars[start...])
    }
}
