import AppKit
import QuartzCore

/// The pet's presentation layer, rebuilt for stage 2: one screen-sized
/// overlay panel per display (same recipe — floating, all-Spaces,
/// non-activating), with the sprite as a CALayer moved GPU-side. Moving a
/// layer is a Core Animation transaction, not a window-server geometry
/// change — this is what brings active-state CPU inside the energy budget.
///
/// It also owns the "click-through with a hole" state: panels ignore mouse
/// events except while the cursor is over actual creature pixels (per-frame
/// alpha mask), which is what makes the pet feel physical instead of painted.
final class OverlayStage {

    let spriteSize = CGSize(width: 64, height: 64)
    let footOverlap: CGFloat = 5

    private(set) var panels: [OverlayPanel] = []
    private var views: [PetView] = []
    private var screenFrames: [CGRect] = []
    private let sprite = CALayer()
    private var currentPanelIndex = 0
    private(set) var currentMask: SpriteSet.AlphaMask?
    private(set) var anchor: CGPoint = .zero
    private(set) var facing: CGFloat = 1
    private(set) var rotationDegrees: CGFloat = 0
    private var holeOpen = false
    private var hidden = false

    // Engine hooks (points are in global AppKit coordinates).
    var onGrab: ((CGPoint) -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    var onRelease: ((CGPoint) -> Void)?

    init() {
        sprite.bounds = CGRect(origin: .zero, size: spriteSize)
        sprite.contentsGravity = .resizeAspect
        sprite.contentsScale = 2 // frames are 128 px for a 64 pt sprite
        sprite.actions = ["contents": NSNull(), "transform": NSNull(),
                          "position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        rebuildPanels()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.rebuildPanels() }
    }

    func rebuildPanels() {
        panels.forEach { $0.orderOut(nil) }
        panels = []
        views = []
        screenFrames = NSScreen.screens.map(\.frame)
        if screenFrames.isEmpty { screenFrames = [CGRect(x: 0, y: 0, width: 1512, height: 982)] }
        for frame in screenFrames {
            let panel = OverlayPanel(contentRect: frame)
            let view = PetView(stage: self, frame: CGRect(origin: .zero, size: frame.size))
            panel.contentView = view
            if !hidden { panel.orderFrontRegardless() }
            panels.append(panel)
            views.append(view)
        }
        currentPanelIndex = min(currentPanelIndex, panels.count - 1)
        views[currentPanelIndex].layer?.addSublayer(sprite)
        place(anchor: anchor)
    }

    /// The display link should tick with the primary display.
    var displayLinkSourceView: NSView { views[0] }

    // MARK: - Placement

    /// Where the sprite's visual center sits for a given feet anchor, given
    /// the current wall rotation: the body extends away from the surface.
    func spriteCenter(for a: CGPoint) -> CGPoint {
        let reach = spriteSize.height / 2 - footOverlap
        switch rotationDegrees {
        case -90: return CGPoint(x: a.x + reach, y: a.y)  // feet on left wall
        case 90: return CGPoint(x: a.x - reach, y: a.y)   // feet on right wall
        default: return CGPoint(x: a.x, y: a.y + reach)   // feet down
        }
    }

    var spriteGlobalRect: CGRect {
        let c = spriteCenter(for: anchor)
        return CGRect(x: c.x - spriteSize.width / 2, y: c.y - spriteSize.height / 2,
                      width: spriteSize.width, height: spriteSize.height)
    }

    func place(anchor a: CGPoint) {
        anchor = a
        let idx = screenFrames.firstIndex { $0.contains(a) } ?? currentPanelIndex
        if idx != currentPanelIndex, idx < views.count {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sprite.removeFromSuperlayer()
            views[idx].layer?.addSublayer(sprite)
            CATransaction.commit()
            currentPanelIndex = idx
        }
        let center = spriteCenter(for: a)
        let origin = panels[currentPanelIndex].frame.origin
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.position = CGPoint(x: (center.x - origin.x).rounded(),
                                  y: (center.y - origin.y).rounded())
        CATransaction.commit()
    }

    func setPose(rotationDegrees rot: CGFloat, facing f: CGFloat) {
        guard rot != rotationDegrees || f != facing else { return }
        rotationDegrees = rot
        facing = f
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let flip = CATransform3DMakeScale(f, 1, 1)
        let spin = CATransform3DMakeRotation(rot * .pi / 180, 0, 0, 1)
        sprite.transform = CATransform3DConcat(flip, spin) // flip in sprite space, then rotate
        CATransaction.commit()
        place(anchor: anchor) // center offset depends on rotation
    }

    func show(_ frame: SpriteSet.Frame?) {
        guard let frame else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.contents = frame.image
        CATransaction.commit()
        currentMask = frame.mask
    }

    var isPetVisible: Bool {
        !hidden && sprite.contents != nil && panels.indices.contains(currentPanelIndex)
            && panels[currentPanelIndex].isVisible
    }

    func hideAll() {
        hidden = true
        panels.forEach { $0.orderOut(nil) }
    }

    func showAll() {
        hidden = false
        panels.forEach { $0.orderFrontRegardless() }
    }

    // MARK: - Hit testing & the hole

    /// Is this global point over actual creature pixels (rotation- and
    /// facing-aware, per-frame alpha mask)?
    func hit(_ p: CGPoint) -> Bool {
        let rect = spriteGlobalRect
        guard rect.contains(p), let mask = currentMask else { return false }
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var v = CGPoint(x: p.x - c.x, y: p.y - c.y)
        let theta = -rotationDegrees * .pi / 180 // inverse rotation
        v = CGPoint(x: v.x * cos(theta) - v.y * sin(theta),
                    y: v.x * sin(theta) + v.y * cos(theta))
        if facing < 0 { v.x = -v.x } // inverse flip
        return mask.opaque(x01: (v.x + spriteSize.width / 2) / spriteSize.width,
                           y01up: (v.y + spriteSize.height / 2) / spriteSize.height)
    }

    /// Open the hole (accept mouse events) only while the cursor is over
    /// creature pixels — or unconditionally while the pet is being dragged.
    /// Everything else on the panel stays pure click-through.
    @discardableResult
    func updateHole(mouse: CGPoint, forceOpen: Bool) -> Bool {
        let open = forceOpen || hit(mouse)
        if open != holeOpen {
            holeOpen = open
            for (i, panel) in panels.enumerated() {
                panel.ignoresMouseEvents = !(open && i == currentPanelIndex)
            }
        }
        return open
    }

    var holeIsOpen: Bool { holeOpen }
}

/// Screen-filling content view: forwards clicks on creature pixels to the
/// stage, refuses everything else (belt and braces on top of the
/// ignoresMouseEvents hole).
final class PetView: NSView {
    private weak var stage: OverlayStage?

    init(stage: OverlayStage, frame: CGRect) {
        self.stage = stage
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func global(_ event: NSEvent) -> CGPoint {
        guard let w = window else { return event.locationInWindow }
        let p = event.locationInWindow
        return CGPoint(x: w.frame.origin.x + p.x, y: w.frame.origin.y + p.y)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let stage, let w = window else { return nil }
        let g = CGPoint(x: w.frame.origin.x + point.x, y: w.frame.origin.y + point.y)
        // While a drag is in flight the hole is forced open; keep receiving.
        return stage.hit(g) || stage.holeIsOpen ? self : nil
    }

    override func mouseDown(with event: NSEvent) { stage?.onGrab?(global(event)) }
    override func mouseDragged(with event: NSEvent) { stage?.onDrag?(global(event)) }
    override func mouseUp(with event: NSEvent) { stage?.onRelease?(global(event)) }
}
