import AppKit
import WindowPetCore

/// Standing asks, fired by the app that is already running all day.
///
/// Each entry costs a real agent turn when it fires, so this respects the same
/// daily ceiling as everything else and never fires more than once per slot.
/// Anything it produces arrives unprompted, which means it goes through the
/// quiet policy rather than talking over a call.
@MainActor
final class ScheduleRunner {

    /// Called with the request to run and the entry it came from.
    var onFire: ((SchedulePolicy.Entry) -> Void)?

    private(set) var entries: [SchedulePolicy.Entry] = []
    private var nextID = 1
    private var ticker: DispatchSourceTimer?

    init() {
        entries = ScheduleStore.load()
        nextID = (entries.map(\.id).max() ?? 0) + 1
        startTickerIfNeeded()
    }

    func add(_ raw: String, now: Date = Date()) -> String {
        guard entries.count < SchedulePolicy.maxEntries else {
            return "I already have \(entries.count) standing asks, which is my limit. Drop one first."
        }
        guard let entry = SchedulePolicy.parse(raw, id: nextID, now: now) else {
            return "I couldn't read a time and a request out of that. Try something like: every weekday at 9: tell me what is on my calendar."
        }
        nextID += 1
        entries.append(entry)
        ScheduleStore.save(entries)
        startTickerIfNeeded()
        return SchedulePolicy.acknowledgement(entry)
    }

    func remove(matching raw: String) -> String {
        let needle = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !entries.isEmpty else { return "Nothing is scheduled." }
        if needle == "everything" || needle == "all" {
            let count = entries.count
            entries.removeAll()
            ScheduleStore.save(entries)
            stopTicker()
            return "Dropped all \(count) standing \(count == 1 ? "ask" : "asks")."
        }
        if let number = Int(needle), entries.indices.contains(number - 1) {
            let removed = entries.remove(at: number - 1)
            ScheduleStore.save(entries)
            return "Dropped: \(removed.description)"
        }
        guard let index = entries.firstIndex(where: {
            $0.request.lowercased().contains(needle) || $0.description.lowercased().contains(needle)
        }) else {
            return "I don't have a standing ask matching \(raw)."
        }
        let removed = entries.remove(at: index)
        ScheduleStore.save(entries)
        if entries.isEmpty { stopTicker() }
        return "Dropped: \(removed.description)"
    }

    func listing() -> String { SchedulePolicy.listing(entries) }

    // MARK: - The tick

    private func startTickerIfNeeded() {
        guard !entries.isEmpty, ticker == nil else { return }
        // Every twenty seconds. The grace window is ten minutes wide, so this
        // is far more often than it needs to be and still costs nothing.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 20, repeating: 20)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        ticker = timer
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    private func tick() {
        guard !entries.isEmpty else { return stopTicker() }
        let now = Date()
        for (index, entry) in entries.enumerated() where SchedulePolicy.isDue(entry, now: now) {
            entries[index].markFired(at: now)
            onFire?(entry)
        }
        // A one-off is done once it has fired; leaving it would clutter the
        // list with things that will never happen again.
        entries.removeAll { $0.cadence == .once && $0.lastFiredAt != nil }
        ScheduleStore.save(entries)
        if entries.isEmpty { stopTicker() }
    }
}

/// Standing asks on disk, next to the layouts and the memory.
@MainActor
enum ScheduleStore {

    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("WindowPet", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("schedules.json")
    }

    static func load() -> [SchedulePolicy.Entry] {
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([SchedulePolicy.Entry].self, from: data)
        else { return [] }
        return entries
    }

    static func save(_ entries: [SchedulePolicy.Entry]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Learned routines on disk.
@MainActor
enum TrickStore {

    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("WindowPet", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("tricks.json")
    }

    static func load() -> [Trick] {
        guard let data = try? Data(contentsOf: url),
              let tricks = try? JSONDecoder().decode([Trick].self, from: data) else { return [] }
        return tricks
    }

    static func save(_ tricks: [Trick]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(tricks) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func store(_ trick: Trick) {
        var tricks = load().filter { TrickPolicy.normalize($0.name) != TrickPolicy.normalize(trick.name) }
        tricks.append(trick)
        if tricks.count > TrickPolicy.maxTricks {
            tricks.removeFirst(tricks.count - TrickPolicy.maxTricks)
        }
        save(tricks)
    }

    static func named(_ name: String) -> Trick? {
        let wanted = TrickPolicy.normalize(name)
        let tricks = load()
        if let exact = tricks.first(where: { TrickPolicy.normalize($0.name) == wanted }) {
            return exact
        }
        let partial = tricks.filter { TrickPolicy.normalize($0.name).contains(wanted) }
        return partial.count == 1 ? partial[0] : nil
    }

    static func remove(_ name: String) -> Bool {
        let wanted = TrickPolicy.normalize(name)
        let tricks = load()
        let kept = tricks.filter { TrickPolicy.normalize($0.name) != wanted }
        guard kept.count != tricks.count else { return false }
        save(kept)
        return true
    }
}
