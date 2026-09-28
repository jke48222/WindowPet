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
    /// The awaiting twin of `executeChecked`, and the one every interactive
    /// caller (the agent loop, the panel, the brain) uses. The verbs that wait
    /// on something outside the app run here without blocking the main
    /// actor: an MCP tool call, AppleScript and administrator commands (which
    /// can sit on a password dialog or a hung app for minutes), `open -a`,
    /// the window glide, synthetic typing and key presses, and tricks made of
    /// those. Everything else falls straight through to the synchronous path,
    /// so the gate, the recorder and the reporting are identical either way.
    ///
    /// Named differently rather than overloaded on purpose: an async overload
    /// with the same name is picked silently inside any async function, which
    /// is exactly the kind of thing nobody notices going wrong.
    static func executeAwaiting(_ action: AssistantAction) async -> (result: String, ok: Bool) {
        let outcome: (result: String, ok: Bool)
        switch action {
        case .mcpCall(let server, let tool, let arguments, _):
            let decoded = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8)))
                as? [String: Any] ?? [:]
            return await shared.mcp.callTool(server: server, tool: tool, arguments: decoded)
        case .typeText(let text):
            guard AXPermission.trusted else { return typingRefusal }
            guard await runKeyboardJob({ live in await typeStringAsync(text, live: live) }) else {
                return stoppedOutcome
            }
            outcome = ("Typed it.", true)
        case .pressKeys(let combo):
            guard AXPermission.trusted else { return keysRefusal }
            guard let parsed = parseKeyCombo(combo) else { return ("I don't know the key \(combo).", false) }
            guard await runKeyboardJob({ live in await postKeyComboAsync(parsed, live: live) }) else {
                return stoppedOutcome
            }
            outcome = ("Pressed \(combo).", true)
        case .readFile(let path):
            // PDF extraction can take most of a second; it runs off the main
            // actor so the pet keeps moving.
            return await FileReader.toolResultAsync(path: path)
        case .runAppleScript(let script):
            outcome = Self.appleScriptOutcome(await runOSAScript(script), admin: false)
        case .runAdminShell(let command):
            outcome = Self.appleScriptOutcome(await runOSAScript(adminScript(for: command)), admin: true)
        case .openApp(let name):
            outcome = await openAppAsync(name)
                ? ("Opening \(name)…", true) : ("I couldn't find an app called \(name).", false)
        case .switchApp(let name):
            if let app = runningApp(named: name) {
                app.activate()
                outcome = ("Switched to \(app.localizedName ?? name)", true)
            } else {
                outcome = await openAppAsync(name)
                    ? ("Opening \(name)…", true) : ("I couldn't find an app called \(name).", false)
            }
        case .windowMove(let move):
            outcome = await moveFrontWindowAsync(move)
        case .runTrick(let name):
            guard let trick = TrickStore.named(name) else {
                return ("I don't know a trick called \(name).", false)
            }
            return await runTrickAsync(trick)
        default:
            return executeChecked(action)
        }
        if outcome.ok, shared.recording != nil, let (verb, argument) = recordable(action) {
            noteForRecording(verb, argument)
        }
        return outcome
    }

    /// `runTrick`, with each step awaited so a trick that types or runs a
    /// script does not freeze the pet while it plays.
    private static func runTrickAsync(_ trick: Trick) async -> (result: String, ok: Bool) {
        var done: [String] = []
        for step in trick.steps {
            // Stop, closing the panel, or the Mac locking cancels the run
            // that is playing the trick; nothing after that point runs.
            if Task.isCancelled {
                let ran = done.isEmpty ? "" : " after \(done.count) of its steps"
                return ("Stopped \(trick.name)\(ran).", false)
            }
            guard let action = AssistantRouting.action(verb: step.verb, argument: step.argument) else {
                return ("\(trick.name) has a step I no longer understand (\(step.description)), so I stopped there.", false)
            }
            if action.needsConfirmation {
                let ran = done.isEmpty ? "" : " I did \(done.count) of them first."
                return ("\(trick.name) reaches a step that needs your say-so (\(action.confirmationSummary ?? step.description)), so I stopped.\(ran) Ask me for that step directly and I will run it.", false)
            }
            let (result, ok) = await executeAwaiting(action)
            guard ok else {
                return ("\(trick.name) stopped at \(step.description): \(result)", false)
            }
            done.append(step.description)
        }
        return ("Did \(trick.name): " + done.joined(separator: ", "), true)
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
            switch windowMovePlan(move) {
            case .failure(let refusal): return (refusal.message, false)
            case .success(let plan): return plan.glideBlocking()
            }

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
            guard AXPermission.trusted else { return typingRefusal }
            // Queued, not typed inline: focus has to leave Rusty's panel
            // before the first key, and typing must not block the main actor.
            enqueueKeyboard { live in await typeStringAsync(text, live: live) }
            return ("Typed it.", true)
        case .copyText(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return ("Copied to the clipboard.", true)
        case .pressKeys(let combo):
            guard AXPermission.trusted else { return keysRefusal }
            guard let parsed = parseKeyCombo(combo) else { return ("I don't know the key \(combo).", false) }
            enqueueKeyboard { live in await postKeyComboAsync(parsed, live: live) }
            return ("Pressed \(combo).", true)
        case .screenshot:
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: ".")
            let path = ("~/Desktop/Rusty Screenshot \(stamp).png" as NSString).expandingTildeInPath
            run("/usr/sbin/screencapture", ["-x", path])
            return ("Screenshot saved to the Desktop.", true)
        case .runAppleScript(let script):
            var errorInfo: NSDictionary?
            let result = NSAppleScript(source: script)?.executeAndReturnError(&errorInfo)
            if let errorInfo {
                let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "unknown error"
                return ("That didn't work: \(message)", false)
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
    /// waiting on it doubles as the existence check. The blocking form is
    /// kept for synchronous callers (tricks from the rig); interactive paths
    /// use `openAppAsync`.
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

    private static func openAppAsync(_ name: String) async -> Bool {
        await runProcess("/usr/bin/open", ["-a", name]).status == 0
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

    // MARK: - Work off the main actor

    struct ProcessOutcome: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Runs a program to completion on a background queue and hands back its
    /// exit status and output. Both pipes are drained concurrently, so a
    /// chatty child can never fill one and deadlock.
    nonisolated static func runProcess(_ path: String, _ args: [String]) async -> ProcessOutcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = args
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: ProcessOutcome(
                        status: -1, stdout: "", stderr: error.localizedDescription))
                    return
                }
                final class Box: @unchecked Sendable { var data = Data() }
                let errBox = Box()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    errBox.data = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                continuation.resume(returning: ProcessOutcome(
                    status: process.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errBox.data, as: UTF8.self)))
            }
        }
    }

    /// AppleScript through `osascript`, off the main actor. NSAppleScript is
    /// main-thread only, and a script talking to a hung app (two-minute
    /// AppleEvent timeout) or an administrator password dialog would freeze
    /// the pet and the panel for as long as it waits.
    private static func runOSAScript(_ source: String) async -> ProcessOutcome {
        await runProcess("/usr/bin/osascript", ["-e", source])
    }

    /// `do shell script … with administrator privileges` triggers the macOS
    /// authentication dialog, so the user types their admin password every
    /// single time. There is no stored credential and no standing helper the
    /// agent could spend without that prompt; combined with the panel's
    /// confirmation, a privileged command needs two human checkpoints.
    private static func adminScript(for command: String) -> String {
        // Escape for embedding inside an AppleScript string literal.
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    /// The blocking form, for synchronous callers only. Interactive paths go
    /// through `executeAwaiting`, which runs the same script off the main
    /// actor.
    private static func runAsAdministrator(_ command: String) -> (result: String, ok: Bool) {
        var errorInfo: NSDictionary?
        let result = NSAppleScript(source: adminScript(for: command))?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            if errorInfo[NSAppleScript.errorNumber] as? Int == -128 {
                return ("Cancelled, nothing ran.", false)
            }
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "unknown error"
            return ("That didn't work: \(message)", false)
        }
        if let text = result?.stringValue, !text.isEmpty {
            return (String(text.prefix(300)), true)
        }
        return ("Done, ran as administrator.", true)
    }

    /// Turns an osascript run into the panel's line. A failure reports ok:
    /// false, so the model gets is_error and a recording skips the step.
    private static func appleScriptOutcome(_ run: ProcessOutcome,
                                           admin: Bool) -> (result: String, ok: Bool) {
        guard run.status == 0 else {
            if run.stderr.contains("(-128)") {  // the user cancelled the password dialog
                return ("Cancelled, nothing ran.", false)
            }
            return ("That didn't work: \(osascriptMessage(run.stderr))", false)
        }
        let text = run.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return (String(text.prefix(300)), true) }
        return (admin ? "Done, ran as administrator." : "Done.", true)
    }

    /// "0:12: execution error: Finder got an error: … (-1728)" to the part a
    /// person can read.
    static func osascriptMessage(_ stderr: String) -> String {
        var message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = message.range(of: "execution error: ") {
            message = String(message[range.upperBound...])
        }
        if let open = message.range(of: " (-", options: .backwards), message.hasSuffix(")") {
            message = String(message[..<open.lowerBound])
        }
        return message.isEmpty ? "unknown error" : String(message.prefix(300))
    }

    // MARK: - Synthetic keyboard input

    /// Stamped into `eventSourceUserData` on every keyboard and media event
    /// Rusty posts. The panel drops any key event carrying it, so a key Rusty
    /// typed can never land in his own input field, let alone answer a safety
    /// check there.
    static let syntheticEventMarker: Int64 = 0x5253_5459  // "RSTY"

    static func isSynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == syntheticEventMarker
    }

    /// Called before the first synthetic key of every typing or key-press
    /// job, so focus leaves Rusty's panel and the keys reach the app in
    /// front. Set by the command bar.
    static var beforeSyntheticKeys: (() -> Void)?

    private static let typingRefusal = ("I need Accessibility to type. System Settings, Privacy and Security, Accessibility, enable WindowPet.", false)
    private static let keysRefusal = ("I need Accessibility to press keys. System Settings, Privacy and Security, Accessibility, enable WindowPet.", false)

    /// Keyboard jobs run one at a time, in order, so two requests can never
    /// interleave their keystrokes.
    private static var keyboardTail: Task<Void, Never>?
    /// Bumped by `cancelKeyboard()`. A job checks it before and between
    /// keystrokes, so every job queued before a cancel stops, not only the
    /// newest one.
    private static var keyboardEpoch = 0
    private static var observingScreenLock = false

    private static let stoppedOutcome = ("Stopped before finishing.", false)

    /// Drops every queued and running keyboard job at its next keystroke.
    /// Called when the Mac locks or sleeps: nothing is typed into the lock
    /// screen, or into whatever is in front when it wakes.
    static func cancelKeyboard() {
        keyboardEpoch += 1
        keyboardTail?.cancel()
        keyboardTail = nil
    }

    /// Queues a keyboard job and waits for it. Cancelling the caller (Stop,
    /// closing the panel, a new request) cancels the job too, which an
    /// unstructured task would otherwise never hear about. Returns false
    /// when the job was stopped before it finished.
    private static func runKeyboardJob(_ work: @escaping KeyboardWork) async -> Bool {
        guard !Task.isCancelled else { return false }
        let (task, finished) = enqueueKeyboard(work)
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        return finished.value
    }

    /// A keyboard job. `live` turns false once the job has been cancelled;
    /// the job checks it before each keystroke.
    private typealias KeyboardWork = @MainActor (_ live: @escaping @MainActor () -> Bool) async -> Void

    /// Queues a job behind the ones already waiting, without waiting for it.
    @discardableResult
    private static func enqueueKeyboard(_ work: @escaping KeyboardWork)
        -> (task: Task<Void, Never>, finished: FinishedFlag) {
        if !observingScreenLock {
            observingScreenLock = true
            ScreenLock.shared.observe(suspend: { AssistantExecutor.cancelKeyboard() },
                                      resume: {})
        }
        let epoch = keyboardEpoch
        let previous = keyboardTail
        let finished = FinishedFlag()
        let task = Task { @MainActor in
            await previous?.value
            let live: @MainActor () -> Bool = { !Task.isCancelled && keyboardEpoch == epoch }
            guard live() else { return }
            beforeSyntheticKeys?()
            // One runloop turn and a beat for the window server to move key
            // focus back to the app in front before anything is posted.
            try? await Task.sleep(for: .milliseconds(80))
            guard live() else { return }
            await work(live)
            if live() { finished.value = true }
        }
        keyboardTail = task
        return (task, finished)
    }

    /// Set from the keyboard task, read after awaiting it; both on the main
    /// actor.
    @MainActor
    private final class FinishedFlag {
        var value = false
    }

    private static func post(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        event.post(tap: .cghidEventTap)
    }

    /// Media keys are systemDefined HID events.
    private static func postMediaKey(_ key: Int32) {
        func send(_ down: Bool) {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = Int((key << 16) | ((down ? 0xA : 0xB) << 8))
            if let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                           modifierFlags: flags, timestamp: 0,
                                           windowNumber: 0, context: nil, subtype: 8,
                                           data1: data1, data2: -1),
               let cg = ev.cgEvent {
                post(cg)
            }
        }
        send(true)
        send(false)
    }

    /// A parsed shortcut like "cmd+shift+4": modifier flags and one key.
    struct KeyCombo {
        let flags: CGEventFlags
        let key: CGKeyCode
    }

    /// Key names come from the shared Core table, so this and the
    /// configurable summon shortcut can never disagree about a key code.
    static func parseKeyCombo(_ combo: String) -> KeyCombo? {
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
        guard let key else { return nil }
        return KeyCombo(flags: flags, key: key)
    }

    /// Presses a shortcut in the focused app.
    private static func postKeyComboAsync(_ combo: KeyCombo, live: @MainActor () -> Bool) async {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: combo.key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: combo.key, keyDown: false) else {
            return
        }
        guard live() else { return }
        down.flags = combo.flags
        up.flags = combo.flags
        post(down)
        try? await Task.sleep(for: .milliseconds(8))
        // A key that went down always comes back up, cancelled or not, so
        // nothing is left held.
        post(up)
    }

    /// Types a string into the focused app as HID keyboard events (needs
    /// the same Accessibility trust as window moves). Paced with awaits
    /// rather than usleep, so a long string never stalls the main actor.
    private static func typeStringAsync(_ text: String, live: @MainActor () -> Bool) async {
        let source = CGEventSource(stateID: .combinedSessionState)
        for chunk in text.map({ String($0) }) {
            // Checked between characters: a stopped request stops typing
            // mid-string rather than finishing it into whatever is in front.
            guard live() else { return }
            let utf16 = Array(chunk.utf16)
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                post(down)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                post(up)
            }
            try? await Task.sleep(for: .milliseconds(4))
        }
    }

    // MARK: - Window moves

    struct Refusal: Error {
        let message: String
    }

    /// Everything needed to glide the front window: read once up front, then
    /// stepped either blocking (synchronous callers) or with awaits.
    struct WindowMovePlan {
        let window: AXUIElement
        let appName: String
        let move: AssistantAction.WindowMove
        let startPos: CGPoint
        let startSize: CGSize
        let targetPos: CGPoint
        let targetSize: CGSize

        static let steps = 8

        /// Eased step `i` of `steps`; the final step is exact.
        func apply(step i: Int) -> Bool {
            let t = CGFloat(i) / CGFloat(Self.steps)
            let e = 1 - pow(1 - t, 3)
            var pos = CGPoint(x: startPos.x + (targetPos.x - startPos.x) * e,
                              y: startPos.y + (targetPos.y - startPos.y) * e)
            var size = CGSize(width: startSize.width + (targetSize.width - startSize.width) * e,
                              height: startSize.height + (targetSize.height - startSize.height) * e)
            var ok = true
            if let posVal = AXValueCreate(.cgPoint, &pos) {
                ok = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posVal) == .success && ok
            }
            if let sizeVal = AXValueCreate(.cgSize, &size) {
                ok = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeVal) == .success && ok
            }
            return ok
        }

        func outcome(landed: Bool) -> (result: String, ok: Bool) {
            guard landed else { return ("\(appName) wouldn't let me move its window.", false) }
            switch move {
            case .left: return ("Slid the window left.", true)
            case .right: return ("Slid the window right.", true)
            case .maximize: return ("Maximized the window.", true)
            case .center: return ("Centered the window.", true)
            }
        }

        /// ~130 ms, blocking. Only for synchronous callers.
        func glideBlocking() -> (result: String, ok: Bool) {
            var landed = false
            for i in 1...Self.steps {
                landed = apply(step: i)
                if i < Self.steps { usleep(16000) }
            }
            return outcome(landed: landed)
        }
    }

    /// Move/resize the frontmost app's focused window via AX (guarded,
    /// timed out — same hardening rules as Tier 2). AX positions use CG
    /// top-left coordinates.
    private static func windowMovePlan(_ move: AssistantAction.WindowMove) -> Result<WindowMovePlan, Refusal> {
        guard AXPermission.trusted else {
            return .failure(Refusal(message: "I need Accessibility to move windows. System Settings, Privacy and Security, Accessibility, enable WindowPet."))
        }
        guard let front = NSWorkspace.shared.frontmostApplication else {
            return .failure(Refusal(message: "No app is in front."))
        }
        let name = front.localizedName ?? "That app"
        let appEl = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 0.15)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let winRefUnwrapped = winRef, CFGetTypeID(winRefUnwrapped) == AXUIElementGetTypeID() else {
            return .failure(Refusal(message: "\(name) isn't showing me a window I can move."))
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
        return .success(WindowMovePlan(window: win, appName: name, move: move,
                                       startPos: startPos, startSize: startSize,
                                       targetPos: targetPos, targetSize: targetSize))
    }

    /// The glide, paced with awaits so the pet keeps animating through it.
    private static func moveFrontWindowAsync(_ move: AssistantAction.WindowMove) async -> (result: String, ok: Bool) {
        switch windowMovePlan(move) {
        case .failure(let refusal):
            return (refusal.message, false)
        case .success(let plan):
            var landed = false
            for i in 1...WindowMovePlan.steps {
                landed = plan.apply(step: i)
                if i < WindowMovePlan.steps { try? await Task.sleep(for: .milliseconds(16)) }
            }
            return plan.outcome(landed: landed)
        }
    }
}
