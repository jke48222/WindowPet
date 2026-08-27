import AppKit

/// Grabs the screen for Rusty's "look at my screen" answers. Capturing
/// another app's window content needs Screen Recording permission on modern
/// macOS; the first capture triggers the system prompt. Downscaled before
/// base64 so the vision request stays fast and cheap without losing legible
/// text (1568px on the long edge is plenty for reading a screen).
enum ScreenCapture {

    static func snapshotBase64(longEdge: Int = 1568) -> String? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rusty-look-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // -x silences the shutter; -t png for a lossless read of text.
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-t", "png", tmp.path]
        do {
            try capture.run()
            capture.waitUntilExit()
        } catch { return nil }
        guard capture.terminationStatus == 0,
              let raw = try? Data(contentsOf: tmp), raw.count > 1000 else { return nil }

        // Downscale in place; if sips is unavailable, send the full-size grab.
        let resize = Process()
        resize.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        resize.arguments = ["-Z", String(longEdge), tmp.path]
        resize.standardOutput = FileHandle.nullDevice
        resize.standardError = FileHandle.nullDevice
        try? resize.run()
        resize.waitUntilExit()

        guard let data = try? Data(contentsOf: tmp) else {
            return raw.base64EncodedString()
        }
        return data.base64EncodedString()
    }
}
