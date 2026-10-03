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

    func testIssuesListTheirLinksAndWorkingOnOneStartsFromItsBoardRow() {
        let board = j(#"""
        {"issues":[
          {"number":5,"title":"Add **exports**","labels":[{"name":"bug"}],"pulls":[{"number":9,"title":"Exports"}],
           "parent":{"number":2,"title":"Epic"}},
          {"number":2,"title":"Epic","subIssues":{"total":3,"completed":1}}]}
        """#)
        let sessions = Session.parseList(j(#"{"sessions":[{"id":"a","title":"Issue #5: Add exports","status":"running"}]}"#))!
        XCTAssertTrue(VoiceTool.listIssues.readsConversations)
        let issues = VoiceTool.listIssues.summary(board, args: [:], sessions: sessions)["issues"].items
        XCTAssertEqual(issues[0], ["number": 5, "title": "Add exports", "labels": ["bug"], "pull_requests": [9], "epic": 2,
                                   "conversations": [["session_id": "a", "title": "Issue #5: Add exports", "status": "Working"]]])
        XCTAssertEqual(issues[1]["sub_issues"], "1 of 3 done")

        XCTAssertTrue(VoiceTool.workOnIssue.changes)
        XCTAssertEqual(VoiceTool.workOnIssue.plan(["issue": 5], repo: "o/r"), .confirm("Start an agent on issue #5."))
        XCTAssertEqual(VoiceTool.workOnIssue.plan(["issue": 5, "confirmed": true], repo: "o/r"), .call(["repo": "o/r", "issue": 5]))
        XCTAssertEqual(VoiceTool.workOnIssue.plan(["confirmed": true], repo: "o/r"), .refuse("issue is missing."))
        let start = Voice.issueStart(board, number: 5, repo: "o/r")!
        XCTAssertEqual(start["activity"], "issue")
        XCTAssertTrue(start["prompt"].string!.hasPrefix("Issue #5: Add **exports**"))
        XCTAssertNil(Voice.issueStart(board, number: 7, repo: "o/r"))
    }

    func testReadingAnIssueGivesItsDescriptionLatestCommentsAndLinks() {
        XCTAssertEqual(VoiceTool.readIssue.operation, "issue")
        XCTAssertFalse(VoiceTool.readIssue.changes)
        XCTAssertTrue(VoiceTool.readIssue.readsConversations)
        XCTAssertEqual(VoiceTool.readIssue.plan(["issue": 5], repo: "o/r"), .call(["repo": "o/r", "issue": 5]))
        XCTAssertEqual(VoiceTool.readIssue.plan([:], repo: "o/r"), .refuse("issue is missing."))
        XCTAssertEqual(APIRoute.named("issue")?.path, "issues/{issue}")
        XCTAssertEqual(APIRoute.named("issue_timeline")?.path, "issues/{issue}/timeline")

        var answer = j(#"""
        {"issue":{"number":5,"title":"Add **exports**","state":"open","type":"Feature","author":"ana","assignees":["bo"],
          "body":"Export the **ledger** as [CSV](https://x.y).\n\nKeep the filters.","labels":[{"name":"bug"}],"comments":7,
          "parent":{"number":2,"title":"Epic"},
          "subIssues":{"total":2,"completed":1,"items":[{"number":6,"title":"Done","state":"closed"},{"number":8,"title":"Left","state":"open"}]},
          "pulls":[{"number":9,"title":"Exports","state":"open","draft":true}]}}
        """#)
        let rows = (1...7).map { n in j(#"{"kind":"commented","actor":"ana","body":"Comment \#(n)"}"#) }
        answer["timeline"] = .array([j(#"{"kind":"labeled","actor":"ana"}"#)] + rows)
        let sessions = Session.parseList(j(#"{"sessions":[{"id":"a","title":"Issue #5: Add exports","status":"running"}]}"#))!
        let out = VoiceTool.readIssue.summary(answer, args: ["issue": 5], sessions: sessions)
        XCTAssertEqual(out["title"], "Add exports")
        XCTAssertEqual(out["state"], "open")
        XCTAssertEqual(out["type"], "Feature")
        XCTAssertEqual(out["description"], "Export the ledger as CSV. Keep the filters.")
        XCTAssertEqual(out["epic"], ["number": 2, "title": "Epic"])
        XCTAssertEqual(out["sub_issues"], "1 of 2 done")
        XCTAssertEqual(out["open_sub_issues"], [["number": 8, "title": "Left"]])
        XCTAssertEqual(out["pull_requests"], [["number": 9, "title": "Exports", "state": "open", "draft": true]])
        XCTAssertEqual(out["conversations"], [["session_id": "a", "title": "Issue #5: Add exports", "status": "Working"]])
        XCTAssertEqual(out["comments"].items.map { $0["text"] }, ["Comment 3", "Comment 4", "Comment 5", "Comment 6", "Comment 7"])
        XCTAssertEqual(out["comments_total"], 7)

        XCTAssertEqual(Voice.issueState(j(#"{"state":"closed","stateReason":"not_planned"}"#)), "closed as not planned")
        XCTAssertEqual(Voice.cut("abcdef", 3), "abc…")
        XCTAssertEqual(VoiceTool.readIssue.summary(j("{}"), args: [:])["error"], "The server did not return the issue.")
    }

    func testAPullRequestsChangesCountItsFilesAndGroupThemByFolder() {
        XCTAssertEqual(VoiceTool.readPullRequest.plan(["number": 9], repo: "o/r"), .call(["repo": "o/r", "pr": 9]))
        XCTAssertEqual(VoiceTool.readPullRequest.plan([:], repo: "o/r"), .refuse("number is missing."))
        let answer = j(#"""
        {"pr":{"changedFiles":3,"additions":40,"deletions":5,"commits":2},
         "files":[{"filename":"App/A.swift","status":"added","additions":30,"deletions":0},
                  {"filename":"App/B.swift","status":"modified","additions":9,"deletions":5},
                  {"filename":"README.md","additions":1,"deletions":0}]}
        """#)
        let out = VoiceTool.readPullRequest.summary(answer, args: [:])
        XCTAssertEqual(out["changed_files"], 3)
        XCTAssertEqual(out["lines_added"], 40)
        XCTAssertEqual(out["lines_removed"], 5)
        XCTAssertEqual(out["commits"], 2)
        XCTAssertEqual(out["by_folder"], [["folder": "App", "files": 2], ["folder": "README.md", "files": 1]])
        XCTAssertEqual(out["files"][2], ["path": "README.md", "change": "modified", "added": 1, "removed": 0])
        XCTAssertTrue(out["files_listed"].isNull)
        XCTAssertEqual(Voice.changes(PullFilesPage(answer)!, listed: 2)["files_listed"], "the first 2 only")
    }
}
