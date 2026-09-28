import AppKit
import WindowPetCore

/// The pet's picture of the world: every on-screen window (AppKit coords,
/// front-to-back) plus screen floors, reduced to standable platforms by
/// Terrain. Refreshed on demand at state-dependent cadences — never per-frame.
final class WorldModel {

    struct WinAK {
        let id: CGWindowID
        let ownerPID: pid_t
        let frame: CGRect // AppKit coords
    }

    /// Test hook: when set, only this PID's windows form terrain, so the rig
    /// is deterministic regardless of what else is on the user's screen.
    var restrictPID: pid_t?

    private(set) var windows: [WinAK] = []
    private(set) var floors: [CGRect] = []
    private(set) var platforms: [Platform] = []
    private(set) var lastRefreshAt: TimeInterval = 0

    func refresh(now: TimeInterval) {
        let h = Self.primaryScreenHeight()
        windows = Tier1.onScreenWindowsFrontToBack()
            .filter { w in
                w.layer == 0 && w.isOnScreen
                    && w.frame.width >= 120 && w.frame.height >= 60
                    && (restrictPID == nil || w.ownerPID == restrictPID)
            }
            .map { WinAK(id: $0.id, ownerPID: $0.ownerPID,
                         frame: Geometry.appKitRect(fromCGGlobal: $0.frame, primaryScreenHeight: h)) }
        floors = NSScreen.screens.map { $0.visibleFrame }
        platforms = Terrain.exposedPlatforms(
            windowsFrontToBack: windows.map { (id: $0.id, frame: $0.frame) },
            floors: floors,
            minSegmentWidth: 40)
        lastRefreshAt = now
    }

    func refreshIfStale(now: TimeInterval, maxAge: TimeInterval) {
        if now - lastRefreshAt > maxAge { refresh(now: now) }
    }

    /// Live single-window query (the cheap hot-loop path). nil once closed
    /// or minimized.
    func liveWindowFrame(id: CGWindowID) -> CGRect? {
        guard let w = Tier1.window(byID: id), w.isOnScreen else { return nil }
        return Geometry.appKitRect(fromCGGlobal: w.frame,
                                   primaryScreenHeight: Self.primaryScreenHeight())
    }

    func cachedWindow(id: CGWindowID) -> WinAK? {
        windows.first { $0.id == id }
    }

    /// Frontmost app's topmost standard window, from the refreshed cache.
    func frontTopWindow(forcePID: pid_t?, allowOwn: Bool) -> WinAK? {
        let pid: pid_t
        if let forcePID {
            pid = forcePID
        } else {
            guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
            pid = app.processIdentifier
            if !allowOwn && pid == ProcessInfo.processInfo.processIdentifier { return nil }
        }
        return windows.first { $0.ownerPID == pid }
    }

    /// Is this window's top edge exposed (standable) at horizontal x?
    func isExposed(windowID: CGWindowID, atX x: CGFloat) -> Bool {
        platforms.contains {
            $0.kind == .window(windowID) && $0.minX - 2 <= x && x <= $0.maxX + 2
        }
    }

    /// The exposed segment the pet occupies while walking at `point`, nil if
    /// it vanished. Every display has a floor of kind `.floor`, so a floor is
    /// identified by the point as well: the one under him, not the first
    /// display whose x range matches.
    func segment(of kind: Platform.Kind, at point: CGPoint) -> Platform? {
        if kind == .floor { return floorPlatform(under: point) }
        return platforms.first { $0.kind == kind && $0.minX - 2 <= point.x && point.x <= $0.maxX + 2 }
    }

    /// The floor under `point`: the highest display floor at or below it
    /// among those spanning its x, else the nearest. Displays stacked one
    /// above another share x ranges, so x alone picks the wrong display.
    /// The pet always has ground somewhere.
    func floorPlatform(under point: CGPoint) -> Platform {
        let f = floorRect(under: point)
        return Platform(kind: .floor, topY: f.minY, minX: f.minX, maxX: f.maxX)
    }

    /// The usable area of the display whose floor is under `point`. Wall
    /// heights come from this rect, the floor's own display.
    func floorRect(under point: CGPoint) -> CGRect {
        DisplayGeometry.floorIndex(under: point, floors: floors).map { floors[$0] }
            ?? CGRect(x: 0, y: 0, width: 1512, height: 982)
    }

    /// The frontmost window when it's maximized-or-larger (≥90% of its
    /// screen) but not truly fullscreen — the "user is focused on one big
    /// thing" signal that quiets the pet.
    func maximizedFrontWindow() -> WinAK? {
        guard let front = windows.first, let cov = coverage(of: front) else { return nil }
        return cov >= 0.90 && !ReactionPolicy.isImmersive(coverage: cov) ? front : nil
    }

    private func coverage(of w: WinAK) -> CGFloat? {
        let screen = NSScreen.screens.first { $0.frame.intersects(w.frame) }
            ?? NSScreen.screens.first
        guard let screen else { return nil }
        let i = w.frame.intersection(screen.frame)
        return (i.width * i.height) / max(1, screen.frame.width * screen.frame.height)
    }

    /// The frontmost window if it essentially covers its whole screen —
    /// fullscreen video/games. Coverage is judged against the screen's FULL
    /// frame, so a maximized window under a visible menu bar doesn't count.
    func immersionWindow() -> WinAK? {
        guard let front = windows.first, let cov = coverage(of: front) else { return nil }
        return ReactionPolicy.isImmersive(coverage: cov) ? front : nil
    }

    static func primaryScreenHeight() -> CGFloat {
        NSScreen.screens.first?.frame.height ?? 1080
    }
}
