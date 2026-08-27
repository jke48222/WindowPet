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
        public init(text: String, savedAt: Date = Date()) {
            self.text = text
            self.savedAt = savedAt
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
    public mutating func remember(_ raw: String, now: Date = Date()) {
        let text = String(raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(Self.maxFactLength))
        guard text.count > 2 else { return }
        let key = Self.normalize(text)
        if let existing = facts.firstIndex(where: { Self.normalize($0.text) == key }) {
            facts[existing] = Fact(text: text, savedAt: now)  // refresh instead of duplicate
        } else {
            facts.append(Fact(text: text, savedAt: now))
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
    public var promptBlock: String {
        var parts: [String] = []
        if !facts.isEmpty {
            parts.append("What you remember about this person: "
                + facts.map(\.text).joined(separator: "; "))
        }
        if !recent.isEmpty {
            parts.append("Earlier in your conversations: " + recent.joined(separator: " / "))
        }
        return parts.joined(separator: ". ")
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
