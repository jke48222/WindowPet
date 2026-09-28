import AppKit
import Carbon.HIToolbox
import WindowPetCore

/// Rusty's chat panel, the single conversation surface for every input
/// method: typed (tap Option-Space or double-click the pet), push-to-talk
/// (hold Option-Space), and the wake word. Colors come from the active skin.
/// The header is a drag handle with a minimize control that collapses the
/// panel to a slim pill. Enter submits, a second Enter confirms destructive
/// verbs, Esc cancels.
///
/// Two rules hold the confirmation gate together:
/// - There is exactly one safety check at a time, and it belongs to the card
///   on screen. A new request, a voice command, a standing ask, Esc, the
///   close button and the summon shortcut all cancel it; nothing can approve
///   a check the user has moved on from.
/// - Return approves a check only when the user's attention is on the panel:
///   it was focused when the check appeared or was focused by the user after,
///   at least 600 ms passed since, and the key came from a person (Rusty's own
///   synthetic keys are dropped before they reach the panel).
///
/// Every run (typed, voice, dropped file, standing ask) has an id. Only the
/// current run may stream text, add progress rows or apply its result; a new
/// request cancels the previous run, and Esc or closing the panel stops it.
@MainActor
final class CommandBar: NSObject, NSTextFieldDelegate {

    private enum Layout {
        static let width: CGFloat = 460
        static let margin: CGFloat = 14
        static let maxTranscriptHeight: CGFloat = 300
        static let inputHeight: CGFloat = 34
        static let headerHeight: CGFloat = 20
        /// Minimized: a small square chip with Rusty's face. Click it to
        /// reopen, so it needs no expand control of its own.
        static let collapsedWidth: CGFloat = 72
        static let collapsedHeight: CGFloat = 64
        /// The transcript keeps this many rows; older ones are dropped with
        /// their views, so a pet running for days stays cheap to lay out.
        static let maxMessages = 200
    }

    fileprivate struct Message {
        enum Kind { case user, rusty, system }
        let id: Int
        let kind: Kind
        var text: String
        var pending = false
        /// A Rusty row still being filled in by the stream.
        var streaming = false
    }

    /// Where a request came from. Decides who may be interrupted, whether the
    /// answer is spoken, and whether a safety check may take the keyboard.
    /// `voice` is push-to-talk, where the user is holding the key; `wakeWord`
    /// is anything the "Hey Rusty" listener heard, which may be a video, a
    /// call or someone else in the room.
    private enum RunSource {
        case typed, voice, wakeWord, dropped, scheduled

        var isVoice: Bool { self == .voice || self == .wakeWord }

        /// The request itself carries words the user did not write: a
        /// dropped file, or a standing ask (possibly written by the model).
        var isUntrusted: Bool { self == .dropped || self == .scheduled }

        /// Heard by the wake word, which picks up any audio nearby. Typing,
        /// key presses, shortcuts and tricks from it confirm.
        var isHeard: Bool { self == .wakeWord }
    }

    private struct ActiveRun {
        let id: Int
        let source: RunSource
        var session: AgentSession?
        /// The work in flight, nil while paused on a safety check.
        var task: Task<Void, Never>?
        /// The standing ask this run is answering, so a run the user
        /// interrupts can be put back in line instead of lost.
        var scheduledEntry: SchedulePolicy.Entry?
        /// Outside content reached this run: its request, the history it
        /// replays, or a result it read. Its answer is recorded as tainted.
        var tainted: Bool
    }

    private enum CheckTarget {
        case agent(AgentSession)
        case direct(AssistantAction)
    }

    /// The one pending safety check, tied to the run that raised it.
    private struct SafetyCheck {
        let runID: Int
        let target: CheckTarget
        let shownAt: Date
        /// When the user's attention reached the panel: at presentation if it
        /// was already focused, otherwise when they focus or click it.
        var armedAt: Date?
    }

    /// A Return sooner than this after the check appeared (or was armed) is
    /// not taken as an answer to it.
    private static let confirmationDelay: TimeInterval = 0.6
    /// An armed check older than this is dropped rather than approved.
    private static let confirmationLifetime: TimeInterval = 120

    private var panel: KeyPanel!
    private var container: HoverView!
    private var gradient: CAGradientLayer!
    private let field = NSTextField()
    private var inputBox: NSView!
    private var headerLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var statusDot: NSView!
    private var faceView: RustyFaceView!
    private var collapseButton: NSButton!
    private var closeButton: NSButton!
    private var dragHandle: HeaderDragView!
    private var transcriptScroll: NSScrollView!
    private var transcriptDoc: FlippedView!

    private var messages: [Message] = []
    private var nextMessageID = 1
    private var rowViews: [MessageRowView] = []
    /// Row views by message id, reused across rebuilds so their measured
    /// sizes survive.
    private var rowCache: [Int: MessageRowView] = [:]
    /// Set when the newest row is new, so relayout brings it into view if
    /// the reader was following the tail.
    private var revealNewestRow = false
    /// Set when the user just added a row themselves (a submit, a drop): it
    /// comes into view even if they had scrolled up.
    private var revealForced = false
    /// A safety check's summary carries the full payload, which can run to
    /// many lines. When it does, the transcript opens at its first line so
    /// the user reads what will run from the top, then scrolls down.
    private var revealFromTopID: Int?

    private var activeRun: ActiveRun?
    private var nextRunID = 1
    private var safetyCheck: SafetyCheck?
    /// Standing asks that came due while something else was running. They
    /// wait their turn rather than cancelling the user's request.
    private var queuedScheduled: [SchedulePolicy.Entry] = []

    private var hotKeyRef: EventHotKeyRef?
    private var dictationHotKeyRef: EventHotKeyRef?
    private var hideTimer: DispatchSourceTimer?
    /// A hide that was due when the pointer came over the panel; it resumes
    /// when the pointer leaves.
    private var hidePausedByHover = false
    /// A hide that was due while the panel had the keyboard; it resumes when
    /// focus leaves the panel.
    private var hidePausedByFocus = false
    /// A hide that was due while a request was running; it resumes when the
    /// run ends.
    private var hidePausedByBusy = false
    private var pointerInside = false
    private var collapsed = false
    private var pinnedOrigin: CGPoint?

    /// Rolling exchange history handed to the LLM tiers so follow-ups ("now
    /// hide it") resolve. Each turn remembers whether it carried outside
    /// content, so the taint travels with the transcript: a later run that
    /// replays a dropped file or a tainted answer starts tainted too.
    private var conversation = ConversationHistory(capacity: 24)
    var history: [(role: String, text: String)] { conversation.plain }

    /// Streamed text waiting for the next flush (see `appendStreamedText`).
    private var streamBuffer = ""
    private var streamFlushPending = false
    /// VoiceOver hears progress lines at most this often.
    private var lastProgressAnnouncement = Date.distantPast

    var onOutcome: ((AssistantBrain.Outcome, _ fromVoice: Bool) -> Void)?
    /// A standing ask's answer or failure. It arrives unprompted, so the app
    /// routes it through the quiet policy (the same door as watch firings)
    /// instead of speaking it at once. When unset, the answer is shown in the
    /// panel and not spoken.
    var onScheduledAnswer: ((String) -> Void)?
    var onHoldStart: (() -> Void)?
    var onHoldEnd: (() -> Void)?
    var petAnchorProvider: (() -> CGPoint)?
    var contextProvider: (() -> String)?

    private var keyIsDown = false
    private var isHolding = false
    private var holdTimer: DispatchSourceTimer?

    var isVisible: Bool { panel.isVisible }

    /// Rig hook: the transcript as plain text.
    var debugTranscript: String { messages.map(\.text).joined(separator: " | ") }
    private var theme: SkinTheme { SkinTheme.current }

    override init() {
        super.init()
        let panel = KeyPanel(contentRect: CGRect(x: 0, y: 0, width: Layout.width, height: 96),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        container = HoverView(frame: CGRect(x: 0, y: 0, width: Layout.width, height: 96))
        container.wantsLayer = true
        let layer = container.layer!
        layer.cornerRadius = 16
        layer.borderWidth = 1
        layer.masksToBounds = true
        gradient = CAGradientLayer()
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        gradient.frame = container.bounds
        layer.insertSublayer(gradient, at: 0)

        dragHandle = HeaderDragView(frame: .zero)
        container.addSubview(dragHandle)

        faceView = RustyFaceView(frame: CGRect(x: Layout.margin, y: 0, width: 26, height: 20))
        faceView.setAccessibilityElement(false)
        container.addSubview(faceView)

        headerLabel = NSTextField(labelWithString: "")
        container.addSubview(headerLabel)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.alignment = .right
        container.addSubview(statusLabel)

        statusDot = NSView(frame: CGRect(x: 0, y: 0, width: 7, height: 7))
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3.5
        // Color and pulse only; the status text beside it carries the words.
        statusDot.setAccessibilityElement(false)
        container.addSubview(statusDot)

        collapseButton = NSButton(frame: CGRect(x: 0, y: 0, width: 18, height: 18))
        collapseButton.isBordered = false
        collapseButton.bezelStyle = .regularSquare
        collapseButton.target = self
        collapseButton.action = #selector(toggleCollapsed)
        collapseButton.setAccessibilityLabel("Minimize")
        container.addSubview(collapseButton)

        closeButton = NSButton(frame: CGRect(x: 0, y: 0, width: 18, height: 18))
        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.target = self
        closeButton.action = #selector(closePanel)
        closeButton.setAccessibilityLabel("Close")
        container.addSubview(closeButton)

        transcriptDoc = FlippedView(frame: .zero)
        transcriptScroll = NSScrollView(frame: .zero)
        transcriptScroll.drawsBackground = false
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.verticalScroller?.controlSize = .small
        transcriptScroll.autohidesScrollers = true
        transcriptScroll.documentView = transcriptDoc
        container.addSubview(transcriptScroll)

        inputBox = NSView(frame: .zero)
        inputBox.wantsLayer = true
        inputBox.layer?.cornerRadius = 10
        inputBox.layer?.borderWidth = 1
        container.addSubview(inputBox)

        field.font = .systemFont(ofSize: 14)
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        inputBox.addSubview(field)

        panel.contentView = container
        panel.copyLastAnswer = { [weak self] in self?.copyLastAnswerToPasteboard() ?? false }
        // Return and Esc reach the gate even when a transcript row, not the
        // input field, holds the keyboard.
        panel.keyRouter = { [weak self] event in self?.routeKey(event) ?? false }
        panel.onCancel = { [weak self] in self?.handleEscape() }
        // A click in the panel is the user's attention arriving.
        panel.onUserClick = { [weak self] in self?.armPendingCheck() }
        self.panel = panel
        dragHandle.onClick = { [weak self] in
            guard let self, self.collapsed else { return }
            self.setCollapsed(false)
            self.panel.makeKey()
            self.field.becomeFirstResponder()
            self.armPendingCheck()
        }
        dragHandle.onDragged = { [weak self] delta in
            guard let self else { return }
            var o = self.panel.frame.origin
            o.x += delta.x
            o.y += delta.y
            self.panel.setFrameOrigin(o)
            self.pinnedOrigin = o
        }
        // Dragging the minimized chip makes it key; hand the keyboard back so
        // nothing typed afterwards lands in a chip with no field.
        dragHandle.onDragEnded = { [weak self] in
            guard let self, self.collapsed else { return }
            self.handFocusBack()
        }
        container.onHoverChanged = { [weak self] inside in self?.pointerMoved(inside: inside) }
        NotificationCenter.default.addObserver(self, selector: #selector(panelBecameKey),
                                               name: NSWindow.didBecomeKeyNotification,
                                               object: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(panelResignedKey),
                                               name: NSWindow.didResignKeyNotification,
                                               object: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(transcriptWillScroll),
                                               name: NSScrollView.willStartLiveScrollNotification,
                                               object: transcriptScroll)
        // Plugging in a mouse switches to legacy scroll bars, which take
        // width from the transcript; rows are laid out again to fit.
        NotificationCenter.default.addObserver(self, selector: #selector(scrollerStyleChanged),
                                               name: NSScroller.preferredScrollerStyleDidChangeNotification,
                                               object: nil)
        // While a shortcut is being recorded, the Carbon hot keys are
        // released: a registered combination is consumed before any window
        // sees it, so pressing the current shortcut could not be recorded.
        NotificationCenter.default.addObserver(self, selector: #selector(hotKeyRecordingWillBegin),
                                               name: HotKeyRecorder.willBeginNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(hotKeyRecordingDidEnd),
                                               name: HotKeyRecorder.didEndNotification,
                                               object: nil)
        // The near-limit warning is said once a day, the moment spending
        // crosses it, rather than only when the ceiling stops a request.
        UsageMeter.shared.onNearLimit = { [weak self] warning in self?.systemNote(warning) }
        // Before Rusty types or presses keys, focus leaves this panel so the
        // keys go to the app in front instead of into his own input field.
        AssistantExecutor.beforeSyntheticKeys = { [weak self] in self?.handFocusBack() }
        retint()
        setStatus(.idle)
        relayout()
    }

    /// Re-applies the active skin. Safe to call live; also rebuilds rows so
    /// bubbles pick up the new tints.
    func retint() {
        let theme = self.theme  // resolve the skin once for the whole pass
        // Match AppKit's own drawing (scrollers, selection, the caret) to the
        // glass rather than to the system appearance.
        panel.appearance = NSAppearance(named: theme.glassTop.isLight ? .aqua : .darkAqua)
        gradient.colors = [theme.glassTop.cgColor, theme.glassBottom.cgColor]
        container.layer?.borderColor = theme.border.cgColor
        headerLabel.attributedStringValue = NSAttributedString(
            string: "RUSTY",
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                         .kern: 2.6,
                         .foregroundColor: theme.userText.withAlphaComponent(0.72)])
        statusLabel.textColor = theme.secondaryText
        inputBox.layer?.backgroundColor = theme.userText.withAlphaComponent(0.07).cgColor
        inputBox.layer?.borderColor = theme.userText.withAlphaComponent(0.10).cgColor
        field.textColor = theme.userText
        field.placeholderAttributedString = NSAttributedString(
            string: "Ask Rusty anything…",
            attributes: [.font: field.font ?? NSFont.systemFont(ofSize: 14),
                         .foregroundColor: theme.userText.withAlphaComponent(0.55)])
        styleControls()
        faceView.theme = theme
        faceView.needsDisplay = true
        setStatus(.idle)
        rebuildRows(retheme: true)
    }

    private func styleControls() {
        let tint = theme.userText.withAlphaComponent(0.55)
        collapseButton.attributedTitle = NSAttributedString(
            string: "–",
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .bold),
                         .foregroundColor: tint])
        closeButton.attributedTitle = NSAttributedString(
            string: "×",
            attributes: [.font: NSFont.systemFont(ofSize: collapsed ? 11 : 14, weight: .medium),
                         .foregroundColor: tint])
        closeButton.setAccessibilityLabel(collapsed ? "Close panel" : "Close")
        dragHandle.actsAsOpenButton = collapsed
    }

    // MARK: - Hotkey (tap toggles, hold is push-to-talk)

    func registerHotKey() {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return noErr }
            let bar = Unmanaged<CommandBar>.fromOpaque(userData).takeUnretainedValue()
            // Both shortcuts arrive through one handler, told apart by the id
            // they were registered with.
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            if id.id == CommandBar.dictationHotKeyID {
                pressed ? bar.onDictateStart?() : bar.onDictateEnd?()
            } else if pressed {
                bar.hotKeyDown()
            } else {
                bar.hotKeyUp()
            }
            return noErr
        }, 2, &eventTypes, selfPtr, nil)
        hotKeysRegistered = true
        applyHotKey(HotKeyStore.current)
        // No dictation object means the key is not taken from other apps.
        if onDictateStart != nil { applyDictationHotKey(HotKeyStore.dictation) }
    }

    /// Set once the Carbon handler is installed; only then are the hot keys
    /// put back after a recording.
    private var hotKeysRegistered = false

    @objc private func hotKeyRecordingWillBegin(_ note: Notification) {
        if let r = hotKeyRef { UnregisterEventHotKey(r); hotKeyRef = nil }
        if let r = dictationHotKeyRef { UnregisterEventHotKey(r); dictationHotKeyRef = nil }
        // The key-up for a key held now will never arrive once it is
        // unregistered, so push-to-talk is ended here instead.
        holdTimer?.cancel()
        holdTimer = nil
        keyIsDown = false
        if isHolding {
            isHolding = false
            onHoldEnd?()
        }
    }

    /// Posted before the recorder's completion runs, so App's own rebind of
    /// the new combination still happens last.
    @objc private func hotKeyRecordingDidEnd(_ note: Notification) {
        guard hotKeysRegistered else { return }
        applyHotKey(HotKeyStore.current)
        if onDictateStart != nil { applyDictationHotKey(HotKeyStore.dictation) }
    }

    static let summonHotKeyID: UInt32 = 1
    static let dictationHotKeyID: UInt32 = 2

    /// Held to dictate straight into the app in front. No model, no cost, and
    /// the words never leave the machine.
    var onDictateStart: (() -> Void)?
    var onDictateEnd: (() -> Void)?

    /// Returns false when macOS refused the registration (another app holds
    /// the combination).
    @discardableResult
    func applyDictationHotKey(_ binding: HotKeyBinding) -> Bool {
        if let existing = dictationHotKeyRef {
            UnregisterEventHotKey(existing)
            dictationHotKeyRef = nil
        }
        let hotKeyID = EventHotKeyID(signature: OSType(0x52535459) /* RSTY */,
                                     id: Self.dictationHotKeyID)
        return RegisterEventHotKey(UInt32(binding.keyCode), binding.carbonModifiers, hotKeyID,
                                   GetApplicationEventTarget(), 0, &dictationHotKeyRef) == noErr
    }

    /// (Re)binds the summon shortcut. Safe to call whenever the user picks a
    /// new one: the old registration is released first.
    @discardableResult
    func applyHotKey(_ binding: HotKeyBinding) -> Bool {
        if let existing = hotKeyRef {
            UnregisterEventHotKey(existing)
            hotKeyRef = nil
        }
        let hotKeyID = EventHotKeyID(signature: OSType(0x52535459) /* RSTY */,
                                     id: Self.summonHotKeyID)
        return RegisterEventHotKey(UInt32(binding.keyCode), binding.carbonModifiers, hotKeyID,
                                   GetApplicationEventTarget(), 0, &hotKeyRef) == noErr
    }

    private func hotKeyDown() {
        guard !keyIsDown else { return }
        keyIsDown = true
        isHolding = false
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + PushToTalk.holdThreshold)
        t.setEventHandler { [weak self] in
            guard let self, self.keyIsDown else { return }
            self.isHolding = true
            self.onHoldStart?()
        }
        t.resume()
        holdTimer = t
    }

    private func hotKeyUp() {
        keyIsDown = false
        holdTimer?.cancel()
        holdTimer = nil
        if isHolding {
            isHolding = false
            onHoldEnd?()
        } else {
            toggle()
        }
    }

    // MARK: - Presentation

    /// The summon gesture (shortcut tap, double-click on the pet). A panel
    /// that is on screen but not focused, after a voice answer or an
    /// announcement, gets focus so a follow-up can be typed; only a focused,
    /// expanded panel is dismissed. A minimized chip is reopened, never
    /// closed: closing would stop the work the user minimized to wait on.
    func toggle() {
        if panel.isVisible && panel.isKeyWindow && !collapsed {
            dismiss()
        } else {
            show()
        }
    }

    /// Typed session: present and take the keyboard. Always a user action, so
    /// it also arms a waiting safety check.
    func show() {
        if collapsed { setCollapsed(false) }
        present()
        panel.makeKey()
        field.becomeFirstResponder()
        armPendingCheck()
    }

    /// The user closing the panel (Esc, the close button, the shortcut, a
    /// double-click). Stops whatever is running and cancels a waiting safety
    /// check, so nothing keeps acting behind a hidden panel and nothing
    /// hidden can be approved later.
    func dismiss() {
        stopActiveWork(reason: .closed)
        cancelHide()
        orderOutPanel()
    }

    /// Every way the panel leaves the screen goes through here. AppKit sends
    /// no mouseExited for a window ordered out under the pointer, so the
    /// hover state is reset by hand rather than left stale.
    private func orderOutPanel() {
        panel.orderOut(nil)
        pointerInside = false
        hidePausedByHover = false
        hidePausedByFocus = false
        hidePausedByBusy = false
    }

    @objc private func toggleCollapsed() {
        setCollapsed(!collapsed)
    }

    /// Closes the panel. Rusty stays on screen; Option-Space brings it back.
    @objc private func closePanel() {
        dismiss()
    }

    private func setCollapsed(_ value: Bool) {
        collapsed = value
        styleControls()
        relayout()
        guard value else { return }
        // A minimized chip has no field and shows no safety check, so it
        // must not hold the keyboard: keys go back to the app in front, and
        // a waiting check needs the user's attention again (expand, then
        // Return) before a Return can answer it.
        if var check = safetyCheck {
            check.armedAt = nil
            safetyCheck = check
        }
        handFocusBack()
    }

    private func present() {
        cancelHide()
        if !panel.isVisible {
            // Open on the display the panel was last pinned to, or the one
            // Rusty is standing on, rather than assuming the main display.
            let anchor = pinnedOrigin ?? petAnchorProvider?()
            let screen = Screens.visibleFrame(for: anchor)
            var origin = CGPoint(x: screen.midX - Layout.width / 2, y: screen.midY + 40)
            if let pinnedOrigin {
                origin = pinnedOrigin
            } else if let a = petAnchorProvider?() {
                origin = CGPoint(x: a.x - Layout.width / 2, y: a.y + 64)
            }
            panel.setFrameOrigin(DisplayChoice.clamp(
                origin: origin, size: CGSize(width: Layout.width, height: 128),
                into: screen, inset: 12))
        }
        relayout()
        panel.orderFrontRegardless()
    }

    private func scheduleHide(after seconds: TimeInterval) {
        cancelHide()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + seconds)
        t.setEventHandler { [weak self] in self?.autoHide() }
        t.resume()
        hideTimer = t
    }

    private func cancelHide() {
        hideTimer?.cancel()
        hideTimer = nil
        hidePausedByHover = false
        hidePausedByFocus = false
        hidePausedByBusy = false
    }

    /// The timed hide. Never hides a panel the user is working in (focused),
    /// reading (pointer over it), or one that is still working or waiting on
    /// a safety check; and never cancels anything, unlike `dismiss()`. A hide
    /// held back for any of those reasons is deferred, not dropped: it
    /// resumes when focus leaves, the pointer leaves, or the run ends.
    private func autoHide() {
        hideTimer = nil
        // Where the pointer is now, not what the last tracking event said:
        // none arrives for a panel ordered out or in away from the pointer.
        let pointerOver = panel.isVisible && panel.frame.contains(NSEvent.mouseLocation)
        pointerInside = pointerOver
        switch AutoHidePolicy.decide(isKey: panel.isKeyWindow,
                                     busy: safetyCheck != nil || activeRun != nil,
                                     pointerOver: pointerOver) {
        case .busy: hidePausedByBusy = true
        case .waitForFocus: hidePausedByFocus = true
        case .pauseForHover: hidePausedByHover = true
        case .hide: orderOutPanel()
        }
    }

    @objc private func panelResignedKey(_ note: Notification) {
        guard hidePausedByFocus else { return }
        hidePausedByFocus = false
        scheduleHide(after: 4)
    }

    @objc private func scrollerStyleChanged(_ note: Notification) {
        relayout()
    }

    private func pointerMoved(inside: Bool) {
        pointerInside = inside
        if inside {
            if hideTimer != nil {
                hideTimer?.cancel()
                hideTimer = nil
                hidePausedByHover = true
            }
        } else if hidePausedByHover {
            scheduleHide(after: 4)
        }
    }

    @objc private func transcriptWillScroll(_ note: Notification) {
        if hideTimer != nil {
            hideTimer?.cancel()
            hideTimer = nil
            hidePausedByHover = true
        }
    }

    /// Hands keyboard focus back to the app in front before Rusty posts
    /// synthetic keys. A nonactivating panel stays key after the user types
    /// in it, and the window server would deliver the keys here.
    private func handFocusBack() {
        guard panel.isKeyWindow else { return }
        panel.makeFirstResponder(nil)
        let wasVisible = panel.isVisible
        panel.orderOut(nil)
        if wasVisible { panel.orderFrontRegardless() }
    }

    // MARK: - Voice entry points (wake word + push-to-talk share the panel)

    /// Capture started: present without stealing keyboard focus.
    func beginVoice() {
        if collapsed { setCollapsed(false) }
        present()
        setStatus(.listening)
    }

    /// Live transcript while the user is still speaking. Updates the pending
    /// row in place (same trick as the streaming answer row) instead of
    /// tearing down every row per partial.
    func voiceTranscript(_ text: String) {
        present()
        setStatus(.listening)
        if let i = messages.lastIndex(where: { $0.pending }) {
            messages[i].text = text
            if let row = rowCache[messages[i].id] {
                row.updateText(text)
                relayout()
                return
            }
        } else {
            append(.user, text, pending: true)
        }
        rebuildRows()
    }

    /// End of capture. Empty text is a miss; otherwise routes like typed.
    /// `fromWakeWord` is true for hands-free capture opened by "Hey Rusty",
    /// false for push-to-talk, where the user is holding the key.
    func finishVoice(_ text: String, fromWakeWord: Bool = false) {
        if text.isEmpty {
            messages.removeAll(where: \.pending)
            rebuildRows()
            setStatus(.idle, note: "Didn't catch that. Try again?")
            scheduleHide(after: 5)
            // A miss is an outcome too: it hands the microphone back to the
            // wake word, which a push-to-talk hold paused.
            onOutcome?(.unrecognized("Didn't catch that."), true)
            return
        }
        if let i = messages.lastIndex(where: { $0.pending }) {
            messages[i].text = text
            messages[i].pending = false
        } else {
            append(.user, text)
        }
        rebuildRows()
        run(text, source: fromWakeWord ? .wakeWord : .voice)
    }

    /// Follow-up window closed with silence: no miss note, just settle.
    func endVoiceQuietly() {
        messages.removeAll(where: \.pending)
        rebuildRows()
        setStatus(.idle)
        scheduleHide(after: 4)
    }

    /// One-shot "hey rusty <command>": no capture phase, straight in. Only
    /// the wake word calls this, so the words are treated as heard rather
    /// than as the user's own typing (see `RunSource.wakeWord`).
    func submitVoice(_ text: String) {
        if collapsed { setCollapsed(false) }
        present()
        append(.user, text)
        rebuildRows()
        run(text, source: .wakeWord)
    }

    /// A file dropped onto Rusty. The drop is the consent, so the contents go
    /// straight into the turn rather than through the gated read_file tool,
    /// and the panel shows what was dropped so it is never a silent read.
    ///
    /// Reading a file into a conversation needs the Claude brain: the
    /// on-device model has a context of a few thousand tokens and a 12-word
    /// reply, and a file's text must never reach a route that could turn it
    /// into an action. Without a key the drop is answered with that, and
    /// nothing is read.
    func submitDroppedFiles(_ urls: [URL]) {
        if collapsed { setCollapsed(false) }
        present()
        let names = urls.prefix(3).map(\.lastPathComponent)
        guard ClaudeRouter.isConfigured else {
            append(.user, "Dropped " + names.joined(separator: ", "))
            append(.system, "Reading files needs the Claude brain. Add an Anthropic API key under Anthropic API Key in the menu bar, then drop it again.")
            rebuildRows()
            scheduleHide(after: 10)
            return
        }
        setStatus(.thinking, note: nil)
        // Read off the main actor: a long PDF takes most of a second to
        // extract, and the pet and the panel keep moving meanwhile.
        Task { [weak self] in
            var readings: [(url: URL, result: Result<FileReader.Reading, FileReader.Refusal>)] = []
            // More than a few at once is a folder's worth; the first three
            // carry the intent and the rest are named rather than read.
            for url in urls.prefix(3) {
                readings.append((url, await FileReader.readAsync(path: url.path, followLinks: true)))
            }
            self?.runDroppedFiles(readings, all: urls)
        }
    }

    private func runDroppedFiles(_ readings: [(url: URL, result: Result<FileReader.Reading, FileReader.Refusal>)],
                                 all urls: [URL]) {
        var parts: [String] = []
        var labels: [String] = []
        for (url, result) in readings {
            switch result {
            case .failure(let refusal):
                labels.append(url.lastPathComponent)
                parts.append("\(url.lastPathComponent): \(refusal.message)")
            case .success(let reading):
                labels.append(reading.name)
                let header = FilePolicy.dropPrompt(name: reading.name, kind: reading.kind,
                                                   byteCount: reading.byteCount)
                if let text = reading.text {
                    parts.append("\(header)\n\n\(text)")
                } else {
                    parts.append(header)
                }
            }
        }
        if urls.count > 3 {
            let rest = urls.dropFirst(3).map(\.lastPathComponent).joined(separator: ", ")
            parts.append("I also dropped these, which you have not seen the contents of: \(rest)")
        }
        // The row the user sees names the files; the turn carries the text.
        // Memory gets the label only: the file itself is never written there.
        let label = "Dropped " + labels.joined(separator: ", ")
        append(.user, label)
        rebuildRows()
        run(parts.joined(separator: "\n\n") + "\n\nWhat do you make of it?",
            source: .dropped, noteAs: label)
    }

    /// Something Rusty says on his own, without being asked: a watch firing, a
    /// standing ask coming due. It always lands in the panel; `speak` is the
    /// quiet policy's decision about whether to say it out loud, because the
    /// user being busy is a reason not to interrupt, not a reason to lose the
    /// message.
    func announce(_ text: String, speak: Bool = true) {
        // A minimized chip has no room for text, and the message must not be
        // lost, so it opens.
        if collapsed { setCollapsed(false) }
        present()
        append(.rusty, text)
        // A watch firing or a standing ask's answer carries what an app, a
        // page or a scheduled run produced, so it replays as tainted.
        conversation.append(role: "assistant", text: text, tainted: true)
        rebuildRows()
        announceForAccessibility("Rusty: \(text)")
        if speak { onOutcome?(.reply(text), false) }
        scheduleHide(after: max(10, readingTime(for: text)))
    }

    /// Runs a standing ask through the full agent, the same way a typed
    /// request goes. It never interrupts the user's own request: one that
    /// comes due while something is running waits its turn. It does not pop
    /// the panel either; the answer arrives through `onScheduledAnswer`,
    /// which the app routes through the quiet policy.
    func runScheduled(_ entry: SchedulePolicy.Entry) {
        guard activeRun == nil, safetyCheck == nil else {
            queuedScheduled.append(entry)
            return
        }
        append(.system, SchedulePolicy.preamble(entry))
        append(.user, entry.request)
        rebuildRows()
        run(entry.request, source: .scheduled, scheduledEntry: entry)
    }

    /// Out-of-band notes (voice errors, menu confirmations, Help) that should
    /// reach the user. Left up for as long as it takes to read.
    func systemNote(_ text: String) {
        if collapsed { setCollapsed(false) }
        present()
        append(.system, text)
        rebuildRows()
        announceForAccessibility(text)
        scheduleHide(after: readingTime(for: text))
    }

    // MARK: - Submission pipeline (shared by typed and voice)

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            handleEscape()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            // A held Return repeats; a repeat is never a deliberate second
            // press, so it cannot answer a safety check.
            if safetyCheck != nil, NSApp.currentEvent?.isARepeat == true { return true }
            submitTyped()
            return true
        }
        return false
    }

    func controlTextDidChange(_ obj: Notification) {
        cancelHide()
    }

    /// Return and Esc when something other than the input field is first
    /// responder (a selected transcript row). Returns true when handled.
    private func routeKey(_ event: NSEvent) -> Bool {
        // A minimized chip has nothing to type into and shows no check. It
        // should not be key at all (see `setCollapsed`); if it is, give the
        // keyboard back and let no key act on it, Esc and Return included.
        if collapsed {
            handFocusBack()
            return true
        }
        let isReturn = Int(event.keyCode) == kVK_Return || Int(event.keyCode) == kVK_ANSI_KeypadEnter
        if isReturn, event.isARepeat, safetyCheck != nil { return true }
        if let editor = field.currentEditor(), panel.firstResponder === editor { return false }
        switch Int(event.keyCode) {
        case kVK_Escape:
            handleEscape()
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            panel.makeFirstResponder(field)
            submitTyped()
            return true
        default:
            return false
        }
    }

    /// Esc: cancel the safety check if there is one (the panel stays, so the
    /// user sees what happened), otherwise stop and close.
    private func handleEscape() {
        if let check = safetyCheck {
            switch check.target {
            case .agent:
                // Declines that step and lets the loop adapt, rather than
                // abandoning the run silently.
                resumeAgent(approved: false)
            case .direct:
                safetyCheck = nil
                finishRun()
                append(.system, "Cancelled. Nothing ran.")
                rebuildRows()
                setStatus(.idle)
            }
            return
        }
        dismiss()
    }

    private func submitTyped() {
        guard !collapsed else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        // Return on an empty field answers the safety check on screen.
        if text.isEmpty {
            if safetyCheck != nil { answerCheckWithReturn() }
            return
        }
        field.stringValue = ""
        append(.user, text)
        rebuildRows()
        run(text, source: .typed)
    }

    /// Approves the pending check if, and only if, the Return is deliberate:
    /// the panel had the user's attention, long enough ago, recently enough.
    private func answerCheckWithReturn() {
        guard let check = safetyCheck, !collapsed else { return }
        let verdict = ConfirmationGate.decide(shownAt: check.shownAt, armedAt: check.armedAt,
                                              now: Date(),
                                              isRepeat: NSApp.currentEvent?.isARepeat == true,
                                              delay: Self.confirmationDelay,
                                              lifetime: Self.confirmationLifetime)
        switch verdict {
        case .ignore:
            return
        case .notArmed:
            setStatus(.idle, note: "Click the panel first, then Return")
            return
        case .tooSoon:
            setStatus(.idle, note: "Press Return again to confirm")
            return
        case .expired:
            stopActiveWork(reason: .expired)
            return
        case .approve:
            break
        }
        switch check.target {
        case .agent:
            resumeAgent(approved: true)
        case .direct(let action):
            approveDirect(action, runID: check.runID)
        }
    }

    @objc private func panelBecameKey(_ note: Notification) {
        armPendingCheck()
    }

    /// The user's attention reached the panel: from now on (after the short
    /// delay) Return may answer the waiting check.
    private func armPendingCheck() {
        // A click on the minimized chip, or on its "–" button, is not
        // attention on a check the chip does not show.
        guard !collapsed, var check = safetyCheck, check.armedAt == nil else { return }
        check.armedAt = Date()
        safetyCheck = check
        setStatus(.idle, note: "Return to confirm, Esc to cancel")
    }

    private enum StopReason { case closed, superseded, expired }

    /// Cancels the running request and the waiting safety check, if any, and
    /// says so in the transcript. The one place a run ends early.
    ///
    /// A standing ask that is interrupted (by the user's own request, or by
    /// closing the panel while it ran unseen) is put back at the front of
    /// the line rather than lost: it has already been marked fired, and a
    /// one-off has already been removed from disk. It runs again once the
    /// user's request is over.
    private func stopActiveWork(reason: StopReason) {
        var note: String?
        var hadCheck = false
        if let check = safetyCheck {
            hadCheck = true
            safetyCheck = nil
            if case .agent(let session) = check.target { session.cancel() }
            switch reason {
            case .closed: note = "Cancelled the step that was waiting. Nothing ran."
            case .superseded: note = "Dropped the step that was waiting, since you asked for something else."
            case .expired: note = "That safety check expired, so nothing ran. Ask again if you still want it."
            }
        }
        if let run = activeRun {
            activeRun = nil
            run.task?.cancel()
            run.session?.cancel()
            // Closing a check the user was shown is a decision about it; a
            // standing ask interrupted any other way waits its turn again.
            let requeue = run.source == .scheduled && reason != .expired
                && !(reason == .closed && hadCheck)
            if requeue, let entry = run.scheduledEntry {
                queuedScheduled.insert(entry, at: 0)
                note = hadCheck
                    ? "The standing ask that was waiting will ask again after this."
                    : nil
            } else if note == nil, run.task != nil {
                note = reason == .superseded ? "Stopped the last request." : "Stopped."
            }
            // The microphone is handed back on every voice outcome; a stopped
            // voice request is one.
            if run.source.isVoice { onOutcome?(.unrecognized("Stopped."), true) }
        }
        clearStreamingRow()
        if let note {
            append(.system, note)
            rebuildRows()
        }
        setStatus(.idle)
        // Standing asks that were waiting keep their turn; a superseding
        // request starts right after this and holds them back until it ends.
        if reason != .superseded {
            Task { @MainActor [weak self] in self?.startQueuedScheduled() }
        }
    }

    private func run(_ text: String, source: RunSource, noteAs: String? = nil,
                     scheduledEntry: SchedulePolicy.Entry? = nil) {
        // Nothing heard runs behind the lock screen. The voice side already
        // drops what it hears when the Mac locks; this is the backstop.
        if source.isVoice && ScreenLock.shared.isSuspended {
            setStatus(.idle, note: "The Mac is locked, so I dropped that.")
            return
        }
        // One request at a time: whatever was running or waiting belongs to a
        // card the user has moved on from.
        if activeRun != nil || safetyCheck != nil { stopActiveWork(reason: .superseded) }
        setStatus(.thinking)
        // What the model sees stays bounded (tokens and latency); what you
        // see in the panel is the full transcript. Taint is decided on the
        // turns the run replays, so it clears only once every tainted turn
        // has fallen out of that window.
        conversation.append(role: "user", text: text, tainted: source.isUntrusted)
        let priorTainted = conversation.priorTurnsTainted
        let context = contextProvider?() ?? ""
        let priorHistory = Array(conversation.plain.dropLast())
        let runID = nextRunID
        nextRunID += 1
        activeRun = ActiveRun(id: runID, source: source, scheduledEntry: scheduledEntry,
                              tainted: source.isUntrusted || priorTainted)

        // Exact commands stay instant and free: no API call for "mute". A
        // dropped file's prompt is never a command. Words that did not come
        // from the user's own typing or held key (a standing ask, the wake
        // word) are gated like a tainted agent run.
        if source != .dropped, let action = AssistantParser.parse(text) {
            let gated = source.isUntrusted || source.isHeard
                ? AgentGate.requiresConfirmation(action, tainted: source.isUntrusted,
                                                 heard: source.isHeard)
                : action.needsConfirmation
            if gated {
                apply(.needsConfirmation(action, reply: nil), runID: runID)
                return
            }
            if AgentGate.bringsInOutsideContent(action) { activeRun?.tainted = true }
            activeRun?.task = Task { [weak self] in
                let (result, ok) = await AssistantExecutor.executeAwaiting(action)
                guard let self, self.activeRun?.id == runID else { return }
                if ok {
                    self.apply(.executed(result, reply: nil), runID: runID)
                } else {
                    // A miss (not an app) falls through to the thinking tiers,
                    // which do not run the grammar a second time.
                    self.think(text, context: context, history: priorHistory,
                               source: source, noteAs: noteAs, runID: runID,
                               grammarMiss: result)
                }
            }
            return
        }
        think(text, context: context, history: priorHistory,
              source: source, noteAs: noteAs, runID: runID, grammarMiss: nil)
    }

    /// The agent loop with a key, the brain chain without one.
    private func think(_ text: String, context: String, history priorHistory: [(role: String, text: String)],
                       source: RunSource, noteAs: String?, runID: Int, grammarMiss: String?) {
        // Outside content from the first step: the request itself (a dropped
        // file, a standing ask, words the wake word heard), or earlier turns
        // replayed from the panel history that carried it.
        let untrusted = activeRun?.tainted ?? source.isUntrusted
        // With a key, run the real agentic loop: Claude calls a tool, reads
        // the result, and decides the next step until the job is done.
        if ClaudeRouter.isConfigured {
            let session = AgentSession()
            session.onProgress = { [weak self, weak session] line in
                guard let self, let session, self.activeRun?.session === session else { return }
                self.noteProgress(line)
            }
            session.onTextDelta = { [weak self, weak session] chunk in
                guard let self, let session, self.activeRun?.session === session else { return }
                self.appendStreamedText(chunk)
            }
            activeRun?.session = session
            activeRun?.task = Task { [weak self] in
                let step = await session.start(text, context: context, history: priorHistory,
                                               noteAs: noteAs, untrustedInput: untrusted,
                                               heard: source.isHeard)
                guard let self, self.activeRun?.id == runID else { return }
                self.applyAgentStep(step, runID: runID)
            }
            return
        }

        activeRun?.task = Task { [weak self] in
            // The panel already parsed and ran the grammar, so the brain
            // does not run it again; a dropped file never reaches here.
            let outcome = await AssistantBrain.handle(text, context: context,
                                                      history: priorHistory,
                                                      untrusted: untrusted,
                                                      heard: source.isHeard,
                                                      grammarAlreadyTried: true,
                                                      grammarMiss: grammarMiss)
            guard let self, self.activeRun?.id == runID else { return }
            self.apply(outcome, runID: runID)
        }
    }

    /// Command-C with nothing selected grabs Rusty's latest answer.
    private func copyLastAnswerToPasteboard() -> Bool {
        guard let answer = messages.last(where: { $0.kind == .rusty })?.text,
              !answer.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer, forType: .string)
        setStatus(.idle, note: "Copied")
        return true
    }

    /// Streams the answer into a live Rusty row as the words arrive. The row
    /// is finalized in place with the sanitized text when the turn completes.
    ///
    /// Chunks arrive 30 to 60 times a second, and every update re-measures
    /// and re-lays out the row on the main thread the pet animates on. So
    /// they are buffered and flushed at most about twelve times a second.
    private func appendStreamedText(_ chunk: String) {
        streamBuffer += chunk
        guard !streamFlushPending else { return }
        streamFlushPending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            self?.flushStreamedText()
        }
    }

    private func flushStreamedText() {
        streamFlushPending = false
        guard !streamBuffer.isEmpty else { return }
        let chunk = streamBuffer
        streamBuffer = ""
        guard let index = messages.lastIndex(where: { $0.streaming }) else {
            append(.rusty, chunk, streaming: true)
            rebuildRows()
            return
        }
        messages[index].text += chunk
        guard let row = rowCache[messages[index].id] else {
            rebuildRows()
            return
        }
        // Only the streaming row changed. Its height is measured from the
        // new text alone (see MessageRowView), and the panel is resized only
        // when that height actually changed.
        let oldHeight = row.frame.height
        row.updateText(messages[index].text)
        if row.frame.width > 0, row.measuredHeight(width: row.frame.width) == oldHeight {
            row.layoutContents()
        } else {
            relayout()
        }
    }

    /// Drops the live streaming row, and anything still waiting to reach it.
    private func clearStreamingRow() {
        streamBuffer = ""
        messages.removeAll { $0.streaming }
    }

    /// Turns the live streaming row into the finished answer, keeping its id
    /// so the view is updated in place rather than replaced by a new row
    /// (which would scroll a long answer back to its first line). False when
    /// there was no streaming row.
    private func finalizeStreamingRow(with text: String) -> Bool {
        streamBuffer = ""
        guard let index = messages.lastIndex(where: { $0.streaming }) else { return false }
        messages[index].text = text
        messages[index].streaming = false
        return true
    }

    /// Live narration of each step while the loop works.
    private func noteProgress(_ line: String) {
        clearStreamingRow()
        append(.system, line)
        rebuildRows()
        setStatus(.thinking)
        // VoiceOver hears progress, but not every line of a busy loop.
        let now = Date()
        if now.timeIntervalSince(lastProgressAnnouncement) > 3 {
            lastProgressAnnouncement = now
            announceForAccessibility(line)
        }
    }

    private func resumeAgent(approved: Bool) {
        guard let check = safetyCheck, case .agent(let session) = check.target,
              activeRun?.id == check.runID else { return }
        let runID = check.runID
        safetyCheck = nil
        setStatus(.thinking)
        if !approved {
            append(.system, "Skipped that step.")
            rebuildRows()
        }
        activeRun?.task = Task { [weak self] in
            let step = await session.resume(approved: approved)
            guard let self, self.activeRun?.id == runID else { return }
            self.applyAgentStep(step, runID: runID)
        }
    }

    /// Runs a confirmed grammar or brain action, off the main actor where it
    /// can block (AppleScript, admin, typing).
    private func approveDirect(_ action: AssistantAction, runID: Int) {
        safetyCheck = nil
        setStatus(.thinking)
        if AgentGate.bringsInOutsideContent(action) { activeRun?.tainted = true }
        activeRun?.task = Task { [weak self] in
            let (result, ok) = await AssistantExecutor.executeAwaiting(action)
            guard let self, let run = self.activeRun, run.id == runID else { return }
            self.finishRun()
            self.setStatus(.idle)
            if ok { SoundFX.shared.play("ack") }
            self.deliverAnswer(result, source: run.source,
                               outcome: ok ? .executed(result, reply: nil) : .unrecognized(result),
                               tainted: run.tainted)
        }
    }

    /// The run is over: clear it and, once the caller has delivered its
    /// result, let a waiting standing ask go. A hide that came due while it
    /// ran resumes (the caller's own hide, if it sets one, replaces this).
    private func finishRun() {
        activeRun = nil
        if hidePausedByBusy {
            hidePausedByBusy = false
            scheduleHide(after: 6)
        }
        Task { @MainActor [weak self] in self?.startQueuedScheduled() }
    }

    private func startQueuedScheduled() {
        guard activeRun == nil, safetyCheck == nil, !queuedScheduled.isEmpty else { return }
        let next = queuedScheduled.removeFirst()
        runScheduled(next)
    }

    /// Shows one of Rusty's answers: chime, add the row (or finish the one
    /// that streamed), remember it, and set the auto-hide to reading length.
    /// Shared by both result paths.
    private func presentAnswer(_ text: String, chime: Bool, tainted: Bool) {
        if chime { SoundFX.shared.play("ack") }
        if !finalizeStreamingRow(with: text) { append(.rusty, text) }
        conversation.append(role: "assistant", text: text, tainted: tainted)
        rebuildRows()
        announceForAccessibility("Rusty: \(text)")
        scheduleHide(after: readingTime(for: text))
    }

    /// An answer reaches the user: a standing ask's goes through the quiet
    /// door (`onScheduledAnswer`), everything else is shown and handed to
    /// `onOutcome` (voice, the pet's reaction).
    private func deliverAnswer(_ text: String, source: RunSource, outcome: AssistantBrain.Outcome,
                               chime: Bool = false, tainted: Bool) {
        if source == .scheduled {
            if let onScheduledAnswer {
                // `announce` adds its own row, so the streamed one goes.
                clearStreamingRow()
                onScheduledAnswer(text)
            } else {
                present()
                presentAnswer(text, chime: false, tainted: true)
            }
            return
        }
        presentAnswer(text, chime: chime, tainted: tainted)
        onOutcome?(outcome, source.isVoice)
    }

    /// Says something to VoiceOver. The panel is nonactivating and usually
    /// not focused after a voice or scheduled run, so without this new rows
    /// would appear in silence. Safety checks are urgent.
    private func announceForAccessibility(_ text: String, urgent: Bool = false) {
        let priority: NSAccessibilityPriorityLevel = urgent ? .high : .medium
        NSAccessibility.post(element: panel as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: priority.rawValue])
    }

    /// Shows a safety-check prompt. It takes the keyboard only if the panel
    /// already had it: a check raised by voice, a standing ask or a run the
    /// user has left must never grab focus from the app they are typing in,
    /// where their next Return would approve it unseen.
    private func presentConfirmation(_ target: CheckTarget, summary: String,
                                     reply: String?, runID: Int, source: RunSource) {
        activeRun?.task = nil
        if !panel.isVisible || collapsed {
            if collapsed { setCollapsed(false) }
            present()
        }
        // Only the user's own typing or held key counts as attention: a check
        // a standing ask or the wake word raised must be clicked first.
        let attending = panel.isKeyWindow && source != .scheduled && source != .wakeWord
        let now = Date()
        safetyCheck = SafetyCheck(runID: runID, target: target, shownAt: now,
                                  armedAt: attending ? now : nil)
        if let reply { presentAnswerRow(reply, tainted: activeRun?.tainted ?? true) }
        append(.system, summary)
        revealFromTopID = messages.last?.id
        let instruction = attending
            ? "Safety check: press Return to confirm, Esc to cancel."
            : "Safety check: click this panel or press \(HotKeyStore.current.displayName), then Return to confirm or Esc to cancel."
        append(.system, instruction)
        // A long payload opens at its first line, which pushes the
        // instruction row below the fold; the header says it as well, so
        // what Rusty is waiting for is always on screen.
        setStatus(.idle, note: attending ? "Return to confirm, Esc to cancel"
                                         : "Click here, then Return to confirm")
        if attending { field.becomeFirstResponder() }
        rebuildRows()
        announceForAccessibility("\(summary). \(instruction)", urgent: true)
    }

    /// A Rusty row without the answer-completion side effects (used inside a
    /// confirmation, where the turn is not done yet).
    private func presentAnswerRow(_ text: String, tainted: Bool) {
        append(.rusty, text)
        conversation.append(role: "assistant", text: text, tainted: tainted)
    }

    /// A failure line, shown and said.
    private func presentFailure(_ message: String) {
        append(.system, message)
        rebuildRows()
        announceForAccessibility(message)
        scheduleHide(after: max(8, readingTime(for: message)))
    }

    private func applyAgentStep(_ step: AgentSession.Step, runID: Int) {
        guard var run = activeRun, run.id == runID else { return }
        // Whatever the session read (a page, a file, a tool result, the
        // screen) taints its answer in the history too.
        if run.session?.tainted == true {
            run.tainted = true
            activeRun?.tainted = true
        }
        let fromVoice = run.source.isVoice
        setStatus(.idle)
        switch step {
        case .done(let answer):
            finishRun()
            deliverAnswer(answer, source: run.source, outcome: .reply(answer), chime: true,
                          tainted: run.tainted)
        case .needsConfirmation(let action, let summary):
            clearStreamingRow()
            guard let session = run.session else { return }
            presentConfirmation(.agent(session), summary: summary, reply: nil,
                                runID: runID, source: run.source)
            // The microphone goes back to the wake word while the user
            // answers at the keyboard.
            if fromVoice { onOutcome?(.needsConfirmation(action, reply: nil), true) }
        case .failed(let message):
            clearStreamingRow()
            finishRun()
            guard message != AgentSession.stoppedMessage else {
                rebuildRows()
                return
            }
            if run.source == .scheduled, let onScheduledAnswer {
                onScheduledAnswer("A standing ask couldn't finish: \(message)")
                rebuildRows()
                return
            }
            presentFailure(message)
            onOutcome?(.unrecognized(message), fromVoice)
        }
    }

    private func apply(_ outcome: AssistantBrain.Outcome, runID: Int) {
        guard let run = activeRun, run.id == runID else { return }
        let fromVoice = run.source.isVoice
        setStatus(.idle)
        switch outcome {
        case .executed(let result, let reply):
            finishRun()
            deliverAnswer(reply ?? result, source: run.source, outcome: outcome, chime: true,
                          tainted: run.tainted)
        case .needsConfirmation(let action, _) where action.exceedsConfirmableLength:
            finishRun()
            presentFailure(AgentSession.tooLongToConfirm)
            onOutcome?(.unrecognized(AgentSession.tooLongToConfirm), fromVoice)
        case .needsConfirmation(let action, let reply):
            presentConfirmation(.direct(action),
                                summary: AgentGate.summary(action, tainted: run.tainted,
                                                           heard: run.source.isHeard),
                                reply: reply, runID: runID, source: run.source)
            onOutcome?(outcome, fromVoice)
        case .reply(let reply):
            finishRun()
            deliverAnswer(reply, source: run.source, outcome: outcome, tainted: run.tainted)
        case .unrecognized(let hint):
            finishRun()
            if run.source == .scheduled, let onScheduledAnswer {
                onScheduledAnswer(hint)
                return
            }
            presentFailure(hint)
            onOutcome?(outcome, fromVoice)
        }
    }

    /// Leaves a message up long enough to actually read (roughly reading
    /// speed), so a paragraph isn't dismissed after a few seconds.
    private func readingTime(for text: String) -> TimeInterval {
        min(45, max(6, Double(text.count) / 18))
    }

    // MARK: - Status lamp

    private enum Status { case idle, listening, thinking }

    private func setStatus(_ newStatus: Status, note: String? = nil) {
        statusDot.layer?.removeAllAnimations()
        switch newStatus {
        case .idle:
            statusDot.layer?.backgroundColor = theme.accent.withAlphaComponent(0.45).cgColor
            statusLabel.stringValue = note ?? ""
        case .listening:
            statusDot.layer?.backgroundColor = theme.accent.cgColor
            statusLabel.stringValue = "Listening…"
            pulse()
        case .thinking:
            statusDot.layer?.backgroundColor = theme.thinking.cgColor
            statusLabel.stringValue = "Thinking…"
            pulse()
        }
        statusLabel.sizeToFit()
        positionStatus()
    }

    private func pulse() {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1.0
        a.toValue = 0.25
        a.duration = 0.7
        a.autoreverses = true
        a.repeatCount = .infinity
        statusDot.layer?.add(a, forKey: "pulse")
    }

    // MARK: - Layout

    private func append(_ kind: Message.Kind, _ text: String,
                        pending: Bool = false, streaming: Bool = false) {
        messages.append(Message(id: nextMessageID, kind: kind, text: text,
                                pending: pending, streaming: streaming))
        nextMessageID += 1
        if kind == .user { revealForced = true }
    }

    /// Brings the row views in line with `messages`. Rows are reused by
    /// message id, so their cached measurements survive and only new or
    /// changed rows cost anything; `retheme` rebuilds them all for a new skin.
    private func rebuildRows(retheme: Bool = false) {
        if messages.count > Layout.maxMessages {
            messages.removeFirst(messages.count - Layout.maxMessages)
        }
        if retheme {
            rowCache.values.forEach { $0.removeFromSuperview() }
            rowCache = [:]
        }
        let theme = self.theme  // resolve the skin once, not once per row
        if let newest = messages.last, rowCache[newest.id] == nil, !retheme {
            revealNewestRow = true
        }
        var kept: [Int: MessageRowView] = [:]
        rowViews = messages.map { message in
            if let row = rowCache[message.id] {
                row.update(text: message.text, pending: message.pending,
                           streaming: message.streaming)
                kept[message.id] = row
                return row
            }
            let row = MessageRowView(message: message, theme: theme)
            transcriptDoc.addSubview(row)
            kept[message.id] = row
            return row
        }
        for (id, row) in rowCache where kept[id] == nil { row.removeFromSuperview() }
        rowCache = kept
        relayout()
    }

    private var panelWidth: CGFloat { collapsed ? Layout.collapsedWidth : Layout.width }

    private func positionStatus() {
        let panelHeight = container.frame.height
        if collapsed {
            // Chip: close in the top-right, status lamp in the top-left.
            // Clicking the chip itself reopens, so there is no expand button.
            closeButton.frame = CGRect(x: Layout.collapsedWidth - 17,
                                       y: Layout.collapsedHeight - 17,
                                       width: 14, height: 14)
            statusDot.frame.origin = CGPoint(x: 7, y: Layout.collapsedHeight - 14)
            return
        }
        statusLabel.frame.origin = CGPoint(
            x: Layout.width - Layout.margin - 8 - 44 - 6 - statusLabel.frame.width,
            y: panelHeight - 12 - Layout.headerHeight + 2)
        statusDot.frame.origin = CGPoint(x: Layout.width - Layout.margin - 7 - 44,
                                         y: panelHeight - 12 - Layout.headerHeight + 5)
        collapseButton.frame = CGRect(x: Layout.width - Layout.margin - 38,
                                      y: panelHeight - 12 - Layout.headerHeight,
                                      width: 18, height: 18)
        closeButton.frame = CGRect(x: Layout.width - Layout.margin - 16,
                                   y: panelHeight - 12 - Layout.headerHeight,
                                   width: 18, height: 18)
    }

    private func relayout() {
        let frameWidth = Layout.width - 2 * Layout.margin
        let spacing: CGFloat = 6
        func stackHeight(_ heights: [CGFloat]) -> CGFloat {
            heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * spacing
        }
        // Rows are laid out at the clip view's width, not the scroll view's.
        // Legacy scroll bars (a mouse connected, or "always show") take their
        // width from the content once the transcript overflows; overlay ones
        // take none.
        var rowWidth = frameWidth
        var heights = rowViews.map { $0.measuredHeight(width: rowWidth) }
        if transcriptScroll.scrollerStyle == .legacy,
           stackHeight(heights) > Layout.maxTranscriptHeight {
            rowWidth = frameWidth - NSScroller.scrollerWidth(for: .small, scrollerStyle: .legacy)
            heights = rowViews.map { $0.measuredHeight(width: rowWidth) }
        }

        // Where the reader is, before anything moves: following the tail, or
        // scrolled up to reread something.
        let clip = transcriptScroll.contentView
        let oldDocHeight = transcriptDoc.frame.height
        let wasFollowing = oldDocHeight <= clip.bounds.height + 1
            || clip.bounds.maxY >= oldDocHeight - 4

        // Full stacked content height; the scroll view shows the tail of it,
        // capped at the viewport. A single long answer scrolls instead of
        // being clipped or dropped.
        let contentHeight = stackHeight(heights)
        let viewport = collapsed ? 0 : min(contentHeight, Layout.maxTranscriptHeight)
        transcriptScroll.isHidden = collapsed || rowViews.isEmpty
        inputBox.isHidden = collapsed

        let panelHeight: CGFloat = collapsed
            ? Layout.collapsedHeight
            : 12 + Layout.inputHeight + (viewport > 0 ? 10 + viewport : 0) + 12 + Layout.headerHeight + 12

        var frame = panel.frame
        let top = frame.maxY
        frame.size = CGSize(width: panelWidth, height: panelHeight)
        frame.origin.y = top - panelHeight
        // Grow within whichever display the panel is on. `panel.screen` is nil
        // once the panel is fully off-screen, so fall back to the display its
        // origin points at rather than to the main one.
        let screen = panel.screen?.visibleFrame ?? Screens.visibleFrame(for: frame.origin)
        frame.origin = DisplayChoice.clamp(origin: frame.origin, size: frame.size,
                                           into: screen, inset: 8)
        panel.setFrame(frame, display: true)
        container.frame = CGRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = container.bounds
        CATransaction.commit()

        headerLabel.isHidden = collapsed
        statusLabel.isHidden = collapsed
        collapseButton.isHidden = collapsed
        if collapsed {
            // The whole chip is a drag handle and a click target, with
            // Rusty's face centered in it.
            dragHandle.frame = container.bounds
            let faceW: CGFloat = 34, faceH: CGFloat = 26
            faceView.frame = CGRect(x: (Layout.collapsedWidth - faceW) / 2,
                                    y: (Layout.collapsedHeight - faceH) / 2 - 3,
                                    width: faceW, height: faceH)
        } else {
            dragHandle.frame = CGRect(x: 0, y: panelHeight - 44, width: panelWidth, height: 44)
            faceView.frame = CGRect(x: Layout.margin, y: panelHeight - 12 - Layout.headerHeight,
                                    width: 26, height: 20)
            headerLabel.sizeToFit()
            headerLabel.frame.origin = CGPoint(x: Layout.margin + 34,
                                               y: panelHeight - 12 - Layout.headerHeight + 2)
        }
        faceView.needsDisplay = true
        positionStatus()

        // Stack rows top-down in the flipped document, newest last.
        transcriptScroll.frame = CGRect(x: Layout.margin, y: 12 + Layout.inputHeight + 10,
                                        width: frameWidth, height: viewport)
        // Exactly the clip's width, so nothing sits under the scroll bar and
        // a sideways scroll has nowhere to go.
        transcriptDoc.frame = CGRect(x: 0, y: 0, width: rowWidth, height: contentHeight)
        var y: CGFloat = 0
        for (i, row) in rowViews.enumerated() {
            row.frame = CGRect(x: 0, y: y, width: rowWidth, height: heights[i])
            row.layoutContents()
            y += heights[i] + spacing
        }
        // A safety check always comes into view, from its first line. A new
        // row comes into view only for a reader following the tail, or when
        // the user added it themselves: from its first line when it is taller
        // than the viewport (so a long answer is read from the top), else
        // with the tail. Someone scrolled up to reread stays where they are,
        // whatever arrives below.
        let revealNew = revealNewestRow && (wasFollowing || revealForced)
        if !collapsed, contentHeight > viewport {
            if let id = revealFromTopID, let summaryRow = rowCache[id],
               contentHeight - summaryRow.frame.minY > viewport {
                transcriptDoc.scroll(CGPoint(x: 0, y: summaryRow.frame.minY))
            } else if revealNew, let newest = rowViews.last, let height = heights.last,
               height > viewport {
                transcriptDoc.scroll(CGPoint(x: 0, y: newest.frame.minY))
            } else if revealNew || wasFollowing {
                transcriptDoc.scroll(CGPoint(x: 0, y: contentHeight - viewport))
            }
        }
        revealNewestRow = false
        revealForced = false
        revealFromTopID = nil

        inputBox.frame = CGRect(x: Layout.margin, y: 12, width: frameWidth, height: Layout.inputHeight)
        field.frame = CGRect(x: 12, y: 7, width: frameWidth - 24, height: 20)
    }
}

private extension NSColor {
    /// Relative luminance above the midpoint: a light glass.
    var isLight: Bool {
        guard let rgb = usingColorSpace(.sRGB) else { return false }
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent
            + 0.0722 * rgb.blueComponent
        return luminance > 0.5
    }
}

private extension SkinTheme {
    /// Status text, notes and system rows. Derived from the skin's own text
    /// color rather than fixed white, so a light custom skin stays readable,
    /// and strong enough to clear 4.5:1 on every built-in glass.
    var secondaryText: NSColor { userText.withAlphaComponent(0.62) }
}

/// The panel's content view: reports the pointer entering and leaving, so a
/// timed hide waits while someone is reading.
private final class HoverView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let tracking = NSTrackingArea(rect: bounds,
                                      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
        addTrackingArea(tracking)
        area = tracking
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }
}

/// Top-left origin so transcript rows stack downward and newest sits at the
/// bottom, matching how the scroll view reveals the tail.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Header strip that moves the whole panel when dragged. A press that never
/// turns into a drag counts as a click, which is how the minimized tile
/// reopens; while minimized it is also an accessible "Open Rusty" button.
private final class HeaderDragView: NSView {
    var onDragged: ((CGPoint) -> Void)?
    var onClick: (() -> Void)?
    /// A press that did turn into a drag has ended.
    var onDragEnded: (() -> Void)?
    var actsAsOpenButton = false
    private var didDrag = false

    override func mouseDown(with event: NSEvent) { didDrag = false }

    override func mouseDragged(with event: NSEvent) {
        didDrag = true
        onDragged?(CGPoint(x: event.deltaX, y: -event.deltaY))
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag { onDragEnded?() } else { onClick?() }
    }

    override func isAccessibilityElement() -> Bool { actsAsOpenButton }
    override func accessibilityRole() -> NSAccessibility.Role? { actsAsOpenButton ? .button : nil }
    override func accessibilityLabel() -> String? { actsAsOpenButton ? "Open Rusty" : nil }
    override func accessibilityPerformPress() -> Bool {
        guard actsAsOpenButton else { return false }
        onClick?()
        return true
    }
}

/// One transcript row: a rounded bubble for user (right) and Rusty (left,
/// accent-tinted), or a dim line for system notes (centered when short,
/// left-aligned with bold section titles when it is a block like Help).
private final class MessageRowView: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let bubble = NSView()
    private let kind: CommandBar.Message.Kind
    private let theme: SkinTheme
    private var text: String
    private var pending: Bool
    /// Still being filled in by the stream: measured incrementally.
    private var streaming: Bool
    private static let maxBubbleTextWidth: CGFloat = 316

    fileprivate init(message: CommandBar.Message, theme: SkinTheme) {
        kind = message.kind
        self.theme = theme
        text = message.text
        pending = message.pending
        streaming = message.streaming
        super.init(frame: .zero)
        bubble.wantsLayer = true
        addSubview(bubble)
        label.font = .systemFont(ofSize: 13)
        label.isSelectable = true
        label.maximumNumberOfLines = 0
        label.cell?.truncatesLastVisibleLine = false
        bubble.addSubview(label)

        switch kind {
        case .user:
            bubble.layer?.backgroundColor = theme.userText.withAlphaComponent(0.09).cgColor
            bubble.layer?.cornerRadius = 11
            label.textColor = theme.userText
        case .rusty:
            bubble.layer?.backgroundColor = theme.accent.withAlphaComponent(0.10).cgColor
            bubble.layer?.borderColor = theme.accent.withAlphaComponent(0.22).cgColor
            bubble.layer?.borderWidth = 1
            bubble.layer?.cornerRadius = 11
            label.textColor = theme.rustyText
        case .system:
            bubble.layer?.backgroundColor = NSColor.clear.cgColor
            label.textColor = theme.secondaryText
            label.font = .systemFont(ofSize: 11.5)
        }
        setLabelText(message.text)
        alphaValue = message.pending ? 0.55 : 1.0
        // VoiceOver reads who said it, then the words.
        switch kind {
        case .user: label.setAccessibilityLabel("You")
        case .rusty: label.setAccessibilityLabel("Rusty")
        case .system: label.setAccessibilityLabel("Note")
        }
    }

    required init?(coder: NSCoder) { nil }

    /// In-place text update for the streaming row, so tokens don't rebuild
    /// the whole transcript.
    func updateText(_ newText: String) {
        guard newText != text else { return }
        text = newText
        setLabelText(newText)
        cachedSize = nil
    }

    func update(text newText: String, pending newPending: Bool, streaming newStreaming: Bool) {
        if newStreaming != streaming {
            streaming = newStreaming
            streamPrefix = (0, .zero)
            cachedSize = nil
        }
        updateText(newText)
        if newPending != pending {
            pending = newPending
            alphaValue = newPending ? 0.55 : 1.0
        }
    }

    private var isBlock: Bool { text.contains("\n") || text.count > 90 }

    private func setLabelText(_ value: String) {
        guard kind == .system else {
            label.stringValue = value
            return
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = isBlock ? .left : .center
        // A safety check shows the whole script or command; nothing is cut
        // off or ellipsized, and a long unbroken run wraps by character.
        paragraph.lineBreakMode = .byWordWrapping
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5),
            .foregroundColor: theme.secondaryText,
            .paragraphStyle: paragraph,
        ]
        guard isBlock else {
            label.attributedStringValue = NSAttributedString(string: value, attributes: body)
            return
        }
        // A section title is an unindented line followed by indented ones
        // (the Help layout); it gets weight so the list has a hierarchy.
        var title = body
        title[.font] = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        title[.foregroundColor] = theme.userText.withAlphaComponent(0.85)
        let lines = value.components(separatedBy: "\n")
        let result = NSMutableAttributedString()
        for (i, line) in lines.enumerated() {
            let next = i + 1 < lines.count ? lines[i + 1] : ""
            let isTitle = !line.isEmpty && !line.hasPrefix(" ") && next.hasPrefix("  ")
            result.append(NSAttributedString(string: line + (i + 1 < lines.count ? "\n" : ""),
                                             attributes: isTitle ? title : body))
        }
        label.attributedStringValue = result
    }

    /// Text measurement is the expensive part of layout, and relayout runs
    /// per token while an answer streams. Cache the boundingRect per
    /// (text, width) so only the row whose text changed is re-measured, and
    /// measuredHeight/layoutContents share one measurement instead of two.
    private var cachedSize: CGSize?
    private var cachedKey: (text: String, width: CGFloat) = ("", -1)

    private func textSize(rowWidth: CGFloat) -> CGSize {
        if let cachedSize, cachedKey == (text, rowWidth) { return cachedSize }
        let textWidth = kind == .system ? rowWidth - 16 : Self.maxBubbleTextWidth
        let measured: CGSize
        if streaming, kind == .rusty {
            measured = streamingSize(textWidth: textWidth)
        } else {
            let size = label.attributedStringValue.boundingRect(
                with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading])
            measured = CGSize(width: ceil(size.width), height: ceil(size.height))
        }
        cachedSize = measured
        cachedKey = (text, rowWidth)
        return measured
    }

    /// Streamed text only ever grows at the end, and paragraphs (split at
    /// newlines) never reflow into one another. So the paragraphs already
    /// finished are measured once and remembered, and each update measures
    /// only the paragraph still being written. Re-measuring the whole
    /// answer on every chunk made a long answer quadratic. Each piece is
    /// rounded up, so the sum never comes out short of the full measure
    /// (which is taken once the stream ends).
    private var streamPrefix: (utf16Length: Int, size: CGSize) = (0, .zero)

    private func streamingSize(textWidth: CGFloat) -> CGSize {
        let whole = text as NSString
        let bounds = CGSize(width: textWidth, height: .greatestFiniteMagnitude)
        let attributes: [NSAttributedString.Key: Any] = [.font: label.font ?? NSFont.systemFont(ofSize: 13)]
        func measure(_ piece: String) -> CGSize {
            // An empty paragraph still takes a line.
            let rect = NSAttributedString(string: piece.isEmpty ? " " : piece, attributes: attributes)
                .boundingRect(with: bounds, options: [.usesLineFragmentOrigin, .usesFontLeading])
            return CGSize(width: ceil(rect.width), height: ceil(rect.height))
        }
        if streamPrefix.utf16Length > whole.length { streamPrefix = (0, .zero) }
        let tailRange = NSRange(location: streamPrefix.utf16Length,
                                length: whole.length - streamPrefix.utf16Length)
        let lastBreak = whole.range(of: "\n", options: .backwards, range: tailRange)
        if lastBreak.location != NSNotFound {
            // Everything up to that newline is finished paragraphs.
            let finished = whole.substring(with: NSRange(
                location: streamPrefix.utf16Length,
                length: lastBreak.location - streamPrefix.utf16Length))
            let size = measure(finished)
            streamPrefix = (lastBreak.location + 1,
                            CGSize(width: max(streamPrefix.size.width, size.width),
                                   height: streamPrefix.size.height + size.height))
        }
        let tail = whole.substring(from: streamPrefix.utf16Length)
        guard streamPrefix.utf16Length > 0 else { return measure(tail) }
        let tailSize = measure(tail)
        return CGSize(width: max(streamPrefix.size.width, tailSize.width),
                      height: streamPrefix.size.height + tailSize.height)
    }

    func measuredHeight(width: CGFloat) -> CGFloat {
        textSize(rowWidth: width).height + (kind == .system ? 4 : 14)
    }

    func layoutContents() {
        let width = frame.width
        let size = textSize(rowWidth: width)
        let textW = size.width
        let textH = size.height
        switch kind {
        case .system:
            bubble.frame = bounds
            label.frame = CGRect(x: 8, y: 2, width: width - 16, height: textH)
        case .user:
            let bubbleW = textW + 22
            bubble.frame = CGRect(x: width - bubbleW, y: 0, width: bubbleW, height: textH + 14)
            label.frame = CGRect(x: 11, y: 7, width: textW + 1, height: textH)
        case .rusty:
            let bubbleW = textW + 22
            bubble.frame = CGRect(x: 0, y: 0, width: bubbleW, height: textH + 14)
            label.frame = CGRect(x: 11, y: 7, width: textW + 1, height: textH)
        }
    }
}

/// Minimal Rusty face for the panel header, drawn in the active skin. Art is
/// authored at 26x20 and scaled to whatever frame it's given, so the same
/// view works as a header stamp and as the big face on the minimized tile.
private final class RustyFaceView: NSView {
    /// Set on retint; never read SkinTheme.current from draw (draw runs per
    /// repaint, and resolving the skin can touch disk).
    var theme: SkinTheme = SkinTheme.current

    override func draw(_ dirtyRect: NSRect) {
        let theme = self.theme
        let scale = min(bounds.width / 26, bounds.height / 20)
        if scale != 1 {
            let transform = NSAffineTransform()
            transform.scaleX(by: scale, yBy: scale)
            transform.concat()
        }
        let plate = NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: 26, height: 20),
                                 xRadius: 5, yRadius: 5)
        theme.userText.withAlphaComponent(0.85).setFill()
        plate.fill()
        theme.border.withAlphaComponent(0.9).setStroke()
        plate.lineWidth = 1.2
        plate.stroke()
        let visor = NSBezierPath(roundedRect: CGRect(x: 3, y: 4.5, width: 20, height: 11),
                                 xRadius: 5, yRadius: 5)
        theme.glassBottom.withAlphaComponent(1).setFill()
        visor.fill()
        theme.accent.setFill()
        NSBezierPath(ovalIn: CGRect(x: 7, y: 7.5, width: 4.5, height: 4.5)).fill()
        NSBezierPath(ovalIn: CGRect(x: 14.5, y: 7.5, width: 4.5, height: 4.5)).fill()
        NSColor.white.withAlphaComponent(0.9).setFill()
        NSBezierPath(ovalIn: CGRect(x: 9, y: 10, width: 1.6, height: 1.6)).fill()
        NSBezierPath(ovalIn: CGRect(x: 16.5, y: 10, width: 1.6, height: 1.6)).fill()
    }
}

/// Borderless panel that can take keyboard focus for the text field.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// Command-C with nothing selected: copy Rusty's last answer, which is
    /// what someone reaching for copy in a chat panel actually wants.
    /// Returns true when it handled the copy.
    var copyLastAnswer: (() -> Bool)?
    /// Sees every key-down first; returns true when it handled the key.
    var keyRouter: ((NSEvent) -> Bool)?
    /// Esc that no view handled.
    var onCancel: (() -> Void)?
    /// Any click inside the panel.
    var onUserClick: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown, .keyUp, .flagsChanged:
            // A key Rusty posted himself never reaches his own panel: not
            // into the input field, and never as a Return on a safety check.
            if let cgEvent = event.cgEvent, AssistantExecutor.isSynthetic(cgEvent) { return }
            if event.type == .keyDown, keyRouter?(event) == true { return }
        case .leftMouseDown, .rightMouseDown:
            onUserClick?()
        default:
            break
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// A menu-bar app has no Edit menu, so nothing turns Command-C into
    /// `copy:` for this panel. Dispatch the standard editing shortcuts to
    /// whatever is focused (the input field, or a selected transcript row).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !flags.contains(.control), !flags.contains(.option),
              let key = event.charactersIgnoringModifiers?.lowercased(),
              let command = EditCommand.forKey(key, shift: flags.contains(.shift)) else {
            return super.performKeyEquivalent(with: event)
        }
        // Copying an empty selection would silently do nothing, so hand it to
        // the transcript instead.
        if command == .copy, let editor = firstResponder as? NSTextView,
           editor.selectedRange().length == 0, copyLastAnswer?() == true {
            return true
        }
        // Sending to nil walks the responder chain from the first responder,
        // which is where the field editor (and its undo manager) lives.
        if NSApp.sendAction(NSSelectorFromString(command.rawValue), to: nil, from: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// The panel's pure rules (ConfirmationGate, AutoHidePolicy,
// ConversationHistory) live in WindowPetCore/PanelRules.swift, where the
// unit tests reach them.
