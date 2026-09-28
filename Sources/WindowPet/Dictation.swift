import AppKit
import WindowPetCore

/// Speech straight into the app in front, with no model in the loop.
///
/// This is the cheapest useful thing Rusty does. The recognizer runs on the
/// Mac (dictation refuses to start where it cannot), and holding one key joins
/// it to the keyboard: the words go from your mouth to the focused text field
/// without a request, a token, or a round trip. Nothing is sent anywhere and
/// nothing is spent.
///
/// The words only ever go to the app that was in front when the key went
/// down. They land a second or two after the key is released, and people
/// switch apps in that time, so every character is checked against that app
/// before it is posted. If it is no longer in front, the rest goes to the
/// clipboard instead of into whatever the user is looking at now.
@MainActor
final class Dictation {

    /// Shows what is being heard while the key is held.
    var onStatus: ((String) -> Void)?
    /// Reports a problem in words, since there is no panel conversation here.
    var onProblem: ((String) -> Void)?

    private let voice: VoiceInput
    private var active = false
    /// The hold in progress, or the last one while its words are still on
    /// their way.
    private var hold: Hold?
    /// Dictated text is typed one job at a time, in order, so two quick holds
    /// can never interleave their characters.
    private var typingTail: Task<Void, Never>?

    /// One press of the key: where its words go and what has happened to them.
    /// Each recognizer callback captures its own hold, so a late result from
    /// one press can never be typed into the app of the next.
    private final class Hold {
        let pid: pid_t?
        let appName: String?
        /// True once something has been typed in this hold, so a second
        /// breath joins the sentence instead of starting a new one.
        var continuing = false
        var lastTyped = ""
        /// Text that went to the clipboard because the app changed. Once a
        /// hold has diverted, the rest of it follows, so the clipboard holds
        /// the whole remainder rather than only the last fragment.
        var diverted = ""
        /// Whether anything reached the app before it diverted.
        var typedAny = false

        init(pid: pid_t?, appName: String?) {
            self.pid = pid
            self.appName = appName
        }
    }

    init(voice: VoiceInput) {
        self.voice = voice
    }

    var isActive: Bool { active }

    func begin() {
        guard !active else { return }
        let front = NSWorkspace.shared.frontmostApplication
        let hold = Hold(pid: front?.processIdentifier, appName: front?.localizedName)
        self.hold = hold
        active = true
        onStatus?(DictationPolicy.statusLine(app: hold.appName))
        voice.beginDictation(
            partial: { [weak self, weak hold] text in
                guard let self, let hold, self.active, self.hold === hold else { return }
                self.onStatus?(text.isEmpty
                    ? DictationPolicy.statusLine(app: hold.appName)
                    : text)
            },
            final: { [weak self] text in
                self?.type(text, into: hold)
            },
            problem: { [weak self] message in
                guard let self else { return }
                self.active = false
                // A refusal is an end too, and the panel's voice handlers have
                // to come back either way.
                self.voice.endDictation()
                self.onProblem?(message)
            })
    }

    func end() {
        guard active else { return }
        active = false
        voice.endDictation()
    }

    private static let accessibilityNote = "I need Accessibility to type. System Settings, Privacy and Security, Accessibility, enable WindowPet. I copied what you said to the clipboard."

    private func type(_ raw: String, into hold: Hold) {
        let text = DictationPolicy.text(from: raw, continuing: hold.continuing)
        guard !text.isEmpty else { return }
        // Nothing is typed twice: the recognizer can deliver the same final
        // result more than once as an utterance settles.
        guard text != hold.lastTyped else { return }
        hold.lastTyped = text
        hold.continuing = true

        guard AXPermission.trusted else {
            divert(text, from: hold, note: Self.accessibilityNote)
            return
        }
        let previous = typingTail
        typingTail = Task { @MainActor [weak self] in
            await previous?.value
            var rest = text
            if hold.diverted.isEmpty {
                AssistantExecutor.beforeSyntheticKeys?()
                // A beat for the window server to settle key focus before the
                // first key, as the executor's keyboard queue does.
                try? await Task.sleep(for: .milliseconds(80))
                rest = await Self.typeWhileInFront(text, target: hold.pid)
                if rest.count < text.count { hold.typedAny = true }
            }
            guard !rest.isEmpty else { return }
            let note = hold.typedAny
                ? "You switched apps partway, so I copied the rest to the clipboard instead."
                : "You switched apps, so I copied it to the clipboard instead."
            self?.divert(rest, from: hold, note: note)
        }
    }

    /// Puts what could not be typed on the clipboard, and says so once per hold.
    private func divert(_ text: String, from hold: Hold, note: String) {
        let first = hold.diverted.isEmpty
        hold.diverted += text
        let copied = hold.diverted.trimmingCharacters(in: .whitespaces)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copied, forType: .string)
        if first { onProblem?(note) }
    }

    /// Types `text` as HID keyboard events, one character at a time, checking
    /// before each one that the target app is still in front. Returns what was
    /// not typed (empty when all of it was).
    private static func typeWhileInFront(_ text: String, target: pid_t?) async -> String {
        let source = CGEventSource(stateID: .combinedSessionState)
        var index = text.startIndex
        while index < text.endIndex {
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard DictationPolicy.mayType(targetPID: target, frontPID: front,
                          suspended: ScreenLock.shared.isSuspended) else {
                return String(text[index...])
            }
            let utf16 = Array(String(text[index]).utf16)
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0,
                                          keyDown: keyDown) else { continue }
                event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                // Marked like every key Rusty posts, so his own shortcut
                // monitors ignore it.
                event.setIntegerValueField(.eventSourceUserData,
                                           value: AssistantExecutor.syntheticEventMarker)
                event.post(tap: .cghidEventTap)
            }
            index = text.index(after: index)
            try? await Task.sleep(for: .milliseconds(4))
        }
        return ""
    }
}
