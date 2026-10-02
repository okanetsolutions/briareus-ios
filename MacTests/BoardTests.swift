// Ported from the Windows client's tests/core_board_tests.c: labels, links, pull request and issue rows, filters, errands,
// merge warnings, reviews, stacks and ▶ Run.
import XCTest
@testable import BriareusMacCore

final class BoardTests: XCTestCase {
    private func pull(_ text: String) -> PullSummary? { PullSummary(j(text)) }
    private func issue(_ text: String) -> IssueSummary? { IssueSummary(j(text)) }
    private func link(_ text: String) -> BoardLink? { BoardLink(j(text)) }
    private func rgb(_ color: String?) -> (red: Int, green: Int, blue: Int)? { PullLabel(name: "x", color: color).rgb }

    // MARK: - Labels

    func testLabelsReadFromAnObjectOrABareName() {
        var l = PullLabel(j(#"{"name":"bug","color":"d73a4a"}"#))!
        XCTAssertEqual(l.name, "bug"); XCTAssertEqual(l.color, "d73a4a")
        l = PullLabel(j(#""backend""#))!; XCTAssertEqual(l.name, "backend"); XCTAssertNil(l.color)
        XCTAssertNil(PullLabel(j(#"{"name":"x","color":7}"#))!.color)
        for bad in [#"{"color":"ffffff"}"#, #"{"name":""}"#, #""""#, #"{"name":3}"#, "12", "null"] { XCTAssertNil(PullLabel(j(bad)), bad) }
    }
    func testLabelColoursReadAsSixHexDigits() {
        XCTAssertTrue(rgb("d93f0b")! == (0xd9, 0x3f, 0x0b))
        XCTAssertTrue(rgb("D93F0B")! == (0xd9, 0x3f, 0x0b))
        XCTAssertTrue(rgb("000000")! == (0, 0, 0))
        XCTAssertTrue(rgb("ffffff")! == (255, 255, 255))
        XCTAssertTrue(rgb("0a0B0c")! == (10, 11, 12))
        // GitHub sends its colours bare; anything else is not read.
        for bad in ["#d93f0b", "fff", "#fff", "gggggg", "12345z", "d93f0b0", "d93f0", "", " d93f0", nil] { XCTAssertNil(rgb(bad), bad ?? "(nil)") }
    }

    // MARK: - Links

    func testBoardLinksNeedANumberAndDefaultTheirTitle() {
        var l = link(#"{"number":4,"title":"Login","url":"https://github.com/o/r/issues/4","repo":"o/r","draft":true,"#
                     + #""state":"open","stateReason":null,"labels":[{"name":"bug"},"ui",{"color":"fff"}]}"#)!
        XCTAssertEqual(l.number, 4); XCTAssertEqual(l.title, "Login"); XCTAssertEqual(l.url, "https://github.com/o/r/issues/4"); XCTAssertEqual(l.repo, "o/r")
        XCTAssertTrue(l.draft); XCTAssertEqual(l.state, "open"); XCTAssertNil(l.stateReason)
        XCTAssertEqual(l.labels.map(\.name), ["bug", "ui"])
        l = link(#"{"number":9}"#)!
        XCTAssertEqual(l.title, "#9"); XCTAssertNil(l.url); XCTAssertNil(l.repo); XCTAssertNil(l.state); XCTAssertFalse(l.draft); XCTAssertEqual(l.labels.count, 0)
        l = link(#"{"number":9,"draft":"true","title":5}"#)!; XCTAssertFalse(l.draft); XCTAssertEqual(l.title, "#9")
        for bad in [#"{"title":"No number"}"#, #"{"number":"4"}"#, "[]"] { XCTAssertNil(link(bad), bad) }
        XCTAssertNil(BoardLink(.null))
    }
    func testBoardLinksNameTheirRepositoryOnlyWhenForeign() {
        var l = link(#"{"number":3,"repo":"acme/other"}"#)!
        XCTAssertTrue(l.isForeign("o/r")); XCTAssertEqual(l.reference("o/r"), "acme/other#3")
        XCTAssertFalse(l.isForeign("Acme/Other")); XCTAssertEqual(l.reference("ACME/OTHER"), "#3")
        XCTAssertTrue(l.isForeign(nil)); XCTAssertEqual(l.reference(nil), "acme/other#3")
        // A link that names no repository is this one's.
        l = link(#"{"number":3}"#)!
        XCTAssertFalse(l.isForeign("o/r")); XCTAssertFalse(l.isForeign(nil)); XCTAssertEqual(l.reference("o/r"), "#3")
    }
    func testBoardLinksAreNotPlannedOnlyWhenClosedAsSuch() {
        let cases: [(String, Bool)] = [
            (#"{"number":1,"state":"closed","stateReason":"not_planned"}"#, true), (#"{"number":1,"state":"closed","stateReason":"completed"}"#, false),
            (#"{"number":1,"state":"closed"}"#, false), (#"{"number":1,"state":"open","stateReason":"not_planned"}"#, false),
            (#"{"number":1,"stateReason":"not_planned"}"#, false), (#"{"number":1,"state":"CLOSED","stateReason":"NOT_PLANNED"}"#, false),
        ]
        for (text, expected) in cases { XCTAssertEqual(link(text)!.notPlanned, expected, text) }
    }

    // MARK: - Pull requests

    func testPullSummariesReadEveryField() {
        let p = pull(#"{"number":7,"title":"Add invoices","url":"https://github.com/o/r/pull/7","branch":"feat/x","baseBranch":"main","draft":true,"#
                     + #""author":"Ana","assignees":["ana",3,"luis"],"#
                     + #""reviewers":[{"user":"luis","state":"APPROVED"},{"state":"approved"},{"user":"bo"},"x"],"#
                     + #""labels":[{"name":"bug","color":"d73a4a"},"ui",{}],"#
                     + #""issues":[{"number":3,"repo":"o/r"},{"title":"none"}],"#
                     + #""mergeable":"mergeable","checks":"success","reviewDecision":"APPROVED","recommended":"run","#
                     + #""updatedAt":"2026-09-28T15:55:49Z"}"#)!
        XCTAssertEqual(p.number, 7); XCTAssertEqual(p.title, "Add invoices"); XCTAssertEqual(p.url, "https://github.com/o/r/pull/7")
        XCTAssertEqual(p.branch, "feat/x"); XCTAssertEqual(p.baseBranch, "main"); XCTAssertTrue(p.draft); XCTAssertEqual(p.author, "Ana")
        XCTAssertEqual(p.assignees, ["ana", "luis"])
        XCTAssertEqual(p.reviewers, [Reviewer(user: "luis", state: "APPROVED"), Reviewer(user: "bo", state: "")])
        XCTAssertEqual(p.labels.map(\.name), ["bug", "ui"])
        XCTAssertEqual(p.issues.map(\.number), [3])
        XCTAssertEqual(p.mergeable, "mergeable"); XCTAssertEqual(p.checks, "success"); XCTAssertEqual(p.reviewDecision, "APPROVED"); XCTAssertEqual(p.recommended, "run")
        XCTAssertNotNil(p.updatedAt)
        XCTAssertEqual(p.raw["number"].int, 7); XCTAssertEqual(p.raw["title"].string, "Add invoices")
    }
    func testPullSummariesDefaultWhatTheServerLeftOut() {
        var p = pull(#"{"number":12}"#)!
        XCTAssertEqual(p.title, "Pull request #12")
        XCTAssertNil(p.url); XCTAssertNil(p.author); XCTAssertNil(p.checks); XCTAssertNil(p.reviewDecision); XCTAssertNil(p.recommended)
        // Branches are never nil, and GitHub's merge answer is unknown until it says.
        XCTAssertEqual(p.branch, ""); XCTAssertEqual(p.baseBranch, ""); XCTAssertEqual(p.mergeable, "unknown")
        XCTAssertFalse(p.draft); XCTAssertNil(p.updatedAt)
        XCTAssertTrue(p.assignees.isEmpty && p.reviewers.isEmpty && p.labels.isEmpty && p.issues.isEmpty)
        XCTAssertFalse(p.conflicting || p.hasConflicts || p.checksFailed || p.awaitsFeedback)
        p = pull(#"{"number":12,"title":null,"branch":4,"draft":"true","mergeable":false,"updatedAt":"yesterday","reviewers":{"user":"x"}}"#)!
        XCTAssertEqual(p.title, "Pull request #12"); XCTAssertEqual(p.branch, ""); XCTAssertFalse(p.draft); XCTAssertEqual(p.mergeable, "unknown"); XCTAssertNil(p.updatedAt)
        XCTAssertEqual(p.reviewers.count, 0)
        XCTAssertEqual(pull(#"{"number":7.9}"#)?.number, 7)
    }
    func testPullSummariesWithoutAPositiveNumberAreRejected() {
        for bad in [#"{"title":"x"}"#, #"{"number":0}"#, #"{"number":-3}"#, #"{"number":"7"}"#, #"{"number":null}"#, "[7]"] { XCTAssertNil(pull(bad), bad) }
        XCTAssertNil(PullSummary(.null))
    }
    func testPullSummaryListsKeepOnlyValidRows() {
        XCTAssertEqual(PullSummary.parseList(j(#"[{"number":1},{"number":0},"x",null,{"title":"t"},{"number":2},3]"#)).map(\.number), [1, 2])
        XCTAssertEqual(PullSummary.parseList(j("[]")).count, 0)
        XCTAssertEqual(PullSummary.parseList(j(#"{"number":1}"#)).count, 0)
        XCTAssertEqual(PullSummary.parseList(.null).count, 0)
    }
    func testPullPredicatesReadMergeableChecksAndLabels() {
        let cases: [(String, Bool, Bool, Bool, Bool)] = [
            (#"{"number":1,"mergeable":"conflicting"}"#, true, true, false, false),
            (#"{"number":1,"mergeable":"CONFLICTING"}"#, false, false, false, false),
            (#"{"number":1,"mergeable":"mergeable"}"#, false, false, false, false),
            (#"{"number":1,"mergeable":"unknown","labels":["HAS-CONFLICTS"]}"#, false, true, false, false),
            (#"{"number":1,"labels":[{"name":"has-conflicts-maybe"}]}"#, false, false, false, false),
            (#"{"number":1,"checks":"failure"}"#, false, false, true, false),
            (#"{"number":1,"checks":"error"}"#, false, false, true, false),
            (#"{"number":1,"checks":"pending"}"#, false, false, false, false),
            (#"{"number":1,"checks":"expected"}"#, false, false, false, false),
            (#"{"number":1,"checks":"success"}"#, false, false, false, false),
            (#"{"number":1,"checks":"FAILURE"}"#, false, false, false, false),
            (#"{"number":1,"labels":["Feedback-Given"]}"#, false, false, false, true),
            (#"{"number":1,"labels":["feedback"]}"#, false, false, false, false),
        ]
        for (text, conflicting, conflicts, failed, feedback) in cases {
            let p = pull(text)!
            XCTAssertEqual(p.conflicting, conflicting, text); XCTAssertEqual(p.hasConflicts, conflicts, text)
            XCTAssertEqual(p.checksFailed, failed, text); XCTAssertEqual(p.awaitsFeedback, feedback, text)
        }
    }

    // MARK: - Issues

    func testIssueSummariesReadEveryField() {
        let i = issue(#"{"number":20,"title":"Child","url":"https://github.com/o/r/issues/20","author":"ana","milestone":"v2","#
                      + #""assignees":["luis"],"labels":["bug"],"comments":4,"updatedAt":"2026-09-28T15:55:49Z","#
                      + #""parent":{"number":21,"title":"Epic","repo":"o/r"},"subIssues":{"total":2,"completed":1},"#
                      + #""pulls":[{"number":8,"draft":true},{"title":"no number"}]}"#)!
        XCTAssertEqual(i.number, 20); XCTAssertEqual(i.title, "Child"); XCTAssertEqual(i.url, "https://github.com/o/r/issues/20"); XCTAssertEqual(i.author, "ana")
        XCTAssertEqual(i.milestone, "v2"); XCTAssertEqual(i.assignees.count, 1); XCTAssertEqual(i.labels.count, 1); XCTAssertEqual(i.comments, 4)
        XCTAssertNotNil(i.updatedAt); XCTAssertNil(i.createdAt)
        XCTAssertEqual(i.parent?.number, 21); XCTAssertEqual(i.parent?.title, "Epic")
        XCTAssertEqual(i.subIssues, 2); XCTAssertEqual(i.subIssuesDone, 1); XCTAssertTrue(i.isEpic)
        XCTAssertEqual(i.pulls.count, 1); XCTAssertTrue(i.pulls[0].draft)
    }
    func testIssueSummariesReadWhenTheyWereOpened() {
        let i = issue(#"{"number":3,"createdAt":"2026-09-28T15:55:49Z","updatedAt":"2026-09-30T10:00:00Z"}"#)!
        XCTAssertLessThan(i.createdAt!, i.updatedAt!)
        XCTAssertNil(issue(#"{"number":3,"createdAt":"yesterday"}"#)!.createdAt)
    }
    func testIssueOpenSubIssuesAreTheEpicsChildrenHere() {
        let issues = IssueSummary.parseList(j(#"[{"number":1,"subIssues":{"total":4,"completed":1}},"#
            + #"{"number":2,"parent":{"number":1,"repo":"o/r"}},{"number":3,"parent":{"number":9}},"#
            + #"{"number":4,"parent":{"number":1,"repo":"other/repo"}},{"number":5,"parent":{"number":1}}]"#))
        XCTAssertEqual(issues.count, 5)
        // #4 has a parent numbered 1 in another repository, which is not this epic.
        XCTAssertEqual(issueOpenSubIssues(issues, epic: 1, repo: "o/r").map { issues[$0].number }, [2, 5])
        XCTAssertEqual(issueOpenSubIssues(issues, epic: 2, repo: "o/r"), [])
        XCTAssertEqual(issueOpenSubIssues([], epic: 1, repo: "o/r"), [])
        XCTAssertEqual(issuesFind(issues, 3), issues[2]); XCTAssertNil(issuesFind(issues, 7))
    }
    func testPullsFindByNumber() {
        let pulls = PullSummary.parseList(j(#"[{"number":8,"title":"a"},{"number":9,"title":"b"}]"#))
        XCTAssertEqual(pullsFind(pulls, 9), pulls[1]); XCTAssertNil(pullsFind(pulls, 4)); XCTAssertNil(pullsFind([], 9))
    }
    func testIssueSummariesDefaultWhatTheServerLeftOut() {
        var i = issue(#"{"number":5}"#)!
        XCTAssertEqual(i.title, "Issue #5"); XCTAssertNil(i.url); XCTAssertNil(i.author); XCTAssertNil(i.milestone)
        XCTAssertEqual(i.comments, 0); XCTAssertNil(i.updatedAt); XCTAssertNil(i.parent); XCTAssertEqual(i.subIssues, 0); XCTAssertEqual(i.subIssuesDone, 0)
        XCTAssertTrue(i.assignees.isEmpty && i.labels.isEmpty && i.pulls.isEmpty); XCTAssertFalse(i.isEpic)
        // A parent without a number is no parent; counts of the wrong type read as none.
        i = issue(#"{"number":5,"parent":{"title":"Epic"},"comments":"4","subIssues":{"total":"3"}}"#)!
        XCTAssertNil(i.parent); XCTAssertEqual(i.comments, 0); XCTAssertEqual(i.subIssues, 0)
        i = issue(#"{"number":5,"parent":null,"subIssues":{"total":0,"completed":0}}"#)!
        XCTAssertNil(i.parent); XCTAssertFalse(i.isEpic)
        XCTAssertEqual(issue(#"{"number":5,"parent":{"number":6}}"#)?.parent?.title, "#6")
        for bad in [#"{"title":"x"}"#, #"{"number":0}"#, #"{"number":-1}"#, #"{"number":"5"}"#] { XCTAssertNil(issue(bad), bad) }
        XCTAssertEqual(IssueSummary.parseList(j(#"[{"number":1},{"number":0},"x",{"number":2}]"#)).map(\.number), [1, 2])
        XCTAssertEqual(IssueSummary.parseList(.null).count, 0)
    }
    private func nested(_ text: String, _ repo: String) -> String {
        let issues = IssueSummary.parseList(j(text))
        let rows = issuesNested(issues, repo: repo)
        var s = rows.map { "\(issues[$0.index].number):\($0.depth)" }.joined(separator: ",")
        if rows.count != issues.count { s += " (\(rows.count) rows for \(issues.count) issues)" }
        return s
    }
    func testIssuesNestDepthFirstUnderEpicsOnTheList() {
        // Children listed before their epic still follow it, in list order, however deep.
        XCTAssertEqual(nested(#"[{"number":3,"parent":{"number":2}},{"number":4,"parent":{"number":1}},{"number":1},"#
                              + #"{"number":2,"parent":{"number":1}},{"number":5}]"#, "o/r"), "1:0,4:1,2:1,3:2,5:0")
        // The parent named in this repository's other case is still this one's.
        XCTAssertEqual(nested(#"[{"number":1},{"number":2,"parent":{"number":1,"repo":"O/R"}}]"#, "o/r"), "1:0,2:1")
        // A parent elsewhere, one not on the list, and an issue its own parent stay flat.
        XCTAssertEqual(nested(#"[{"number":1},{"number":2,"parent":{"number":1,"repo":"acme/other"}},"#
                              + #"{"number":3,"parent":{"number":99}},{"number":4,"parent":{"number":4}}]"#, "o/r"), "1:0,2:0,3:0,4:0")
        XCTAssertEqual(nested("[]", "o/r"), "")
    }
    func testIssuesInACycleAreEachDrawnOnce() {
        XCTAssertEqual(nested(#"[{"number":1,"parent":{"number":3}},{"number":2,"parent":{"number":1}},{"number":3,"parent":{"number":2}}]"#, "o/r"), "1:0,2:1,3:2")
        XCTAssertEqual(nested(#"[{"number":9},{"number":1,"parent":{"number":2}},{"number":2,"parent":{"number":1}},{"number":5,"parent":{"number":2}}]"#, "o/r"),
                       "9:0,1:0,2:1,5:2")
    }
    func testIssuePromptsNameTheIssueItsEpicAndHowToCloseIt() {
        var p = issuePrompt(issue(#"{"number":20,"title":"Child"}"#)!, repo: "o/r")
        XCTAssertTrue(p.hasPrefix("Issue #20: Child\n\n"))
        XCTAssertTrue(p.contains("Read o/r issue #20 in full"))
        XCTAssertTrue(p.contains("`gh issue view 20 --repo o/r --comments`"))
        XCTAssertFalse(p.contains("sub-issue"))
        XCTAssertTrue(p.contains("this session\u{2019}s own branch"))
        XCTAssertTrue(p.contains("`Closes #20`"))
        XCTAssertTrue(p.hasSuffix("say what is missing and stop rather than guessing at it."))
        XCTAssertTrue(issuePrompt(issue(#"{"number":5}"#)!, repo: "o/r").hasPrefix("Issue #5: Issue #5\n"))
        // An epic named without a repository, or in this one's other case, is read here.
        p = issuePrompt(issue(#"{"number":20,"title":"Child","parent":{"number":21}}"#)!, repo: "o/r")
        XCTAssertTrue(p.contains("It is a sub-issue of o/r#21 (#21). Read that epic too"))
        p = issuePrompt(issue(#"{"number":20,"title":"Child","parent":{"number":21,"title":"Epic","repo":"O/R"}}"#)!, repo: "o/r")
        XCTAssertTrue(p.contains("sub-issue of o/r#21 (Epic)"))
        p = issuePrompt(issue(#"{"number":20,"title":"Child","parent":{"number":21,"title":"Theirs","repo":"acme/other"}}"#)!, repo: "o/r")
        XCTAssertTrue(p.contains("sub-issue of acme/other#21 (Theirs)")); XCTAssertTrue(p.contains("`Closes #20`"))
    }

    // MARK: - Rows and filters

    func testBoardRowsCarryWhatThePickersFilterOn() {
        let p = pull(#"{"number":1,"author":"ana","reviewers":[{"user":"luis"}],"labels":["bug","ui"]}"#)!
        var r = BoardRow(p)
        XCTAssertEqual(r.author, p.author); XCTAssertEqual(r.reviewers, p.reviewers); XCTAssertEqual(r.labels, p.labels)
        let i = issue(#"{"number":2,"author":"bo","assignees":["x"],"labels":["bug"]}"#)!
        r = BoardRow(i)
        XCTAssertEqual(r.author, i.author); XCTAssertEqual(r.reviewers, []); XCTAssertEqual(r.labels, i.labels)
    }
    func testBoardFiltersKeepTheirPicksFolded() {
        var f = BoardFilter()
        XCTAssertEqual(f[.author], ""); XCTAssertEqual(f[.reviewer], ""); XCTAssertEqual(f[.label], ""); XCTAssertFalse(f.isOn)
        f[.author] = "TheBot"; XCTAssertEqual(f[.author], "thebot"); XCTAssertTrue(f.isOn)
        f[.reviewer] = "Ana"; XCTAssertEqual(f[.reviewer], "ana")
        f[.label] = "Has-Conflicts"; XCTAssertEqual(f[.label], "has-conflicts")
        f.set(.author, nil); XCTAssertEqual(f[.author], "")
        f[.reviewer] = ""; f[.label] = ""
        XCTAssertFalse(f.isOn)
        f[.label] = "x"; XCTAssertTrue(f.isOn)
        XCTAssertEqual(FilterKind.author.name, "author"); XCTAssertEqual(FilterKind.reviewer.name, "reviewer"); XCTAssertEqual(FilterKind.label.name, "label")
    }
    func testBoardFilterCopiesCompareEqual() {
        var a = BoardFilter(); a[.author] = "Ana"; a[.label] = "bug"
        var b = a
        XCTAssertEqual(a, b)
        a[.author] = "luis"
        XCTAssertNotEqual(a, b); XCTAssertEqual(b[.author], "ana")
        b[.author] = "LUIS"; XCTAssertEqual(a, b)
        b[.reviewer] = "x"; XCTAssertNotEqual(a, b)
        b[.reviewer] = ""; b[.label] = "ui"; XCTAssertNotEqual(a, b)
    }

    // Three pull requests and two issues the filter tests share.
    private let filterPulls = #"[{"number":1,"author":"Ana","reviewers":[{"user":"luis"},{"user":"Bo"}],"labels":["bug","UI","Bug"]},"#
        + #"{"number":2,"author":"luis","reviewers":[{"user":"ana"}],"labels":["backend"]},"#
        + #"{"number":3,"author":"ana","reviewers":[{"user":"LUIS"}],"labels":["bug"]},"#
        + #"{"number":4,"labels":["zeta","alpha"]}]"#
    private func rows() -> (pulls: [PullSummary], rows: [BoardRow]) {
        let pulls = PullSummary.parseList(j(filterPulls))
        return (pulls, pulls.map(BoardRow.init))
    }
    private func passing(_ f: BoardFilter, _ r: (pulls: [PullSummary], rows: [BoardRow]), _ skipping: FilterKind? = nil) -> String {
        r.rows.indices.filter { f.passes(r.rows[$0], skipping: skipping) }.map { String(r.pulls[$0].number) }.joined(separator: ",")
    }
    private func options(_ f: BoardFilter, _ kind: FilterKind, _ rows: [BoardRow]) -> String {
        f.options(kind, rows: rows).map { "\($0.value)=\($0.text) \($0.count)" }.joined(separator: ",")
    }
    func testBoardFiltersPassRowsFoldingCase() {
        let r = rows()
        var f = BoardFilter()
        XCTAssertEqual(passing(f, r), "1,2,3,4")
        f[.author] = "ANA"; XCTAssertEqual(passing(f, r), "1,3")
        f[.reviewer] = "luis"; XCTAssertEqual(passing(f, r), "1,3")
        f[.label] = "ui"; XCTAssertEqual(passing(f, r), "1")
        // Skipping a picker leaves it out of the test; the others still apply.
        XCTAssertEqual(passing(f, r, .label), "1,3")
        XCTAssertEqual(passing(f, r, .author), "1")
        f[.author] = "luis"; XCTAssertEqual(passing(f, r), "")
        XCTAssertEqual(passing(f, r, .author), "1")
        // A row without an author never matches an author pick.
        f[.reviewer] = ""; f[.label] = ""; f[.author] = "x"
        XCTAssertEqual(passing(f, r), "")
    }
    func testBoardFilterOptionsAreCountedAgainstTheOtherPickers() {
        let r = rows().rows
        var f = BoardFilter()
        // Case variants fold into one option named as first seen; a label twice on one row counts once; sorted ignoring case.
        XCTAssertEqual(options(f, .author, r), "ana=Ana 2,luis=luis 1")
        XCTAssertEqual(options(f, .reviewer, r), "ana=ana 1,bo=Bo 1,luis=luis 2")
        XCTAssertEqual(options(f, .label, r), "alpha=alpha 1,backend=backend 1,bug=bug 2,ui=UI 1,zeta=zeta 1")
        f[.author] = "ana"
        // The author picker still counts every author; the others count only Ana's rows.
        XCTAssertEqual(options(f, .author, r), "ana=Ana 2,luis=luis 1")
        XCTAssertEqual(options(f, .label, r), "bug=bug 2,ui=UI 1")
        XCTAssertEqual(options(f, .reviewer, r), "bo=Bo 1,luis=luis 2")
        f[.label] = "UI"
        XCTAssertEqual(options(f, .author, r), "ana=Ana 1")
        XCTAssertEqual(options(f, .reviewer, r), "bo=Bo 1,luis=luis 1")
    }
    func testAPickTheOthersEmptyStillListsItself() {
        let r = rows().rows
        var f = BoardFilter()
        f[.author] = "luis"; f[.label] = "UI"
        XCTAssertEqual(options(f, .label, r), "backend=backend 1,ui=ui 0")
        XCTAssertEqual(options(f, .author, r), "ana=Ana 1,luis=luis 0")
        // A pick nobody carries, or a board with no rows, lists only the pick.
        f[.author] = "Ghost"
        XCTAssertEqual(options(f, .author, []), "ghost=ghost 0")
        f[.author] = ""; f[.label] = ""
        XCTAssertEqual(options(f, .author, []), "")
        XCTAssertEqual(f.options(.label, rows: []).count, 0)
    }
    func testIssueRowsOfferNoReviewers() {
        let rows = IssueSummary.parseList(j(#"[{"number":1,"author":"ana","labels":["bug"]},{"number":2,"author":"bo"}]"#)).map(BoardRow.init)
        var f = BoardFilter()
        XCTAssertEqual(options(f, .reviewer, rows), "")
        XCTAssertEqual(options(f, .author, rows), "ana=ana 1,bo=bo 1")
        f[.reviewer] = "luis"
        XCTAssertFalse(f.passes(rows[0])); XCTAssertTrue(f.passes(rows[0], skipping: .reviewer))
        XCTAssertEqual(options(f, .reviewer, rows), "luis=luis 0")
    }
    func testTheBoardOpensOnTheAuthorOnlyWhileTheyHaveRows() {
        let r = rows().rows
        var f = BoardFilter.opening(author: "ANA", rows: r)
        XCTAssertEqual(f[.author], "ana"); XCTAssertEqual(f[.reviewer], ""); XCTAssertEqual(f[.label], "")
        f = BoardFilter.opening(author: "luis", rows: r); XCTAssertEqual(f[.author], "luis")
        // Reviewing is not authoring.
        f = BoardFilter.opening(author: "Bo", rows: r); XCTAssertFalse(f.isOn); XCTAssertEqual(f[.author], "")
        XCTAssertFalse(BoardFilter.opening(author: "", rows: r).isOn)
        XCTAssertFalse(BoardFilter.opening(author: "ana", rows: []).isOn)
        XCTAssertFalse(BoardFilter.opening(author: nil, rows: r).isOn)
    }

    // MARK: - Actions

    private func ids(_ a: [BoardAction]) -> String { a.map(\.id).joined(separator: ",") }
    private func offered(_ catalog: String?, _ pullText: String?, _ failedChecks: Int) -> String {
        ids(BoardAction.offered(catalog: catalog.map { j($0) } ?? .null, pull: pullText.flatMap(pull), failedChecks: failedChecks))
    }
    private func known(_ id: String) -> BoardAction? { BoardAction.known.first { $0.id == id } }

    func testKnownErrandsAreListedInTheDashboardsOrder() {
        let k = BoardAction.known
        XCTAssertEqual(ids(k), "run,review,solve-conflicts,fix-checks,implement-feedback,custom-feedback,pr-body-summary,delete-self-comments")
        for a in k { XCTAssertFalse(a.label.isEmpty); XCTAssertFalse(a.hint.isEmpty); XCTAssertEqual(a.input != nil, a.id == "custom-feedback") }
        let feedback = known("custom-feedback")!
        XCTAssertEqual(feedback.label, "Give feedback")
        XCTAssertEqual(feedback.input, ActionInput(label: "Your feedback", placeholder: "What should change on this pull request?", required: true))
        XCTAssertEqual(known("run")?.label, "Run"); XCTAssertEqual(known("review")?.label, "Code review")
        // QA and the test sheet were removed (#12).
        XCTAssertNil(known("qa")); XCTAssertNil(known("test-sheet")); XCTAssertNil(known("test-run"))
    }
    func testErrandsStartThroughTheirOwnOperation() {
        // Since /api/v1 (#26) every errand but Run and Code review goes through `action`, not an operation named after it.
        for a in BoardAction.known {
            XCTAssertEqual(a.operation, a.id == "run" ? "serve_pull" : a.id == "review" ? "review" : "action")
            XCTAssertEqual(a.timeoutMs, a.id == "run" ? 170_000 : nil)
        }
        let served = BoardAction(id: "label-pull", label: "Label it")
        XCTAssertEqual(served.operation, "action"); XCTAssertNil(served.timeoutMs)
    }
    func testErrandArgumentsTakeTheShapeEachRouteWants() {
        var a = known("run")!.arguments(repo: "o/r", number: 9, branch: "feat/x", input: "ignored")
        XCTAssertEqual(a.count, 2); XCTAssertEqual(a["repo"].string, "o/r"); XCTAssertEqual(a["prNumber"].int, 9)
        XCTAssertTrue(a["branch"].isNull); XCTAssertTrue(a["action"].isNull)
        a = known("review")!.arguments(repo: "o/r", number: 9, branch: "feat/x")
        XCTAssertEqual(a.count, 3); XCTAssertEqual(a["branch"].string, "feat/x")
        a = known("review")!.arguments(repo: "o/r", number: 9)
        XCTAssertEqual(a.count, 2); XCTAssertTrue(a["action"].isNull)
        for errand in ["solve-conflicts", "fix-checks", "implement-feedback", "pr-body-summary", "delete-self-comments"] {
            // Errands look the pull request up by number, so the branch is not sent, nor input they do not take.
            a = known(errand)!.arguments(repo: "o/r", number: 9, branch: "feat/x", input: "text")
            XCTAssertEqual(a.count, 3); XCTAssertEqual(a["action"].string, errand)
            XCTAssertTrue(a["branch"].isNull); XCTAssertTrue(a["input"].isNull)
        }
        let feedback = known("custom-feedback")!
        a = feedback.arguments(repo: "o/r", number: 9, branch: "feat/x", input: "\t Use 404 \r\n")
        XCTAssertEqual(a.count, 4); XCTAssertEqual(a["action"].string, "custom-feedback"); XCTAssertEqual(a["input"].string, "Use 404")
        a = feedback.arguments(repo: "o/r", number: 9, input: " \n\t ")
        XCTAssertEqual(a.count, 3); XCTAssertTrue(a["input"].isNull)
        XCTAssertEqual(feedback.arguments(repo: "o/r", number: 9).count, 3)
        XCTAssertEqual(feedback.arguments(repo: "o/r", number: 9, input: "line one\nline two")["input"].string, "line one\nline two")
    }
    func testErrandsAreOfferedForTheStateAPullRequestIsIn() {
        let always = "run,review,custom-feedback,pr-body-summary,delete-self-comments"
        XCTAssertEqual(offered(nil, #"{"number":1,"mergeable":"mergeable","checks":"success"}"#, 0), always)
        // A draft is offered the same errands.
        XCTAssertEqual(offered(nil, #"{"number":1,"draft":true}"#, 0), always)
        XCTAssertEqual(offered(nil, #"{"number":1,"mergeable":"conflicting"}"#, 0), "run,review,solve-conflicts,custom-feedback,pr-body-summary,delete-self-comments")
        XCTAssertEqual(offered(nil, #"{"number":1,"labels":["Has-Conflicts"]}"#, 0), "run,review,solve-conflicts,custom-feedback,pr-body-summary,delete-self-comments")
        XCTAssertEqual(offered(nil, #"{"number":1,"checks":"error"}"#, 0), "run,review,fix-checks,custom-feedback,pr-body-summary,delete-self-comments")
        // A run still going has nothing to fix; a count of failed checks from the Checks tab outweighs the summary.
        XCTAssertEqual(offered(nil, #"{"number":1,"checks":"pending"}"#, 0), always)
        XCTAssertEqual(offered(nil, #"{"number":1,"checks":"success"}"#, 2), "run,review,fix-checks,custom-feedback,pr-body-summary,delete-self-comments")
        XCTAssertEqual(offered(nil, #"{"number":1}"#, -1), always)
        XCTAssertEqual(offered(nil, #"{"number":1,"labels":["FEEDBACK-GIVEN"]}"#, 0), "run,review,implement-feedback,custom-feedback,pr-body-summary,delete-self-comments")
        XCTAssertEqual(offered(nil, #"{"number":1,"mergeable":"conflicting","checks":"failure","labels":["feedback-given"]}"#, 0),
                       "run,review,solve-conflicts,fix-checks,implement-feedback,custom-feedback,pr-body-summary,delete-self-comments")
        // Without a pull request, everything but fixing checks nobody has seen fail.
        XCTAssertEqual(offered(nil, nil, 0), "run,review,solve-conflicts,implement-feedback,custom-feedback,pr-body-summary,delete-self-comments")
        XCTAssertEqual(offered(nil, nil, 1), "run,review,solve-conflicts,fix-checks,implement-feedback,custom-feedback,pr-body-summary,delete-self-comments")
    }
    func testAKnownCatalogRestrictsErrandsToThoseItLists() {
        let conflicted = #"{"number":1,"mergeable":"conflicting","checks":"failure","labels":["feedback-given"]}"#
        let all = "run,review,solve-conflicts,fix-checks,implement-feedback,custom-feedback,pr-body-summary,delete-self-comments"
        // An empty catalog, or one with nothing readable in it, is not known yet.
        XCTAssertEqual(offered("[]", conflicted, 0), all)
        XCTAssertEqual(offered(#"[{"id":"pr-body-summary"},{"label":"x"},"y"]"#, conflicted, 0), all)
        XCTAssertEqual(offered(#"{"id":"pr-body-summary","label":"PR body"}"#, #"{"number":1}"#, 0), "run,review,custom-feedback,pr-body-summary,delete-self-comments")
        // Run and Code review have routes of their own and stay.
        XCTAssertEqual(offered(#"[{"id":"pr-body-summary","label":"PR body"}]"#, conflicted, 0), "run,review,pr-body-summary")
        // Listed is not enough: the pull request has to be in the state for it.
        XCTAssertEqual(offered(#"[{"id":"solve-conflicts","label":"S"},{"id":"fix-checks","label":"F"},{"id":"implement-feedback","label":"I"}]"#, #"{"number":1}"#, 0), "run,review")
        XCTAssertEqual(offered(#"[{"id":"implement-feedback","label":"I"},{"id":"solve-conflicts","label":"S"}]"#, conflicted, 0), "run,review,solve-conflicts,implement-feedback")
    }
    func testErrandsTheAppDoesNotKnowFollowInTheServersOrder() {
        let catalog = #"[{"id":"zz-last","label":"Z"},{"id":"run","label":"Serve"},{"id":"qa","label":"QA"},{"id":"test-sheet","label":"Sheet"},"#
            + #"{"id":"test-run","label":"Run sheet"},{"id":"aa-first","label":"A","hint":"Does a","input":{"label":"Why?"}},"#
            + #"{"id":"zz-last","label":"Z again","hint":"later wins"}]"#
        let a = BoardAction.offered(catalog: j(catalog), pull: nil, failedChecks: 0)
        // QA, the test sheet and its run stay gone even when the server lists them (#12).
        XCTAssertEqual(ids(a), "run,review,zz-last,aa-first")
        guard a.count == 4 else { return }
        // The app words its own errands; the server's label for one it knows is not used.
        XCTAssertEqual(a[0].label, "Run"); XCTAssertNil(a[0].input)
        XCTAssertEqual(a[2].label, "Z again"); XCTAssertEqual(a[2].hint, "later wins"); XCTAssertNil(a[2].input)
        XCTAssertEqual(a[3].label, "A"); XCTAssertEqual(a[3].hint, "Does a")
        XCTAssertEqual(a[3].input, ActionInput(label: "Why?", placeholder: "", required: false))
        XCTAssertEqual(a[3].operation, "action")
        var args = a[3].arguments(repo: "o/r", number: 4, branch: "b", input: " because ")
        XCTAssertEqual(args.count, 4); XCTAssertEqual(args["action"].string, "aa-first"); XCTAssertEqual(args["input"].string, "because")
        args = a[2].arguments(repo: "o/r", number: 4, branch: "b", input: "nothing to take it")
        XCTAssertEqual(args.count, 3); XCTAssertEqual(args["action"].string, "zz-last")
    }
    func testTheServerWordsTheQuestionAnErrandAsks() {
        let c = j(#"[{"id":"custom-feedback","label":"Feedback","input":{"label":"Tell it","placeholder":"e.g. rename","required":false}},"#
                  + #"{"id":"pr-body-summary","label":"PR body","input":{"label":"Tone?","required":true}},"#
                  + #"{"id":"delete-self-comments","label":"Delete","input":{"placeholder":"no label"}}]"#)
        let a = BoardAction.offered(catalog: c, pull: nil, failedChecks: 0)
        XCTAssertEqual(ids(a), "run,review,custom-feedback,pr-body-summary,delete-self-comments")
        if a.count == 5 {
            XCTAssertEqual(a[2].label, "Give feedback")
            XCTAssertEqual(a[2].input, ActionInput(label: "Tell it", placeholder: "e.g. rename", required: false))
            XCTAssertEqual(a[3].input, ActionInput(label: "Tone?", placeholder: "", required: true))
            // An input without a label is no input.
            XCTAssertNil(a[4].input)
        }
        // Before the catalog is known, the app's own wording.
        for b in BoardAction.offered(catalog: .null, pull: nil, failedChecks: 0) where b.id == "custom-feedback" {
            XCTAssertEqual(b.input?.required, true); XCTAssertEqual(b.input?.label, "Your feedback")
        }
    }
    func testAnErrandTheServerListsWithoutAQuestionKeepsTheAppsOwn() {
        let a = BoardAction.offered(catalog: j(#"[{"id":"custom-feedback","label":"Give feedback"}]"#), pull: nil, failedChecks: 0)
        let feedback = a.first { $0.id == "custom-feedback" }
        XCTAssertEqual(feedback?.input?.required, true); XCTAssertEqual(feedback?.input?.label, "Your feedback")
    }

    // MARK: - Merge warnings

    private func warnings(_ mergeable: String?, _ state: String?) -> String {
        mergeWarnings(mergeable: mergeable.map { j($0) } ?? .null, state: state).joined(separator: "|")
    }
    func testMergeWarningsCoverEveryMergeableState() {
        let conflicts = "This branch has conflicts that must be resolved before it can merge."
        let checking = "GitHub is still checking whether this branch can merge."
        let blocked = "GitHub reports this pull request as blocked: a required review or check is missing."
        let behind = "This branch is behind its base branch and may need updating before it can merge."
        for quiet in ["clean", "unstable", "has_hooks", "dirty", "draft", "unknown", "closed", "merged", "BLOCKED", "Behind", "", nil] {
            XCTAssertEqual(warnings("true", quiet), "", quiet ?? "(nil)")
        }
        XCTAssertEqual(warnings("false", "dirty"), conflicts)
        XCTAssertEqual(warnings("null", "unknown"), checking)
        // Nothing sent is still being checked; a string is not GitHub's answer either way.
        XCTAssertEqual(warnings(nil, nil), checking)
        XCTAssertEqual(warnings(#""false""#, "clean"), "")
        XCTAssertEqual(warnings("0", "clean"), "")
        XCTAssertEqual(warnings("true", "blocked"), blocked)
        XCTAssertEqual(warnings("true", "behind"), behind)
        XCTAssertEqual(warnings("false", "behind"), "\(conflicts)|\(behind)")
        XCTAssertEqual(warnings("null", "blocked"), "\(checking)|\(blocked)")
        // Closed or merged, only a conflict still gets a word.
        XCTAssertEqual(warnings("false", "closed"), conflicts)
        XCTAssertEqual(warnings("false", "merged"), conflicts)
    }

    // MARK: - Reviews

    private func status(_ decision: String?, _ reviews: String?) -> ReviewStatus { ReviewStatus(decision: decision, reviews: reviews.map { j($0) } ?? .null) }
    func testReviewStatusWeighsTheDecisionBeforeTheReviewers() {
        XCTAssertEqual(status(nil, nil), .none)
        XCTAssertEqual(status(nil, "[]"), .none)
        XCTAssertEqual(status("", "[]"), .none)
        XCTAssertEqual(status("APPROVED", nil), .approved)
        XCTAssertEqual(status("Changes_Requested", nil), .changesRequested)
        XCTAssertEqual(status("REVIEW_REQUIRED", nil), .requested)
        // GitHub's own decision wins over what reviewers said.
        XCTAssertEqual(status("approved", #"[{"state":"CHANGES_REQUESTED"}]"#), .approved)
        XCTAssertEqual(status("changes_requested", #"[{"state":"APPROVED"}]"#), .changesRequested)
        // Without one, changes outweigh approval, approval feedback, and feedback a request.
        XCTAssertEqual(status(nil, #"[{"state":"approved"},{"state":"changes_requested"},{"state":"commented"}]"#), .changesRequested)
        XCTAssertEqual(status(nil, #"[{"state":"commented"},{"state":"APPROVED"}]"#), .approved)
        XCTAssertEqual(status(nil, #"[{"state":"requested"},{"state":"Commented"}]"#), .feedback)
        XCTAssertEqual(status("review_required", #"[{"state":"commented"}]"#), .feedback)
        XCTAssertEqual(status("review_required", #"[{"state":"approved"}]"#), .approved)
        XCTAssertEqual(status(nil, #"[{"state":"REQUESTED"}]"#), .requested)
        XCTAssertEqual(status("unknown", #"[{"state":"dismissed"},{"state":"pending"},{},{"state":3},"approved"]"#), .none)
        XCTAssertEqual(status(nil, #"{"state":"approved"}"#), .none)
    }
    func testReviewStatusReadsTheBoardRowsReviewers() {
        let r = [Reviewer(user: "ana", state: "requested"), Reviewer(user: "luis", state: "COMMENTED"), Reviewer(user: "bo", state: ""), Reviewer(user: "cy")]
        XCTAssertEqual(ReviewStatus(decision: nil, reviewers: r), .feedback)
        XCTAssertEqual(ReviewStatus(decision: nil, reviewers: Array(r.prefix(1))), .requested)
        XCTAssertEqual(ReviewStatus(decision: nil, reviewers: Array(r.suffix(2))), .none)
        XCTAssertEqual(ReviewStatus(decision: "APPROVED", reviewers: r), .approved)
        XCTAssertEqual(ReviewStatus(decision: nil, reviewers: []), .none)
        XCTAssertEqual(ReviewStatus(decision: "review_required", reviewers: []), .requested)
        let p = pull(#"{"number":1,"reviewers":[{"user":"a","state":"approved"},{"user":"b","state":"changes_requested"}]}"#)!
        XCTAssertEqual(ReviewStatus(decision: p.reviewDecision, reviewers: p.reviewers), .changesRequested)
        XCTAssertEqual(ReviewStatus.none.text, "")
        XCTAssertEqual(ReviewStatus.approved.text, "Approved")
        XCTAssertEqual(ReviewStatus.changesRequested.text, "Changes requested")
        XCTAssertEqual(ReviewStatus.feedback.text, "Feedback given")
        XCTAssertEqual(ReviewStatus.requested.text, "Review requested")
    }

    // MARK: - Stacks

    private func stack(_ value: String, _ stacks: String? = nil) -> StackPosition? { StackPosition(j(value), stacks: stacks.map { j($0) } ?? .null) }
    func testStackPositionsNeedAPositionAndATotal() {
        for bad in [#"{"total":3}"#, #"{"position":2}"#, #"{"position":"2","total":3}"#, "null"] { XCTAssertNil(stack(bad), bad) }
        XCTAssertNil(StackPosition(.null, stacks: .null))
        var sp = stack(#"{"position":2,"total":3}"#)!
        XCTAssertEqual(sp.position, 2); XCTAssertEqual(sp.total, 3); XCTAssertFalse(sp.partial); XCTAssertNil(sp.base); XCTAssertEqual(sp.chain.count, 0)
        XCTAssertEqual(sp.label(), "2/3")
        sp = stack(#"{"position":2,"total":3,"partial":true}"#)!; XCTAssertTrue(sp.partial)
        XCTAssertEqual(sp.label(), "2/3+")
        XCTAssertFalse(stack(#"{"position":2,"total":3,"partial":"yes"}"#)!.partial)
    }
    func testStackChainsAreFoundByIdNumberOrString() {
        let stacks = #"{"5":[{"number":1,"title":"Base","depth":1,"branch":"b1"},{"number":2,"depth":2,"headRef":"b2"},"#
            + #"{"title":"no number"},{"number":3,"depth":3,"branch":"","headRef":"b3","draft":true},{"number":4,"branch":""}],"#
            + #""abc":[{"number":9}]}"#
        let sp = stack(#"{"id":5,"position":2,"total":4}"#, stacks)!
        XCTAssertEqual(sp.chain.count, 4)
        if sp.chain.count == 4 {
            XCTAssertEqual(sp.chain[0].title, "Base"); XCTAssertEqual(sp.chain[0].branch, "b1"); XCTAssertFalse(sp.chain[0].draft)
            XCTAssertEqual(sp.chain[1].title, "Pull request #2"); XCTAssertEqual(sp.chain[1].branch, "b2")
            XCTAssertEqual(sp.chain[2].branch, "b3"); XCTAssertTrue(sp.chain[2].draft); XCTAssertEqual(sp.chain[2].depth, 3)
            // No depth reads as the bottom, and an empty branch as none.
            XCTAssertEqual(sp.chain[3].depth, 1); XCTAssertNil(sp.chain[3].branch)
        }
        XCTAssertEqual(stack(#"{"id":"5","position":1,"total":4}"#, stacks)?.chain.count, 4)
        XCTAssertEqual(stack(#"{"id":"abc","position":1,"total":1}"#, stacks)?.chain.count, 1)
        // An id with no chain, or none at all, still places the pull request.
        let other = stack(#"{"id":6,"position":1,"total":2}"#, stacks)!
        XCTAssertEqual(other.chain.count, 0); XCTAssertEqual(other.total, 2)
        XCTAssertEqual(stack(#"{"position":1,"total":2}"#, stacks)?.chain.count, 0)
        XCTAssertEqual(stack(#"{"id":"abc","position":1,"total":2}"#, #"{"abc":{"number":1}}"#)?.chain.count, 0)
    }
    func testStackLabelsShowEachItemsOwnDepth() {
        var sp = stack(#"{"id":1,"position":2,"total":3}"#, #"{"1":[{"number":10,"depth":1},{"number":11,"depth":2},{"number":12,"depth":3}]}"#)!
        XCTAssertEqual(sp.label(), "2/3")
        XCTAssertEqual(sp.label(10), "1/3")
        XCTAssertEqual(sp.label(12), "3/3")
        // One not in the chain reads as the stack's own position.
        XCTAssertEqual(sp.label(99), "2/3")
        sp.partial = true
        XCTAssertEqual(sp.label(11), "2/3+")
        XCTAssertEqual(sp.label(), "2/3+")
    }
    func testStackBranchesComeFromTheBoardsRows() {
        var sp = stack(#"{"id":1,"position":3,"total":3}"#, #"{"1":[{"number":12,"depth":3},{"number":10,"depth":1},{"number":11,"depth":2,"branch":"own"}]}"#)!
        var rows = PullSummary.parseList(j(#"[{"number":10,"branch":"b10","baseBranch":"master"},{"number":11,"branch":"b11","baseBranch":"b10"},"#
                                           + #"{"number":12,"branch":"","baseBranch":"b11"},{"number":99,"branch":"x"}]"#))
        sp.fillBranches(rows)
        // A branch the chain names is kept, an empty one in a row is not lent, and the bottom by depth lends its base.
        XCTAssertNil(sp.chain[0].branch); XCTAssertEqual(sp.chain[1].branch, "b10"); XCTAssertEqual(sp.chain[2].branch, "own")
        XCTAssertEqual(sp.base, "master")
        // A later look replaces the base; a bottom without one keeps what was known.
        sp.fillBranches(PullSummary.parseList(j(#"[{"number":10,"baseBranch":"main"}]"#)))
        XCTAssertEqual(sp.base, "main"); XCTAssertEqual(sp.chain[1].branch, "b10")
        sp.fillBranches(PullSummary.parseList(j(#"[{"number":10}]"#))); XCTAssertEqual(sp.base, "main")
        sp.fillBranches([]); XCTAssertEqual(sp.base, "main")
        // A partial chain that reaches the bottom still knows its base.
        sp = stack(#"{"id":1,"position":2,"total":3,"partial":true}"#, #"{"1":[{"number":10,"depth":1},{"number":11,"depth":2}]}"#)!
        rows = PullSummary.parseList(j(#"[{"number":10,"branch":"b10","baseBranch":"master"}]"#))
        sp.fillBranches(rows); XCTAssertEqual(sp.base, "master")
        // An empty chain learns nothing.
        sp = stack(#"{"position":1,"total":1}"#)!
        sp.fillBranches(rows); XCTAssertNil(sp.base)
    }
    func testStacksSurviveASaveAndRestore() {
        var sp = stack(#"{"id":1,"position":2,"total":3,"partial":true}"#,
                       #"{"1":[{"number":10,"title":"Bottom","depth":1,"branch":"b10"},{"number":11,"title":"Mid","depth":2,"draft":true},"#
                       + #"{"number":12,"depth":3,"branch":"b12"}]}"#)!
        sp.base = "master"
        var saved = sp.json
        XCTAssertTrue(saved["partial"].is(true)); XCTAssertEqual(saved["base"].string, "master")
        let chain = saved["chain"]
        XCTAssertEqual(chain.count, 3)
        // Only a draft says so, and an item without a branch leaves it out.
        XCTAssertTrue(chain[0]["draft"].isNull); XCTAssertTrue(chain[1]["draft"].is(true))
        XCTAssertTrue(chain[1]["branch"].isNull); XCTAssertEqual(chain[2]["title"].string, "Pull request #12")
        var back = StackPosition(restoring: saved)!
        XCTAssertEqual(back, sp)
        XCTAssertEqual(back.label(11), "2/3+")
        XCTAssertEqual(back.json, saved)
        // Without a base or chain, neither is saved nor restored.
        sp = stack(#"{"position":1,"total":1}"#)!
        saved = sp.json
        XCTAssertTrue(saved["base"].isNull); XCTAssertEqual(saved["chain"].count, 0); XCTAssertTrue(saved["partial"].is(false))
        back = StackPosition(restoring: saved)!
        XCTAssertNil(back.base); XCTAssertEqual(back.chain.count, 0); XCTAssertFalse(back.partial)
        XCTAssertNil(StackPosition(restoring: j(#"{"position":1,"base":""}"#)))
        back = StackPosition(restoring: j(#"{"position":1,"total":1,"base":"","chain":[{"title":"x"}]}"#))!
        XCTAssertNil(back.base); XCTAssertEqual(back.chain.count, 0)
        XCTAssertNil(StackPosition(restoring: .null))
    }
    private func topFirst(_ chain: String) -> String {
        let sp = stack(#"{"id":1,"position":1,"total":9}"#, #"{"1":\#(chain)}"#)!
        return sp.topFirst.map { String(sp.chain[$0].number) }.joined(separator: ",")
    }
    func testStackOverviewsListTheTopFirst() {
        XCTAssertEqual(topFirst(#"[{"number":1,"depth":1},{"number":2,"depth":2},{"number":3,"depth":3}]"#), "3,2,1")
        XCTAssertEqual(topFirst(#"[{"number":3,"depth":3},{"number":1,"depth":1},{"number":2,"depth":2}]"#), "3,2,1")
        // Siblings at one depth keep the server's order.
        XCTAssertEqual(topFirst(#"[{"number":1,"depth":1},{"number":4,"depth":2},{"number":2,"depth":2},{"number":5,"depth":3},{"number":3,"depth":2}]"#), "5,4,2,3,1")
        XCTAssertEqual(topFirst(#"[{"number":7}]"#), "7")
        XCTAssertEqual(topFirst("[]"), "")
    }

    // MARK: - Links out

    func testOnlyHttpsURLsWithAHostAndNoCredentialsAreOpened() {
        for safe in ["https://github.com/o/r/pull/1", "https://github.com", "https://github.com/", "https://github.com:443/x", "https://a.b?q=1",
                     "https://a.b#frag", "https://github.com/user@example/x", "https://github.com/?u=a@b", "https://x#@y"] {
            XCTAssertTrue(safeWebURL(safe), safe)
        }
        let unsafe: [String?] = [nil, "", "http://github.com", "HTTPS://github.com", " https://github.com", "https:github.com", "https:/github.com",
                                 "https://", "https:///path", "https://?q", "https://#x", "https://user@github.com", "https://user:pass@github.com/x",
                                 "https://github.com@evil.example", "https://@github.com", "javascript:alert(1)", "javascript://https://x", "file:///C:/x",
                                 "ftp://github.com", "//github.com", "github.com"]
        for u in unsafe { XCTAssertFalse(safeWebURL(u), u ?? "(nil)") }
    }

    // MARK: - ▶ Run

    func testRunProfilesAreReadForTheProjectDefaultFirst() {
        let projects = j(#"{"projects":[{"repo":"o/other","runProfiles":["x"]},{"repo":"o/r","runProfiles":["veterinary_central","","demo",7]}]}"#)
        XCTAssertEqual(runProfilesParse(projects, repo: "o/r"), ["veterinary_central", "demo"])
        // The bare array reads the same.
        XCTAssertEqual(runProfilesParse(projects["projects"], repo: "o/other"), ["x"])
    }
    func testRunProfilesAreEmptyWhenNoneOrUnlisted() {
        let projects = j(#"{"projects":[{"repo":"o/r"},{"repo":"o/s","runProfiles":[]}]}"#)
        XCTAssertEqual(runProfilesParse(projects, repo: "o/r"), [])
        XCTAssertEqual(runProfilesParse(projects, repo: "o/s"), [])
        XCTAssertEqual(runProfilesParse(projects, repo: "o/missing"), [])
        XCTAssertEqual(runProfilesParse(.null, repo: "o/r"), [])
    }
    func testTheRunBeingPreparedIsTheNewestRunSessionOnThePullRequest() {
        let sessions = j(#"{"sessions":["#
            + #"{"id":"old","title":"Run: #7 Fix","startedOnPr":7,"createdAt":"2026-10-01T10:00:00Z"},"#
            + #"{"id":"chat","title":"Fix the bug","startedOnPr":7,"createdAt":"2026-10-01T12:00:00Z"},"#
            + #"{"id":"other","title":"Run: #8","startedOnPr":8,"createdAt":"2026-10-01T12:00:00Z"},"#
            + #"{"id":"new","title":"Run: #7 Fix","prStatus":{"number":7},"createdAt":"2026-10-01T11:00:00Z"}]}"#)
        XCTAssertEqual(runSessionPreparing(sessions, number: 7), "new")
        XCTAssertEqual(runSessionPreparing(sessions, number: 8), "other")
        XCTAssertNil(runSessionPreparing(sessions, number: 9))
        XCTAssertNil(runSessionPreparing(.null, number: 7))
    }
    func testARunAlreadyServingIsFoundByItsServeLink() {
        let sessions = j(#"{"sessions":["#
            + #"{"id":"idle","startedOnPr":7,"serveLinks":null},"#
            + #"{"id":"local","startedOnPr":7,"serveLinks":[{"url":"http://127.0.0.1:8123"}]},"#
            + #"{"id":"elsewhere","startedOnPr":8,"serveLinks":[{"url":"https://8124.preview.example.com"}]},"#
            + #"{"id":"live","startedOnPr":7,"serveLinks":[{"tenant":"a","url":"https://a-8125.preview.example.com"},{"url":"https://b"}]}]}"#)
        // Only an https link is opened in the tab.
        let live = runSessionServing(sessions, number: 7)
        XCTAssertEqual(live?.sessionId, "live"); XCTAssertEqual(live?.url, "https://a-8125.preview.example.com")
        XCTAssertEqual(runSessionServing(sessions["sessions"], number: 8)?.sessionId, "elsewhere")
        XCTAssertNil(runSessionServing(sessions, number: 9))
    }
    func testTheRunLogReadsLogLinesPastItsCursor() {
        var log = RunLog()
        let events = j(#"["#
            + #"{"seq":1,"kind":"user","text":"hello"},"#
            + #"{"seq":2,"kind":"info","text":"Preparing pull request #7"},"#
            + #"{"seq":3,"kind":"cmd","text":"composer install"},"#
            + #"{"seq":4,"kind":"setup","text":"Installing\r\n\nDone"},"#
            + #"{"seq":5,"kind":"stderr","text":"npm WARN deprecated"},"#
            + #"{"seq":6,"kind":"status","status":"idle"},"#
            + #"{"seq":7,"kind":"text","text":"the agent speaking"},"#
            + #"{"seq":8,"kind":"git","text":"Cloning"},"#
            + #"{"seq":9,"kind":"tool","text":"Bash"}]"#)
        XCTAssertTrue(log.addEvents(events))
        XCTAssertEqual(log.lines.count, 7); XCTAssertEqual(log.cursor, 9)
        XCTAssertEqual(log.lines.map(\.text), ["Preparing pull request #7", "$ composer install", "Installing", "Done", "npm WARN deprecated", "\u{2022} idle", "Cloning"])
        XCTAssertTrue(log.lines[4].isError); XCTAssertFalse(log.lines[3].isError)
        // Read again from the same answer: nothing is added twice.
        XCTAssertFalse(log.addEvents(events)); XCTAssertEqual(log.lines.count, 7)
        XCTAssertTrue(log.addEvents(j(#"[{"seq":9,"kind":"info","text":"again"},{"seq":10,"kind":"info","text":"Serving on 8123"}]"#)))
        XCTAssertEqual(log.lines.count, 8); XCTAssertEqual(log.lines[7].text, "Serving on 8123")
        log.clear()
        XCTAssertEqual(log.lines.count, 0); XCTAssertEqual(log.cursor, 0)
    }
    func testTheRunLogKeepsItsLatestLines() {
        var log = RunLog()
        XCTAssertEqual(log.add("", error: false), 0)
        XCTAssertEqual(log.add("one\ntwo\n", error: false), 2)
        for i in 0..<RunLog.cap { log.add("line \(i)", error: i % 2 == 0) }
        XCTAssertEqual(log.lines.count, RunLog.cap)
        XCTAssertEqual(log.lines[0].text, "line 0"); XCTAssertTrue(log.lines[0].isError)
        XCTAssertEqual(log.lines[RunLog.cap - 1].text, "line 399"); XCTAssertFalse(log.lines[RunLog.cap - 1].isError)
        // A full log still reports what it added.
        XCTAssertTrue(log.addEvents(j(#"[{"seq":1,"kind":"info","text":"newest"}]"#))); XCTAssertEqual(log.lines.count, RunLog.cap)
        XCTAssertEqual(log.lines[0].text, "line 1"); XCTAssertEqual(log.lines[RunLog.cap - 1].text, "newest")
    }
}
