import CoreGraphics

/// Small GOAP-style planner over the platform graph: BE-ON(target) via
/// walk / ranged-leap / step-off actions. Multi-step plans are what make the
/// pet look like it has intentions ("walk under it, then jump") instead of
/// teleporting. If no ranged plan exists the caller may fall back to a single
/// direct cartoon leap — reachability must never regress.
public enum Planner {

    public enum Step: Equatable {
        case walkTo(x: CGFloat)
        case leapTo(kind: Platform.Kind, x: CGFloat)
        case stepOffTo(x: CGFloat) // nudge past the edge and fall at this x
    }

    public struct Config {
        public let leapRange: CGFloat
        public let petHalfWidth: CGFloat
        public init(leapRange: CGFloat = 560, petHalfWidth: CGFloat = 32) {
            self.leapRange = leapRange
            self.petHalfWidth = petHalfWidth
        }
    }

    private struct Node {
        let kind: Platform.Kind
        let x: CGFloat
        let steps: [Step]
        let cost: CGFloat
    }

    /// Breadth-limited best-first search, depth ≤ 4. Deterministic.
    public static func plan(fromKind: Platform.Kind, fromX: CGFloat,
                            to targetKind: Platform.Kind,
                            platforms: [Platform],
                            config: Config = Config()) -> [Step]? {
        guard let targetPlatform = platforms.first(where: { $0.kind == targetKind }) else { return nil }
        let targetX = perchX(on: targetPlatform, config: config)

        var frontier = [Node(kind: fromKind, x: fromX, steps: [], cost: 0)]
        var visited: Set<String> = [key(fromKind, fromX)]
        var best: Node?

        for _ in 0..<4 { // depth
            var next: [Node] = []
            for node in frontier {
                if node.kind == targetKind {
                    if best == nil || node.cost < best!.cost { best = node }
                    continue
                }
                next.append(contentsOf: expand(node, platforms: platforms,
                                               targetKind: targetKind, targetX: targetX,
                                               config: config, visited: &visited))
            }
            if next.isEmpty { break }
            frontier = next.sorted { $0.cost < $1.cost }
            if frontier.count > 24 { frontier = Array(frontier.prefix(24)) }
        }
        for node in frontier where node.kind == targetKind {
            if best == nil || node.cost < best!.cost { best = node }
        }
        return best?.steps
    }

    private static func expand(_ node: Node, platforms: [Platform],
                               targetKind: Platform.Kind, targetX: CGFloat,
                               config: Config, visited: inout Set<String>) -> [Node] {
        guard let here = platforms.first(where: {
            $0.kind == node.kind && $0.minX - 14 <= node.x && node.x <= $0.maxX + 14
        }) ?? platforms.first(where: { $0.kind == node.kind }) else { return [] }

        var out: [Node] = []
        let hereY = here.topY

        // Leap to any platform whose perch (or aligned point) is in range.
        for p in platforms where p.kind != node.kind {
            let candidates = [perchX(on: p, config: config),
                              min(max(node.x, p.minX + config.petHalfWidth),
                                  p.maxX - config.petHalfWidth)]
            for cx in candidates {
                let d = hypot(cx - node.x, p.topY - hereY)
                guard d <= config.leapRange else { continue }
                let k = key(p.kind, cx)
                guard !visited.contains(k) else { continue }
                visited.insert(k)
                out.append(Node(kind: p.kind, x: cx,
                                steps: node.steps + [.leapTo(kind: p.kind, x: cx)],
                                cost: node.cost + d / 400 + 0.4))
                break // one candidate per platform is plenty
            }
        }

        // Walk along the current platform toward a launch point under/over
        // the target, then reconsider from there.
        let walkX = min(max(targetX, here.minX + config.petHalfWidth),
                        here.maxX - config.petHalfWidth)
        if abs(walkX - node.x) > 24 {
            let k = key(node.kind, walkX)
            if !visited.contains(k) {
                visited.insert(k)
                out.append(Node(kind: node.kind, x: walkX,
                                steps: node.steps + [.walkTo(x: walkX)],
                                cost: node.cost + abs(walkX - node.x) / 300))
            }
        }

        // Step off a window edge and fall to whatever's below.
        if case .window = node.kind {
            for edgeX in [here.minX - 12, here.maxX + 12] {
                guard let landing = Terrain.landingPlatform(in: platforms, x: edgeX,
                                                            fromY: hereY - 0.6,
                                                            toY: -100_000) else { continue }
                let k = key(landing.kind, edgeX)
                guard !visited.contains(k) else { continue }
                visited.insert(k)
                let walkEdge: Step = .walkTo(x: edgeX < here.minX ? here.minX + config.petHalfWidth - 8
                                                                  : here.maxX - config.petHalfWidth + 8)
                out.append(Node(kind: landing.kind, x: edgeX,
                                steps: node.steps + [walkEdge, .stepOffTo(x: edgeX)],
                                cost: node.cost + 0.8))
            }
        }
        return out
    }

    public static func perchX(on p: Platform, config: Config) -> CGFloat {
        let x = p.minX + p.width * 0.62
        return min(max(x, p.minX + config.petHalfWidth), p.maxX - config.petHalfWidth)
    }

    private static func key(_ kind: Platform.Kind, _ x: CGFloat) -> String {
        let k: String
        switch kind {
        case .window(let id): k = "w\(id)"
        case .floor: k = "f"
        }
        return "\(k):\(Int(x / 40))" // 40pt buckets keep the search tiny
    }
}
