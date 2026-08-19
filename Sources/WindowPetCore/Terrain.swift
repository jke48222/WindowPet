import CoreGraphics

/// A standable surface in AppKit coordinates: an exposed segment of a window's
/// top edge, or a screen's floor (visibleFrame bottom).
public struct Platform: Equatable {
    public enum Kind: Equatable {
        case window(UInt32)   // CGWindowID
        case floor
    }
    public let kind: Kind
    public let topY: CGFloat
    public let minX: CGFloat
    public let maxX: CGFloat

    public init(kind: Kind, topY: CGFloat, minX: CGFloat, maxX: CGFloat) {
        self.kind = kind
        self.topY = topY
        self.minX = minX
        self.maxX = maxX
    }
    public var width: CGFloat { maxX - minX }
}

/// Turns the Tier-1 window list into terrain: which stretches of which top
/// edges are actually exposed, given z-order. The window layout is a platformer
/// level; this is the level geometry.
public enum Terrain {

    /// `windowsFrontToBack` must be in z-order, index 0 frontmost, AppKit
    /// coords. A window in front occludes the part of a lower window's top
    /// edge it overlaps — the pet shouldn't stand on a hidden title bar.
    public static func exposedPlatforms(windowsFrontToBack: [(id: UInt32, frame: CGRect)],
                                        floors: [CGRect],
                                        minSegmentWidth: CGFloat = 24) -> [Platform] {
        var result: [Platform] = []
        for (i, w) in windowsFrontToBack.enumerated() {
            let top = w.frame.maxY
            var segments: [(CGFloat, CGFloat)] = [(w.frame.minX, w.frame.maxX)]
            for j in 0..<i {
                let o = windowsFrontToBack[j].frame
                // The occluder hides the standing spot if it straddles the
                // line just below the top edge (where the feet touch).
                guard o.minY < top - 4, o.maxY > top - 4 else { continue }
                segments = subtract(segments, (o.minX, o.maxX))
                if segments.isEmpty { break }
            }
            for s in segments where s.1 - s.0 >= minSegmentWidth {
                result.append(Platform(kind: .window(w.id), topY: top, minX: s.0, maxX: s.1))
            }
        }
        for f in floors {
            result.append(Platform(kind: .floor, topY: f.minY, minX: f.minX, maxX: f.maxX))
        }
        return result
    }

    /// Highest platform whose top edge lies in the vertical band swept this
    /// frame (fromY ≥ topY ≥ toY) at horizontal position x — i.e., what the
    /// falling pet hits first.
    public static func landingPlatform(in platforms: [Platform], x: CGFloat,
                                       fromY: CGFloat, toY: CGFloat) -> Platform? {
        platforms
            .filter { $0.minX <= x && x <= $0.maxX && $0.topY <= fromY + 0.5 && $0.topY >= toY }
            .max { $0.topY < $1.topY }
    }

    static func subtract(_ segs: [(CGFloat, CGFloat)], _ cut: (CGFloat, CGFloat)) -> [(CGFloat, CGFloat)] {
        var out: [(CGFloat, CGFloat)] = []
        for s in segs {
            if cut.1 <= s.0 || cut.0 >= s.1 { out.append(s); continue }
            if cut.0 > s.0 { out.append((s.0, cut.0)) }
            if cut.1 < s.1 { out.append((cut.1, s.1)) }
        }
        return out
    }
}
