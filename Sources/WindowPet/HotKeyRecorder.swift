import AppKit
import Carbon.HIToolbox
import WindowPetCore

/// Where the summon shortcut lives between launches.
enum HotKeyStore {

    /// The app has two global shortcuts now, and they are stored the same way.
    /// A slot keeps the defaults keys and the fallback binding together so
    /// adding a third is one case rather than four scattered constants.
    enum Slot {
        /// Summons the chat panel.
        case summon
        /// Dictates into whatever app is in front, with no model involved.
        case dictate

        var codeKey: String {
            switch self {
            case .summon: return "hotKeyCode"
            case .dictate: return "dictationHotKeyCode"
            }
        }

        var modifiersKey: String {
            switch self {
            case .summon: return "hotKeyModifiers"
            case .dictate: return "dictationHotKeyModifiers"
            }
        }

        var fallback: HotKeyBinding {
            switch self {
            case .summon: return .default
            // Option-D, next to the summon shortcut and not taken by macOS.
            case .dictate:
                return HotKeyBinding(keyCode: KeyCodes.byName["d"] ?? 2, modifiers: .option)
            }
        }

        var displayName: String {
            switch self {
            case .summon: return "Summon Rusty"
            case .dictate: return "Dictate Into The App In Front"
            }
        }
    }

    static func binding(_ slot: Slot) -> HotKeyBinding {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: slot.codeKey) != nil else { return slot.fallback }
        let binding = HotKeyBinding(
            keyCode: UInt16(defaults.integer(forKey: slot.codeKey)),
            modifiers: HotKeyModifiers(rawValue: defaults.integer(forKey: slot.modifiersKey)))
        return binding.isValid ? binding : slot.fallback
    }

    static var current: HotKeyBinding { binding(.summon) }
    static var dictation: HotKeyBinding { binding(.dictate) }

    static func save(_ binding: HotKeyBinding, for slot: Slot = .summon) {
        UserDefaults.standard.set(Int(binding.keyCode), forKey: slot.codeKey)
        UserDefaults.standard.set(binding.modifiers.rawValue, forKey: slot.modifiersKey)
    }

    static func reset(_ slot: Slot = .summon) {
        UserDefaults.standard.removeObject(forKey: slot.codeKey)
        UserDefaults.standard.removeObject(forKey: slot.modifiersKey)
    }

    /// True when the two shortcuts would fight over the same keystroke.
    static func collides(_ binding: HotKeyBinding, with slot: Slot) -> Bool {
        let other: Slot = slot == .summon ? .dictate : .summon
        let existing = Self.binding(other)
        return existing.keyCode == binding.keyCode && existing.modifiers == binding.modifiers
    }
}

extension HotKeyBinding {
    /// Carbon wants its own modifier bitfield for RegisterEventHotKey.
    var carbonModifiers: UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
        if modifiers.contains(.option) { flags |= UInt32(optionKey) }
        if modifiers.contains(.control) { flags |= UInt32(controlKey) }
        return flags
    }

    /// Reads a binding out of an AppKit key event.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: HotKeyModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        self.init(keyCode: event.keyCode, modifiers: modifiers)
    }
}

/// A small panel that listens for the next shortcut the user presses and
/// hands it back. Modal-ish: it takes key focus, Escape cancels, and so does
/// clicking anywhere else.
///
/// While it is open the app's own global shortcuts must be out of the way,
/// or pressing the current shortcut would fire it instead of being recorded.
/// The recorder posts `willBeginNotification` before it listens and
/// `didEndNotification` once it closes; whoever registered the Carbon hot
/// keys releases them on the first and registers the saved ones again on
/// the second.
@MainActor
final class HotKeyRecorder: NSObject {

    /// Posted on the main thread just before the recorder starts listening.
    static let willBeginNotification = Notification.Name("WindowPetHotKeyRecorderWillBegin")
    /// Posted on the main thread once the recorder has closed, before its
    /// completion runs, so the completion's own rebinding has the last word.
    static let didEndNotification = Notification.Name("WindowPetHotKeyRecorderDidEnd")

    /// The recorder on screen, if any. Held strongly until it finishes, so
    /// a caller that drops its reference early cannot strand the panel, its
    /// key monitor, or the released shortcuts. Opening a second recorder
    /// closes the first rather than leaving two panels fighting over keys.
    private static var active: HotKeyRecorder?

    private var panel: NSPanel?
    private var label: NSTextField!
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var completion: ((HotKeyBinding?) -> Void)?
    /// The app that was in front before the recorder took focus. It gets
    /// focus back when the recorder closes, so the next keystrokes land
    /// where the user was working instead of in an app with no key window.
    private var previousApp: NSRunningApplication?
    /// A valid combination was pressed and the panel is showing it for a
    /// moment before closing. Further keys are still swallowed but ignored.
    private var captured = false
    private var isRecording = false

    func record(current: HotKeyBinding, completion: @escaping (HotKeyBinding?) -> Void) {
        if let other = Self.active, other !== self { other.finish(nil) }
        if isRecording { finish(nil) }
        Self.active = self
        isRecording = true
        captured = false
        self.completion = completion
        let theme = SkinTheme.current

        let panel = RecorderPanel(contentRect: CGRect(x: 0, y: 0, width: 340, height: 120),
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        panel.level = .modalPanel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSView(frame: CGRect(x: 0, y: 0, width: 340, height: 120))
        container.wantsLayer = true
        container.layer?.cornerRadius = 16
        container.layer?.borderWidth = 1
        container.layer?.borderColor = theme.border.cgColor
        let gradient = CAGradientLayer()
        gradient.colors = [theme.glassTop.cgColor, theme.glassBottom.cgColor]
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        gradient.frame = container.bounds
        gradient.cornerRadius = 16
        container.layer?.insertSublayer(gradient, at: 0)

        let title = NSTextField(labelWithString: "Press a new shortcut")
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = theme.userText
        title.alignment = .center
        title.frame = CGRect(x: 0, y: 78, width: 340, height: 20)
        container.addSubview(title)

        label = NSTextField(labelWithString: current.displayName)
        label.font = .systemFont(ofSize: 18, weight: .semibold)
        label.textColor = theme.accent
        label.alignment = .center
        label.frame = CGRect(x: 0, y: 46, width: 340, height: 26)
        container.addSubview(label)

        let hint = NSTextField(labelWithString: "Needs Option, Control or Command. Escape cancels.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = theme.userText.withAlphaComponent(0.62)
        hint.alignment = .center
        hint.frame = CGRect(x: 0, y: 20, width: 340, height: 18)
        container.addSubview(hint)

        panel.contentView = container
        // AppKit's own drawing follows the glass, not the system appearance,
        // so a light custom skin keeps readable controls.
        panel.appearance = NSAppearance(named: Self.glassIsLight(theme.glassTop) ? .aqua : .darkAqua)
        // Appears on the display the pointer is on, so a key-capture prompt
        // never opens behind the person on another monitor.
        let screen = Screens.visibleFrame()
        panel.setFrameOrigin(CGPoint(x: screen.midX - 170, y: screen.midY - 60))
        self.panel = panel

        // Release the app's own shortcuts first: a registered Carbon hot key
        // is consumed before any window sees it, so the current shortcut
        // could never be pressed into the recorder.
        NotificationCenter.default.post(name: Self.willBeginNotification, object: self)

        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            ? nil : front
        panel.orderFrontRegardless()
        NSApp.activate()
        panel.makeKey()

        // Only keys aimed at the recorder are captured. Everything typed into
        // any other window of the app (the command bar, a dialog) passes
        // through untouched.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }
            self.handle(event)
            return nil  // swallow it; this panel exists to capture keys
        }
        // Clicking anywhere else, in this app or another, cancels. Without
        // this the panel could sit at modal level with nothing listening.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resignedKey() }
        }
    }

    private static func glassIsLight(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent
            + 0.0722 * rgb.blueComponent > 0.5
    }

    private func handle(_ event: NSEvent) {
        guard isRecording, !captured else { return }
        if event.keyCode == UInt16(kVK_Escape) {
            finish(nil)
            return
        }
        guard let binding = HotKeyBinding(event: event) else { return }
        guard binding.isValid else {
            label.stringValue = binding.problem ?? "Try another shortcut"
            return
        }
        captured = true
        label.stringValue = binding.displayName
        // Let the user see what they pressed before it closes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.finish(binding)
        }
    }

    /// Focus left the panel. A combination that was already captured still
    /// counts; anything else is a cancel.
    private func resignedKey() {
        guard isRecording, !captured else { return }
        finish(nil, restoreFocus: false)
    }

    /// Closes the recorder exactly once, whichever of Escape, a captured
    /// combination, a click elsewhere or a second recorder gets there first.
    private func finish(_ binding: HotKeyBinding?, restoreFocus: Bool = true) {
        guard isRecording else { return }
        isRecording = false
        captured = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        panel?.orderOut(nil)
        panel = nil
        if Self.active === self { Self.active = nil }

        // Hand focus back to the app the user was in, but only if we still
        // hold it: after a click into another app, that app keeps it.
        let previous = previousApp
        previousApp = nil
        if restoreFocus, NSApp.isActive, let previous, !previous.isTerminated {
            NSApp.yieldActivation(to: previous)
            previous.activate()
        }

        NotificationCenter.default.post(name: Self.didEndNotification, object: self)
        let done = completion
        completion = nil
        done?(binding)
    }
}

private final class RecorderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
