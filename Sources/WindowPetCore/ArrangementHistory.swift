import CoreGraphics
import Foundation

/// Putting the windows back.
///
/// The second time anyone uses a layout they move five windows and want the
/// old arrangement back. Storing the frames themselves rather than the slots
/// they were nearest to matters: a window that was deliberately at an odd size
/// returns to that odd size instead of being tidied into a half.
public struct RememberedFrame: Equatable, Sendable {
    public let app: String
    /// The frame in Accessibility coordinates, which is what puts it back.
    public let frame: CGRect

    public init(app: String, frame: CGRect) {
        self.app = app
        self.frame = frame
    }
}

public struct ArrangementHistory: Equatable, Sendable {

    /// Deep enough to undo a session's fiddling, shallow enough that it is
    /// never a second window manager.
    public static let maxDepth = 10

    public private(set) var steps: [[RememberedFrame]] = []

    public init() {}

    public var canUndo: Bool { !steps.isEmpty }

    /// Records where windows were, before moving them. An empty record is
    /// dropped: an arrangement that moved nothing is not an undo step, and
    /// leaving it in would make the first undo do nothing at all.
    public mutating func record(_ frames: [RememberedFrame]) {
        guard !frames.isEmpty else { return }
        steps.append(frames)
        if steps.count > Self.maxDepth { steps.removeFirst(steps.count - Self.maxDepth) }
    }

    public mutating func popLast() -> [RememberedFrame]? {
        steps.popLast()
    }

    public mutating func clear() { steps.removeAll() }

    public static func nothingToUndo() -> String {
        "I have not moved any windows yet, so there is nothing to put back."
    }

    public static func undone(_ frames: [RememberedFrame], failed: [String]) -> String {
        let names = frames.map(\.app)
        var parts: [String] = []
        if !names.isEmpty {
            parts.append("Put " + names.joined(separator: ", ") + " back.")
        }
        if !failed.isEmpty {
            parts.append("Couldn't move " + failed.joined(separator: ", ") + " back.")
        }
        return parts.isEmpty ? nothingToUndo() : parts.joined(separator: " ")
    }
}
