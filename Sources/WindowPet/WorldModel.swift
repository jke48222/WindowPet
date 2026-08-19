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

    /// The exposed segment the pet occupies while walking, nil if it vanished.
    func segment(of kind: Platform.Kind, atX x: CGFloat) -> Platform? {
        platforms.first { $0.kind == kind && $0.minX - 2 <= x && x <= $0.maxX + 2 }
    }

    /// Floor under horizontal position x: the screen containing it, else the
    /// nearest — the pet always has ground somewhere.
    func floorPlatform(atX x: CGFloat) -> Platform {
        let f = floors.first { $0.minX <= x && x <= $0.maxX }
            ?? floors.min { abs($0.midX - x) < abs($1.midX - x) }
            ?? CGRect(x: 0, y: 0, width: 1512, height: 982)
        return Platform(kind: .floor, topY: f.minY, minX: f.minX, maxX: f.maxX)
    }

    static func primaryScreenHeight() -> CGFloat {
        NSScreen.screens.first?.frame.height ?? 1080
    }
}
