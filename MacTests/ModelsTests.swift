// Ported from the Windows client's tests/core_models_tests.c, from projects on (devices, discovery and routes are ConnectionTests').
import XCTest
@testable import BriareusMacCore

func j(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> JSON {
    guard let v = JSON.parse(text) else { XCTFail("not JSON: \(text)", file: file, line: line); return .null }
    return v
}

final class ModelsTests: XCTestCase {
    // MARK: - Projects

    func testProjectsReadLabelAndTitle() {
        let p = Project.parseList(j(#"{"projects":[{"repo":"o/a","label":"Alpha"},{"repo":"o/b","label":""},{"repo":"o/c","label":null},{"label":"No repo"},{"repo":5},{"repo":"o/d","label":3}]}"#))!
        XCTAssertEqual(p.count, 4)
        XCTAssertEqual(p.map(\.title), ["Alpha", "o/b", "o/c", "o/d"])
        XCTAssertNil(p[2].label); XCTAssertNil(p[3].label); XCTAssertEqual(p[1].label, "")
        // A bare array reads the same; neither an object without the list nor a scalar does.
        let saved = Project.json(p)
        let again = Project.parseList(saved)!
        XCTAssertEqual(again.count, 4)
        XCTAssertEqual(again[0].label, "Alpha"); XCTAssertNil(again[2].label); XCTAssertEqual(again[3].repo, "o/d")
        XCTAssertEqual(Project.json(again), saved)
        XCTAssertTrue(saved[2]["label"].isNull); XCTAssertEqual(saved[2].count, 2)
        for bad in ["{}", #"{"projects":null}"#, #"{"projects":{}}"#, "null", "3"] { XCTAssertNil(Project.parseList(j(bad)), bad) }
        XCTAssertEqual(Project.parseList(j("[]"))?.count, 0)
    }
    func testProjectWithoutLabel() {
        let p = Project(j(#"{"repo":"o/b"}"#))!
        XCTAssertNil(p.label); XCTAssertEqual(p.title, "o/b")
        XCTAssertEqual(p.json["repo"].string, "o/b")
        XCTAssertNil(Project(j(#"{"label":"x"}"#)))
    }

    // MARK: - Sessions

    private func session(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> Session {
        guard let s = Session(j(text)) else { XCTFail("no session: \(text)", file: file, line: line); return Session(raw: [:]) }
        return s
    }
    func testSessionNeedsAnIdAndAStatus() {
        for bad in [#"{"status":"idle"}"#, #"{"id":"s"}"#, #"{"id":1,"status":"idle"}"#, #"{"id":"s","status":null}"#, "[]", "null"] {
            XCTAssertNil(Session(j(bad)), bad)
        }
        let list = j(#"{"sessions":[{"id":"a","status":"idle"},{"id":"b"},{"id":"c","status":"running","future":[1]}]}"#)
        let s = Session.parseList(list)!
        XCTAssertEqual(s.map(\.id), ["a", "c"])
        // Unknown fields ride along, so a saved list round-trips.
        let saved = Session.json(s)
        XCTAssertEqual(saved[1], list["sessions"][2])
        let again = Session.parseList(saved)!
        XCTAssertEqual(again.count, 2); XCTAssertEqual(again[1].status, "running")
        for bad in ["{}", #"{"sessions":null}"#, #""x""#] { XCTAssertNil(Session.parseList(j(bad))) }
    }
    func testSessionAccessorsFallBackWhenFieldsAreMissing() {
        var s = session(#"{"id":"a","status":"idle","repo":"o/r","model":"opus","provider":"claude","title":"Fix login"}"#)
        XCTAssertEqual(s.repo, "o/r"); XCTAssertEqual(s.model, "opus"); XCTAssertEqual(s.provider, "claude")
        XCTAssertEqual(s.displayTitle, "Fix login")
        s = session(#"{"id":"a","status":"idle","repo":null,"model":"","provider":2,"title":""}"#)
        XCTAssertNil(s.repo); XCTAssertNil(s.model); XCTAssertNil(s.provider)
        XCTAssertEqual(s.displayTitle, "New conversation")
        XCTAssertEqual(session(#"{"id":"a","status":"idle","title":7}"#).displayTitle, "New conversation")
        // A session never parsed reads as empty rather than crashing.
        let empty = Session(raw: .null)
        XCTAssertEqual(empty.id, ""); XCTAssertEqual(empty.status, ""); XCTAssertNil(empty.repo)
        XCTAssertEqual(empty.displayTitle, "New conversation"); XCTAssertFalse(empty.isActive)
    }
    func testSessionIsActiveByStatus() {
        for st in ["queued", "preparing", "running", "starting"] { XCTAssertTrue(session(#"{"id":"a","status":"\#(st)"}"#).isActive, st) }
        for st in ["idle", "closed", "failed", "done", "Running", "", "future"] { XCTAssertFalse(session(#"{"id":"a","status":"\#(st)"}"#).isActive, st) }
    }
    func testSessionLiveInputAndQueue() {
        let s = session(#"{"id":"a","status":"running","liveInput":true,"queued":[{"text":"next"}]}"#)
        XCTAssertTrue(s.liveInput); XCTAssertEqual(s.queued.count, 1)
        for off in [#"{"id":"a","status":"running"}"#, #"{"id":"a","status":"running","liveInput":false}"#,
                    #"{"id":"a","status":"running","liveInput":1}"#, #"{"id":"a","status":"running","liveInput":"true"}"#] {
            let s = session(off); XCTAssertFalse(s.liveInput); XCTAssertTrue(s.queued.isNull)
        }
    }
    func testSessionReviewLoopFlags() {
        var s = session(#"{"id":"a","status":"idle","reviewLoop":{"on":true}}"#)
        XCTAssertTrue(s.reviewLoopOn); XCTAssertTrue(s.canReviewLoop)
        s = session(#"{"id":"a","status":"idle"}"#); XCTAssertFalse(s.reviewLoopOn); XCTAssertTrue(s.canReviewLoop)
        // Every flag that marks a session as not started from scratch on a task rules the loop out; an unset value does not.
        let flags = [#""reviewBranch":"f""#, #""qaBranch":"q""#, #""autoClose":true"#, #""loopParentId":"p""#, #""local":true"#, #""orchestrator":1"#]
        let unset = [#""reviewBranch":"""#, #""qaBranch":null"#, #""autoClose":false"#, #""loopParentId":null"#, #""local":false"#, #""orchestrator":0"#]
        for i in 0..<6 {
            XCTAssertFalse(session(#"{"id":"a","status":"idle",\#(flags[i])}"#).canReviewLoop, flags[i])
            XCTAssertTrue(session(#"{"id":"a","status":"idle",\#(unset[i])}"#).canReviewLoop, unset[i])
        }
        XCTAssertFalse(session(#"{"id":"a","status":"closed"}"#).canReviewLoop)
    }
    func testHeldTriageNeedsFindingsAndPrefersTheStandaloneReview() {
        var s = session(#"{"id":"a","status":"idle","reviewTriage":{"findings":[{"key":"own"}]},"reviewLoop":{"triage":{"findings":[{"key":"loop"}]}}}"#)
        XCTAssertEqual(s.heldTriage?["findings"][0]["key"].string, "own")
        // The Findings screen's round prefers the loop's.
        XCTAssertEqual(s.heldRound?["findings"][0]["key"].string, "loop")
        s = session(#"{"id":"a","status":"idle","reviewTriage":{"findings":[]},"reviewLoop":{"triage":{"findings":[{"key":"loop"}]}}}"#)
        XCTAssertEqual(s.heldTriage?["findings"][0]["key"].string, "loop")
        s = session(#"{"id":"a","status":"idle","reviewTriage":{},"reviewLoop":{"triage":{"findings":[]}}}"#)
        XCTAssertNil(s.heldTriage); XCTAssertNotNil(s.heldRound)
    }
    func testSessionPullNumberIgnoresWhatIsNotAPullRequest() {
        XCTAssertNil(session(#"{"id":"s","status":"idle","prStatus":{"number":-3}}"#).pullNumber)
        XCTAssertNil(session(#"{"id":"s","status":"idle","startedOnPr":"4"}"#).pullNumber)
        XCTAssertEqual(session(#"{"id":"s","status":"idle","prStatus":{"number":"9"},"startedOnPr":4}"#).pullNumber, 4)
        XCTAssertEqual(session(#"{"id":"s","status":"idle","prStatus":{},"startedOnPr":11}"#).pullNumber, 11)
    }
    func testSessionOnIssueReadsTheTitleAnIssueStartGives() {
        let cases = [(#"{"id":"s","status":"idle","title":"Issue #12: Fix login"}"#, true), (#"{"id":"s","status":"idle","title":"Issue #123: Other"}"#, false),
                     (#"{"id":"s","status":"idle","title":"Look at Issue #12: later"}"#, false), (#"{"id":"s","status":"idle"}"#, false),
                     (#"{"id":"s","status":"idle","title":"Issue #12"}"#, false)]
        for (text, expected) in cases { XCTAssertEqual(session(text).onIssue(12), expected, text) }
        XCTAssertFalse(session(cases[0].0).onIssue(0))
    }

    // MARK: - Findings

    func testHeldRoundsOfAnEmptyList() {
        XCTAssertEqual(Session.heldRounds([]).count, 0)
        let s = session(#"{"id":"a","status":"idle","reviewTriage":"held","reviewLoop":{"triage":[]}}"#)
        XCTAssertNil(s.heldRound)
        XCTAssertEqual(Session.heldRounds([s]).count, 0)
    }
    func testHeldRoundsWithEqualHoldsKeepTheListOrder() {
        let s = Session.parseList(j(#"[{"id":"a","status":"idle","reviewTriage":{"heldAt":"2026-09-29T10:00:00Z"}},"#
            + #"{"id":"b","status":"idle"},"#
            + #"{"id":"c","status":"idle","reviewTriage":{"heldAt":"2026-09-29T09:00:00Z"}},"#
            + #"{"id":"d","status":"idle","reviewTriage":{"heldAt":"2026-09-29T10:00:00Z"}},"#
            + #"{"id":"e","status":"idle","reviewTriage":{"heldAt":"2026-09-29T09:00:00Z"}}]"#))!
        let r = Session.heldRounds(s)
        XCTAssertEqual(r.map(\.index), [2, 4, 0, 3])
        XCTAssertEqual(r[0].held, s[2].heldRound)
    }
    func testHeldRoundURLReusesTheConversationsOwnLinkOnlyForItsPullRequest() {
        let held7 = j(#"{"prNumber":7}"#), held9 = j(#"{"prNumber":9}"#), none = j("{}")
        var s = session(#"{"id":"a","status":"idle","repo":"o/r","prStatus":{"number":7,"url":"https://ghe.example/o/r/pull/7"}}"#)
        XCTAssertEqual(s.heldRoundPRURL(held7), "https://ghe.example/o/r/pull/7")
        XCTAssertEqual(s.heldRoundPRURL(held9), "https://github.com/o/r/pull/9")
        // An empty link or one without a number is built from the round's number.
        s = session(#"{"id":"a","status":"idle","repo":"o/r","prStatus":{"number":7,"url":""}}"#)
        XCTAssertEqual(s.heldRoundPRURL(held7), "https://github.com/o/r/pull/7")
        s = session(#"{"id":"a","status":"idle","repo":"o/r","prStatus":{"url":"https://ghe.example/x"}}"#)
        XCTAssertEqual(s.heldRoundPRURL(held7), "https://github.com/o/r/pull/7")
        s = session(#"{"id":"a","status":"idle"}"#)
        XCTAssertEqual(s.heldRoundPRURL(held9), "https://github.com//pull/9")
        // A round without a number has the conversation's own link, or none.
        s = session(#"{"id":"a","status":"idle","repo":"o/r","prStatus":{"number":7,"url":"https://ghe.example/o/r/pull/7"}}"#)
        XCTAssertEqual(s.heldRoundPRURL(none), "https://ghe.example/o/r/pull/7")
        XCTAssertNil(session(#"{"id":"a","status":"idle","repo":"o/r"}"#).heldRoundPRURL(none))
        XCTAssertEqual(heldRoundPRNumber(held7), 7); XCTAssertNil(heldRoundPRNumber(none)); XCTAssertNil(heldRoundPRNumber(.null))
        XCTAssertNil(heldRoundPRNumber(j(#"{"prNumber":0}"#))); XCTAssertNil(heldRoundPRNumber(j(#"{"prNumber":"7"}"#)))
    }
    func testHeldRoundIsMineUnlessAStandaloneReviewSaysOtherwise() {
        for m in ["{}", #"{"mine":false}"#, #"{"standalone":false,"mine":false}"#, #"{"standalone":null}"#, #"{"standalone":true,"mine":true}"#] {
            XCTAssertTrue(heldRoundIsMine(j(m)), m)
        }
        for t in [#"{"standalone":true}"#, #"{"standalone":true,"mine":false}"#, #"{"standalone":true,"mine":"yes"}"#, #"{"standalone":1,"mine":1}"#] {
            XCTAssertFalse(heldRoundIsMine(j(t)), t)
        }
    }
    func testTriageOutcomeTextCoversEveryOutcome() {
        let failed = "Verdicts recorded, but no fix session started. The session\u{2019}s log says why."
        let cases: [(String, String, Bool)] = [
            (#"{"completed":true,"prNumber":12}"#, "Review completed; what it found stays on PR #12 for its author.", false),
            (#"{"completed":true}"#, "Review completed; what it found stays on the pull request for its author.", false),
            (#"{"completed":true,"prNumber":"12"}"#, "Review completed; what it found stays on the pull request for its author.", false),
            (#"{"converged":true,"approved":true}"#, "Verdicts recorded; nothing was left to fix, so code-approved was added and the loop converged.", false),
            (#"{"approved":true,"fixing":true}"#, "Verdicts recorded; nothing was left to fix, so code-approved was added.", false),
            (#"{"fixing":"session-id"}"#, "Verdicts recorded; a fix session is running.", false),
            (#"{"reviewing":true,"deferred":true}"#, "Verdicts recorded; nothing was left to fix, but the branch had moved, so the new commits are being reviewed.", false),
            (#"{"deferred":true}"#, "Verdicts recorded; nothing was left to fix, but the branch had moved. The new commits are reviewed once the session settles idle.", false),
            (#"{"completed":false,"converged":null,"fixing":"","deferred":0}"#, failed, true),
            ("{}", failed, true),
        ]
        for (outcome, text, danger) in cases {
            let r = triageOutcomeText(j(outcome))
            XCTAssertEqual(r.text, text, outcome); XCTAssertEqual(r.danger, danger, outcome)
        }
        XCTAssertEqual(triageOutcomeText(.null).text, failed); XCTAssertTrue(triageOutcomeText(.null).danger)
    }
    func testFindingsSubtitleCountsReviewsAndPullRequests() {
        XCTAssertEqual(findingsSubtitle(rounds: 0, pullRequests: 0), "nothing is waiting")
        XCTAssertEqual(findingsSubtitle(rounds: 0, pullRequests: 3), "nothing is waiting")
        XCTAssertEqual(findingsSubtitle(rounds: 1, pullRequests: 1), "1 review waiting for a decision")
        XCTAssertEqual(findingsSubtitle(rounds: 2, pullRequests: 2), "2 reviews waiting for a decision")
        XCTAssertEqual(findingsSubtitle(rounds: 2, pullRequests: 1), "2 reviews on 1 pull request waiting for a decision")
        XCTAssertEqual(findingsSubtitle(rounds: 5, pullRequests: 3), "5 reviews on 3 pull requests waiting for a decision")
    }

    // MARK: - Events and transcript

    private func event(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> Event {
        guard let e = Event(j(text)) else { XCTFail("no event: \(text)", file: file, line: line); return Event(j(#"{"seq":0,"kind":"x"}"#))! }
        return e
    }
    func testEventReadsEveryField() {
        var e = event(#"{"seq":4,"kind":"result","t":"2026-09-28T15:55:49.120Z","text":"Done","name":"Bash","summary":"ls","question":"Go?","#
                      + #""options":["Yes","No"],"attachments":[{"id":"u1"}],"costUsd":0.25,"durationMs":1200,"isError":false}"#)
        XCTAssertEqual(e.seq, 4); XCTAssertEqual(e.kind, "result"); XCTAssertEqual(e.text, "Done"); XCTAssertEqual(e.name, "Bash")
        XCTAssertEqual(e.summary, "ls"); XCTAssertEqual(e.question, "Go?")
        XCTAssertEqual(e.options?.count, 2); XCTAssertEqual(e.attachments?.count, 1)
        XCTAssertEqual(e.costUsd, 0.25); XCTAssertEqual(e.durationMs, 1200); XCTAssertEqual(e.isError, false)
        XCTAssertEqual(e.time?.timeIntervalSince1970, 1790610949)
        e = event(#"{"seq":5,"kind":"tool_error","options":{},"attachments":"x","costUsd":null,"isError":true,"t":"yesterday"}"#)
        XCTAssertNil(e.options); XCTAssertNil(e.attachments); XCTAssertNil(e.costUsd); XCTAssertNil(e.durationMs); XCTAssertEqual(e.isError, true)
        XCTAssertNil(e.text); XCTAssertNil(e.name); XCTAssertNil(e.time)
        e = event(#"{"seq":6,"kind":"text"}"#); XCTAssertNil(e.isError); XCTAssertNil(e.time)
    }
    func testEventNeedsAKindAndASequence() {
        for bad in [#"{"kind":"text"}"#, #"{"seq":1}"#, #"{"seq":"1","kind":"text"}"#, #"{"seq":1,"kind":3}"#, "[]", "null"] { XCTAssertNil(Event(j(bad)), bad) }
    }
    func testEventDetailPrefersTextOverSummary() {
        XCTAssertEqual(event(#"{"seq":1,"kind":"tool","summary":"git status"}"#).detail, "git status")
        XCTAssertEqual(event(#"{"seq":1,"kind":"text","text":"Hi","summary":"ignored"}"#).detail, "Hi")
        XCTAssertEqual(event(#"{"seq":1,"kind":"text","text":"","summary":"s"}"#).detail, "")
        XCTAssertNil(event(#"{"seq":1,"kind":"cmd"}"#).detail)
    }
    func testEventVisibleByKindAndContent() {
        let cases: [(String, Bool)] = [
            (#"{"seq":1,"kind":"status","text":"running"}"#, false), (#"{"seq":1,"kind":"status"}"#, false),
            (#"{"seq":1,"kind":"tool"}"#, true), (#"{"seq":1,"kind":"tool_error"}"#, true), (#"{"seq":1,"kind":"result"}"#, true),
            (#"{"seq":1,"kind":"ask","question":"Which?"}"#, true), (#"{"seq":1,"kind":"future","text":"shown"}"#, true),
            (#"{"seq":1,"kind":"future"}"#, false), (#"{"seq":1,"kind":"git","summary":"only a summary"}"#, false),
            (#"{"seq":1,"kind":"setup","text":"npm ERR!"}"#, true), (#"{"seq":1,"kind":"cmd","text":"$ php artisan migrate:fresh --seed"}"#, true),
        ]
        for (text, visible) in cases { XCTAssertEqual(event(text).isVisible, visible, text) }
    }
    func testSetupOutputStaysInTheTranscript() {
        // Hiding setup lines hid why a session failed during workspace setup.
        var t = Transcript()
        t.append(j(#"[{"seq":1,"kind":"cmd","text":"$ php artisan migrate:fresh --seed"},{"seq":2,"kind":"setup","text":"SQLSTATE[HY000] [2002] Connection refused"},{"seq":3,"kind":"status","status":"failed"}]"#))
        XCTAssertEqual(t.events.count, 3)
        XCTAssertTrue(t.events[1].isVisible); XCTAssertEqual(t.events[1].detail, "SQLSTATE[HY000] [2002] Connection refused")
        XCTAssertFalse(t.events[2].isVisible)
    }
    func testTranscriptCursorOnlyMovesForward() {
        var t = Transcript()
        XCTAssertEqual(t.events.count, 0); XCTAssertEqual(t.cursor, 0)
        t.append(j(#"[{"seq":10,"kind":"text","text":"b"},{"seq":12,"kind":"text","text":"c"}]"#)); XCTAssertEqual(t.cursor, 12)
        t.append(j(#"[{"seq":4,"kind":"text","text":"a"},{"seq":10,"kind":"text","text":"dup"}]"#))
        XCTAssertEqual(t.cursor, 12); XCTAssertEqual(t.events.map(\.seq), [4, 10, 12])
        // The first copy of a sequence wins.
        XCTAssertEqual(t.events[1].text, "b")
        // Unreadable entries and non-arrays are skipped.
        t.append(j(#"[{"kind":"text"},{"seq":"13","kind":"text"},7,null]"#)); XCTAssertEqual(t.events.count, 3); XCTAssertEqual(t.cursor, 12)
        t.append(.null); XCTAssertEqual(t.events.count, 3)
        t.append(j(#"{"seq":20,"kind":"text"}"#)); XCTAssertEqual(t.events.count, 3)
        XCTAssertEqual(t.events[0].text, "a")
    }
    func testTranscriptGrowsAndSorts() {
        var t = Transcript()
        let events = JSON.array((1...200).reversed().map { ["seq": JSON($0), "kind": "text", "text": "x"] })
        t.append(events)
        XCTAssertEqual(t.events.count, 200); XCTAssertEqual(t.cursor, 200)
        XCTAssertEqual(t.events.map(\.seq), Array(1...200))
        t.append(events); XCTAssertEqual(t.events.count, 200)
    }
    func testSavedTranscriptRestoresEventsAndCursor() {
        let events = j(#"[{"seq":2,"kind":"text","text":"b","extra":{"k":1}},{"seq":1,"kind":"user","text":"a"}]"#)
        var t = Transcript(); t.append(events)
        let saved = t.json
        XCTAssertEqual(saved.count, 2); XCTAssertEqual(saved[0]["seq"].int, 1)
        XCTAssertEqual(saved[1], events[0])
        var again = Transcript(); again.append(saved)
        XCTAssertEqual(again.events.count, 2); XCTAssertEqual(again.cursor, 2)
        XCTAssertEqual(again.json, saved)
        XCTAssertEqual(Transcript().json, .array([]))
    }

    // MARK: - Runtimes

    static let catalog = #"{"default":{"providerId":2,"model":"opus","effort":"high"},"providers":["#
        + #"{"id":1,"label":"Codex","available":false,"defaultModel":"gpt","models":[{"id":"gpt","label":"GPT","efforts":["low"],"defaultEffort":"low"}]},"#
        + #"{"id":2,"label":"Claude","available":true,"defaultModel":"opus","models":["#
        + #"{"id":"sonnet","label":"","efforts":["low","medium"]},"#
        + #"{"id":"opus","label":"Opus","efforts":["low","high"],"defaultEffort":"high"},"#
        + #"{"id":"haiku"}]},"#
        + #"{"id":3,"label":"Old","models":[]},"#
        + #"{"id":4,"label":"","defaultModel":"missing","models":[{"id":"m","efforts":[]}]}]}"#

    func testRuntimeCatalogReadsProvidersAndModels() {
        let c = RuntimeCatalog(j(Self.catalog))!
        XCTAssertEqual(c.providers.count, 4)
        XCTAssertEqual(c.providers.map(\.available), [false, true, nil, nil])
        XCTAssertFalse(c.providers[0].isAvailable); XCTAssertTrue(c.providers[1].isAvailable); XCTAssertTrue(c.providers[2].isAvailable)
        let claude = c.provider(2)!
        XCTAssertEqual(claude, c.providers[1]); XCTAssertNil(c.provider(9))
        XCTAssertEqual(claude.models.count, 3); XCTAssertEqual(claude.defaultModel, "opus")
        // A model without a label goes by its id.
        XCTAssertEqual(claude.models.map(\.title), ["sonnet", "Opus", "haiku"])
        XCTAssertNil(claude.models[2].efforts)
        XCTAssertEqual(c.providers[3].models[0].efforts, [])
    }
    func testRuntimeCatalogRejectsMalformedProviders() {
        let bad = ["{}", #"{"providers":{}}"#, "[]",
                   #"{"providers":[{"label":"X","models":[]}]}"#,
                   #"{"providers":[{"id":"1","label":"X","models":[]}]}"#,
                   #"{"providers":[{"id":1,"models":[]}]}"#,
                   #"{"providers":[{"id":1,"label":"X"}]}"#,
                   #"{"providers":[{"id":1,"label":"X","models":[{"label":"no id"}]}]}"#,
                   #"{"providers":[{"id":1,"label":"X","models":[{"id":"ok"}]},{"id":2,"label":"Y","models":[{"id":"ok"},{"id":5}]}]}"#]
        for b in bad { XCTAssertNil(RuntimeCatalog(j(b)), b) }
        // A default without a provider is no default.
        let c = RuntimeCatalog(j(#"{"default":{"model":"opus"},"providers":[]}"#))!
        XCTAssertNil(c.defaultChoice)
    }
    func testRuntimeCatalogRoundTrips() {
        let c = RuntimeCatalog(j(Self.catalog))!
        let saved = c.json
        XCTAssertTrue(saved["providers"][2]["available"].isNull)
        XCTAssertEqual(saved["providers"][2].count, 4)
        let again = RuntimeCatalog(saved)!
        XCTAssertEqual(again.json.serialized(), c.json.serialized())
        XCTAssertEqual(again.defaultChoice, c.defaultChoice); XCTAssertNotNil(again.defaultChoice)
        XCTAssertNil(again.providers[2].available); XCTAssertEqual(again.providers[0].available, false)
        XCTAssertNil(again.providers[1].models[2].efforts)
        let empty = RuntimeCatalog(j(#"{"providers":[]}"#))!.json
        XCTAssertTrue(empty["default"].isNull); XCTAssertEqual(empty.count, 2)
    }
    func testRuntimeChoiceFallsBackFromModelToDefaultToFirst() {
        let c = RuntimeCatalog(j(Self.catalog))!
        // A model without its own default effort takes its first.
        XCTAssertEqual(c.choice(provider: 2, model: "sonnet"), RuntimeChoice(providerId: 2, model: "sonnet", effort: "low"))
        XCTAssertEqual(c.choice(provider: 2, model: "haiku"), RuntimeChoice(providerId: 2, model: "haiku", effort: nil))
        // A provider without models is still a choice, with nothing more to say.
        XCTAssertEqual(c.choice(provider: 3, model: "x"), RuntimeChoice(providerId: 3))
        // A default model the provider does not list falls to its first; empty efforts give no effort.
        XCTAssertEqual(c.choice(provider: 4), RuntimeChoice(providerId: 4, model: "m", effort: nil))
        // An unavailable provider can still be chosen by hand.
        XCTAssertEqual(c.choice(provider: 1), RuntimeChoice(providerId: 1, model: "gpt", effort: "low"))
        XCTAssertNil(c.choice(provider: 99, model: "opus"))
    }
    func testRuntimeFirstAvailableSkipsOnlyProvidersTurnedOff() {
        XCTAssertEqual(RuntimeCatalog(j(Self.catalog))!.firstAvailable(), RuntimeChoice(providerId: 2, model: "opus", effort: "high"))
        // A provider that does not say is available, as older servers omit the field.
        let c = RuntimeCatalog(j(#"{"providers":[{"id":1,"label":"A","available":false,"models":[]},{"id":5,"label":"B","models":[{"id":"b"}]}]}"#))!
        XCTAssertEqual(c.firstAvailable(), RuntimeChoice(providerId: 5, model: "b"))
        XCTAssertNil(RuntimeCatalog(j(#"{"providers":[{"id":1,"label":"A","available":false,"models":[]}]}"#))!.firstAvailable())
    }
    func testRuntimeEffortsAndLabelsForKnownAndUnknownChoices() {
        let c = RuntimeCatalog(j(Self.catalog))!
        let opus = RuntimeChoice(providerId: 2, model: "opus", effort: "high"), haiku = RuntimeChoice(providerId: 2, model: "haiku"),
            gone = RuntimeChoice(providerId: 2, model: "gone"), nomodel = RuntimeChoice(providerId: 2), stranger = RuntimeChoice(providerId: 9, model: "x"),
            bare = RuntimeChoice(providerId: 9), unnamed = RuntimeChoice(providerId: 4, model: "m"), sonnet = RuntimeChoice(providerId: 2, model: "sonnet")
        XCTAssertEqual(c.efforts(for: opus), ["low", "high"])
        XCTAssertEqual(c.efforts(for: haiku), []); XCTAssertEqual(c.efforts(for: gone), []); XCTAssertEqual(c.efforts(for: stranger), [])
        XCTAssertNil(c.model(for: nomodel)); XCTAssertEqual(c.model(for: opus), c.providers[1].models[1])
        XCTAssertEqual(c.label(for: opus), "Claude \u{00B7} Opus")
        XCTAssertEqual(c.label(for: sonnet), "Claude \u{00B7} sonnet")
        XCTAssertEqual(c.label(for: gone), "Claude \u{00B7} gone")
        XCTAssertEqual(c.label(for: nomodel), "Claude")
        XCTAssertEqual(c.label(for: stranger), "x")
        XCTAssertEqual(c.label(for: bare), "")
        XCTAssertEqual(c.label(for: unnamed), "m")
    }
    func testRuntimeChoiceEqualityAndArguments() {
        let a = RuntimeChoice(providerId: 2, model: "opus", effort: "high")
        XCTAssertEqual(a, a)
        XCTAssertNotEqual(a, RuntimeChoice(providerId: 2, model: "opus"))
        XCTAssertNotEqual(a, RuntimeChoice(providerId: 3, model: "opus", effort: "high"))
        XCTAssertNotEqual(a, RuntimeChoice(providerId: 2, model: "sonnet", effort: "high"))
        XCTAssertEqual(RuntimeChoice(providerId: 1), RuntimeChoice(providerId: 1))
        // Starts send "provider", as the client API names it; empty strings are left out.
        XCTAssertEqual(a.arguments.serialized(), #"{"effort":"high","model":"opus","provider":2}"#)
        XCTAssertEqual(RuntimeChoice(providerId: 4, model: "", effort: "").arguments.serialized(), #"{"provider":4}"#)
    }

    // MARK: - Pull request files

    func testPullFileReadsAndRoundTrips() {
        let f = PullFile(j(#"{"filename":"src/new.c","previousFilename":"src/old.c","status":"renamed","additions":0,"deletions":4,"patch":"@@ -1 +1 @@","url":"https://x/y","sha":"abc"}"#))!
        XCTAssertEqual(f.filename, "src/new.c"); XCTAssertEqual(f.previousFilename, "src/old.c"); XCTAssertEqual(f.status, "renamed")
        XCTAssertEqual(f.additions, 0); XCTAssertEqual(f.deletions, 4); XCTAssertEqual(f.patch, "@@ -1 +1 @@"); XCTAssertEqual(f.url, "https://x/y")
        let saved = f.json
        XCTAssertTrue(saved["sha"].isNull)
        let again = PullFile(saved)!
        XCTAssertEqual(again, f); XCTAssertEqual(again.json, saved)
        // Counts the server left out stay unknown through a save.
        let g = PullFile(j(#"{"filename":"a","additions":"3","deletions":null}"#))!
        XCTAssertNil(g.additions); XCTAssertNil(g.deletions); XCTAssertNil(g.status); XCTAssertNil(g.patch)
        XCTAssertTrue(g.json["additions"].isNull); XCTAssertNil(PullFile(g.json)!.additions)
        for bad in ["{}", #"{"filename":3}"#, #"{"filename":null}"#, #""a""#] { XCTAssertNil(PullFile(j(bad)), bad) }
    }
    func testPullFileNameAndDirectory() {
        let cases = [("README.md", "README.md", ""), ("src/a.c", "a.c", "src"), ("a/b/c/d.txt", "d.txt", "a/b/c"), ("/rooted", "rooted", ""),
                     (".github/workflows/ci.yml", "ci.yml", ".github/workflows")]
        for (path, name, dir) in cases {
            let f = PullFile(filename: path)
            XCTAssertEqual(f.name, name); XCTAssertEqual(f.directory, dir)
        }
    }
    func testPullFilesPageReadsPagingAndRejectsWithoutFiles() {
        var p = PullFilesPage(j(#"{"pr":{"headSha":"h"},"files":[{"filename":"a"},{"nope":1},{"filename":"b"}],"nextPage":3,"truncated":true}"#))!
        XCTAssertEqual(p.files.map(\.filename), ["a", "b"]); XCTAssertEqual(p.nextPage, 3); XCTAssertTrue(p.truncated)
        XCTAssertEqual(p.pr["headSha"].string, "h")
        p = PullFilesPage(j(#"{"files":[],"truncated":"yes"}"#))!
        XCTAssertNil(p.nextPage); XCTAssertFalse(p.truncated); XCTAssertTrue(p.pr.isNull)
        for bad in ["{}", #"{"files":null}"#, #"{"files":{}}"#, "[]", "null"] { XCTAssertNil(PullFilesPage(j(bad)), bad) }
    }
    func testPullFileListStartsOnPageOneAndRoundTrips() {
        let l = PullFileList()
        XCTAssertEqual(l.nextPage, 1); XCTAssertTrue(l.pr.isNull); XCTAssertEqual(l.files.count, 0); XCTAssertFalse(l.truncated)
        XCTAssertEqual(l.arguments(repo: "o/r", number: 7)?.serialized(), #"{"pr":7,"repo":"o/r"}"#)
        XCTAssertEqual(l.json["nextPage"].int, 1)
        XCTAssertEqual(PullFileList(l.json)?.nextPage, 1)
        let m = PullFileList(j(#"{"pr":{"headSha":"h","baseSha":"b"},"files":[{"filename":"a","additions":2}],"nextPage":4,"truncated":true}"#))!
        let again = PullFileList(m.json)!
        XCTAssertEqual(again.nextPage, 4); XCTAssertTrue(again.truncated); XCTAssertEqual(again.files.count, 1); XCTAssertEqual(again.files[0].additions, 2)
        XCTAssertEqual(again.json, m.json)
        for bad in ["{}", #"{"files":{}}"#, "null"] { XCTAssertNil(PullFileList(j(bad)), bad) }
    }
    func testPullFileListArgumentsPinLaterPages() {
        var l = PullFileList(j(#"{"pr":{"headSha":"h1","baseSha":"b1"},"files":[],"nextPage":3}"#))!
        XCTAssertEqual(l.arguments(repo: "o/r", number: 7)?.serialized(), #"{"baseSha":"b1","headSha":"h1","page":3,"pr":7,"repo":"o/r"}"#)
        // Without the revision to pin to, the shas are left out rather than sent empty.
        l = PullFileList(j(#"{"pr":null,"files":[],"nextPage":2}"#))!
        XCTAssertEqual(l.arguments(repo: "o/r", number: 7)?.serialized(), #"{"page":2,"pr":7,"repo":"o/r"}"#)
        l.nextPage = nil; XCTAssertNil(l.arguments(repo: "o/r", number: 7))
    }
    func testPullFileListAppendKeepsTheFirstRevisionAndSkipsRepeats() {
        var l = PullFileList()
        let p1 = PullFilesPage(j(#"{"pr":{"headSha":"h1","body":"first"},"files":[{"filename":"a"},{"filename":"a","status":"dup"},{"filename":"b"}],"nextPage":2,"truncated":true}"#))!
        let p2 = PullFilesPage(j(#"{"pr":{"headSha":"h2","body":"second"},"files":[{"filename":"b"},{"filename":"c"}],"nextPage":null,"truncated":false}"#))!
        l.append(p1)
        XCTAssertEqual(l.files.count, 2); XCTAssertNil(l.files[0].status); XCTAssertEqual(l.nextPage, 2); XCTAssertTrue(l.truncated)
        XCTAssertEqual(l.files[1].filename, "b")
        l.append(p2)
        XCTAssertEqual(l.files.map(\.filename), ["a", "b", "c"]); XCTAssertNil(l.nextPage); XCTAssertFalse(l.truncated)
        XCTAssertEqual(l.pr["body"].string, "first")
    }
    func testPullFileListConfirmNeedsTheSameRevision() {
        var l = PullFileList(j(#"{"pr":{"headSha":"h1","body":"old"},"files":[{"filename":"a"}],"nextPage":null,"truncated":true}"#))!
        // Neither side has a base: still the same revision.
        XCTAssertTrue(l.confirm(PullFilesPage(j(#"{"pr":{"headSha":"h1","body":"new"},"files":[{"filename":"z"}],"nextPage":2,"truncated":false}"#))!))
        XCTAssertEqual(l.pr["body"].string, "new")
        XCTAssertEqual(l.files.map(\.filename), ["a"]); XCTAssertNil(l.nextPage); XCTAssertTrue(l.truncated)
        for other in [#"{"pr":{"headSha":"h1","baseSha":"b"},"files":[]}"#, #"{"pr":{},"files":[]}"#, #"{"files":[]}"#, #"{"pr":{"headSha":"H1"},"files":[]}"#] {
            XCTAssertFalse(l.confirm(PullFilesPage(j(other))!), other)
            XCTAssertEqual(l.pr["body"].string, "new")
        }
    }

    // MARK: - Dates

    func testBoardDateParseReadsUTCAndOffsets() {
        let cases: [(String, Int)] = [
            ("1970-01-01T00:00:00Z", 0), ("2026-09-28T15:55:49Z", 1790610949), ("2026-09-28T15:55:49.120Z", 1790610949),
            ("2026-09-28T15:55:49,5Z", 1790610949), ("2026-09-28T15:55:49.123456789Z", 1790610949), ("2026-09-28t15:55:49z", 1790610949),
            ("2026-09-28 15:55:49Z", 1790610949), ("2026-09-28T15:55Z", 1790610900), ("2026-09-28T17:55:49+02:00", 1790610949),
            ("2026-09-28T17:55:49+0200", 1790610949), ("2026-09-28T17:55:49+02", 1790610949), ("2026-09-28T14:25:49-01:30", 1790610949),
            ("2026-09-28T15:55:49.5-00:00", 1790610949), ("2000-02-29T12:00:00Z", 951825600), ("2000-03-01T00:00:00Z", 951868800),
            ("2100-03-01T00:00:00Z", 4107542400), ("1969-12-31T23:59:59Z", -1), ("1900-01-01T00:00:00Z", -2208988800),
        ]
        for (text, epoch) in cases {
            XCTAssertEqual(boardDateEpoch(text), epoch, text)
            XCTAssertEqual(boardDateParse(text)?.timeIntervalSince1970, TimeInterval(epoch), text)
        }
    }
    func testBoardDateParseRejectsWhatIsNotATimestamp() {
        let bad: [String?] = [
            nil, "", "2026-09-28", "2026-09-28T", "2026-09-28T15:55:49", "2026-09-28T15:55:49 Z", "2026-09-28T15:55:49Zx",
            "2026-9-28T15:55:49Z", "26-09-28T15:55:49Z", "2026/09/28T15:55:49Z", "2026-09-28X15:55:49Z", "2026-09-28T15-55-49Z",
            "2026-09-28T15:55:4Z", "2026-09-28T15:55:49.Z", "2026-09-28T15:55:49+2", "2026-09-28T15:55:49+02:0",
            "2026-00-28T15:55:49Z", "2026-13-28T15:55:49Z", "2026-09-00T15:55:49Z", "2026-09-32T15:55:49Z",
            "2026-09-28T24:00:00Z", "2026-09-28T15:60:00Z", "2026-09-28T15:55:61Z", "Mon, 28 Sep 2026 15:55:49 GMT",
        ]
        for b in bad { XCTAssertNil(boardDateParse(b), b ?? "(nil)") }
        // A leap second is read, landing on the next minute.
        XCTAssertEqual(boardDateEpoch("2016-12-31T23:59:60Z"), 1483228800)
    }
}
