import Foundation

/// The clipboard history's rules, kept pure so the part that decides what is
/// never stored is testable in isolation.
///
/// The bias is toward forgetting. A desktop assistant that quietly keeps every
/// copied string is a liability the first time somebody copies a key out of a
/// password manager, so anything that looks like a credential is dropped
/// before it reaches memory, and nothing here is ever written to disk.
public enum ClipPolicy {

    /// Enough to be useful across an afternoon, small enough that it is not a
    /// second clipboard manager.
    public static let maxClips = 20
    /// Longer than this and it is a document, not a clip.
    public static let maxLength = 4000

    /// Credential shapes. Each prefix is a real token format, so a match is a
    /// near certainty rather than a guess.
    static let secretMarkers = [
        "age-secret-key", "sk-ant-", "sk-proj-", "sk-live-", "ghp_", "gho_",
        "ghu_", "ghs_", "github_pat_", "xoxb-", "xoxp-", "akia", "asia",
        "-----begin", "aws_secret_access_key", "private_key",
    ]

    /// True when the text looks like something nobody meant to keep a copy of.
    public static func isSecret(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if secretMarkers.contains(where: { lowered.contains($0) }) { return true }
        // A single long token with no spaces, mixing cases and digits, is a
        // key or a token far more often than it is prose worth recalling.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: { $0.isWhitespace }), trimmed.count >= 32 else { return false }
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=_-.")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        // A URL is long and unbroken too, and is worth remembering.
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") { return false }
        let hasUpper = trimmed.contains { $0.isUppercase }
        let hasLower = trimmed.contains { $0.isLowercase }
        let hasDigit = trimmed.contains { $0.isNumber }
        return hasUpper && hasLower && hasDigit
    }

    /// The clip as it should be stored, or nil when it should not be stored
    /// at all: empty, whitespace only, oversized, or secret.
    public static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength, !isSecret(trimmed) else { return nil }
        return trimmed
    }

    /// Newest first, no duplicates, capped. Re-copying something old moves it
    /// to the front rather than making a second entry.
    public static func insert(_ clip: String, into clips: [String]) -> [String] {
        guard let normalized = normalize(clip) else { return clips }
        var updated = clips.filter { $0 != normalized }
        updated.insert(normalized, at: 0)
        if updated.count > maxClips { updated.removeLast(updated.count - maxClips) }
        return updated
    }

    /// One line per clip, numbered from 1 and truncated, so a model can pick
    /// one by number or by what it says.
    public static func summary(_ clips: [String], previewLength: Int = 90) -> String {
        guard !clips.isEmpty else {
            return "Nothing in the clipboard history yet. I start remembering what you copy while I am running, and I skip anything that looks like a password or a key."
        }
        let lines = clips.enumerated().map { index, clip -> String in
            let flat = clip.replacingOccurrences(of: "\n", with: " ")
            let preview = flat.count > previewLength
                ? String(flat.prefix(previewLength - 1)) + "…" : flat
            return "\(index + 1). \(preview)"
        }
        return lines.joined(separator: "\n")
    }

    /// Finds a clip by 1-based number, or by the words in it. Returns the
    /// index into `clips`, or nil when nothing matches.
    public static func match(_ query: String, in clips: [String]) -> Int? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !clips.isEmpty else { return nil }
        if trimmed.isEmpty { return 0 }
        if let number = Int(trimmed) {
            let index = number - 1
            return clips.indices.contains(index) ? index : nil
        }
        let needle = trimmed.lowercased()
        return clips.firstIndex { $0.lowercased().contains(needle) }
    }
}
