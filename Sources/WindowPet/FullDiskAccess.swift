import AppKit

/// Full Disk Access is a user-granted TCC permission: no app can flip it for
/// itself, so this only detects the state and points the user at the exact
/// System Settings pane. With it granted, the shell and AppleScript tools
/// Rusty runs can reach protected locations (Mail, Messages, Safari, other
/// apps' containers, Time Machine) instead of being quietly denied.
enum FullDiskAccess {

    /// The TCC database exists for every user but is readable only with Full
    /// Disk Access, which makes opening it a reliable, side-effect-free probe.
    static var granted: Bool {
        let path = ("~/Library/Application Support/com.apple.TCC/TCC.db" as NSString)
            .expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else { return false }
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        return true
    }

    /// Opens System Settings straight to Privacy and Security, Full Disk
    /// Access. The user drags WindowPet in (or toggles it on) themselves.
    static func openSettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }
}
