import CoreGraphics
import Foundation

/// Where a window goes, in the vocabulary people actually use for screens.
/// Pure geometry against a display's usable area, so the halves, quarters and
/// thirds behave the same on a laptop and on a 5K monitor.
public enum LayoutSlot: String, CaseIterable, Codable, Sendable {
    case left, right, top, bottom
    case topLeft, topRight, bottomLeft, bottomRight
    case center, full
    /// Thirds, for the wide monitors where halves waste the middle.
    case leftThird, middleThird, rightThird

    public func rect(in visible: CGRect) -> CGRect {
        let width = visible.width, height = visible.height
        let x = visible.minX, y = visible.minY
        switch self {
        case .full: return visible
        // AppKit's origin is bottom-left, so "top" is the high half of y.
        case .left: return CGRect(x: x, y: y, width: width / 2, height: height)
        case .right: return CGRect(x: x + width / 2, y: y, width: width / 2, height: height)
        case .top: return CGRect(x: x, y: y + height / 2, width: width, height: height / 2)
        case .bottom: return CGRect(x: x, y: y, width: width, height: height / 2)
        case .topLeft: return CGRect(x: x, y: y + height / 2, width: width / 2, height: height / 2)
        case .topRight: return CGRect(x: x + width / 2, y: y + height / 2, width: width / 2, height: height / 2)
        case .bottomLeft: return CGRect(x: x, y: y, width: width / 2, height: height / 2)
        case .bottomRight: return CGRect(x: x + width / 2, y: y, width: width / 2, height: height / 2)
        case .center:
            return CGRect(x: x + width * 0.15, y: y + height * 0.1,
                          width: width * 0.7, height: height * 0.8)
        case .leftThird: return CGRect(x: x, y: y, width: width / 3, height: height)
        case .middleThird: return CGRect(x: x + width / 3, y: y, width: width / 3, height: height)
        case .rightThird: return CGRect(x: x + width * 2 / 3, y: y, width: width / 3, height: height)
        }
    }

    public var displayName: String {
        switch self {
        case .topLeft: return "top left"
        case .topRight: return "top right"
        case .bottomLeft: return "bottom left"
        case .bottomRight: return "bottom right"
        case .leftThird: return "left third"
        case .middleThird: return "middle third"
        case .rightThird: return "right third"
        case .full: return "full screen"
        default: return rawValue
        }
    }

    /// Filler that carries no position on its own but shows up in the phrases
    /// people say: "the left half", "full screen", "top right corner".
    static let fillerWords: Set<String> = ["the", "half", "side", "screen", "corner", "of"]

    /// Every word that means something here. A phrase containing anything
    /// outside this set is not a slot at all.
    static let vocabulary: Set<String> = Set([
        "top", "upper", "bottom", "lower", "left", "right", "middle",
        "center", "centre", "third", "thirds", "full", "maximize",
        "maximise", "fullscreen",
    ]).union(fillerWords)

    /// Spelled the way a person would say it. Word order is not fixed ("left
    /// top" and "top left" both arrive), so this matches on the words present
    /// rather than on an exact phrase.
    ///
    /// Unknown words make the whole phrase a miss rather than being ignored.
    /// That matters more than it looks: reading "Code left" as "left" would
    /// quietly take a word off the end of "Visual Studio Code".
    public static func parse(_ raw: String) -> LayoutSlot? {
        let text = raw.lowercased().trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let words = Set(text.split(whereSeparator: { !$0.isLetter }).map(String.init))
        guard !words.isEmpty, words.isSubset(of: vocabulary) else { return nil }
        // Longest, most specific readings first: "left third" is not "left".
        if words.contains("third") || words.contains("thirds") {
            if words.contains("left") { return .leftThird }
            if words.contains("right") { return .rightThird }
            if words.contains("middle") || words.contains("center") || words.contains("centre") {
                return .middleThird
            }
        }
        let top = words.contains("top") || words.contains("upper")
        let bottom = words.contains("bottom") || words.contains("lower")
        let left = words.contains("left")
        let right = words.contains("right")
        if top && left { return .topLeft }
        if top && right { return .topRight }
        if bottom && left { return .bottomLeft }
        if bottom && right { return .bottomRight }
        if words.contains("full") || words.contains("maximize") || words.contains("maximise")
            || words.contains("fullscreen") { return .full }
        if words.contains("center") || words.contains("centre") || words.contains("middle") {
            return .center
        }
        if left { return .left }
        if right { return .right }
        if top { return .top }
        if bottom { return .bottom }
        return nil
    }

    /// The slot a window is closest to already, used when saving a layout from
    /// however the screen happens to be arranged right now. Compares against
    /// every slot's rectangle and takes the best overlap, so the answer
    /// degrades gracefully for windows that sit between slots.
    public static func nearest(to frame: CGRect, in visible: CGRect) -> LayoutSlot {
        var best: (slot: LayoutSlot, score: CGFloat) = (.center, -1)
        for slot in LayoutSlot.allCases {
            let candidate = slot.rect(in: visible)
            let overlap = candidate.intersection(frame)
            guard !overlap.isNull else { continue }
            let shared = overlap.width * overlap.height
            let union = candidate.width * candidate.height
                + frame.width * frame.height - shared
            guard union > 0 else { continue }
            // Intersection over union, so a slot is not rewarded for being big.
            let score = shared / union
            if score > best.score { best = (slot, score) }
        }
        return best.slot
    }
}

/// One app placed in one slot on one display.
public struct WindowPlacement: Codable, Equatable, Sendable {
    public let app: String
    public let slot: LayoutSlot
    public let display: Int

    public init(app: String, slot: LayoutSlot, display: Int = 0) {
        self.app = app
        self.slot = slot
        self.display = display
    }

    public var description: String {
        "\(app) \(slot.displayName)"
    }
}

/// A named arrangement of windows, saved and recalled by name.
public struct WindowLayout: Codable, Equatable, Sendable {
    public let name: String
    public let placements: [WindowPlacement]

    public init(name: String, placements: [WindowPlacement]) {
        self.name = name
        self.placements = placements
    }

    /// Names are matched the way people type them, so "Writing" recalls
    /// "writing".
    public static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public var summary: String {
        placements.isEmpty
            ? "\(name) is empty"
            : "\(name): " + placements.map(\.description).joined(separator: ", ")
    }
}

/// Parsing the one-line form the assistant uses: "Safari left, Terminal
/// bottom right". Kept separate from the model so the grammar has its own
/// tests.
public enum LayoutParser {

    /// Splits on commas and the word "and", then reads each piece as an app
    /// name followed by a slot. The slot words are always at the end, which is
    /// what makes an unquoted app name with spaces work.
    public static func placements(from raw: String) -> [WindowPlacement] {
        let pieces = raw
            .replacingOccurrences(of: " and ", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return pieces.compactMap(placement(from:))
    }

    public static func placement(from raw: String) -> WindowPlacement? {
        // Written as "Safari: left" or "Safari left". The colon form wins when
        // it is there, because an app named "Left Field" would otherwise lose
        // its last word to the slot.
        if let colon = raw.firstIndex(of: ":") {
            let app = String(raw[raw.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let slotText = String(raw[raw.index(after: colon)...])
            guard !app.isEmpty, let slot = LayoutSlot.parse(slotText) else { return nil }
            return WindowPlacement(app: app, slot: slot)
        }
        var words = raw.split(separator: " ").map(String.init)
        guard words.count >= 2 else { return nil }
        // Take slot words off the end, longest first: "bottom right" is two.
        for trailing in stride(from: min(2, words.count - 1), through: 1, by: -1) {
            let tail = words.suffix(trailing).joined(separator: " ")
            if let slot = LayoutSlot.parse(tail) {
                words.removeLast(trailing)
                let app = words.joined(separator: " ")
                guard !app.isEmpty else { return nil }
                return WindowPlacement(app: app, slot: slot)
            }
        }
        return nil
    }
}
