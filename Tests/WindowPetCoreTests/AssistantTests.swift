import XCTest
@testable import WindowPetCore

final class AssistantTests: XCTestCase {

    func testAppVerbs() {
        XCTAssertEqual(AssistantParser.parse("open Safari"), .openApp("Safari"))
        XCTAssertEqual(AssistantParser.parse("launch Xcode"), .openApp("Xcode"))
        XCTAssertEqual(AssistantParser.parse("switch to Terminal"), .switchApp("Terminal"))
        XCTAssertEqual(AssistantParser.parse("focus Music"), .switchApp("Music"))
        XCTAssertEqual(AssistantParser.parse("hide Finder"), .hideApp("Finder"))
        XCTAssertEqual(AssistantParser.parse("quit Slack"), .quitApp("Slack"))
    }

    func testQuitIsGated() {
        XCTAssertTrue(AssistantParser.parse("quit Slack")!.needsConfirmation)
        XCTAssertFalse(AssistantParser.parse("open Slack")!.needsConfirmation)
    }

    func testWindowVolumeMedia() {
        XCTAssertEqual(AssistantParser.parse("move window left"), .windowMove(.left))
        XCTAssertEqual(AssistantParser.parse("Maximize"), .windowMove(.maximize))
        XCTAssertEqual(AssistantParser.parse("volume up"), .volume(.up))
        XCTAssertEqual(AssistantParser.parse("mute"), .volume(.mute))
        XCTAssertEqual(AssistantParser.parse("play"), .media(.playpause))
        XCTAssertEqual(AssistantParser.parse("next track"), .media(.next))
    }

    func testSearchAndShortcutCarryArguments() {
        XCTAssertEqual(AssistantParser.parse("search brindle mastiff mix"),
                       .search("brindle mastiff mix"))
        XCTAssertEqual(AssistantParser.parse("run shortcut Morning Routine"),
                       .runShortcut("Morning Routine"))
    }

    func testRoutingMapsVerbs() {
        XCTAssertEqual(AssistantRouting.action(verb: "open", argument: "Safari"), .openApp("Safari"))
        XCTAssertEqual(AssistantRouting.action(verb: "SWITCH", argument: " Xcode "), .switchApp("Xcode"))
        XCTAssertEqual(AssistantRouting.action(verb: "window_left", argument: ""), .windowMove(.left))
        XCTAssertEqual(AssistantRouting.action(verb: "quit", argument: "Slack"), .quitApp("Slack"))
        XCTAssertTrue(AssistantRouting.action(verb: "quit", argument: "Slack")!.needsConfirmation)
        XCTAssertEqual(AssistantRouting.action(verb: "search", argument: "tin robots"), .search("tin robots"))
    }

    func testRoutingRejectsUnknownAndEmpty() {
        XCTAssertNil(AssistantRouting.action(verb: "none", argument: ""))
        XCTAssertNil(AssistantRouting.action(verb: "self_destruct", argument: "now"))
        XCTAssertNil(AssistantRouting.action(verb: "open", argument: ""))
    }

    func testReplySanitizer() {
        XCTAssertEqual(AssistantRouting.sanitizeReply("  Beep!\nAt your service.  "),
                       "Beep! At your service.")
        XCTAssertEqual(AssistantRouting.sanitizeReply(String(repeating: "a", count: 200)).count, 90)
    }

    func testPushToTalkThreshold() {
        XCTAssertFalse(PushToTalk.isHold(downDuration: 0.15)) // tap → bar
        XCTAssertTrue(PushToTalk.isHold(downDuration: 0.5))   // hold → listen
    }

    func testElevenLabsRequestConstruction() {
        let r = ElevenLabs.speechRequest(text: " Beep boop! ", apiKey: "k123", voiceID: "voiceX")!
        XCTAssertTrue(r.url.absoluteString.hasPrefix("https://api.elevenlabs.io/v1/text-to-speech/voiceX"))
        XCTAssertEqual(r.headers["xi-api-key"], "k123")
        XCTAssertEqual(r.headers["Accept"], "audio/mpeg")
        let json = try! JSONSerialization.jsonObject(with: r.body) as! [String: Any]
        XCTAssertEqual(json["text"] as? String, "Beep boop!")
        XCTAssertEqual(json["model_id"] as? String, ElevenLabs.defaultModelID)
        XCTAssertNil(ElevenLabs.speechRequest(text: "  ", apiKey: "k"))
        XCTAssertNil(ElevenLabs.speechRequest(text: "hi", apiKey: ""))
    }

    func testEdgeTTSArguments() {
        let args = EdgeTTS.arguments(text: " Beep\nboop! ", voice: "en-US-AnaNeural",
                                     outputPath: "/tmp/x.mp3")!
        XCTAssertEqual(args, ["-m", "edge_tts", "--voice", "en-US-AnaNeural",
                              "--text", "Beep boop!", "--write-media", "/tmp/x.mp3"])
        XCTAssertNil(EdgeTTS.arguments(text: "  ", voice: "v", outputPath: "/tmp/x"))
        XCTAssertLessThanOrEqual(EdgeTTS.sanitize(String(repeating: "b", count: 500)).count, 280)
    }

    func testWakeWordMatching() {
        XCTAssertTrue(WakeWord.matches("Hey, Rusty!"))
        XCTAssertTrue(WakeWord.matches("hey rusty can you open safari"))
        XCTAssertTrue(WakeWord.matches("um hey Rusty"))
        XCTAssertFalse(WakeWord.matches("this hinge is rusty"))
        XCTAssertFalse(WakeWord.matches("hey russell"))
    }

    func testWakeWordCommandExtraction() {
        XCTAssertEqual(WakeWord.extractCommand("Hey Rusty, mute the sound."), "mute the sound")
        XCTAssertEqual(WakeWord.extractCommand("Hey, Rusty!"), "")
        XCTAssertNil(WakeWord.extractCommand("just some words"))
    }

    func testCaseAndGarbage() {
        XCTAssertEqual(AssistantParser.parse("OPEN safari"), .openApp("safari"))
        XCTAssertNil(AssistantParser.parse(""))
        XCTAssertNil(AssistantParser.parse("do something impossible"))
        XCTAssertNil(AssistantParser.parse("open"))
    }
}
