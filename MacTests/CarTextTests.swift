// What the car's screen says of a conversation, a pull request and an issue, and what it makes of what was dictated.
import XCTest
@testable import BriareusMacCore

final class CarTextTests: XCTestCase {
    private func json(_ text: String) -> JSON { JSON.parse(text)! }

    func testTheCarShowsAConversationInAFewWords() {
        let sessions = Session.parseList(json(#"[{"id":"a","status":"running","title":"Fix login","queued":[{"text":"x"}]},{"id":"b","status":"idle","reviewTriage":{"findings":[{"key":"k"}]}},{"id":"c","status":"closed"}]"#))!
        XCTAssertEqual(sessions.map { CarText.status($0) }, ["Working · 1 queued", "Waiting for you · 1 finding", "Closed"])
        XCTAssertEqual(CarText.status(sessions[1], asking: true), "Asks you a question · 1 finding")
        XCTAssertEqual(CarText.status(sessions[0], asking: true), "Working · Asks you a question · 1 queued")
        let events = json(#"[{"seq":1,"kind":"user","text":"Go"},{"seq":2,"kind":"ask","question":"Which **one**, see [docs](https://e.com)?","options":[{"label":"Left"},{"label":"Right"}]},{"seq":3,"kind":"tool","name":"Bash"}]"#).items.compactMap(Event.init)
        XCTAssertEqual(CarText.openQuestion(events)?.seq, 2)
        XCTAssertEqual(CarText.options(events[1]), ["Left", "Right"])
        XCTAssertEqual(CarText.question(events[1]), "Which one, see docs?")
        let answered = json(#"[{"seq":1,"kind":"ask","question":"Sure?"},{"seq":2,"kind":"user","text":"Yes"},{"seq":3,"kind":"result"}]"#).items.compactMap(Event.init)
        XCTAssertNil(CarText.openQuestion(answered))
        XCTAssertEqual(CarText.inline("a_b_c and *this* and 2 * 3 * 4"), "a_b_c and this and 2 * 3 * 4")
    }
    func testWhatAMessageDoesDependsOnTheTurn() {
        XCTAssertEqual(CarText.sent(nil), "Sent")
        XCTAssertEqual(CarText.sent(Session(["id": "a", "status": "idle"])), "Sent")
        XCTAssertEqual(CarText.sent(Session(["id": "a", "status": "running", "liveInput": true])), "Sent into the running turn")
        XCTAssertEqual(CarText.sent(Session(["id": "a", "status": "running"])), "Queued for the next turn")
    }
    func testFindingsWaitingAreListedOldestHoldFirst() {
        let sessions = Session.parseList(json(#"[{"id":"new","status":"idle","reviewTriage":{"heldAt":"2026-02-02T00:00:00Z","findings":[{"key":"a"}]}},{"id":"none","status":"idle"},{"id":"empty","status":"idle","reviewTriage":{"heldAt":"2026-01-01T00:00:00Z","findings":[]}},{"id":"old","status":"idle","reviewLoop":{"triage":{"heldAt":"2026-01-01T00:00:00Z","findings":[{"key":"b"}]}}}]"#))!
        XCTAssertEqual(CarText.holdingFindings(sessions).map(\.id), ["old", "new"])
    }

    func testTheCarShowsAPullRequestInAFewWords() {
        let pr = json(#"{"checks":{"passed":2,"failed":1,"pending":0,"runs":[{"name":"lint","conclusion":"failure"},{"name":"test","conclusion":"success"}]},"reviews":[{"user":"bo","state":"CHANGES_REQUESTED"},{"state":"APPROVED"}]}"#)
        XCTAssertEqual(CarText.checks(pr["checks"]), "2 passed · 1 failed · 0 running")
        XCTAssertEqual(CarText.checks(.null), "None")
        XCTAssertEqual(CarText.reviews(pr).map { "\($0.user): \($0.state)" }, ["bo: Changes requested"])
        XCTAssertEqual(CarText.review(pr, row: nil), "Changes requested")
        XCTAssertNil(CarText.review(.null, row: nil))
        let row = PullSummary(json(#"{"number":4,"title":"T","draft":true,"mergeable":"conflicting","checks":"failure","author":"ana","reviewDecision":"APPROVED"}"#))!
        XCTAssertEqual(CarText.review(pr, row: row), "Approved")
        XCTAssertEqual(CarText.pullLine(row), "#4 · Draft · Conflicts · Checks failed · @ana")
        let finding = json(#"{"title":"Leak","severity":"high","file":"src/io/file.swift"}"#)
        XCTAssertEqual(CarText.finding(finding, verdict: "Fix"), "Fix · high · file.swift")
        XCTAssertEqual(CarText.finding(["fixed": true], verdict: "Fix"), "Fixed")
        XCTAssertEqual(CarText.verdictTitle("dismissed"), "Dismiss")
        XCTAssertNil(CarText.verdictTitle("later"))
    }
    func testAMergeSquashesUnlessTheRepositoryRefuses() {
        XCTAssertEqual(CarText.mergeMethod(allowed: []), "squash")
        XCTAssertEqual(CarText.mergeMethod(allowed: ["merge", "squash"]), "squash")
        XCTAssertEqual(CarText.mergeMethod(allowed: ["rebase", "merge"]), "merge")
        XCTAssertEqual(CarText.mergeTitle("rebase"), "Rebase and merge")
        XCTAssertEqual(CarText.merged(["status": "merged"], base: "main"), "Merged into main")
        XCTAssertEqual(CarText.merged(["status": "enqueued"], base: "main"), "Queued to merge into main")
        XCTAssertEqual(CarText.merged(["status": "pending"], base: "main"), "GitHub is finishing the merge into main")
    }

    func testTheCarShowsAnIssueInAFewWords() {
        let epic = IssueSummary(json(#"{"number":7,"title":"Epic","subIssues":{"total":3,"completed":1},"labels":[{"name":"a"},{"name":"b"},{"name":"c"}]}"#))!
        XCTAssertEqual(CarText.issueLine(epic, nested: false), "#7 · Epic 1/3 · a · b")
        let child = IssueSummary(json(#"{"number":8,"title":"Child","parent":{"number":7,"title":"Epic"}}"#))!
        XCTAssertEqual(CarText.issueLine(child, nested: true), "#8 · In #7")
        XCTAssertEqual(CarText.issueLine(child, nested: false), "#8")
        XCTAssertEqual(CarText.closingIssue(epic, working: true, comment: true),
                       "2 of its sub-issues are still open and stay open. A session is still working on it; closing does not stop it. Your comment is posted first.")
        XCTAssertNil(CarText.closingIssue(child, working: false, comment: false))
    }

    func testWhatWasDictatedIsShownWholeAndCutShorter() {
        XCTAssertEqual(CarText.title(" Fix  the\nlogin. "), "Fix the login")
        XCTAssertEqual(CarText.variants("Short"), ["“Short”"])
        let long = String(repeating: "word ", count: 40).trimmingCharacters(in: .whitespaces)
        let variants = CarText.variants(long, before: "Send “")
        XCTAssertEqual(variants.count, 3); XCTAssertEqual(variants[0], "Send “\(long)”")
        XCTAssertEqual(variants[2].count, "Send “".count + 59 + 2); XCTAssertTrue(variants[2].hasSuffix("…”"))
    }
}
