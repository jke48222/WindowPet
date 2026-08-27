import AppKit
import WindowPetCore

/// Loads a Shimeji character pack (shimeji-ee layout: conf/actions.xml +
/// img/*.png) into a WindowPet SpriteSet: their art, our brain. The pack's
/// behaviors.xml is deliberately ignored — the GOBT engine drives every
/// character. Alpha masks are built from the imported frames, so imported
/// characters are immediately boopable, grabbable, and throwable.
enum ShimejiImporter {

    static let tickSeconds = 0.04 // shimeji-ee runs ~25 ticks/second

    static func load(packAt root: URL) -> (set: SpriteSet, name: String)? {
        let fm = FileManager.default
        let xmlCandidates = [
            root.appendingPathComponent("conf/actions.xml"),
            root.appendingPathComponent("actions.xml"),
        ]
        guard let xmlURL = xmlCandidates.first(where: { fm.fileExists(atPath: $0.path) }),
              let data = try? Data(contentsOf: xmlURL) else { return nil }
        let imgCandidates = [root.appendingPathComponent("img"), root]
        guard let imgRoot = imgCandidates.first(where: { fm.fileExists(atPath: $0.path) })
        else { return nil }

        let mapped = ShimejiMapping.select(from: ShimejiActionsParser.parse(xml: data))
        guard !mapped.isEmpty else { return nil }

        var imageCache: [String: CGImage] = [:]
        func image(for pose: ShimejiPose) -> CGImage? {
            var rel = pose.image
            if rel.hasPrefix("/") { rel.removeFirst() }
            if rel.hasPrefix("img/") { rel.removeFirst(4) }
            if let hit = imageCache[rel] { return hit }
            let url = imgRoot.appendingPathComponent(rel)
            guard let ns = NSImage(contentsOf: url),
                  let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { return nil }
            imageCache[rel] = cg
            return cg
        }

        var anims: [SpriteSet.Kind: SpriteSet.Anim] = [:]
        for kind in SpriteSet.Kind.allCases {
            guard let poses = mapped[kind.rawValue] else { continue }
            var frames: [SpriteSet.Frame] = []
            var durations: [TimeInterval] = []
            for pose in poses {
                guard let cg = image(for: pose) else { continue }
                frames.append(SpriteSet.Frame(image: cg,
                                              mask: SpriteSet.AlphaMask.build(from: cg)))
                durations.append(min(max(Double(pose.durationTicks) * tickSeconds, 0.06), 2.0))
            }
            guard !frames.isEmpty else { continue }
            let loops = [.idle, .walk, .fall, .sleep].contains(kind)
            anims[kind] = SpriteSet.Anim(frames: frames, durations: durations, loops: loops)
        }
        guard anims[.idle] != nil else { return nil }

        // Classic Shimeji art faces LEFT in its source frames.
        return (SpriteSet(anims: anims, facesLeft: true), root.lastPathComponent)
    }
}
