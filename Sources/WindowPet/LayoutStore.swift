import Foundation
import WindowPetCore

/// Named window arrangements, saved next to the memory file so they survive
/// launches. Small enough to rewrite whole on every change.
@MainActor
enum LayoutStore {

    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("WindowPet", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("layouts.json")
    }

    static func load() -> [WindowLayout] {
        guard let data = try? Data(contentsOf: url),
              let layouts = try? JSONDecoder().decode([WindowLayout].self, from: data) else {
            return []
        }
        return layouts
    }

    static func save(_ layouts: [WindowLayout]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(layouts) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Saving over an existing name replaces it: people re-save a layout after
    /// nudging it, and a second "writing" would be a bug rather than a choice.
    static func store(_ layout: WindowLayout) {
        var layouts = load().filter {
            WindowLayout.normalize($0.name) != WindowLayout.normalize(layout.name)
        }
        layouts.append(layout)
        save(layouts)
    }

    static func named(_ name: String) -> WindowLayout? {
        let wanted = WindowLayout.normalize(name)
        let layouts = load()
        if let exact = layouts.first(where: { WindowLayout.normalize($0.name) == wanted }) {
            return exact
        }
        // People recall layouts by half the name. One partial match is an
        // answer; several is ambiguous, so it is treated as a miss.
        let partial = layouts.filter { WindowLayout.normalize($0.name).contains(wanted) }
        return partial.count == 1 ? partial[0] : nil
    }

    static func listing() -> String {
        let layouts = load()
        guard !layouts.isEmpty else {
            return "No saved layouts yet. Arrange your windows how you like them, then ask me to save the layout under a name."
        }
        return layouts.map(\.summary).joined(separator: "\n")
    }
}
