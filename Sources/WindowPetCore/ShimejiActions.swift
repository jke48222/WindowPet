import Foundation

/// One frame of a Shimeji action: image path (relative to the pack's img/
/// root, usually with a leading slash) and duration in Shimeji ticks (~40 ms).
public struct ShimejiPose: Equatable {
    public let image: String
    public let durationTicks: Int
    public init(image: String, durationTicks: Int) {
        self.image = image
        self.durationTicks = durationTicks
    }
}

/// Parses a shimeji-ee `conf/actions.xml` (English schema) into
/// actionName(lowercased) → poses of its FIRST <Animation> block. Tolerant:
/// any root element, namespaces ignored, Embedded/composite actions read the
/// same as simple ones, ActionReferences skipped (no poses).
public final class ShimejiActionsParser: NSObject, XMLParserDelegate {

    public static func parse(xml: Data) -> [String: [ShimejiPose]] {
        let p = ShimejiActionsParser()
        let parser = XMLParser(data: xml)
        parser.delegate = p
        parser.shouldProcessNamespaces = false
        parser.parse()
        return p.actions
    }

    private var actions: [String: [ShimejiPose]] = [:]
    private var currentAction: String?
    private var currentPoses: [ShimejiPose] = []
    private var animationDepth = 0
    private var sawAnimationForAction = false

    public func parser(_ parser: XMLParser, didStartElement name: String,
                       namespaceURI: String?, qualifiedName: String?,
                       attributes attrs: [String: String]) {
        let element = name.components(separatedBy: ":").last ?? name
        switch element {
        case "Action":
            currentAction = attrs["Name"]
            currentPoses = []
            sawAnimationForAction = false
        case "Animation":
            animationDepth += 1
        case "Pose":
            // Only the action's first animation block counts.
            guard currentAction != nil, animationDepth > 0, !sawAnimationForAction || !currentPoses.isEmpty || true else { return }
            guard !sawAnimationForAction else { return }
            if let image = attrs["Image"] {
                let ticks = Int(attrs["Duration"] ?? "") ?? 5
                currentPoses.append(ShimejiPose(image: image, durationTicks: ticks))
            }
        default:
            break
        }
    }

    public func parser(_ parser: XMLParser, didEndElement name: String,
                       namespaceURI: String?, qualifiedName: String?) {
        let element = name.components(separatedBy: ":").last ?? name
        switch element {
        case "Animation":
            animationDepth -= 1
            if animationDepth == 0, currentAction != nil, !currentPoses.isEmpty {
                sawAnimationForAction = true
            }
        case "Action":
            if let action = currentAction, !currentPoses.isEmpty {
                let key = action.lowercased()
                if actions[key] == nil { actions[key] = currentPoses }
            }
            currentAction = nil
            currentPoses = []
            sawAnimationForAction = false
        default:
            break
        }
    }
}

/// Maps Shimeji action names onto WindowPet animation kinds, with fallback
/// chains — packs vary in which actions they define.
public enum ShimejiMapping {
    public static let alternatives: [(kind: String, names: [String])] = [
        ("idle", ["stand", "sit", "sitting"]),
        ("walk", ["walk"]),
        ("fall", ["falling", "fall", "fallwithie"]),
        ("land", ["bouncing", "bounce", "landing"]),
        ("jump", ["pinched", "dragging", "jump", "jumping"]),
        ("sleep", ["lie", "liedown", "sprawl", "sit", "sitting"]),
        ("blink", []),
    ]

    /// kind → poses. Missing kinds fall back: land→fall, jump→fall,
    /// sleep→idle, blink→idle, and ultimately idle's first pose.
    public static func select(from actions: [String: [ShimejiPose]]) -> [String: [ShimejiPose]] {
        var out: [String: [ShimejiPose]] = [:]
        for (kind, names) in alternatives {
            if let hit = names.compactMap({ actions[$0] }).first {
                out[kind] = hit
            }
        }
        guard let idle = out["idle"] ?? actions.values.first else { return [:] }
        out["idle"] = idle
        let fallbacks: [(String, String)] = [("fall", "idle"), ("walk", "idle"),
                                             ("land", "fall"), ("jump", "fall"),
                                             ("sleep", "idle"), ("blink", "idle")]
        for (kind, from) in fallbacks where out[kind] == nil {
            out[kind] = [out[from]?.first ?? idle[0]]
        }
        return out
    }
}
