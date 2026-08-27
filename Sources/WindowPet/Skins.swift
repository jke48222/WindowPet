import AppKit
import WindowPetCore

/// One finish for Rusty and everything around him: the sprite set (drawn by
/// PetGen with the matching palette) plus the chat panel and speech bubble
/// tints. Picking a skin recolors the whole product in one move.
struct SkinTheme {
    let id: String
    let displayName: String
    /// Chat panel glass.
    let glassTop: NSColor
    let glassBottom: NSColor
    let border: NSColor
    /// Accent: the skin's eye color. Status lamp, Rusty bubble tint, glints.
    let accent: NSColor
    let thinking: NSColor
    let userText: NSColor
    let rustyText: NSColor
    /// Speech bubble over the pet.
    let bubbleFill: NSColor
    let bubbleTextColor: NSColor

    static let builtins: [SkinTheme] = [
        SkinTheme(id: "tinplate", displayName: "Tinplate",
                  glassTop: NSColor(srgbRed: 43/255, green: 37/255, blue: 31/255, alpha: 0.97),
                  glassBottom: NSColor(srgbRed: 26/255, green: 22/255, blue: 18/255, alpha: 0.97),
                  border: NSColor(srgbRed: 176/255, green: 150/255, blue: 100/255, alpha: 0.4),
                  accent: NSColor(srgbRed: 255/255, green: 199/255, blue: 92/255, alpha: 1),
                  thinking: NSColor(srgbRed: 255/255, green: 128/255, blue: 70/255, alpha: 1),
                  userText: NSColor(srgbRed: 240/255, green: 233/255, blue: 220/255, alpha: 1),
                  rustyText: NSColor(srgbRed: 255/255, green: 230/255, blue: 180/255, alpha: 1),
                  bubbleFill: NSColor(srgbRed: 38/255, green: 32/255, blue: 26/255, alpha: 0.94),
                  bubbleTextColor: NSColor(srgbRed: 245/255, green: 238/255, blue: 224/255, alpha: 1)),
        SkinTheme(id: "seafoam", displayName: "Seafoam",
                  glassTop: NSColor(srgbRed: 27/255, green: 32/255, blue: 44/255, alpha: 0.97),
                  glassBottom: NSColor(srgbRed: 13/255, green: 16/255, blue: 24/255, alpha: 0.97),
                  border: NSColor(srgbRed: 128/255, green: 134/255, blue: 142/255, alpha: 0.45),
                  accent: NSColor(srgbRed: 120/255, green: 235/255, blue: 255/255, alpha: 1),
                  thinking: NSColor(srgbRed: 255/255, green: 180/255, blue: 74/255, alpha: 1),
                  userText: NSColor(srgbRed: 233/255, green: 237/255, blue: 241/255, alpha: 1),
                  rustyText: NSColor(srgbRed: 206/255, green: 243/255, blue: 255/255, alpha: 1),
                  bubbleFill: NSColor(srgbRed: 26/255, green: 31/255, blue: 38/255, alpha: 0.94),
                  bubbleTextColor: NSColor(calibratedWhite: 1, alpha: 0.96)),
        SkinTheme(id: "midnight", displayName: "Midnight",
                  glassTop: NSColor(srgbRed: 24/255, green: 28/255, blue: 37/255, alpha: 0.97),
                  glassBottom: NSColor(srgbRed: 10/255, green: 12/255, blue: 18/255, alpha: 0.98),
                  border: NSColor(srgbRed: 96/255, green: 110/255, blue: 132/255, alpha: 0.45),
                  accent: NSColor(srgbRed: 150/255, green: 235/255, blue: 255/255, alpha: 1),
                  thinking: NSColor(srgbRed: 255/255, green: 150/255, blue: 84/255, alpha: 1),
                  userText: NSColor(srgbRed: 226/255, green: 232/255, blue: 240/255, alpha: 1),
                  rustyText: NSColor(srgbRed: 200/255, green: 240/255, blue: 255/255, alpha: 1),
                  bubbleFill: NSColor(srgbRed: 18/255, green: 21/255, blue: 29/255, alpha: 0.95),
                  bubbleTextColor: NSColor(calibratedWhite: 1, alpha: 0.96)),
        SkinTheme(id: "sakura", displayName: "Sakura",
                  glassTop: NSColor(srgbRed: 46/255, green: 32/255, blue: 39/255, alpha: 0.97),
                  glassBottom: NSColor(srgbRed: 28/255, green: 18/255, blue: 24/255, alpha: 0.97),
                  border: NSColor(srgbRed: 196/255, green: 140/255, blue: 152/255, alpha: 0.42),
                  accent: NSColor(srgbRed: 255/255, green: 214/255, blue: 130/255, alpha: 1),
                  thinking: NSColor(srgbRed: 255/255, green: 132/255, blue: 92/255, alpha: 1),
                  userText: NSColor(srgbRed: 244/255, green: 234/255, blue: 236/255, alpha: 1),
                  rustyText: NSColor(srgbRed: 255/255, green: 226/255, blue: 214/255, alpha: 1),
                  bubbleFill: NSColor(srgbRed: 40/255, green: 27/255, blue: 33/255, alpha: 0.94),
                  bubbleTextColor: NSColor(srgbRed: 250/255, green: 240/255, blue: 240/255, alpha: 1)),
    ]

    /// Built-ins plus anything the user dropped in the skins folder. The
    /// custom half is cached (see CustomSkins), so this is cheap to read from
    /// a draw or layout path.
    static var all: [SkinTheme] { builtins + CustomSkins.themes() }

    static var currentID: String {
        let stored = UserDefaults.standard.string(forKey: "skin") ?? "tinplate"
        return all.contains(where: { $0.id == stored }) ? stored : "tinplate"
    }

    static var current: SkinTheme {
        let id = currentID  // resolve once, not once per element scanned
        return all.first { $0.id == id } ?? builtins[0]
    }

    /// Which built-in sprite set a skin wears. Custom skins pick one.
    static var currentSpriteID: String {
        let id = currentID
        guard id.hasPrefix("custom:") else { return id }
        return CustomSkins.definitions().first { $0.id == id }?.sprites ?? "tinplate"
    }
}

/// User skins: plain JSON files in Application Support, picked up at launch
/// and listed in the Skin menu next to the built-ins.
enum CustomSkins {

    static var folderURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("WindowPet", isDirectory: true)
            .appendingPathComponent("Skins", isDirectory: true)
    }

    /// Creates the folder with a worked example the first time it is opened,
    /// so there is something to edit rather than an empty window.
    @discardableResult
    static func ensureFolder() -> URL {
        let folder = folderURL
        let manager = FileManager.default
        if !manager.fileExists(atPath: folder.path) {
            try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(SkinDefinition.example) {
                try? data.write(to: folder.appendingPathComponent("my-skin.json"))
            }
            let readme = """
            Drop a .json file here to add your own skin. Copy my-skin.json and
            edit it, then pick your skin from the Skin menu.

            sprites: which robot finish to wear, one of
            \(SkinDefinition.spriteChoices.joined(separator: ", ")).
            Every other field is a color, written like #33aaff or #33aaffcc.
            Bad files are skipped, and the menu says which ones and why.
            """
            try? readme.write(to: folder.appendingPathComponent("README.txt"),
                              atomically: true, encoding: .utf8)
        }
        return folder
    }

    private static func jsonFiles() -> [URL] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension.lowercased() == "json" }
    }

    static func definitions() -> [SkinDefinition] {
        jsonFiles()
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url -> SkinDefinition? in
                guard let data = try? Data(contentsOf: url),
                      let definition = try? JSONDecoder().decode(SkinDefinition.self, from: data),
                      definition.problems.isEmpty else { return nil }
                return definition
            }
    }

    /// Files that failed to load, with the reason, so a typo is visible
    /// instead of a skin silently missing from the menu.
    static func problems() -> [String] {
        jsonFiles().compactMap { url -> String? in
            let name = url.lastPathComponent
            guard let data = try? Data(contentsOf: url) else { return "\(name): unreadable" }
            guard let definition = try? JSONDecoder().decode(SkinDefinition.self, from: data) else {
                return "\(name): not valid skin JSON"
            }
            let problems = definition.problems
            return problems.isEmpty ? nil : "\(name): \(problems.joined(separator: ", "))"
        }
    }

    /// Decoded custom skins, cached so `SkinTheme.current` (read from draw and
    /// layout, potentially per frame while streaming) does not scan the disk.
    /// `reload()` clears it when the folder changes.
    private static var cache: [SkinTheme]?

    static func themes() -> [SkinTheme] {
        if let cache { return cache }
        let loaded = load()
        cache = loaded
        return loaded
    }

    static func reload() { cache = nil }

    static func load() -> [SkinTheme] {
        definitions().compactMap { definition in
            func color(_ hex: String) -> NSColor {
                guard let c = HexColor.parse(hex) else { return .gray }
                return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
            }
            return SkinTheme(
                id: definition.id, displayName: definition.name,
                glassTop: color(definition.glassTop),
                glassBottom: color(definition.glassBottom),
                border: color(definition.border),
                accent: color(definition.accent),
                thinking: color(definition.thinking),
                userText: color(definition.userText),
                rustyText: color(definition.rustyText),
                bubbleFill: color(definition.bubbleFill),
                bubbleTextColor: color(definition.bubbleText))
        }
    }
}
