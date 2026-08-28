import Foundation

/// Turning speech into text meant for the app in front, rather than for Rusty.
///
/// The whole point is that no model is involved: the words go from the
/// on-device recognizer straight into the focused app, so dictation is free,
/// private, and instant. That leaves the tidying to this file, which is why
/// spoken punctuation and sentence casing live here rather than in a prompt.
public enum DictationPolicy {

    /// Spoken punctuation, in the forms people actually say them. Longest
    /// phrases first so "new paragraph" is not read as "new" then "paragraph".
    ///
    /// `ambiguous` marks the ones that are also ordinary nouns. Those are the
    /// only phrases a determiner can veto: "new line" is always a command, but
    /// "that period" is a length of time.
    static let spoken: [(phrase: String, replacement: String, ambiguous: Bool)] = [
        ("new paragraph", "\n\n", false),
        ("new line", "\n", false),
        ("open parenthesis", "(", false),
        ("close parenthesis", ")", false),
        ("open quote", "\"", false),
        ("close quote", "\"", false),
        ("exclamation point", "!", false),
        ("exclamation mark", "!", false),
        ("question mark", "?", false),
        ("semicolon", ";", true),
        ("apostrophe", "'", true),
        ("ellipsis", "…", true),
        ("full stop", ".", true),
        ("period", ".", true),
        ("comma", ",", true),
        ("colon", ":", true),
        ("dash", "-", true),
        ("hyphen", "-", true),
    ]

    /// Filler the recognizer faithfully transcribes and nobody wants typed.
    static let fillers = ["um", "uh", "erm", "uhh", "umm"]

    /// The transcript as it should be typed.
    ///
    /// `continuing` is true when text was already dictated into this field, in
    /// which case the result is not capitalized and gets a leading space, so a
    /// second breath joins the sentence rather than starting a new one.
    public static func text(from raw: String, continuing: Bool = false) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        text = removeFillers(from: text)
        text = applySpokenPunctuation(to: text)
        text = tidySpacing(text)
        if !continuing { text = capitalizingFirstLetter(text) }
        guard !text.isEmpty else { return "" }
        return continuing ? " " + text : text
    }

    static func removeFillers(from text: String) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        let kept = words.filter { word in
            let bare = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
            return !fillers.contains(bare)
        }
        return kept.joined(separator: " ")
    }

    /// Words that mean the next word is a noun. "That period piece" and "the
    /// comma splice" are about a period and a comma; "world period" ends a
    /// sentence. A determiner in front is the cheapest reliable signal for
    /// telling those apart, and it costs nothing when it is wrong: the word is
    /// simply typed as a word.
    static let determiners: Set<String> = [
        "the", "a", "an", "this", "that", "these", "those", "each", "every",
        "my", "your", "his", "her", "its", "our", "their", "another", "one",
        "some", "any", "no", "which", "what",
    ]

    /// Replaces spoken punctuation only when it stands as its own word and is
    /// not being used as a noun.
    static func applySpokenPunctuation(to text: String) -> String {
        var result = text
        for (phrase, replacement, ambiguous) in spoken {
            // Word boundaries on both sides, case insensitive. The preceding
            // word is captured so a determiner in front can veto the swap.
            let pattern = "(?:(?<![\\p{L}])([\\p{L}']+)\\s+)?(?<![\\p{L}])"
                + NSRegularExpression.escapedPattern(for: phrase) + "(?![\\p{L}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            else { continue }
            var output = ""
            var cursor = result.startIndex
            for match in regex.matches(in: result,
                                       range: NSRange(result.startIndex..., in: result)) {
                guard let whole = Range(match.range, in: result) else { continue }
                var preceding = ""
                if let range = Range(match.range(at: 1), in: result) {
                    preceding = String(result[range])
                }
                output += result[cursor..<whole.lowerBound]
                if ambiguous, determiners.contains(preceding.lowercased()) {
                    output += result[whole]  // a noun, left alone
                } else if preceding.isEmpty {
                    output += replacement
                } else {
                    output += preceding + " " + replacement
                }
                cursor = whole.upperBound
            }
            output += result[cursor...]
            result = output
        }
        return result
    }

    /// Punctuation hugs the word before it and takes one space after; newlines
    /// take none. Recognizers leave the spacing wrong in both directions.
    static func tidySpacing(_ text: String) -> String {
        var result = text
        for mark in [".", ",", "!", "?", ";", ":", "…"] {
            result = result.replacingOccurrences(of: " \(mark)", with: mark)
        }
        result = result.replacingOccurrences(of: " \n", with: "\n")
        result = result.replacingOccurrences(of: "\n ", with: "\n")
        result = result.replacingOccurrences(of: "( ", with: "(")
        result = result.replacingOccurrences(of: " )", with: ")")
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    static func capitalizingFirstLetter(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased() + text.dropFirst()
    }

    /// Said in the bubble while dictation is live, so it is never ambiguous
    /// whether Rusty is listening for himself or for the app in front.
    public static func statusLine(app: String?) -> String {
        guard let app, !app.isEmpty else { return "Dictating" }
        return "Dictating into \(app)"
    }
}
