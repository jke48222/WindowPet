import AppKit
import PDFKit
import WindowPetCore

/// Reading a file into the conversation, for the two ways one gets there:
/// dropped onto Rusty, or asked for by name through the gated `read_file`
/// tool.
///
/// Nothing here touches UI state, so it is not bound to the main actor. The
/// app's callers use the `async` forms, which do the reading (a PDF's text
/// extraction can take most of a second) on a background thread, so the pet
/// and the panel keep moving while a file is read.
enum FileReader {

    /// How much of a document the conversation ever sees. Matches
    /// `FilePolicy.excerpt`'s default, so a PDF stops being extracted once
    /// it has produced this much.
    static let excerptLimit = 24_000

    struct Reading: Sendable {
        let name: String
        let kind: FilePolicy.Kind
        let byteCount: Int
        /// nil when the file is not words: an image, an archive, a binary.
        let text: String?
    }

    /// A reason a file could not be read, phrased for a person. Carried as an
    /// Error so `Result` will hold it.
    struct Refusal: Error, Sendable {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// - Parameter followLinks: a dropped file is consent by the act, so a
    ///   dropped link is read at its target. A path the model chose is not:
    ///   the safety check names the path, so a link (or a linked folder on
    ///   the way) that points somewhere else is refused rather than read
    ///   under a name the user never saw.
    static func readAsync(path: String, followLinks: Bool = false) async -> Result<Reading, Refusal> {
        await Task.detached(priority: .userInitiated) {
            read(path: path, followLinks: followLinks)
        }.value
    }

    static func read(path rawPath: String, followLinks: Bool = false) -> Result<Reading, Refusal> {
        let path = (rawPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let name = url.lastPathComponent
        let resolved = url.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else {
            return .failure(Refusal("There is no file at \(path)."))
        }
        if !followLinks, !sameLocation(url.path, resolved.path) {
            return .failure(Refusal("\(name) is a link to \(resolved.path). Ask me to read that path directly if that is the file you mean."))
        }
        if isDirectory.boolValue {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: resolved.path)) ?? []
            let listed = contents.prefix(60).joined(separator: "\n")
            let more = contents.count > 60 ? "\n[and \(contents.count - 60) more]" : ""
            return .success(Reading(name: name, kind: .other("folder"), byteCount: 0,
                                    text: contents.isEmpty ? "The folder is empty."
                                                           : listed + more))
        }
        let data: Data
        let size: Int
        switch readRegularFile(at: resolved.path, name: name) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let read): (data, size) = read
        }
        let kind = FilePolicy.kind(ofPath: resolved.path)
        switch kind {
        case .text:
            // Not UTF-8: Latin-1 reads anything, and a slightly wrong
            // character beats refusing a readable file.
            guard let contents = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1) else {
                return .failure(Refusal("I couldn't read \(name) as text."))
            }
            return .success(Reading(name: name, kind: kind, byteCount: size,
                                    text: FilePolicy.excerpt(contents, name: name)))
        case .pdf:
            guard let document = PDFDocument(data: data) else {
                return .failure(Refusal("I couldn't open \(name) as a PDF."))
            }
            // Page by page, stopping once there is more than the excerpt
            // keeps: the rest would be extracted only to be thrown away.
            var joined = ""
            var pagesRead = 0
            for index in 0..<document.pageCount {
                if joined.count > Self.excerptLimit { break }
                pagesRead += 1
                guard let page = document.page(at: index)?.string else { continue }
                if !joined.isEmpty { joined += "\n\n" }
                joined += page
            }
            guard !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(Refusal("\(name) is a PDF with no selectable text in it, most likely a scan. I would need to look at it as an image."))
            }
            guard pagesRead < document.pageCount else {
                return .success(Reading(name: name, kind: kind, byteCount: size,
                                        text: FilePolicy.excerpt(joined, name: name,
                                                                 limit: Self.excerptLimit)))
            }
            let excerpt = String(joined.prefix(Self.excerptLimit))
                + "\n\n[\(name) continues past this point. You are seeing the first "
                + "\(Self.excerptLimit) characters, from the first \(pagesRead) of its "
                + "\(document.pageCount) pages.]"
            return .success(Reading(name: name, kind: kind, byteCount: size, text: excerpt))
        case .other:
            return .success(Reading(name: name, kind: kind, byteCount: size, text: nil))
        }
    }

    /// /tmp, /var and /etc are links into /private on every Mac; a path
    /// through them is not a link the user was misled by.
    private static func sameLocation(_ a: String, _ b: String) -> Bool {
        a == b || "/private" + a == b || a == "/private" + b
    }

    /// Opens without following a final link and without blocking (a FIFO
    /// would otherwise hang the read forever), checks from the open
    /// descriptor that it is a regular file within the size cap, then reads
    /// at most that cap.
    private static func readRegularFile(at path: String, name: String) -> Result<(Data, Int), Refusal> {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            return .failure(Refusal("I couldn't open \(name) (\(String(cString: strerror(errno))))."))
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            return .failure(Refusal("\(name) isn't a regular file, so I won't read it."))
        }
        let size = Int(info.st_size)
        guard size <= FilePolicy.maxBytes else {
            return .failure(Refusal(FilePolicy.tooLargeMessage(name: name, byteCount: size)))
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        let data = (try? handle.read(upToCount: FilePolicy.maxBytes)) ?? Data()
        return .success((data, size))
    }

    /// `toolResult`, read on a background thread.
    static func toolResultAsync(path: String) async -> (result: String, ok: Bool) {
        await Task.detached(priority: .userInitiated) { toolResult(path: path) }.value
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
