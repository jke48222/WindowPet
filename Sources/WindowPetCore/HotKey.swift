import Foundation

/// Canonical virtual key-code table, shared by the configurable summon
/// hotkey and the `press_keys` tool so the two can never drift apart.
public enum KeyCodes {

    public static let byName: [String: UInt16] = [
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4,
        "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31,
        "p": 35, "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9,
        "w": 13, "x": 7, "y": 16, "z": 6,
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22,
        "7": 26, "8": 28, "9": 25,
        "space": 49, "return": 36, "enter": 36, "tab": 48, "escape": 53,
        "esc": 53, "delete": 51, "backspace": 51, "forwarddelete": 117,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "comma": 43, ",": 43, "period": 47, ".": 47, "slash": 44, "/": 44,
        "semicolon": 41, "quote": 39, "minus": 27, "-": 27, "equal": 24,
        "=": 24, "leftbracket": 33, "[": 33, "rightbracket": 30, "]": 30,
        "backslash": 42, "grave": 50, "`": 50,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    /// Display name for a key code. Prefers the spelled-out name people
    /// recognize in a shortcut ("Space", not " ").
    static let displayNames: [UInt16: String] = [
        49: "Space", 36: "Return", 48: "Tab", 53: "Escape", 51: "Delete",
        117: "Forward Delete", 123: "Left", 124: "Right", 125: "Down",
        126: "Up", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        43: "Comma", 47: "Period", 44: "Slash", 41: "Semicolon", 39: "Quote",
        27: "Minus", 24: "Equal", 33: "[", 30: "]", 42: "Backslash",
        50: "Grave",
    ]

    public static func name(for code: UInt16) -> String? {
        if let special = displayNames[code] { return special }
        // Letters, digits, and function keys read back as themselves,
        // uppercased. (F-keys are 2-3 chars, so they never collide with a
        // single-character literal.)
        if let literal = byName.first(where: {
            $0.value == code && ($0.key.count == 1 || $0.key.hasPrefix("f"))
        })?.key {
            return literal.uppercased()
        }
        return nil
    }
}

public struct HotKeyModifiers: OptionSet, Equatable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = HotKeyModifiers(rawValue: 1 << 0)
    public static let shift = HotKeyModifiers(rawValue: 1 << 1)
    public static let option = HotKeyModifiers(rawValue: 1 << 2)
    public static let control = HotKeyModifiers(rawValue: 1 << 3)

    /// Spelled out rather than glyphed, matching the rest of the app's copy.
    public var displayName: String {
        var parts: [String] = []
        if contains(.control) { parts.append("Control") }
        if contains(.option) { parts.append("Option") }
        if contains(.shift) { parts.append("Shift") }
        if contains(.command) { parts.append("Command") }
        return parts.joined(separator: "-")
    }
}

/// The shortcut that summons Rusty's chat panel.
public struct HotKeyBinding: Equatable, Sendable {
    public let keyCode: UInt16
    public let modifiers: HotKeyModifiers

    public init(keyCode: UInt16, modifiers: HotKeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let `default` = HotKeyBinding(keyCode: 49, modifiers: .option)

    /// A global shortcut needs at least one modifier, or it would swallow a
    /// plain keystroke everywhere. Command-Q and friends stay off limits so
    /// the binding cannot shadow quitting an app.
    public var isValid: Bool {
        guard !modifiers.isEmpty, KeyCodes.name(for: keyCode) != nil else { return false }
        let reserved: [(UInt16, HotKeyModifiers)] = [
            (KeyCodes.byName["q"]!, .command),
            (KeyCodes.byName["w"]!, .command),
            (KeyCodes.byName["tab"]!, .command),
        ]
        return !reserved.contains { $0.0 == keyCode && modifiers == $0.1 }
    }

    public var displayName: String {
        let key = KeyCodes.name(for: keyCode) ?? "Key \(keyCode)"
        let mods = modifiers.displayName
        return mods.isEmpty ? key : "\(mods)-\(key)"
    }
}
