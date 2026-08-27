import AppKit
import WindowPetCore

/// The app's one bridge from AppKit's display list to the pure policy in
/// `DisplayChoice`. Everything that positions UI or snaps a window goes
/// through here, so a two-display Mac behaves the same as a one-display Mac.
@MainActor
enum Screens {

    /// Height of the primary display, used to flip between AppKit's
    /// bottom-left origin and the Accessibility API's top-left origin. The
    /// primary display is always `screens[0]`: the one whose origin is (0, 0).
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 982 }

    /// Stand-in for a machine that reports no displays (headless test runs,
    /// and the sliver of launch before the window server answers).
    static let fallbackVisibleFrame = CGRect(x: 0, y: 0, width: 1512, height: 944)

    private static var frames: [CGRect] { NSScreen.screens.map(\.frame) }

    /// Index of `NSScreen.main` in the display list, when it has one.
    private static var keyIndex: Int? {
        guard let main = NSScreen.main else { return nil }
        return NSScreen.screens.firstIndex { $0.frame == main.frame }
    }

    /// Where UI should appear: the display holding `point` if given, else the
    /// display under the pointer, else the key screen, else the primary.
    static func best(for point: CGPoint? = nil) -> NSScreen? {
        guard let index = DisplayChoice.index(preferred: point, mouse: NSEvent.mouseLocation,
                                              fallback: keyIndex, in: frames) else { return nil }
        return NSScreen.screens[index]
    }

    static func visibleFrame(for point: CGPoint? = nil) -> CGRect {
        best(for: point)?.visibleFrame ?? fallbackVisibleFrame
    }

    /// Usable area of the display a window occupies, given its Accessibility
    /// frame (top-left origin, measured from the primary display). This is
    /// what makes "snap left" snap within the display the window is already
    /// on instead of yanking it to the main one.
    static func visibleFrame(forAXPosition position: CGPoint, size: CGSize) -> CGRect {
        let appKit = Geometry.appKitRect(
            fromCGGlobal: CGRect(origin: position, size: size),
            primaryScreenHeight: primaryHeight)
        if let index = DisplayChoice.index(overlapping: appKit, in: frames) {
            return NSScreen.screens[index].visibleFrame
        }
        return visibleFrame(for: CGPoint(x: appKit.midX, y: appKit.midY))
    }

    /// Keeps a panel of `size` on a real display, moving it to the nearest
    /// sensible spot when its remembered origin no longer lands anywhere.
    static func clamp(origin: CGPoint, size: CGSize, inset: CGFloat = 12) -> CGPoint {
        DisplayChoice.clamp(origin: origin, size: size,
                            into: visibleFrame(for: origin), inset: inset)
    }
}
