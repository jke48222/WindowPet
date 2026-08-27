import Foundation

/// A user-authored skin, read from a JSON file. Colors are hex strings so a
/// skin is something a person can write by hand in a text editor.
///
/// `sprites` picks which built-in robot finish to wear ("tinplate",
/// "seafoam", "midnight", "sakura"); the rest recolors the chat panel, the
/// speech bubble, and the status lamp.
public struct SkinDefinition: Codable, Equatable, Sendable {
    public let name: String
    public let sprites: String
    public let accent: String
    public let thinking: String
    public let glassTop: String
    public let glassBottom: String
    public let border: String
    public let userText: String
    public let rustyText: String
    public let bubbleFill: String
    public let bubbleText: String

    public init(name: String, sprites: String, accent: String, thinking: String,
                glassTop: String, glassBottom: String, border: String,
                userText: String, rustyText: String, bubbleFill: String,
                bubbleText: String) {
        self.name = name
        self.sprites = sprites
        self.accent = accent
        self.thinking = thinking
        self.glassTop = glassTop
        self.glassBottom = glassBottom
        self.border = border
        self.userText = userText
        self.rustyText = rustyText
        self.bubbleFill = bubbleFill
        self.bubbleText = bubbleText
    }

    public static let spriteChoices = ["tinplate", "seafoam", "midnight", "sakura"]

    /// A skin is usable only if it names itself, picks real sprites, and
    /// every color parses. Anything else is reported rather than silently
    /// rendering a half-black panel.
    public var problems: [String] {
        var problems: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            problems.append("needs a name")
        }
        if !Self.spriteChoices.contains(sprites) {
            problems.append("sprites must be one of \(Self.spriteChoices.joined(separator: ", "))")
        }
        for (label, hex) in [("accent", accent), ("thinking", thinking),
                             ("glassTop", glassTop), ("glassBottom", glassBottom),
                             ("border", border), ("userText", userText),
                             ("rustyText", rustyText), ("bubbleFill", bubbleFill),
                             ("bubbleText", bubbleText)]
        where HexColor.parse(hex) == nil {
            problems.append("\(label) is not a color like #33aaff or #33aaffcc")
        }
        return problems
    }

    /// Stable identifier derived from the name, used as the stored setting.
    public var id: String {
        "custom:" + PetMemory.normalize(name).replacingOccurrences(of: " ", with: "-")
    }

    /// The starting point handed to someone writing their first skin.
    public static let example = SkinDefinition(
        name: "My Skin", sprites: "tinplate",
        accent: "#ffc75c", thinking: "#ff8046",
        glassTop: "#2b251f", glassBottom: "#1a1612",
        border: "#b09664", userText: "#f0e9dc", rustyText: "#ffe6b4",
        bubbleFill: "#26201a", bubbleText: "#f5eee0")
}

/// Hex color parsing, kept pure so bad input is caught before it reaches a
/// drawing call. Accepts #rgb, #rrggbb, and #rrggbbaa, with or without the
/// leading hash.
public enum HexColor {
    public static func parse(_ raw: String) -> (r: Double, g: Double, b: Double, a: Double)? {
        var text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.allSatisfy({ $0.isHexDigit }) else { return nil }

        func component(_ slice: Substring) -> Double {
            Double(UInt8(slice, radix: 16) ?? 0) / 255
        }
        // #abc is shorthand for #aabbcc; expand it, then one code path covers
        // all lengths.
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6 || text.count == 8 else { return nil }
        let start = text.startIndex
        func pair(_ offset: Int) -> Double {
            component(text[text.index(start, offsetBy: offset)..<text.index(start, offsetBy: offset + 2)])
        }
        return (pair(0), pair(2), pair(4), text.count == 8 ? pair(6) : 1)
    }
}
