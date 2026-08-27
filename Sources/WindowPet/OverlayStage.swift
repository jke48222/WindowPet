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
@MainActor
final class OverlayStage {

    let spriteSize = CGSize(width: 64, height: 64)
    let footOverlap: CGFloat = 5

    private(set) var panels: [OverlayPanel] = []
    private var views: [PetView] = []
    private var screenFrames: [CGRect] = []
    /// Highest y the sprite may reach per screen: below the menu bar AND the
    /// notch band (which macOS paints black over everything in fullscreen).
    private var screenClampTops: [CGFloat] = []
    private let sprite = CALayer()
    private let bubble = CALayer()
    private let bubbleText = CATextLayer()

    /// Re-applies the current skin's bubble palette (skin switches).
    func retintBubble() {
        bubble.backgroundColor = SkinTheme.current.bubbleFill.cgColor
        bubble.borderColor = SkinTheme.current.accent.withAlphaComponent(0.16).cgColor
        bubbleTail.fillColor = bubble.backgroundColor
    }
    private let bubbleTail = CAShapeLayer()
    private var bubbleHideAt: TimeInterval = 0
    private var bubbleTimer: DispatchSourceTimer?
    private(set) var bubbleVisible = false
    private(set) var debugBubbleText = ""
    private var currentPanelIndex = 0
    private(set) var currentMask: SpriteSet.AlphaMask?
    private(set) var anchor: CGPoint = .zero
    private(set) var facing: CGFloat = 1   // logical (engine's intent)
    private(set) var rotationDegrees: CGFloat = 0
    /// -1 for sprite sets whose art faces left (classic Shimeji).
    var facingSign: CGFloat = 1 {
        didSet {
            guard facingSign != oldValue else { return }
            applyTransform()
            place(anchor: anchor)
        }
    }
    private var effectiveFacing: CGFloat { facing * facingSign }
    private var holeOpen = false
    private var hidden = false

    // Engine hooks (points are in global AppKit coordinates).
    var onGrab: ((CGPoint) -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    var onRelease: ((CGPoint) -> Void)?
    var onDoubleClick: (() -> Void)?
    /// Files dropped onto the sprite. Dropping something on Rusty is a
    /// physical act of consent, so these are read without a confirmation the
    /// way the gated read_file tool needs one.
    var onFilesDropped: (([URL]) -> Void)?

    init() {
        sprite.bounds = CGRect(origin: .zero, size: spriteSize)
        sprite.contentsGravity = .resizeAspect
        sprite.contentsScale = 2 // frames are 128 px for a 64 pt sprite
        sprite.actions = ["contents": NSNull(), "transform": NSNull(),
                          "position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        bubble.backgroundColor = SkinTheme.current.bubbleFill.cgColor
        bubble.cornerRadius = 12
        bubble.borderWidth = 1
        bubble.borderColor = SkinTheme.current.accent.withAlphaComponent(0.16).cgColor
        bubble.isHidden = true
        bubble.actions = ["position": NSNull(), "hidden": NSNull(), "bounds": NSNull()]
        bubbleText.contentsScale = 2
        bubbleText.isWrapped = true
        bubbleText.actions = ["contents": NSNull()]
        bubble.addSublayer(bubbleText)
        bubbleTail.fillColor = bubble.backgroundColor
        bubbleTail.actions = ["position": NSNull(), "hidden": NSNull(), "path": NSNull()]
        bubble.addSublayer(bubbleTail)

        rebuildPanels()
        // Displays plugged, unplugged, or rearranged. Delivered on the main
        // queue, hence assumeIsolated rather than a hop.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildPanels() }
        }
    }

    func rebuildPanels() {
        panels.forEach { $0.orderOut(nil) }
        panels = []
        views = []
        screenFrames = NSScreen.screens.map(\.frame)
        screenClampTops = NSScreen.screens.map {
            min($0.visibleFrame.maxY, $0.frame.maxY - $0.safeAreaInsets.top)
        }
        if screenFrames.isEmpty {
            screenFrames = [CGRect(x: 0, y: 0, width: 1512, height: 982)]
            screenClampTops = [944]
        }
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
        views[currentPanelIndex].layer?.addSublayer(bubble)
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
        case 180: return CGPoint(x: a.x, y: a.y - reach)  // hanging: body below
        default: return CGPoint(x: a.x, y: a.y + reach)   // feet down
        }
    }

    /// Highest y a sprite may occupy around this anchor (menu bar / notch).
    func clampTop(forAnchor a: CGPoint) -> CGFloat {
        let idx = screenFrames.firstIndex { $0.contains(a) }
            ?? min(currentPanelIndex, max(0, screenClampTops.count - 1))
        return screenClampTops.indices.contains(idx) ? screenClampTops[idx] : 944
    }

    /// Where the sprite is actually drawn: the physics center, pushed down
    /// just enough to stay fully on its screen. Standing on a maximized
    /// window's title bar otherwise leaves only the toes visible.
    func displayedCenter(for a: CGPoint) -> CGPoint {
        var c = spriteCenter(for: a)
        let idx = screenFrames.firstIndex { $0.contains(a) }
            ?? screenFrames.firstIndex { $0.contains(c) }
            ?? min(currentPanelIndex, screenFrames.count - 1)
        let overflow = (c.y + spriteSize.height / 2) - screenClampTops[idx]
        if overflow > 0 { c.y -= overflow }
        return c
    }

    var spriteGlobalRect: CGRect {
        let c = displayedCenter(for: anchor)
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
            bubble.removeFromSuperlayer()
            views[idx].layer?.addSublayer(sprite)
            views[idx].layer?.addSublayer(bubble)
            CATransaction.commit()
            currentPanelIndex = idx
        }
        let center = displayedCenter(for: a)
        let origin = panels[currentPanelIndex].frame.origin
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.position = CGPoint(x: (center.x - origin.x).rounded(),
                                  y: (center.y - origin.y).rounded())
        if bubbleVisible { layoutBubble(spriteCenterLocal: sprite.position) }
        CATransaction.commit()
    }

    // MARK: - Speech bubble

    /// Show a short line above the pet (below it when hanging near the
    /// screen top). Follows him while visible; auto-hides.
    func say(_ text: String, for seconds: TimeInterval = 4) {
        debugBubbleText = text
        let attr = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: SkinTheme.current.bubbleTextColor,
        ])
        let maxW: CGFloat = 252
        let bounds = attr.boundingRect(with: CGSize(width: maxW, height: 220),
                                       options: [.usesLineFragmentOrigin])
        let w = min(maxW, bounds.width.rounded(.up)) + 24
        let h = bounds.height.rounded(.up) + 18
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bubble.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        bubbleText.string = attr
        bubbleText.frame = CGRect(x: 12, y: 9, width: w - 24, height: h - 18)
        let wasHidden = bubble.isHidden
        bubble.isHidden = false
        layoutBubble(spriteCenterLocal: sprite.position)
        CATransaction.commit()
        if wasHidden {
            bubble.opacity = 0
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.14)
            bubble.opacity = 1
            CATransaction.commit()
        }
        bubbleVisible = true
        bubbleHideAt = CACurrentMediaTime() + seconds
        bubbleTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + seconds)
        t.setEventHandler { [weak self] in self?.hideBubble() }
        t.resume()
        bubbleTimer = t
    }

    func hideBubble() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bubble.isHidden = true
        CATransaction.commit()
        bubbleVisible = false
        debugBubbleText = ""
    }

    private func layoutBubble(spriteCenterLocal c: CGPoint) {
        let screen = panels[currentPanelIndex].frame
        let clampTopLocal = clampTop(forAnchor: anchor) - screen.origin.y
        let half = spriteSize.height / 2
        let bh = bubble.bounds.height
        let above = c.y + half + 10 + bh / 2
        let placeAbove = above + bh / 2 <= clampTopLocal
        let y = placeAbove ? above : c.y - half - 10 - bh / 2
        var x = c.x
        x = min(max(x, bubble.bounds.width / 2 + 6),
                screen.width - bubble.bounds.width / 2 - 6)
        bubble.position = CGPoint(x: x.rounded(), y: y.rounded())
        // Tail points at the sprite.
        let tail = CGMutablePath()
        let tx = min(max(c.x - bubble.position.x, -bubble.bounds.width / 2 + 16),
                     bubble.bounds.width / 2 - 16)
        if placeAbove {
            tail.move(to: CGPoint(x: tx - 7, y: 1))
            tail.addLine(to: CGPoint(x: tx + 7, y: 1))
            tail.addLine(to: CGPoint(x: tx, y: -7))
        } else {
            tail.move(to: CGPoint(x: tx - 7, y: bubble.bounds.height - 1))
            tail.addLine(to: CGPoint(x: tx + 7, y: bubble.bounds.height - 1))
            tail.addLine(to: CGPoint(x: tx, y: bubble.bounds.height + 7))
        }
        tail.closeSubpath()
        bubbleTail.path = tail
        bubbleTail.position = .zero
        bubbleTail.frame = bubble.bounds
    }

    func setPose(rotationDegrees rot: CGFloat, facing f: CGFloat) {
        guard rot != rotationDegrees || f != facing else { return }
        rotationDegrees = rot
        facing = f
        applyTransform()
        place(anchor: anchor) // center offset depends on rotation
    }

    private func applyTransform() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if rotationDegrees == 180 {
            // Ceiling hang: vertical flip (not a spin) keeps left/right facing
            // matched to walking direction while upside down.
            sprite.transform = CATransform3DMakeScale(effectiveFacing, -1, 1)
        } else {
            let flip = CATransform3DMakeScale(effectiveFacing, 1, 1)
            let spin = CATransform3DMakeRotation(rotationDegrees * .pi / 180, 0, 0, 1)
            sprite.transform = CATransform3DConcat(flip, spin)
        }
        CATransaction.commit()
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
        if rotationDegrees == 180 {
            v.y = -v.y // inverse of the hang's vertical flip
        } else {
            let theta = -rotationDegrees * .pi / 180 // inverse rotation
            v = CGPoint(x: v.x * cos(theta) - v.y * sin(theta),
                        y: v.x * sin(theta) + v.y * cos(theta))
        }
        if effectiveFacing < 0 { v.x = -v.x } // inverse flip
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
@MainActor
final class PetView: NSView {
    private weak var stage: OverlayStage?

    init(stage: OverlayStage, frame: CGRect) {
        self.stage = stage
        super.init(frame: frame)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
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

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            stage?.onDoubleClick?()
            return
        }
        stage?.onGrab?(global(event))
    }
    override func mouseDragged(with event: NSEvent) { stage?.onDrag?(global(event)) }
    override func mouseUp(with event: NSEvent) { stage?.onRelease?(global(event)) }

    // MARK: - Dropping a file on him

    /// The click-through hole normally makes this view invisible to the mouse
    /// everywhere except the sprite, and drags land the same way: a file is
    /// only accepted over Rusty himself, so dropping on the desktop behind him
    /// still reaches the desktop.
    private func isOverPet(_ sender: NSDraggingInfo) -> Bool {
        guard let stage, let window else { return false }
        let point = sender.draggingLocation
        return stage.hit(CGPoint(x: window.frame.origin.x + point.x,
                                 y: window.frame.origin.y + point.y))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isOverPet(sender) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isOverPet(sender) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isOverPet(sender),
              let urls = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        stage?.onFilesDropped?(urls)
        return true
    }
}
