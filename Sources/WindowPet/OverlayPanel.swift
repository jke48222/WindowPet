import AppKit

/// The pet's window: transparent, borderless, click-through, on every Space,
/// never steals focus. This is the overlay recipe from the dossier (same
/// pattern as Clicky's OverlayWindow) — a non-activating NSPanel is the
/// difference between a pet and an interruption.
final class OverlayPanel: NSPanel {

    init(contentRect: CGRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        collectionBehavior = [
            .canJoinAllSpaces,       // appear on every Space, like the menu bar
            .fullScreenAuxiliary,    // allowed to show over fullscreen windows
            .stationary,             // don't slide during Space-switch animation
        ]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true    // pure click-through for the milestone
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        animationBehavior = .none    // no genie effects when ordering in/out
    }

    // Never take key or main — reinforces .nonactivatingPanel.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
