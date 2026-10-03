// The voice mode's session and tools: what GPT-Live is started with, which calls a tool makes on the project, and what it
// answers.
import XCTest
@testable import BriareusMacCore

final class VoiceTests: XCTestCase {
    private func j(_ s: String) -> JSON { JSON.parse(s)! }

    func testCreateCarriesTheOfferTheVoiceTheProjectAndEveryToolOnTheBackend() {
        let create = Voice.create(offer: "v=0", voice: "gleam", backend: "gpt-6-luna", project: "HQ (o/hq)")
        XCTAssertEqual(create["transport"], ["type": "webrtc", "sdp": "v=0"])
        let session = create["session"]
        XCTAssertEqual(session["model"], "gpt-live-1")
        // WebRTC negotiates the format; only the voice is chosen.
        XCTAssertEqual(session["audio"], ["output": ["voice": "gleam"]])
        XCTAssertEqual(session["delegation"]["type"], "responses")
        XCTAssertEqual(session["delegation"]["responses"]["model"], "gpt-6-luna")
        let names = session["delegation"]["responses"]["tools"].items.compactMap { $0["name"].string }
        XCTAssertEqual(names, VoiceTool.allCases.map(\.rawValue))
        XCTAssertTrue(session["instructions"].string!.contains("HQ (o/hq)"))
        XCTAssertTrue(session["delegation"]["responses"]["instructions"].string!.contains("HQ (o/hq)"))
    }

    func testNoToolNamesAProjectAndEveryCallIsOnTheConversationsOwn() {
        for tool in VoiceTool.allCases {
            XCTAssertTrue(tool.definition["parameters"]["properties"]["repo"].isNull, tool.rawValue)
        }
        // Whatever the backend sends, the repository is the project's.
        XCTAssertEqual(VoiceTool.listConversations.plan(["repo": "other/repo"], repo: "o/r"), .call(["repo": "o/r"]))
        XCTAssertEqual(VoiceTool.listPullRequests.plan([:], repo: "o/r"), .call(["repo": "o/r"]))
        XCTAssertEqual(VoiceTool.waitingFindings.plan([:], repo: "o/r"), .call(["repo": "o/r"]))
        XCTAssertEqual(VoiceTool.startConversation.plan(["repo": "other/repo", "prompt": "Go", "confirmed": true], repo: "o/r"),
                       .call(["repo": "o/r", "prompt": "Go"]))
        XCTAssertEqual(VoiceTool.allCases.filter(\.namesConversation), [.readConversation, .sendMessage, .stopConversation])
        let sessions = j(#"{"sessions":[{"id":"a","repo":"o/r","status":"idle"}]}"#)
        XCTAssertTrue(Voice.owns(sessions, session: "a"))
        XCTAssertFalse(Voice.owns(sessions, session: "b"))
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
        XCTAssertEqual(VoiceTool.sendMessage.plan(args, repo: "o/r"), .confirm("Send: ship it"))
        var yes = args
        yes["confirmed"] = true
        XCTAssertEqual(VoiceTool.sendMessage.plan(yes, repo: "o/r"), .call(["sessionId": "s1", "text": "ship it"]))
        XCTAssertEqual(VoiceTool.stopConversation.plan(["session_id": "s1"], repo: "o/r"), .confirm("Stop the agent's running turn."))
        XCTAssertEqual(VoiceTool.startConversation.plan(["prompt": "Fix the login", "branch": "dev"], repo: "o/r"),
                       .confirm("Start an agent from dev with: Fix the login"))
        XCTAssertEqual(VoiceTool.startConversation.plan(["prompt": "Fix the login", "branch": "dev", "confirmed": true], repo: "o/r"),
                       .call(["repo": "o/r", "prompt": "Fix the login", "branch": "dev"]))
    }

    func testMissingArgumentsAreRefusedWithoutACall() {
        XCTAssertEqual(VoiceTool.readConversation.plan([:], repo: "o/r"), .refuse("session_id is missing."))
        XCTAssertEqual(VoiceTool.sendMessage.plan(["session_id": "s1", "text": "  ", "confirmed": true], repo: "o/r"),
                       .refuse("session_id and text are needed."))
        XCTAssertEqual(VoiceTool.startConversation.plan(["prompt": " ", "confirmed": true], repo: "o/r"), .refuse("prompt is missing."))
        XCTAssertEqual(VoiceTool.readConversation.plan(["session_id": "s1"], repo: "o/r"), .call(["sessionId": "s1", "since": 0]))
    }

    func testConversationsSayTheirStatusAndDropClosedOnesWhenAskedForActive() {
        let answer = j(#"{"sessions":[{"id":"a","title":"Login","repo":"o/r","status":"running","prStatus":{"number":7}},{"id":"b","title":"Old","repo":"o/r","status":"closed"}]}"#)
        let all = VoiceTool.listConversations.summary(answer, args: [:])
        XCTAssertEqual(all["total"], 2)
        XCTAssertEqual(all["conversations"][0], ["session_id": "a", "title": "Login", "status": "Working", "pull_request": ["number": 7, "state": "open"]])
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

    func testAPullRequestIsReadyToMergeOnlyWithTheApprovedLabelAndPassingChecks() {
        let answer = j(#"""
        {"pulls":[
          {"number":1,"title":"Ready","checks":"success","labels":[{"name":"Code-Approved"}],"reviewDecision":"APPROVED"},
          {"number":2,"title":"Approved by review only","checks":"success","labels":[],"reviewDecision":"APPROVED"},
          {"number":3,"title":"Checks running","checks":"pending","labels":[{"name":"code-approved"}]},
          {"number":4,"title":"Conflicts","checks":"success","mergeable":"conflicting","labels":[{"name":"code-approved"}]},
          {"number":5,"title":"Draft","checks":"success","draft":true,"labels":[{"name":"code-approved"}]}]}
        """#)
        let pulls = VoiceTool.listPullRequests.summary(answer, args: [:])["pull_requests"].items
        XCTAssertEqual(pulls.map { $0["ready_to_merge"] }, [true, false, false, false, false])
        XCTAssertEqual(pulls[0]["labels"], ["Code-Approved"])
        XCTAssertTrue(VoiceTool.listPullRequests.definition["description"].string!.contains("ready to merge"))
    }

    func testConversationsAndPullRequestsAreLinkedBothWays() {
        let sessions = j(#"""
        {"sessions":[
          {"id":"a","title":"Fix yarn audit","status":"idle","prStatus":{"number":7,"state":"merged","checks":{"passed":4,"failed":0,"pending":0}}},
          {"id":"b","title":"Backups","status":"running","prStatus":{"number":9,"state":"open","draft":true}},
          {"id":"c","title":"On a PR","status":"idle","startedOnPr":12}]}
        """#)
        let listed = VoiceTool.listConversations.summary(sessions, args: [:])["conversations"].items
        XCTAssertEqual(listed[0]["pull_request"], ["number": 7, "state": "merged", "checks": "4 passed · 0 failed · 0 running"])
        XCTAssertEqual(listed[1]["pull_request"], ["number": 9, "state": "open", "draft": true])
        XCTAssertEqual(listed[2]["pull_request"], ["number": 12])

        XCTAssertTrue(VoiceTool.listPullRequests.readsConversations)
        let pulls = j(#"{"pulls":[{"number":9,"title":"Backups"},{"number":10,"title":"Alone"}]}"#)
        let out = VoiceTool.listPullRequests.summary(pulls, args: [:], sessions: Session.parseList(sessions)!)["pull_requests"].items
        XCTAssertEqual(out[0]["conversations"], [["session_id": "b", "title": "Backups"]])
        XCTAssertEqual(out[1]["conversations"], [])
    }
}
