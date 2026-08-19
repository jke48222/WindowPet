import AppKit
import CoreGraphics

/// A window as seen by Tier 1. Frame is in CG global coordinates (top-left
/// origin) — convert via Geometry before touching AppKit.
struct TrackedWindow {
    let id: CGWindowID
    let ownerPID: pid_t
    let frame: CGRect
    let isOnScreen: Bool
    let layer: Int
}

/// Tier 1 of the two-tier window model: `CGWindowListCopyWindowInfo`, polled.
/// Bounds + z-order for every window with zero permissions. This is the
/// always-correct geometry floor; AX (Tier 2, later) adds semantics on top.
///
/// PERMISSION INVARIANT: this file must never read `kCGWindowName` or
/// `kCGWindowOwnerName` — window titles and owner names trip the Screen
/// Recording prompt on macOS 15+. Bounds, layer, PID, and window number do
/// not. Keep it greppable.
enum Tier1 {

    /// Every on-screen window, front-to-back (CGWindowList returns z-order).
    static func onScreenWindowsFrontToBack() -> [TrackedWindow] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return raw.compactMap(decode)
    }

    /// Topmost ordinary document window owned by `pid`. Layer 0 filters out
    /// panels, status items, tooltips, and our own floating overlay; the size
    /// floor skips popovers and tool palettes.
    static func topmostStandardWindow(ownedBy pid: pid_t) -> TrackedWindow? {
        onScreenWindowsFrontToBack().first { w in
            w.ownerPID == pid && w.layer == 0 && w.isOnScreen
                && w.frame.width >= 120 && w.frame.height >= 60
        }
    }

    /// Cheap single-window query for the tracking loop — asks the window
    /// server about ONE window instead of copying the whole list at 60 Hz.
    /// Returns nil once the window is destroyed.
    static func window(byID id: CGWindowID) -> TrackedWindow? {
        guard let raw = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let dict = raw.first else {
            return nil
        }
        return decode(dict)
    }

    private static func decode(_ dict: [String: Any]) -> TrackedWindow? {
        guard let idNum = dict[kCGWindowNumber as String] as? NSNumber,
              let pidNum = dict[kCGWindowOwnerPID as String] as? NSNumber,
              let boundsDict = dict[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: boundsDict) else {
            return nil
        }
        let alpha = (dict[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0
        guard alpha > 0.05 else { return nil }
        return TrackedWindow(
            id: CGWindowID(idNum.uint32Value),
            ownerPID: pid_t(pidNum.int32Value),
            frame: frame,
            isOnScreen: (dict[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false,
            layer: (dict[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        )
    }
}
