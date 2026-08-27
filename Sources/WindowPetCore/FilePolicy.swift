import Foundation

/// What Rusty will read off disk, and how much of it.
///
/// Two paths reach a file. Dropping one onto him is consent by the act
/// itself, so the drop reads immediately. The `read_file` tool is the model
/// asking on its own, which passes the confirmation gate first, because a
/// model that can be talked into reading an arbitrary path is a model that
/// can be talked into reading a key file.
public enum FilePolicy {

    /// Enough for a long document, small enough to stay inside one turn.
    public static let maxBytes = 400_000

    /// Extensions read as text. Anything else is described rather than read,
    /// so a binary never lands in the conversation as mojibake.
    public static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "rtf", "csv", "tsv", "json", "yaml", "yml",
        "toml", "ini", "cfg", "conf", "log", "swift", "py", "js", "jsx", "ts",
        "tsx", "rb", "go", "rs", "c", "h", "cpp", "hpp", "m", "mm", "java",
        "kt", "sh", "bash", "zsh", "sql", "html", "css", "xml", "plist",
        "gitignore", "env",
    ]

    public static let pdfExtensions: Set<String> = ["pdf"]

    public enum Kind: Equatable, Sendable {
        case text
        case pdf
        /// Readable in principle, but not as words.
        case other(String)
    }

    public static func kind(ofPath path: String) -> Kind {
        let ext = (path as NSString).pathExtension.lowercased()
        if textExtensions.contains(ext) { return .text }
        if pdfExtensions.contains(ext) { return .pdf }
        return .other(ext.isEmpty ? "file" : ext)
    }

    /// Trims a file's contents to something that fits in a turn, and says so
    /// when it had to. Silently truncating would let the model answer
    /// confidently about a document it only half saw.
    public static func excerpt(_ contents: String, name: String, limit: Int = 24_000) -> String {
        guard contents.count > limit else { return contents }
        return String(contents.prefix(limit))
            + "\n\n[\(name) continues past this point. You are seeing the first "
            + "\(limit) characters of \(contents.count).]"
    }

    /// How a dropped file is announced to the conversation. The user did
    /// something physical, so the turn reads as their words rather than as an
    /// event the model has to decode.
    public static func dropPrompt(name: String, kind: Kind, byteCount: Int) -> String {
        switch kind {
        case .text, .pdf:
            return "I dropped \(name) on you. Here it is."
        case .other(let ext):
            return "I dropped \(name) on you. It is a \(ext) file, "
                + "\(readableSize(byteCount)), and I cannot show you the contents."
        }
    }

    public static func readableSize(_ bytes: Int) -> String {
        if bytes >= 1_000_000 { return String(format: "%.1f MB", Double(bytes) / 1_000_000) }
        if bytes >= 1_000 { return "\(bytes / 1000) KB" }
        return "\(bytes) bytes"
    }

    public static func tooLargeMessage(name: String, byteCount: Int) -> String {
        "\(name) is \(readableSize(byteCount)), which is past the "
            + "\(readableSize(maxBytes)) I will read in one go. Point me at a smaller file, "
            + "or tell me which part of it you care about."
    }
}
