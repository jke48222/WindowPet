import Foundation

/// The standard macOS text-editing shortcuts, as a lookup the chat panel can
/// use to dispatch them by hand.
///
/// A menu-bar app has no Edit menu, and the panel is a borderless
/// non-activating NSPanel, so nothing in the normal responder chain turns
/// Command-C into `copy:`. The panel intercepts the key equivalent and sends
/// the matching selector to the first responder instead. Keeping the mapping
/// here (pure, no AppKit) makes it testable.
public enum EditCommand: String, Equatable, CaseIterable {
    case cut = "cut:"
    case copy = "copy:"
    case paste = "paste:"
    case selectAll = "selectAll:"
    case undo = "undo:"
    case redo = "redo:"

    /// `key` is the character with modifiers stripped, lowercased.
    /// Command-Shift-Z is redo, matching every other Mac text field.
    public static func forKey(_ key: String, shift: Bool) -> EditCommand? {
        switch key {
        case "x": return .cut
        case "c": return .copy
        case "v": return .paste
        case "a": return .selectAll
        case "z": return shift ? .redo : .undo
        default: return nil
        }
    }
}
