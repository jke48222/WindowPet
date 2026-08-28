import AppKit
import ApplicationServices
import WindowPetCore

/// What the assistant can see of the windows Rusty stands on.
///
/// Tier 1 already polls every window's geometry, layer and owning process for
/// the creature to walk on, with no permissions at all. Until now the
/// assistant half of him could not read any of it. This is the bridge, and it
/// keeps the permission invariant: app names come from `NSRunningApplication`
/// via the process id, never from `kCGWindowOwnerName`, and no window title is
/// read anywhere in it.
@MainActor
enum WindowInventory {

    /// Skips our own overlay, menu-bar items, tooltips and palettes. Layer 0
    /// plus a size floor is the same filter the creature uses to decide what
    /// counts as standable ground.
    static func snapshots() -> [WindowSnapshot] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // Excluded by identity, not just by process: a second copy of
        // WindowPet (the running pet while a headless run answers a question,
        // say) is still us, and Rusty reporting his own overlay as one of the
        // user's windows would be nonsense.
        let ownBundle = Bundle.main.bundleIdentifier
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let displays = NSScreen.screens.map(\.frame)
        var names: [pid_t: String] = [:]

        return Tier1.onScreenWindowsFrontToBack().compactMap { window in
            guard window.layer == 0, window.isOnScreen, window.ownerPID != ownPID,
                  window.frame.width >= 120, window.frame.height >= 60 else { return nil }
            let name: String
            if let cached = names[window.ownerPID] {
                name = cached
            } else {
                guard let app = NSRunningApplication(processIdentifier: window.ownerPID),
                      let localized = app.localizedName, !localized.isEmpty,
                      app.bundleIdentifier == nil || app.bundleIdentifier != ownBundle
                else { return nil }
                name = localized
                names[window.ownerPID] = localized
            }
            let frame = Geometry.appKitRect(fromCGGlobal: window.frame,
                                            primaryScreenHeight: Screens.primaryHeight)
            let display = DisplayChoice.index(overlapping: frame, in: displays) ?? 0
            return WindowSnapshot(app: name, frame: frame,
                                  isFrontmost: window.ownerPID == frontPID,
                                  display: display)
        }
    }

    static func report() -> String {
        WindowReport.describe(snapshots(), displays: NSScreen.screens.map(\.visibleFrame))
    }
}

/// Moving other apps' windows through the Accessibility trust the pet already
/// holds. Shared by the single-window snaps and by whole layouts.
@MainActor
enum WindowArranger {

    /// The focused window of a running app, or nil when the app is not
    /// running, has no window, or refuses to hand one over.
    static func focusedWindow(ofPID pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.15)
        var reference: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString,
                                            &reference) == .success,
              let value = reference, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            // Some apps expose no focused window but do list their windows.
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString,
                                                &windowsRef) == .success,
                  let list = windowsRef as? [AXUIElement], let first = list.first else { return nil }
            return first
        }
        return (value as! AXUIElement)
    }

    /// Sets a window's frame in one step. `rect` is in AppKit coordinates;
    /// the Accessibility API wants top-left origin measured from the primary
    /// display, so this is where the flip happens.
    @discardableResult
    static func setFrame(_ window: AXUIElement, to rect: CGRect) -> Bool {
        var position = CGPoint(x: rect.minX, y: Screens.primaryHeight - rect.maxY)
        var size = CGSize(width: rect.width, height: rect.height)
        var ok = true
        // Size first, then position: a window that clamps its size would
        // otherwise be nudged off its intended origin by the resize.
        if let value = AXValueCreate(.cgSize, &size) {
            ok = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success && ok
        }
        if let value = AXValueCreate(.cgPoint, &position) {
            ok = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success && ok
        }
        if let value = AXValueCreate(.cgSize, &size) {
            _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        }
        return ok
    }

    /// Applies a set of placements, reporting what actually moved. Every
    /// failure is named: a layout that half worked and said "done" would be
    /// worse than one that failed loudly.
    ///
    /// Where each window was is recorded first, so "put it back" works. The
    /// frames are stored rather than the slots they were nearest to: a window
    /// deliberately left at an odd size returns to that odd size instead of
    /// being tidied into a half on the way home.
    static func apply(_ placements: [WindowPlacement]) -> String {
        guard AXPermission.trusted else {
            return "I need Accessibility to arrange windows. System Settings, Privacy and Security, Accessibility, enable WindowPet."
        }
        var moved: [String] = []
        var missed: [String] = []
        var before: [RememberedFrame] = []
        for placement in placements {
            guard let app = AssistantExecutor.runningApp(named: placement.app) else {
                missed.append("\(placement.app) is not running")
                continue
            }
            guard let window = focusedWindow(ofPID: app.processIdentifier) else {
                missed.append("\(placement.app) has no window I can move")
                continue
            }
            // Place on the display the window is already on, so a layout
            // recalled on a laptop does not drag everything to one screen.
            let visible = currentFrame(of: window)
                .map { Screens.visibleFrame(forAXPosition: $0.origin, size: $0.size) }
                ?? Screens.visibleFrame()
            let target = placement.slot.rect(in: visible)
            let previous = currentFrame(of: window)
            if setFrame(window, to: target) {
                moved.append("\(app.localizedName ?? placement.app) \(placement.slot.displayName)")
                if let previous {
                    before.append(RememberedFrame(app: app.localizedName ?? placement.app,
                                                  frame: previous))
                }
            } else {
                missed.append("\(placement.app) would not move")
            }
        }
        AssistantExecutor.shared.arrangements.record(before)
        var parts: [String] = []
        if !moved.isEmpty { parts.append("Placed " + moved.joined(separator: ", ") + ".") }
        if !missed.isEmpty { parts.append("Couldn't: " + missed.joined(separator: "; ") + ".") }
        return parts.isEmpty ? "Nothing to place." : parts.joined(separator: " ")
    }

    /// Puts the windows back where the last arrangement found them.
    static func undo() -> String {
        guard AXPermission.trusted else {
            return "I need Accessibility to move windows. System Settings, Privacy and Security, Accessibility, enable WindowPet."
        }
        guard let frames = AssistantExecutor.shared.arrangements.popLast() else {
            return ArrangementHistory.nothingToUndo()
        }
        var restored: [RememberedFrame] = []
        var failed: [String] = []
        for remembered in frames {
            guard let app = AssistantExecutor.runningApp(named: remembered.app),
                  let window = focusedWindow(ofPID: app.processIdentifier) else {
                // The app quit or closed the window since. Nothing to put back,
                // and saying so is better than silently doing less.
                failed.append(remembered.app)
                continue
            }
            if setFrame(window, to: appKitRect(fromAX: remembered.frame)) {
                restored.append(remembered)
            } else {
                failed.append(remembered.app)
            }
        }
        return ArrangementHistory.undone(restored, failed: failed)
    }

    /// `setFrame` takes AppKit coordinates and flips them on the way out, so a
    /// frame that was read in Accessibility coordinates has to be flipped back
    /// before it goes through. Doing this once here is what keeps the flip
    /// from being applied zero times or twice.
    private static func appKitRect(fromAX rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: Screens.primaryHeight - rect.minY - rect.height,
               width: rect.width, height: rect.height)
    }

    /// A window's current frame in Accessibility coordinates.
    static func currentFrame(of window: AXUIElement) -> CGRect? {
        var position = CGPoint.zero
        var size = CGSize.zero
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString,
                                            &positionRef) == .success,
              let positionValue = positionRef, CFGetTypeID(positionValue) == AXValueGetTypeID(),
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString,
                                            &sizeRef) == .success,
              let sizeValue = sizeRef, CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }

    /// Reads the screen as it stands and turns it into placements, so "save
    /// this as writing" captures what the person just arranged by hand.
    static func capture() -> [WindowPlacement] {
        let displays = NSScreen.screens.map(\.visibleFrame)
        var seen = Set<String>()
        return WindowInventory.snapshots().compactMap { snapshot in
            // One placement per app: the focused window is what a layout can
            // actually move back later.
            guard !seen.contains(snapshot.app) else { return nil }
            seen.insert(snapshot.app)
            let visible = displays.indices.contains(snapshot.display)
                ? displays[snapshot.display] : (displays.first ?? Screens.fallbackVisibleFrame)
            return WindowPlacement(app: snapshot.app,
                                   slot: LayoutSlot.nearest(to: snapshot.frame, in: visible),
                                   display: snapshot.display)
        }
    }
}
