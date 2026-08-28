import AppKit
import ApplicationServices
import QuartzCore
import WindowPetCore

/// Executes gated AssistantActions. Window moves use the Accessibility trust
/// the pet already holds (same capability as Voice Control); everything else
/// is ordinary NSWorkspace/AppleScript/Shortcuts plumbing. Returns a short
/// human line for the command bar.
@MainActor
enum AssistantExecutor {

    /// The long-lived pieces the verbs above reach for: a watch registry that
    /// keeps ticking after the turn ends, a clipboard history that has been
    /// recording since launch, and the MCP servers. They are state the app
    /// owns, not state a single command creates, so they live in one place
    /// the executor and the app delegate both address.
    @MainActor
    final class Services {
        let watches = WatchRegistry()
        let clipboard = ClipboardHistory()
        let mcp = MCPHost()
        let schedules = ScheduleRunner()
        /// Where windows were before the last arrangement, so "put it back"
        /// works.
        var arrangements = ArrangementHistory()
        /// Steps captured since "start recording", or nil when not recording.
        var recording: [TrickStep]?
    }

    static let shared = Services()

    static func execute(_ action: AssistantAction) -> String {
        executeChecked(action).result
    }

    /// The verb and argument a completed action came from, for the trick
    /// recorder. Derived from the action rather than from the caller's raw
    /// input, so a recording captures what actually ran.
    private static func recordable(_ action: AssistantAction) -> (String, String)? {
        switch action {
        case .openApp(let name): return ("open", name)
        case .switchApp(let name): return ("switch", name)
        case .hideApp(let name): return ("hide", name)
        case .windowMove(let move):
            switch move {
            case .left: return ("window_left", "")
            case .right: return ("window_right", "")
            case .maximize: return ("maximize", "")
            case .center: return ("center", "")
            }
        case .volume(let op):
            switch op {
            case .up: return ("volume_up", "")
            case .down: return ("volume_down", "")
            case .mute: return ("mute", "")
            case .unmute: return ("unmute", "")
            }
        case .media(let op):
            switch op {
            case .playpause: return ("play_pause", "")
            case .next: return ("next", "")
            case .previous: return ("previous", "")
            }
        case .search(let query): return ("search", query)
        case .openURL(let url): return ("open_url", url.absoluteString)
        case .typeText(let text): return ("type_text", text)
        case .copyText(let text): return ("copy_text", text)
        case .pressKeys(let combo): return ("press_keys", combo)
        case .screenshot: return ("screenshot", "")
        case .runShortcut(let name): return ("shortcut", name)
        case .placeWindows(let placements):
            return ("place_windows", placements.map(\.description).joined(separator: ", "))
        case .applyLayout(let name): return ("layout", name)
        // Everything else is either gated, a question whose answer only means
        // something in the moment, or part of the recorder itself.
        default: return nil
        }
    }

    /// Runs a learned routine step by step. Each step goes back through the
    /// ordinary verb mapping, so a step that needed a confirmation when it was
    /// recorded still needs one now: a trick cannot launder a gated action
    /// into an unattended one. A gated step stops the routine rather than
    /// being skipped, so nothing runs out of order behind it.
    private static func runTrick(_ trick: Trick) -> (result: String, ok: Bool) {
        var done: [String] = []
        for step in trick.steps {
            guard let action = AssistantRouting.action(verb: step.verb, argument: step.argument) else {
                return ("\(trick.name) has a step I no longer understand (\(step.description)), so I stopped there.", false)
            }
            if action.needsConfirmation {
                let ran = done.isEmpty ? "" : " I did \(done.count) of them first."
                return ("\(trick.name) reaches a step that needs your say-so (\(action.confirmationSummary ?? step.description)), so I stopped.\(ran) Ask me for that step directly and I will run it.", false)
            }
            let (result, ok) = executeChecked(action)
            guard ok else {
                return ("\(trick.name) stopped at \(step.description): \(result)", false)
            }
            done.append(step.description)
        }
        return ("Did \(trick.name): " + done.joined(separator: ", "), true)
    }

    /// Called for every action that actually ran, so a recording captures what
    /// he did rather than what he was asked.
    static func noteForRecording(_ verb: String, _ argument: String) {
        guard shared.recording != nil else { return }
        guard let appended = TrickPolicy.appending(TrickStep(verb: verb, argument: argument),
                                                   to: shared.recording ?? []) else { return }
        shared.recording = appended
    }

    /// Same execution, but reports whether the target was actually found —
    /// the brain uses a miss ("open big brother on paramount plus" is not an
    /// app) as its cue to hand the utterance to a smarter tier instead of
    /// pretending something opened.
    /// The awaiting twin of `executeChecked`, for callers that can be handed an
    /// action which waits on another process. Exactly one can: an MCP tool
    /// call. Everything else falls straight through to the synchronous path,
    /// so the gate, the recorder and the reporting are identical either way.
    ///
    /// Named differently rather than overloaded on purpose: an async overload
    /// with the same name is picked silently inside any async function, which
    /// is exactly the kind of thing nobody notices going wrong.
    static func executeAwaiting(_ action: AssistantAction) async -> (result: String, ok: Bool) {
        guard case .mcpCall(let server, let tool, let arguments, _) = action else {
            return executeChecked(action)
        }
        let decoded = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8)))
            as? [String: Any] ?? [:]
        return await shared.mcp.callTool(server: server, tool: tool, arguments: decoded)
    }

    static func executeChecked(_ action: AssistantAction) -> (result: String, ok: Bool) {
        let outcome = perform(action)
        // Only steps that actually worked join a recording. A trick made of
        // things that failed would fail the same way every time it ran.
        if outcome.ok, shared.recording != nil, let (verb, argument) = recordable(action) {
            noteForRecording(verb, argument)
        }
        return outcome
    }

    private static func perform(_ action: AssistantAction) -> (result: String, ok: Bool) {
        switch action {
        case .openApp(let name):
            if openAppChecked(name) { return ("Opening \(name)…", true) }
            return ("I couldn't find an app called \(name).", false)
        case .switchApp(let name):
            if let app = runningApp(named: name) {
                app.activate()
                return ("Switched to \(app.localizedName ?? name)", true)
            }
            if openAppChecked(name) { return ("Opening \(name)…", true) }
            return ("I couldn't find an app called \(name).", false)
        case .hideApp(let name):
            guard let app = runningApp(named: name) else { return ("\(name) isn't running", false) }
            app.hide()
            return ("Hid \(app.localizedName ?? name)", true)
        case .quitApp(let name):
            guard let app = runningApp(named: name) else { return ("\(name) isn't running", false) }
            app.terminate()
            return ("Asked \(app.localizedName ?? name) to quit", true)
        case .windowMove(let move):
            return (moveFrontWindow(move), true)  // honest message either way; LLMs can't fix permissions

        // MARK: awareness and arrangement

        case .listWindows:
            return (WindowInventory.report(), true)
        case .placeWindows(let placements):
            return (WindowArranger.apply(placements), true)
        case .saveLayout(let name):
            let placements = WindowArranger.capture()
            guard !placements.isEmpty else {
                return ("There are no windows open for me to remember.", false)
            }
            let layout = WindowLayout(name: name.trimmingCharacters(in: .whitespaces),
                                      placements: placements)
            LayoutStore.store(layout)
            return ("Saved \(layout.summary)", true)
        case .applyLayout(let name):
            guard let layout = LayoutStore.named(name) else {
                return ("I don't have a layout called \(name).", false)
            }
            return (WindowArranger.apply(layout.placements), true)
        case .listLayouts:
            return (LayoutStore.listing(), true)

        case .watchApp(let app, let reason):
            let message = shared.watches.watch(app: app, reason: reason, now: CACurrentMediaTime())
            // A refusal reads as a miss so the brain can try something else,
            // rather than reporting a promise that was never made.
            return (message, message.hasPrefix("Watching"))
        case .listWatches:
            return (shared.watches.listing(), true)
        case .stopWatching(let name):
            return (shared.watches.stop(matching: name), true)

        case .listClips:
            return (shared.clipboard.listing(), true)
        case .recallClip(let query):
            return shared.clipboard.recall(query)

        case .readFile(let path):
            return FileReader.toolResult(path: path)

        case .mcpCall:
            // Unreachable through the loop, which awaits the async twin below.
            // A synchronous caller handed an MCP action would otherwise block
            // the main actor on another process, so this refuses instead.
            return ("That tool has to run without blocking; nothing ran.", false)

        // MARK: putting things back, standing asks, learned routines

        case .undoArrangement:
            return (WindowArranger.undo(), true)

        case .schedule(let raw):
            let message = shared.schedules.add(raw)
            return (message, message.hasPrefix("Set:"))
        case .listSchedules:
            return (shared.schedules.listing(), true)
        case .unschedule(let raw):
            return (shared.schedules.remove(matching: raw), true)

        case .startRecordingTrick:
            shared.recording = []
            return (TrickPolicy.recordingStarted(), true)
        case .saveTrick(let name):
            guard let steps = shared.recording else {
                return ("I am not recording anything right now. Ask me to start recording first.", false)
            }
            shared.recording = nil
            let trick = Trick(name: name.trimmingCharacters(in: .whitespaces), steps: steps)
            guard !trick.steps.isEmpty else {
                return (TrickPolicy.recordingSaved(trick), false)
            }
            TrickStore.store(trick)
            return (TrickPolicy.recordingSaved(trick), true)
        case .runTrick(let name):
            guard let trick = TrickStore.named(name) else {
                return ("I don't know a trick called \(name).", false)
            }
            return runTrick(trick)
        case .listTricks:
            return (TrickPolicy.listing(TrickStore.load()), true)
        case .forgetTrick(let name):
            return TrickStore.remove(name)
                ? ("Forgot \(name).", true)
                : ("I don't know a trick called \(name).", false)
        case .volume(let op):
            switch op {
            case .up: runAppleScript("set volume output volume (min(100, (output volume of (get volume settings)) + 10))")
            case .down: runAppleScript("set volume output volume (max(0, (output volume of (get volume settings)) - 10))")
            case .mute: runAppleScript("set volume output muted true")
            case .unmute: runAppleScript("set volume output muted false")
            }
            return ("Volume \(op.rawValue)", true)
        case .media(let op):
            let key: Int32 = op == .playpause ? 16 : (op == .next ? 17 : 18) // NX_KEYTYPE_*
            postMediaKey(key)
            return (op == .playpause ? "Play/pause" : (op == .next ? "Next track" : "Previous track"), true)
        case .search(let q):
            let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
            if let url = URL(string: "https://www.google.com/search?q=\(encoded)") {
                NSWorkspace.shared.open(url)
            }
            return ("Searching for \(q)…", true)
        case .openURL(let url):
            NSWorkspace.shared.open(url)
            return ("Opening \(url.host ?? url.absoluteString)…", true)
        case .typeText(let text):
            guard AXPermission.trusted else {
                return ("I need Accessibility to type. System Settings, Privacy and Security, Accessibility, enable WindowPet.", true)
            }
            typeString(text)
            return ("Typed it.", true)
        case .copyText(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return ("Copied to the clipboard.", true)
        case .pressKeys(let combo):
            guard AXPermission.trusted else {
                return ("I need Accessibility to press keys. System Settings, Privacy and Security, Accessibility, enable WindowPet.", true)
            }
            return pressKeyCombo(combo) ? ("Pressed \(combo).", true)
                                        : ("I don't know the key \(combo).", false)
        case .screenshot:
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: ".")
            let path = ("~/Desktop/Rusty Screenshot \(stamp).png" as NSString).expandingTildeInPath
            run("/usr/sbin/screencapture", ["-x", path])
            return ("Screenshot saved to the Desktop.", true)
        case .runAppleScript(let script):
            var errorInfo: NSDictionary?
            let result = NSAppleScript(source: script)?.executeAndReturnError(&errorInfo)
            if let errorInfo, let message = errorInfo[NSAppleScript.errorMessage] as? String {
                return ("That didn't work: \(message)", true)
            }
            if let text = result?.stringValue, !text.isEmpty {
                return (String(text.prefix(300)), true)
            }
            return ("Done.", true)
        case .runAdminShell(let command):
            return runAsAdministrator(command)
        case .runShortcut(let name):
            run("/usr/bin/shortcuts", ["run", name])
            return ("Running shortcut \(name)…", true)
        }
    }

    static func runningApp(named name: String) -> NSRunningApplication? {
        let target = name.lowercased()
        return NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular
                && ($0.localizedName?.lowercased() == target
                    || $0.localizedName?.lowercased().hasPrefix(target) == true)
        }
    }

    /// `open -a` resolves app names the same way Launch Services does; a
    /// nonexistent name fails fast (non-zero exit) without side effects, so
    /// waiting on it doubles as the existence check.
    private static func openAppChecked(_ name: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", name]
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch { return false }
    }

    private static func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
    }

    private static func runAppleScript(_ source: String) {
        NSAppleScript(source: source)?.executeAndReturnError(nil)
    }

    /// Media keys are systemDefined HID events.
    private static func postMediaKey(_ key: Int32) {
        func post(_ down: Bool) {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = Int((key << 16) | ((down ? 0xA : 0xB) << 8))
            if let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                           modifierFlags: flags, timestamp: 0,
                                           windowNumber: 0, context: nil, subtype: 8,
                                           data1: data1, data2: -1) {
                ev.cgEvent?.post(tap: .cghidEventTap)
            }
        }
        post(true)
        post(false)
    }

    /// Move/resize the frontmost app's focused window via AX (guarded,
    /// timed out — same hardening rules as Tier 2). AX positions use CG
    /// top-left coordinates.
    private static func moveFrontWindow(_ move: AssistantAction.WindowMove) -> String {
        guard AXPermission.trusted else {
            return "I need Accessibility to move windows. System Settings, Privacy and Security, Accessibility, enable WindowPet."
        }
        guard let front = NSWorkspace.shared.frontmostApplication else { return "No app is in front." }
        let appEl = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 0.15)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let winRefUnwrapped = winRef, CFGetTypeID(winRefUnwrapped) == AXUIElementGetTypeID() else {
            return "\(front.localizedName ?? "That app") isn't showing me a window I can move."
        }
        let win = winRefUnwrapped as! AXUIElement

        // Read the current frame first: it decides both which display to snap
        // within and where the glide starts from.
        var startPos = CGPoint.zero
        var startSize = CGSize(width: 800, height: 600)
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        var knowsFrame = false
        if AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
           let pv = posRef, CFGetTypeID(pv) == AXValueGetTypeID() {
            AXValueGetValue(pv as! AXValue, .cgPoint, &startPos)
            knowsFrame = true
        }
        if AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef) == .success,
           let sv = sizeRef, CFGetTypeID(sv) == AXValueGetTypeID() {
            AXValueGetValue(sv as! AXValue, .cgSize, &startSize)
        }

        // Snap inside the display the window is already on. Using the main
        // display here would teleport a window across a two-display setup.
        let v = knowsFrame
            ? Screens.visibleFrame(forAXPosition: startPos, size: startSize)
            : Screens.visibleFrame()
        let ak: CGRect
        switch move {
        case .left: ak = CGRect(x: v.minX, y: v.minY, width: v.width / 2, height: v.height)
        case .right: ak = CGRect(x: v.midX, y: v.minY, width: v.width / 2, height: v.height)
        case .maximize: ak = v
        case .center: ak = CGRect(x: v.midX - v.width * 0.35, y: v.midY - v.height * 0.4,
                                  width: v.width * 0.7, height: v.height * 0.8)
        }
        let targetPos = CGPoint(x: ak.minX, y: Screens.primaryHeight - ak.maxY) // AppKit → AX top-left
        let targetSize = CGSize(width: ak.width, height: ak.height)
        // Without a readable frame there is nothing to glide from, so start
        // at the destination and let the move land in one step.
        if !knowsFrame {
            startPos = targetPos
            startSize = targetSize
        }

        func setFrame(_ p: CGPoint, _ sz: CGSize) -> Bool {
            var pos = p
            var size = sz
            var ok = true
            if let posVal = AXValueCreate(.cgPoint, &pos) {
                ok = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, posVal) == .success && ok
            }
            if let sizeVal = AXValueCreate(.cgSize, &size) {
                ok = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sizeVal) == .success && ok
            }
            return ok
        }

        // Eased 8-step slide, ~130ms; final step is exact.
        var landed = false
        for i in 1...8 {
            let t = CGFloat(i) / 8
            let e = 1 - pow(1 - t, 3)
            let p = CGPoint(x: startPos.x + (targetPos.x - startPos.x) * e,
                            y: startPos.y + (targetPos.y - startPos.y) * e)
            let sz = CGSize(width: startSize.width + (targetSize.width - startSize.width) * e,
                            height: startSize.height + (targetSize.height - startSize.height) * e)
            landed = setFrame(p, sz)
            if i < 8 { usleep(16000) }
        }
        guard landed else {
            return "\(front.localizedName ?? "That app") wouldn't let me move its window."
        }
        switch move {
        case .left: return "Slid the window left."
        case .right: return "Slid the window right."
        case .maximize: return "Maximized the window."
        case .center: return "Centered the window."
        }
    }

    /// Runs a shell command as root through the Apple-sanctioned path:
    /// `do shell script … with administrator privileges` triggers the macOS
    /// authentication dialog, so the user types their admin password every
    /// single time. There is no stored credential and no standing helper the
    /// agent could spend without that prompt; combined with the panel's
    /// confirmation, a privileged command needs two human checkpoints.
    private static func runAsAdministrator(_ command: String) -> (result: String, ok: Bool) {
        // Escape for embedding inside an AppleScript string literal.
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        var errorInfo: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = errorInfo[NSAppleScript.errorNumber] as? Int
            if code == -128 {  // user cancelled the password dialog
                return ("Cancelled, nothing ran.", true)
            }
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "unknown error"
            return ("That didn't work: \(message)", true)
        }
        if let text = result?.stringValue, !text.isEmpty {
            return (String(text.prefix(300)), true)
        }
        return ("Done, ran as administrator.", true)
    }

    /// Presses a shortcut like "cmd+shift+4" or "cmd+t" in the focused app.
    /// Key names come from the shared Core table, so this and the
    /// configurable summon shortcut can never disagree about a key code.
    private static func pressKeyCombo(_ combo: String) -> Bool {
        var flags: CGEventFlags = []
        var key: CGKeyCode?
        for part in combo.lowercased().split(whereSeparator: { "+ ".contains($0) }) {
            switch part {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "opt", "option", "alt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default: key = KeyCodes.byName[String(part)].map { CGKeyCode($0) }
            }
        }
        guard let key else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else {
            return false
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        usleep(8000)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Types a string into the focused app as HID keyboard events (needs
    /// the same Accessibility trust as window moves).
    private static func typeString(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for chunk in text.map({ String($0) }) {
            let utf16 = Array(chunk.utf16)
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                up.post(tap: .cghidEventTap)
            }
            usleep(4000)
        }
    }
}
