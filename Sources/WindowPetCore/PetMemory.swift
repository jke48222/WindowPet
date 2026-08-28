import Foundation

/// What Rusty remembers between launches: durable facts about the person he
/// works for, plus a short tail of recent conversation so a follow-up still
/// resolves after a restart.
///
/// Facts are small, human-readable strings ("prefers Safari over Chrome").
/// Storage is a plain JSON file the user can read or delete, and nothing is
/// written without the model deciding it is worth keeping.
public struct PetMemory: Codable, Equatable {

    public struct Fact: Codable, Equatable {
        public let text: String
        public let savedAt: Date
        /// The app this fact is about, when it is about one. "In Xcode I want
        /// the left half" is true in Xcode and noise everywhere else, so a
        /// scoped fact only reaches the model while that app is in front.
        /// Optional, and absent in every memory file written before this
        /// existed, so decoding stays backward compatible.
        public let scope: String?

        public init(text: String, savedAt: Date = Date(), scope: String? = nil) {
            self.text = text
            self.savedAt = savedAt
            self.scope = scope
        }

        /// True when this fact belongs in the prompt for `app`. Unscoped facts
        /// always do.
        public func applies(inApp app: String?) -> Bool {
            guard let scope, !scope.isEmpty else { return true }
            guard let app, !app.isEmpty else { return false }
            return PetMemory.normalize(scope) == PetMemory.normalize(app)
        }
    }

    public private(set) var facts: [Fact]
    public private(set) var recent: [String]

    public static let maxFacts = 40
    public static let maxRecent = 6
    /// Long enough for a real preference, short enough to stay a fact.
    public static let maxFactLength = 200

    public init(facts: [Fact] = [], recent: [String] = []) {
        self.facts = facts
        self.recent = recent
    }

    /// Adds a fact unless it is empty or already known. Near-duplicates are
    /// treated as the same fact so the list does not silt up with rewordings
    /// of "likes dark mode".
    public mutating func remember(_ raw: String, now: Date = Date(), scope: String? = nil) {
        let text = String(raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(Self.maxFactLength))
        guard text.count > 2 else { return }
        let key = Self.normalize(text)
        let cleanScope = scope?.trimmingCharacters(in: .whitespaces)
        // The same words scoped to two different apps are two different facts,
        // so identity is the text AND the scope.
        if let existing = facts.firstIndex(where: {
            Self.normalize($0.text) == key && Self.normalize($0.scope ?? "") == Self.normalize(cleanScope ?? "")
        }) {
            facts[existing] = Fact(text: text, savedAt: now, scope: cleanScope)  // refresh, not duplicate
        } else {
            facts.append(Fact(text: text, savedAt: now, scope: cleanScope))
        }
        if facts.count > Self.maxFacts {
            facts.removeFirst(facts.count - Self.maxFacts)  // oldest out first
        }
    }

    /// Forgetting means everywhere: facts AND the recent-conversation tail,
    /// or an erased secret would keep echoing back through recent context.
    public mutating func forget(matching raw: String) {
        let key = Self.normalize(raw)
        guard !key.isEmpty else { return }
        facts.removeAll { Self.normalize($0.text).contains(key) }
        recent.removeAll { Self.normalize($0).contains(key) }
    }

    public mutating func forgetEverything() {
        facts.removeAll()
        recent.removeAll()
    }

    public mutating func noteExchange(_ line: String) {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        recent.append(String(text.prefix(300)))
        if recent.count > Self.maxRecent {
            recent.removeFirst(recent.count - Self.maxRecent)
        }
    }

    /// The block handed to the model as context. Empty when there is nothing
    /// worth saying, so a fresh install sends no noise.
    ///
    /// `app` is whatever is in front right now. Facts scoped to a different
    /// app are left out: they would be noise at best and wrong at worst.
    public func promptBlock(inApp app: String? = nil) -> String {
        var parts: [String] = []
        let general = facts.filter { $0.scope == nil || $0.scope?.isEmpty == true }
        let here = facts.filter { $0.scope?.isEmpty == false && $0.applies(inApp: app) }
        if !general.isEmpty {
            parts.append("What you remember about this person: "
                + general.map(\.text).joined(separator: "; "))
        }
        if !here.isEmpty, let app {
            parts.append("What you remember about how they work in \(app): "
                + here.map(\.text).joined(separator: "; "))
        }
        if !recent.isEmpty {
            parts.append("Earlier in your conversations: " + recent.joined(separator: " / "))
        }
        return parts.joined(separator: ". ")
    }

    /// Kept so existing callers and tests that want everything unscoped still
    /// read naturally.
    public var promptBlock: String { promptBlock(inApp: nil) }

    /// Splits "in Xcode: keep the left half" into a scope and a fact. The
    /// model is told to write facts this way when they are app-specific, and
    /// anything without the prefix stays global.
    public static func splitScope(_ raw: String) -> (scope: String?, text: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        for prefix in ["in ", "for ", "when in ", "while in "] where lowered.hasPrefix(prefix) {
            let rest = trimmed.dropFirst(prefix.count)
            // The scope ends at the first colon; without one there is no way
            // to tell an app name from the rest of the sentence.
            guard let colon = rest.firstIndex(of: ":") else { continue }
            let scope = rest[rest.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            let text = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !scope.isEmpty, scope.count <= 60, !text.isEmpty else { continue }
            return (scope, text)
        }
        return (nil, trimmed)
    }

    public static func normalize(_ text: String) -> String { TextNormalize.tokens(text) }
}

/// Reads and writes the memory file. Kept separate from the value type so the
/// logic above stays pure and testable.
public enum PetMemoryStore {

    public static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("WindowPet", isDirectory: true)
            .appendingPathComponent("memory.json")
    }

    public static func load() -> PetMemory {
        guard let data = try? Data(contentsOf: fileURL),
              let memory = try? JSONDecoder().decode(PetMemory.self, from: data) else {
            return PetMemory()
        }
        return memory
    }

    public static func save(_ memory: PetMemory) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(memory) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // First write of the session: the directory may not exist yet.
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
