import AppKit
import PDFKit
import WindowPetCore

/// Reading a file into the conversation, for the two ways one gets there:
/// dropped onto Rusty, or asked for by name through the gated `read_file`
/// tool.
@MainActor
enum FileReader {

    struct Reading {
        let name: String
        let kind: FilePolicy.Kind
        let byteCount: Int
        /// nil when the file is not words: an image, an archive, a binary.
        let text: String?
    }

    /// A reason a file could not be read, phrased for a person. Carried as an
    /// Error so `Result` will hold it.
    struct Refusal: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    static func read(path rawPath: String) -> Result<Reading, Refusal> {
        let path = (rawPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .failure(Refusal("There is no file at \(path)."))
        }
        if isDirectory.boolValue {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            let listed = contents.prefix(60).joined(separator: "\n")
            let more = contents.count > 60 ? "\n[and \(contents.count - 60) more]" : ""
            return .success(Reading(name: name, kind: .other("folder"), byteCount: 0,
                                    text: contents.isEmpty ? "The folder is empty."
                                                           : listed + more))
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        guard size <= FilePolicy.maxBytes else {
            return .failure(Refusal(FilePolicy.tooLargeMessage(name: name, byteCount: size)))
        }
        let kind = FilePolicy.kind(ofPath: path)
        switch kind {
        case .text:
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
                // Not UTF-8. Latin-1 reads anything without throwing, and a
                // slightly wrong character beats refusing a readable file.
                guard let fallback = try? String(contentsOf: url, encoding: .isoLatin1) else {
                    return .failure(Refusal("I couldn't read \(name) as text."))
                }
                return .success(Reading(name: name, kind: kind, byteCount: size,
                                        text: FilePolicy.excerpt(fallback, name: name)))
            }
            return .success(Reading(name: name, kind: kind, byteCount: size,
                                    text: FilePolicy.excerpt(contents, name: name)))
        case .pdf:
            guard let document = PDFDocument(url: url) else {
                return .failure(Refusal("I couldn't open \(name) as a PDF."))
            }
            let pages = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }
            let joined = pages.joined(separator: "\n\n")
            guard !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(Refusal("\(name) is a PDF with no selectable text in it, most likely a scan. I would need to look at it as an image."))
            }
            return .success(Reading(name: name, kind: kind, byteCount: size,
                                    text: FilePolicy.excerpt(joined, name: name)))
        case .other:
            return .success(Reading(name: name, kind: kind, byteCount: size, text: nil))
        }
    }

    /// The tool result for `read_file`: the contents, or an honest account of
    /// why there are none.
    static func toolResult(path: String) -> (result: String, ok: Bool) {
        switch read(path: path) {
        case .failure(let refusal):
            return (refusal.message, false)
        case .success(let reading):
            guard let text = reading.text else {
                return ("\(reading.name) is a \(reading.byteCount > 0 ? FilePolicy.readableSize(reading.byteCount) : "") file I cannot read as words.", false)
            }
            return ("\(reading.name):\n\n\(text)", true)
        }
    }
}
