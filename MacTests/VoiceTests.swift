// The voice mode's session and tools: what GPT-Live is started with, which calls a tool makes, and what it answers.
import XCTest
@testable import BriareusMacCore

final class VoiceTests: XCTestCase {
    private func j(_ s: String) -> JSON { JSON.parse(s)! }

    func testStartCarriesTheVoiceTheAudioAndEveryToolOnTheBackend() {
        let start = Voice.start(voice: "gleam", backend: "gpt-6-luna")
        XCTAssertEqual(start["type"], "session.start")
        let session = start["session"]
        XCTAssertEqual(session["model"], "gpt-live-1")
        XCTAssertEqual(session["audio"]["format"], ["type": "audio/pcm", "rate": 24000])
        XCTAssertEqual(session["audio"]["output"]["voice"], "gleam")
        XCTAssertEqual(session["delegation"]["type"], "responses")
        XCTAssertEqual(session["delegation"]["responses"]["model"], "gpt-6-luna")
        let names = session["delegation"]["responses"]["tools"].items.compactMap { $0["name"].string }
        XCTAssertEqual(names, VoiceTool.allCases.map(\.rawValue))
    }

    func testEveryToolThatChangesSomethingAsksForConfirmed() {
        for tool in VoiceTool.allCases {
            let required = tool.definition["parameters"]["required"].strings
            XCTAssertEqual(required.contains("confirmed"), tool.changes, tool.rawValue)
            XCTAssertNotNil(APIRoute.named(tool.operation), tool.rawValue)
        }
    }

    func testAChangeWaitsForAYesAndThenMakesItsCall() {
        let args: JSON = ["session_id": "s1", "text": " ship it ", "confirmed": false]
        XCTAssertEqual(VoiceTool.sendMessage.plan(args), .confirm("Send: ship it"))
        var yes = args
        yes["confirmed"] = true
        XCTAssertEqual(VoiceTool.sendMessage.plan(yes), .call(["sessionId": "s1", "text": "ship it"]))
        XCTAssertEqual(VoiceTool.stopConversation.plan(["session_id": "s1"]), .confirm("Stop the agent's running turn."))
        XCTAssertEqual(VoiceTool.startConversation.plan(["repo": "o/r", "prompt": "Fix the login", "branch": "dev", "confirmed": true]),
                       .call(["repo": "o/r", "prompt": "Fix the login", "branch": "dev"]))
    }

    func testMissingArgumentsAreRefusedWithoutACall() {
        XCTAssertEqual(VoiceTool.readConversation.plan([:]), .refuse("session_id is missing."))
        XCTAssertEqual(VoiceTool.sendMessage.plan(["session_id": "s1", "text": "  ", "confirmed": true]),
                       .refuse("session_id and text are needed."))
        XCTAssertEqual(VoiceTool.readConversation.plan(["session_id": "s1"]), .call(["sessionId": "s1", "since": 0]))
        XCTAssertEqual(VoiceTool.listConversations.plan(["repo": ""]), .call([:]))
    }

    func testConversationsSayTheirStatusAndDropClosedOnesWhenAskedForActive() {
        let answer = j(#"{"sessions":[{"id":"a","title":"Login","repo":"o/r","status":"running","prStatus":{"number":7}},{"id":"b","title":"Old","repo":"o/r","status":"closed"}]}"#)
        let all = VoiceTool.listConversations.summary(answer, args: [:])
        XCTAssertEqual(all["total"], 2)
        XCTAssertEqual(all["conversations"][0], ["session_id": "a", "title": "Login", "repo": "o/r", "status": "Working", "pull_request": 7])
        let active = VoiceTool.listConversations.summary(answer, args: ["active_only": true])
        XCTAssertEqual(active["conversations"].items.map { $0["session_id"] }, ["a"])
    }

    func testAConversationReadsItsLatestMessagesAndItsOpenQuestion() {
        let answer = j(#"""
        {"session":{"id":"a","title":"Login","repo":"o/r","status":"idle"},
         "events":[{"seq":1,"kind":"user","text":"Fix **login**"},{"seq":2,"kind":"tool","summary":"Edit"},
                   {"seq":3,"kind":"text","text":"Done. Use [the docs](http://x)?"},
                   {"seq":4,"kind":"ask","question":"Which branch?","options":[{"label":"main"},{"label":"dev"}]}]}
        """#)
        let out = VoiceTool.readConversation.summary(answer, args: [:])
        XCTAssertEqual(out["question"], "Which branch?")
        XCTAssertEqual(out["options"], ["main", "dev"])
        XCTAssertEqual(out["status"], "Asks you a question")
        XCTAssertEqual(out["latest"], [["from": "user", "text": "Fix login"], ["from": "agent", "text": "Done. Use the docs?"],
                                       ["from": "agent", "text": "Which branch?"]])
    }

    func testLatestCutsLongMessages() {
        let long = String(repeating: "a", count: 50)
        let events = [Event(j(#"{"seq":1,"kind":"text","text":"\#(long)"}"#))!]
        XCTAssertEqual(Voice.latest(events, length: 10)[0]["text"], .string(String(repeating: "a", count: 10) + "…"))
    }
}
