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

    /// Token prefixes that only count at the start of a word, since a few of
    /// them ("key-", "sk_") also turn up inside ordinary text. ElevenLabs
    /// keys are "sk_" plus lowercase hex, which is exactly the key the app
    /// asks people to paste in.
    static let tokenPrefixes = [
        "sk_", "sk-", "xi-", "key-", "hf_", "npm_", "glpat-", "shpat_", "shpss_",
        "shpca_", "rk_live_", "sk_live_", "sk_test_", "whsec_", "xoxa-", "xoxr-",
        "pypi-", "dop_v1_", "sg.", "eyj",
    ]

    /// A label followed by a value: "password: hunter2", "API_KEY=...",
    /// "DB_PASSWORD=...", "client_secret=...", "refresh_token=...".
    ///
    /// The label may carry any number of `NAME_` or `name-` prefixes, which
    /// is how env files and config keys spell them. `\b` cannot open the
    /// label: `_` is a word character, so `DB_PASSWORD` has no boundary
    /// before `PASSWORD`. A lookbehind for a letter or digit keeps
    /// "compass: north" and "bypass=1" from matching instead.
    static let labelledSecret =
        #"(?i)(?<![A-Za-z0-9])(?:[A-Za-z0-9]+[_-])*(pass(word|wd|code|phrase)?|pwd|secrets?|token|api[ _-]?key|access[ _-]?key|private[ _-]?key|credentials?|bearer)(?![A-Za-z0-9])\s*[:=]\s*\S+"#

    /// `STRIPE_KEY=...`, `SIGNING_KEY: ...`: a bare "key" label is too
    /// common in prose to count alone, so it needs a prefix and a value long
    /// enough to be a credential.
    static let prefixedKey =
        #"(?i)(?<![A-Za-z0-9])(?:[A-Za-z0-9]+[_-])+key(?![A-Za-z0-9])\s*[:=]\s*["']?\S{8,}"#

    /// URL parameter names that carry a credential, compared against each
    /// `_`, `-` or `.` separated part of the name ("access_token",
    /// "X-Amz-Signature", "api_key").
    static let secretParameterParts: Set<String> = [
        "token", "key", "apikey", "secret", "sig", "signature", "code", "auth",
        "password", "passwd", "pass", "pwd", "credential", "credentials", "jwt",
        "session", "sessionid",
    ]

    /// True when the text looks like something nobody meant to keep a copy of.
    public static func isSecret(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if secretMarkers.contains(where: { lowered.contains($0) }) { return true }
        if text.range(of: labelledSecret, options: .regularExpression) != nil { return true }
        if text.range(of: prefixedKey, options: .regularExpression) != nil { return true }
        if lowered.range(of: #"\bbearer\s+\S{16,}"#, options: .regularExpression) != nil {
            return true
        }
        // A URL can carry a credential in its user info, its query, its
        // fragment or its very address (a webhook). Checked before the
        // lone-URL exemption below, which only covers the URL's shape.
        if urlCandidates(text).contains(where: isSecretURL) { return true }
        // A lone URL is otherwise worth remembering, however long and random
        // its path looks.
        let trimmed = lowered.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains(where: \.isWhitespace),
           trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return false
        }
        return tokens(text).contains(where: isSecretToken)
    }

    /// Words of the text, split on whitespace and the punctuation that
    /// surrounds a pasted value (quotes, `=`, `:`, commas, brackets).
    static func tokens(_ text: String) -> [Substring] {
        text.split(whereSeparator: { character in
            character.isWhitespace || "\"'`=:,;()[]{}<>".contains(character)
        })
    }

    /// Every whitespace-separated word that contains a scheme separator,
    /// with the quotes and brackets that usually surround a pasted URL
    /// peeled off. `tokens` cannot be used here: it splits on `:`, which
    /// would cut `https://user:pass@host` apart.
    static func urlCandidates(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace)
            .filter { $0.contains("://") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`()[]{}<>,;")) }
    }

    /// True when the URL itself is a credential or carries one: a password
    /// in the user info (`postgres://admin:pw@db`), a credential-named query
    /// or fragment parameter (`?key=`, `#access_token=`), a parameter value
    /// with a known token shape, or a webhook address whose path is the key.
    static func isSecretURL(_ candidate: String) -> Bool {
        // User info with a password. The regex covers strings URLComponents
        // refuses to parse, such as a password with an unescaped `#` or `%`.
        if candidate.range(of: #"://[^/\s@]*:[^/\s@]+@"#, options: .regularExpression) != nil {
            return true
        }
        guard let components = URLComponents(string: candidate) else { return false }
        if let password = components.password, !password.isEmpty { return true }

        let host = components.host?.lowercased() ?? ""
        let path = components.path.lowercased()
        if host == "hooks.slack.com", path.hasPrefix("/services/") { return true }
        if host == "discord.com" || host == "discordapp.com" || host.hasSuffix(".discord.com"),
           path.hasPrefix("/api/webhooks/") { return true }

        var items = components.queryItems ?? []
        // OAuth implicit flows put the token in the fragment, shaped like a
        // query string.
        if let fragment = components.fragment, fragment.contains("="),
           let parsed = URLComponents(string: "?" + fragment)?.queryItems {
            items += parsed
        }
        return items.contains { item in
            guard let value = item.value, !value.isEmpty else { return false }
            let parts = item.name.lowercased()
                .split(whereSeparator: { "_-.".contains($0) })
                .map(String.init)
            if parts.contains(where: secretParameterParts.contains) { return true }
            return isKnownTokenShape(Substring(value))
        }
    }

    /// A token whose prefix names a real credential format (with digits
    /// after it, which real keys carry and "key-value-store" does not), or a
    /// JWT. Unlike the entropy test below, this never fires on an opaque ID
    /// such as a share link or a tracking parameter.
    static func isKnownTokenShape(_ token: Substring) -> Bool {
        let lowered = token.lowercased()
        if secretMarkers.contains(where: { lowered.contains($0) }) { return true }
        for prefix in tokenPrefixes where lowered.hasPrefix(prefix) {
            if token.count >= prefix.count + 16,
               token.dropFirst(prefix.count).contains(where: \.isNumber) { return true }
        }
        // Google API keys: "AIza" plus 35 characters.
        if token.hasPrefix("AIza"), token.count >= 39 { return true }
        // A JWT: three base64url parts, the first starting "eyJ".
        if lowered.hasPrefix("eyj"), token.split(separator: ".").count == 3 { return true }
        return false
    }

    static func isSecretToken(_ token: Substring) -> Bool {
        let lowered = token.lowercased()
        // A URL is long and unbroken too, and is worth remembering.
        if lowered.hasPrefix("http") || lowered.hasPrefix("//") || lowered.hasPrefix("www.") {
            return false
        }
        if isKnownTokenShape(token) { return true }

        guard token.count >= 24 else { return false }
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=_-.")
        guard token.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }

        let alphanumerics = token.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        guard alphanumerics.count >= 20 else { return false }
        let digits = alphanumerics.filter(\.isNumber).count
        let letters = alphanumerics.count - digits
        guard digits > 0 else { return false }

        // Hex of any case: API keys, webhook secrets, Datadog and Mailgun
        // tokens. (A pasted commit hash goes too; forgetting is the bias.)
        if letters > 0, alphanumerics.allSatisfy(\.isHexDigit) { return true }
        // Mixed case plus digits is a key or a token far more often than it
        // is prose worth recalling.
        if token.contains(where: \.isUppercase), token.contains(where: \.isLowercase) { return true }
        // Single-case random strings: a real share of digits and few word
        // separators, which rules out snake_case names and file names.
        let separators = token.filter { "_-.".contains($0) }.count
        return separators <= 2 && Double(digits) / Double(alphanumerics.count) >= 0.2
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
