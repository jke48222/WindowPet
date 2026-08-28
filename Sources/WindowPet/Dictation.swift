import AppKit
import WindowPetCore

/// Speech straight into the app in front, with no model in the loop.
///
/// This is the cheapest useful thing Rusty does. The recognizer is already
/// on-device, `type_text` already exists, and holding one key joins them: the
/// words go from your mouth to the focused text field without a request, a
/// token, or a round trip. Nothing is sent anywhere and nothing is spent.
@MainActor
final class Dictation {

    /// Shows what is being heard while the key is held.
    var onStatus: ((String) -> Void)?
    /// Reports a problem in words, since there is no panel conversation here.
    var onProblem: ((String) -> Void)?

    private let voice: VoiceInput
    private var active = false
    /// True once something has been typed in this hold, so a second breath
    /// joins the sentence instead of starting a new one.
    private var continuing = false
    private var lastTyped = ""
    private var targetApp: String?

    init(voice: VoiceInput) {
        self.voice = voice
    }

    var isActive: Bool { active }

    func begin() {
        guard !active else { return }
        // Dictating into Rusty's own panel would be a loop with no purpose,
        // and the panel already has push to talk.
        targetApp = NSWorkspace.shared.frontmostApplication?.localizedName
        active = true
        continuing = false
        lastTyped = ""
        onStatus?(DictationPolicy.statusLine(app: targetApp))
        voice.beginDictation(
            partial: { [weak self] text in
                guard let self, self.active else { return }
                self.onStatus?(text.isEmpty
                    ? DictationPolicy.statusLine(app: self.targetApp)
                    : text)
            },
            final: { [weak self] text in
                self?.type(text)
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

    private func type(_ raw: String) {
        let text = DictationPolicy.text(from: raw, continuing: continuing)
        guard !text.isEmpty else { return }
        // Nothing is typed twice: the recognizer can deliver the same final
        // result more than once as an utterance settles.
        guard text != lastTyped else { return }
        lastTyped = text
        continuing = true
        _ = AssistantExecutor.execute(.typeText(text))
    }
}
