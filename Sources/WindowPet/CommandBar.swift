import AppKit
import Carbon.HIToolbox
import WindowPetCore

/// Rusty's chat panel, the single conversation surface for every input
/// method: typed (tap Option-Space or double-click the pet), push-to-talk
/// (hold Option-Space), and the wake word. Colors come from the active skin.
/// The header is a drag handle with a minimize control that collapses the
/// panel to a slim pill. Enter submits, a second Enter confirms destructive
/// verbs, Esc dismisses.
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
    }

    fileprivate struct Message {
        enum Kind { case user, rusty, system }
        let kind: Kind
        var text: String
        var pending = false
        /// A Rusty row still being filled in by the stream.
        var streaming = false
    }

    private var panel: NSPanel!
    private var container: NSView!
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
    private var rowViews: [MessageRowView] = []
    private var pendingConfirmation: AssistantAction?
    /// The live agentic loop, kept across a safety check so it can resume.
    private var agent: AgentSession?
    private var lastRunWasVoice = false
    private var hotKeyRef: EventHotKeyRef?
    private var hideTimer: DispatchSourceTimer?
    private var collapsed = false
    private var pinnedOrigin: CGPoint?

    /// Rolling plain-text exchange history handed to the LLM tiers so
    /// follow-ups ("now hide it") resolve.
    private(set) var history: [(role: String, text: String)] = []

    var onOutcome: ((AssistantBrain.Outcome, _ fromVoice: Bool) -> Void)?
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

        container = NSView(frame: CGRect(x: 0, y: 0, width: Layout.width, height: 96))
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
        container.addSubview(statusDot)

        collapseButton = NSButton(frame: CGRect(x: 0, y: 0, width: 18, height: 18))
        collapseButton.isBordered = false
        collapseButton.bezelStyle = .regularSquare
        collapseButton.target = self
        collapseButton.action = #selector(toggleCollapsed)
        container.addSubview(collapseButton)

        closeButton = NSButton(frame: CGRect(x: 0, y: 0, width: 18, height: 18))
        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.target = self
        closeButton.action = #selector(closePanel)
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
        inputBox.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        inputBox.layer?.borderWidth = 1
        inputBox.layer?.borderColor = NSColor.white.withAlphaComponent(0.06).cgColor
        container.addSubview(inputBox)

        field.placeholderString = "Ask Rusty anything…"
        field.font = .systemFont(ofSize: 14)
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        inputBox.addSubview(field)

        panel.contentView = container
        panel.copyLastAnswer = { [weak self] in self?.copyLastAnswerToPasteboard() ?? false }
        self.panel = panel
        dragHandle.onClick = { [weak self] in
            guard let self, self.collapsed else { return }
            self.setCollapsed(false)
            self.panel.makeKey()
            self.field.becomeFirstResponder()
        }
        dragHandle.onDragged = { [weak self] delta in
            guard let self else { return }
            var o = self.panel.frame.origin
            o.x += delta.x
            o.y += delta.y
            self.panel.setFrameOrigin(o)
            self.pinnedOrigin = o
        }
        retint()
        setStatus(.idle)
        relayout()
    }

    /// Re-applies the active skin. Safe to call live; also rebuilds rows so
    /// bubbles pick up the new tints.
    func retint() {
        let theme = self.theme  // resolve the skin once for the whole pass
        gradient.colors = [theme.glassTop.cgColor, theme.glassBottom.cgColor]
        container.layer?.borderColor = theme.border.cgColor
        headerLabel.attributedStringValue = NSAttributedString(
            string: "RUSTY",
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                         .kern: 2.6,
                         .foregroundColor: theme.userText.withAlphaComponent(0.72)])
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        field.textColor = theme.userText
        styleControls()
        faceView.theme = theme
        faceView.needsDisplay = true
        setStatus(.idle)
        rebuildRows()
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
            if GetEventKind(event) == UInt32(kEventHotKeyPressed) {
                bar.hotKeyDown()
            } else {
                bar.hotKeyUp()
            }
            return noErr
        }, 2, &eventTypes, selfPtr, nil)
        applyHotKey(HotKeyStore.current)
    }

    /// (Re)binds the summon shortcut. Safe to call whenever the user picks a
    /// new one: the old registration is released first.
    func applyHotKey(_ binding: HotKeyBinding) {
        if let existing = hotKeyRef {
            UnregisterEventHotKey(existing)
            hotKeyRef = nil
        }
        let hotKeyID = EventHotKeyID(signature: OSType(0x52535459) /* RSTY */, id: 1)
        RegisterEventHotKey(UInt32(binding.keyCode), binding.carbonModifiers, hotKeyID,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
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

    func toggle() {
        panel.isVisible ? dismiss() : show()
    }

    /// Typed session: present and take the keyboard.
    func show() {
        if collapsed { setCollapsed(false) }
        present()
        panel.makeKey()
        field.becomeFirstResponder()
    }

    func dismiss() {
        cancelHide()
        panel.orderOut(nil)
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
    }

    private func present() {
        cancelHide()
        if !panel.isVisible {
            let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1512, height: 944)
            var origin = pinnedOrigin ?? CGPoint(x: screen.midX - Layout.width / 2,
                                                 y: screen.midY + 40)
            if pinnedOrigin == nil, let a = petAnchorProvider?() {
                origin = CGPoint(x: a.x - Layout.width / 2, y: a.y + 64)
            }
            origin.x = min(max(origin.x, screen.minX + 12), screen.maxX - Layout.width - 12)
            origin.y = min(max(origin.y, screen.minY + 12), screen.maxY - 140)
            panel.setFrameOrigin(origin)
        }
        relayout()
        panel.orderFrontRegardless()
    }

    private func scheduleHide(after seconds: TimeInterval) {
        cancelHide()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + seconds)
        t.setEventHandler { [weak self] in self?.dismiss() }
        t.resume()
        hideTimer = t
    }

    private func cancelHide() {
        hideTimer?.cancel()
        hideTimer = nil
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
            if i < rowViews.count {
                rowViews[i].updateText(text)
                relayout()
                cancelHide()
                return
            }
        } else {
            messages.append(Message(kind: .user, text: text, pending: true))
        }
        rebuildRows()
    }

    /// End of capture. Empty text is a miss; otherwise routes like typed.
    func finishVoice(_ text: String) {
        if text.isEmpty {
            messages.removeAll(where: \.pending)
            rebuildRows()
            setStatus(.idle, note: "Didn't catch that. Try again?")
            scheduleHide(after: 5)
            return
        }
        if let i = messages.lastIndex(where: { $0.pending }) {
            messages[i].text = text
            messages[i].pending = false
        } else {
            messages.append(Message(kind: .user, text: text))
        }
        rebuildRows()
        run(text, fromVoice: true)
    }

    /// Follow-up window closed with silence: no miss note, just settle.
    func endVoiceQuietly() {
        messages.removeAll(where: \.pending)
        rebuildRows()
        setStatus(.idle)
        scheduleHide(after: 4)
    }

    /// One-shot "hey rusty <command>": no capture phase, straight in.
    func submitVoice(_ text: String) {
        if collapsed { setCollapsed(false) }
        present()
        messages.append(Message(kind: .user, text: text))
        rebuildRows()
        run(text, fromVoice: true)
    }

    /// Out-of-band notes (voice errors etc.) that should reach the user.
    func systemNote(_ text: String) {
        present()
        messages.append(Message(kind: .system, text: text))
        rebuildRows()
        scheduleHide(after: 6)
    }

    // MARK: - Submission pipeline (shared by typed and voice)

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            // Esc during a safety check declines that step and lets the loop
            // adapt, rather than abandoning the run silently.
            if let session = agent, session.isAwaitingConfirmation {
                resumeAgent(approved: false)
                return true
            }
            dismiss()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            submitTyped()
            return true
        }
        return false
    }

    func controlTextDidChange(_ obj: Notification) {
        cancelHide()
    }

    private func submitTyped() {
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        // Return on an empty field answers a pending safety check.
        if text.isEmpty, let session = agent, session.isAwaitingConfirmation {
            resumeAgent(approved: true)
            return
        }
        if let pending = pendingConfirmation, text.isEmpty {
            pendingConfirmation = nil
            let (result, _) = AssistantExecutor.executeChecked(pending)
            messages.append(Message(kind: .rusty, text: result))
            history.append((role: "assistant", text: result))
            rebuildRows()
            SoundFX.shared.play("ack")
            onOutcome?(.executed(result, reply: nil), false)
            scheduleHide(after: 6)
            return
        }
        pendingConfirmation = nil
        guard !text.isEmpty else { return }
        field.stringValue = ""
        messages.append(Message(kind: .user, text: text))
        rebuildRows()
        run(text, fromVoice: false)
    }

    private func run(_ text: String, fromVoice: Bool) {
        setStatus(.thinking)
        history.append((role: "user", text: text))
        // What the model sees stays bounded (tokens and latency); what you
        // see in the panel is the full transcript.
        if history.count > 24 { history.removeFirst(history.count - 24) }
        let context = contextProvider?() ?? ""
        let priorHistory = Array(history.dropLast())

        // Exact commands stay instant and free: no API call for "mute".
        if let action = AssistantParser.parse(text) {
            if action.needsConfirmation {
                apply(.needsConfirmation(action, reply: nil), fromVoice: fromVoice)
                return
            }
            let (result, ok) = AssistantExecutor.executeChecked(action)
            if ok {
                apply(.executed(result, reply: nil), fromVoice: fromVoice)
                return
            }
            // A miss (not an app) falls through to the thinking tiers.
        }

        // With a key, run the real agentic loop: Claude calls a tool, reads
        // the result, and decides the next step until the job is done.
        if ClaudeRouter.isConfigured {
            let session = AgentSession()
            session.onProgress = { [weak self] line in
                Task { @MainActor in self?.noteProgress(line) }
            }
            session.onTextDelta = { [weak self] chunk in
                Task { @MainActor in self?.appendStreamedText(chunk) }
            }
            agent = session
            Task {
                let step = await session.start(text, context: context, history: priorHistory)
                await MainActor.run { [weak self] in self?.applyAgentStep(step, fromVoice: fromVoice) }
            }
            return
        }

        Task {
            let outcome = await AssistantBrain.handle(text, context: context,
                                                      history: priorHistory)
            await MainActor.run { [weak self] in self?.apply(outcome, fromVoice: fromVoice) }
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
    /// is replaced by the final sanitized text when the turn completes.
    private func appendStreamedText(_ chunk: String) {
        if let index = messages.lastIndex(where: { $0.streaming }) {
            messages[index].text += chunk
            // Only the streaming row changed, so update it in place rather
            // than rebuilding every row on every token.
            if index < rowViews.count {
                rowViews[index].updateText(messages[index].text)
                relayout()
                cancelHide()
                return
            }
        } else {
            messages.append(Message(kind: .rusty, text: chunk, streaming: true))
        }
        rebuildRows()
    }

    /// Drops the live streaming row once the finished text is in hand.
    private func clearStreamingRow() {
        messages.removeAll { $0.streaming }
    }

    /// Live narration of each step while the loop works.
    private func noteProgress(_ line: String) {
        clearStreamingRow()
        messages.append(Message(kind: .system, text: line))
        rebuildRows()
        setStatus(.thinking)
    }

    private func resumeAgent(approved: Bool) {
        guard let session = agent else { return }
        setStatus(.thinking)
        if !approved {
            messages.append(Message(kind: .system, text: "Skipped that step."))
            rebuildRows()
        }
        Task {
            let step = await session.resume(approved: approved)
            await MainActor.run { [weak self] in
                self?.applyAgentStep(step, fromVoice: self?.lastRunWasVoice ?? false)
            }
        }
    }

    /// Shows one of Rusty's answers: chime, add the row, remember it, and set
    /// the auto-hide to reading length. Shared by both result paths.
    private func presentAnswer(_ text: String, chime: Bool) {
        if chime { SoundFX.shared.play("ack") }
        messages.append(Message(kind: .rusty, text: text))
        history.append((role: "assistant", text: text))
        scheduleHide(after: readingTime(for: text))
    }

    /// Shows a safety-check prompt and hands over the keyboard so Return
    /// confirms. One wording for every confirmation, from either path.
    private func presentConfirmation(summary: String?, reply: String?) {
        if let reply { presentAnswerRow(reply) }
        if let summary { messages.append(Message(kind: .system, text: summary)) }
        messages.append(Message(kind: .system,
                                text: "Safety check: press Return to confirm, Esc to cancel."))
        panel.makeKey()
        field.becomeFirstResponder()
    }

    /// A Rusty row without the answer-completion side effects (used inside a
    /// confirmation, where the turn is not done yet).
    private func presentAnswerRow(_ text: String) {
        messages.append(Message(kind: .rusty, text: text))
        history.append((role: "assistant", text: text))
    }

    private func applyAgentStep(_ step: AgentSession.Step, fromVoice: Bool) {
        lastRunWasVoice = fromVoice
        setStatus(.idle)
        clearStreamingRow()
        switch step {
        case .done(let answer):
            agent = nil
            presentAnswer(answer, chime: true)
            rebuildRows()
            onOutcome?(.reply(answer), fromVoice)
        case .needsConfirmation(_, let summary):
            presentConfirmation(summary: summary, reply: nil)
            rebuildRows()
        case .failed(let message):
            agent = nil
            messages.append(Message(kind: .system, text: message))
            rebuildRows()
            scheduleHide(after: 8)
            onOutcome?(.unrecognized(message), fromVoice)
        }
    }

    private func apply(_ outcome: AssistantBrain.Outcome, fromVoice: Bool) {
        setStatus(.idle)
        switch outcome {
        case .executed(let result, let reply):
            presentAnswer(reply ?? result, chime: true)
        case .needsConfirmation(let action, let reply):
            pendingConfirmation = action
            presentConfirmation(summary: action.confirmationSummary, reply: reply)
        case .reply(let reply):
            presentAnswer(reply, chime: false)
        case .unrecognized(let hint):
            messages.append(Message(kind: .system, text: hint))
            scheduleHide(after: 8)
        }
        rebuildRows()
        onOutcome?(outcome, fromVoice)
    }

    /// Leaves a long answer up long enough to actually read (roughly reading
    /// speed), so a paragraph isn't dismissed after eight seconds.
    private func readingTime(for text: String) -> TimeInterval {
        min(45, max(8, Double(text.count) / 18))
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

    private func rebuildRows() {
        // Full history: nothing is dropped, the transcript just scrolls. Rows
        // are rebuilt wholesale, which is fine for a session's worth of chat;
        // if a transcript ever gets long enough to feel it, virtualize here.
        rowViews.forEach { $0.removeFromSuperview() }
        let theme = self.theme  // resolve the skin once, not once per row
        rowViews = messages.map { message in
            let row = MessageRowView(message: message, theme: theme)
            transcriptDoc.addSubview(row)
            return row
        }
        relayout()
        cancelHide()
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
        let rowWidth = Layout.width - 2 * Layout.margin
        let heights = rowViews.map { $0.measuredHeight(width: rowWidth) }

        // Full stacked content height; the scroll view shows the tail of it,
        // capped at the viewport. A single long answer scrolls instead of
        // being clipped or dropped.
        let spacing: CGFloat = 6
        let contentHeight = heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * spacing
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
        if let screen = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            if frame.maxY > screen.maxY - 8 { frame.origin.y = screen.maxY - 8 - panelHeight }
            if frame.origin.y < screen.minY + 8 { frame.origin.y = screen.minY + 8 }
            if frame.maxX > screen.maxX - 8 { frame.origin.x = screen.maxX - 8 - panelWidth }
            if frame.origin.x < screen.minX + 8 { frame.origin.x = screen.minX + 8 }
        }
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
                                        width: rowWidth, height: viewport)
        transcriptDoc.frame = CGRect(x: 0, y: 0, width: rowWidth, height: contentHeight)
        var y: CGFloat = 0
        for (i, row) in rowViews.enumerated() {
            row.frame = CGRect(x: 0, y: y, width: rowWidth, height: heights[i])
            row.layoutContents()
            y += heights[i] + spacing
        }
        // Keep the newest message in view.
        if !collapsed, contentHeight > viewport {
            transcriptDoc.scroll(CGPoint(x: 0, y: contentHeight - viewport))
        }

        inputBox.frame = CGRect(x: Layout.margin, y: 12, width: rowWidth, height: Layout.inputHeight)
        field.frame = CGRect(x: 12, y: 7, width: rowWidth - 24, height: 20)
    }
}

/// Top-left origin so transcript rows stack downward and newest sits at the
/// bottom, matching how the scroll view reveals the tail.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Header strip that moves the whole panel when dragged. A press that never
/// turns into a drag counts as a click, which is how the minimized tile
/// reopens.
private final class HeaderDragView: NSView {
    var onDragged: ((CGPoint) -> Void)?
    var onClick: (() -> Void)?
    private var didDrag = false

    override func mouseDown(with event: NSEvent) { didDrag = false }

    override func mouseDragged(with event: NSEvent) {
        didDrag = true
        onDragged?(CGPoint(x: event.deltaX, y: -event.deltaY))
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag { onClick?() }
    }
}

/// One transcript row: a rounded bubble for user (right) and Rusty (left,
/// accent-tinted), or a centered dim line for system notes.
private final class MessageRowView: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let bubble = NSView()
    private let kind: CommandBar.Message.Kind
    private static let maxBubbleTextWidth: CGFloat = 316

    fileprivate init(message: CommandBar.Message, theme: SkinTheme) {
        kind = message.kind
        super.init(frame: .zero)
        bubble.wantsLayer = true
        addSubview(bubble)
        label.font = .systemFont(ofSize: 13)
        label.isSelectable = true
        bubble.addSubview(label)
        label.stringValue = message.text

        switch kind {
        case .user:
            bubble.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.09).cgColor
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
            label.textColor = NSColor.white.withAlphaComponent(0.45)
            label.font = .systemFont(ofSize: 11.5)
            label.alignment = .center
        }
        alphaValue = message.pending ? 0.55 : 1.0
    }

    required init?(coder: NSCoder) { nil }

    /// In-place text update for the streaming row, so tokens don't rebuild
    /// the whole transcript.
    func updateText(_ text: String) {
        label.stringValue = text
        cachedSize = nil
    }

    /// Text measurement is the expensive part of layout, and relayout runs
    /// per token while an answer streams. Cache the boundingRect per
    /// (text, width) so only the row whose text changed is re-measured, and
    /// measuredHeight/layoutContents share one measurement instead of two.
    private var cachedSize: CGSize?
    private var cachedKey: (text: String, width: CGFloat) = ("", -1)

    private func textSize(rowWidth: CGFloat) -> CGSize {
        if let cachedSize, cachedKey == (label.stringValue, rowWidth) { return cachedSize }
        let textWidth = kind == .system ? rowWidth - 16 : Self.maxBubbleTextWidth
        let size = label.attributedStringValue.boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let measured = CGSize(width: ceil(size.width), height: ceil(size.height))
        cachedSize = measured
        cachedKey = (label.stringValue, rowWidth)
        return measured
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
