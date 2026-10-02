// The Findings and Usage screens' pure parts (Mac/Core/FindingsLogic.swift and UsageLogic.swift), against what
// the Windows client produces.
import XCTest
@testable import BriareusMacCore

final class FindingsLogicTests: XCTestCase {
    private func session(_ id: String, repo: String, held: JSON) -> Session {
        Session(["id": .string(id), "status": "idle", "repo": .string(repo), "reviewTriage": held])!
    }

    func testGroupsByPullRequestAndFoldedRepository() {
        let sessions = [
            session("a", repo: "Org/App", held: ["prNumber": 4, "heldAt": "2026-01-01"]),
            session("b", repo: "org/app", held: ["prNumber": 4, "heldAt": "2026-01-02"]),
            session("c", repo: "org/app", held: ["prNumber": 5, "heldAt": "2026-01-03"]),
        ]
        let rounds = Session.heldRounds(sessions)
        let groups = Findings.groups(rounds, sessions: sessions)
        XCTAssertEqual(groups, [FindingsGroup(repo: "Org/App", pr: 4, rounds: [0, 1]), FindingsGroup(repo: "org/app", pr: 5, rounds: [2])])
    }

    func testVerdictsForASaveSendNullsAndEveryComment() {
        let findings: JSON = [["key": "a"], ["key": "b"], ["title": "no key"]]
        let v = Findings.verdicts(findings, decision: { $0 == "a" ? "fix" : "" }, reason: { _ in "" }, completing: false)
        XCTAssertEqual(v, [["key": "a", "decision": "fix", "reason": ""], ["key": "b", "decision": nil, "reason": ""]])
    }
    func testCompletingSendsUnmarkedAsOptionalAndOnlyCommentsGiven() {
        let findings: JSON = [["key": "a"], ["key": "b"]]
        let v = Findings.verdicts(findings, decision: { $0 == "a" ? "dismissed" : "" }, reason: { $0 == "b" ? "why" : "" }, completing: true)
        XCTAssertEqual(v, [["key": "a", "decision": "dismissed"], ["key": "b", "decision": "optional", "reason": "why"]])
    }

    func testCompletePrompts() {
        XCTAssertEqual(Findings.completePrompt(mine: true, fixes: 1, pr: 7).title, "Start a paid fix session for 1 finding?")
        XCTAssertEqual(Findings.completePrompt(mine: true, fixes: 2, pr: 7).message,
                       "Every verdict and comment is recorded on PR #7; what is marked fix goes to the fix session.")
        XCTAssertEqual(Findings.completePrompt(mine: true, fixes: 0, pr: 7).title, "Complete with nothing to fix?")
        XCTAssertEqual(Findings.completePrompt(mine: false, fixes: 0, pr: 7).message, "What it found stays on PR #7 for its author.")
        XCTAssertEqual(Findings.completeLabel(fixes: 3, sending: false), "Complete \u{00B7} send 3 to be fixed")
        XCTAssertEqual(Findings.completeLabel(fixes: 0, sending: false), "Complete \u{00B7} nothing to fix, approve and close")
        XCTAssertEqual(Findings.completeLabel(fixes: 3, sending: true), "Completing\u{2026}")
    }

    func testCardWords() {
        XCTAssertEqual(Findings.groupCount(findings: 1, reviews: 1), "1 finding")
        XCTAssertEqual(Findings.groupCount(findings: 5, reviews: 2), "5 findings across 2 reviews")
        XCTAssertEqual(Findings.unmarkedText(1), "1 finding still unmarked; Complete appears once every finding has a verdict.")
        XCTAssertEqual(Findings.howText(mine: false, manage: true, count: 0), "Every finding was deleted from the review. Complete takes this card off the queue.")
        XCTAssertEqual(Findings.howText(mine: true, manage: false, count: 2), "2 findings. This device is read-only: the verdicts are given with a Manage token.")
        XCTAssertEqual(Findings.location(["file": "a.swift", "line": 12]), "a.swift:12 \u{2197}")
        XCTAssertEqual(Findings.location(["file": "a.swift"]), "a.swift \u{2197}")
        XCTAssertNil(Findings.location(["file": ""]))
        XCTAssertEqual(Findings.parkedAdvice(["parked": "duplicate", "parkedWhy": "seen in round 1"]), "The loop would have parked it: seen in round 1.")
        XCTAssertEqual(Findings.parkedAdvice(["parked": "duplicate"]), "The loop would have parked it: duplicate.")
        XCTAssertNil(Findings.parkedAdvice([:]))
        XCTAssertEqual(Findings.roundMeta(["standalone": true]), "code review")
        XCTAssertEqual(Findings.roundMeta(["round": 3]), "round 3")
    }

    func testDeleteAndCompletionAnswers() {
        XCTAssertEqual(Findings.deleteOutcome(["warning": "x"]).text, "Deleted, but the review still declares it: x")
        XCTAssertTrue(Findings.deleteOutcome(["warning": "x"]).danger)
        XCTAssertEqual(Findings.deleteOutcome(["commentDeleted": true]).text, "Deleted from the review")
        XCTAssertEqual(Findings.deleteOutcome([:]).text, "The review no longer declares it; it had no comment of its own to delete")
        XCTAssertFalse(Findings.completionSpeaks(["dismissed": true]))
        XCTAssertTrue(Findings.completionSpeaks(["dismissed": true, "approved": true]))
        XCTAssertTrue(Findings.completionSpeaks(["fixing": true]))
    }

    func testWaitingCountsSavedHeldRounds() {
        let saved: [String: JSON] = [
            "sessions:a/b": [["id": "1", "status": "idle", "reviewTriage": ["findings": []]], ["id": "2", "status": "idle"]],
            "sessions:c/d": [["id": "3", "status": "idle", "reviewLoop": ["triage": ["round": 1]]]],
        ]
        let n = Findings.waiting(projects: [Project(repo: "a/b"), Project(repo: "c/d"), Project(repo: "e/f")]) { saved[$0] }
        XCTAssertEqual(n, 2)
    }
}

final class UsageLogicTests: XCTestCase {
    private let en = Locale(identifier: "en_US")

    func testTokensAsUsageWordsThem() {
        XCTAssertEqual(Usage.tokens(21_599_700_000), "21599.7M")
        XCTAssertEqual(Usage.tokens(80_500_000), "80.5M")
        XCTAssertEqual(Usage.tokens(93_000), "93.0k")
        XCTAssertEqual(Usage.tokens(999), "999")
        XCTAssertEqual(Usage.tokens(0), "0")
    }
    func testCostCarriesAPlusWhenSomeTurnsAreUnpriced() {
        XCTAssertEqual(Usage.cost(["costUsd": 1.234]), "$1.23")
        XCTAssertEqual(Usage.cost(["costUsd": 1.234, "unpricedTurns": 2]), "$1.23+")
        XCTAssertNil(Usage.cost(["costUsd": nil]))
        XCTAssertEqual(Usage.costOrDash([:]), "\u{2014}")
        XCTAssertEqual(Usage.costNote(["unpricedTurns": 2, "turns": 9]), "2 of 9 turns could not be priced")
        XCTAssertEqual(Usage.costNote(["costUsd": nil]), "no turn carries a price")
        XCTAssertEqual(Usage.costNote(["costUsd": 3]), "every turn priced")
    }
    func testBucketAndWindowNames() {
        XCTAssertEqual(Usage.bucketName("2026-08-03", month: false, locale: en), "Aug 3")
        XCTAssertEqual(Usage.bucketName("2026-08", month: true, locale: en), "Aug 2026")
        XCTAssertEqual(Usage.bucketName("nope", month: true, locale: en), "nope")
        XCTAssertEqual(Usage.windowName(["period": "all"], periodLabel: "All time", locale: en), "all time")
        XCTAssertEqual(Usage.windowName(["period": "month", "month": "2026-08"], periodLabel: "", locale: en), "August 2026")
        XCTAssertEqual(Usage.windowName(["period": "7d", "buckets": [["date": "2026-08-01"], ["date": "2026-08-07"]]], periodLabel: "", locale: en),
                       "Aug 1 \u{2013} Aug 7")
        XCTAssertEqual(Usage.windowName(["period": "today", "buckets": [["date": "2026-08-01"]]], periodLabel: "", locale: en), "Aug 1")
        XCTAssertEqual(Usage.windowName(["period": "7d"], periodLabel: "Last 7 days", locale: en), "Last 7 days")
    }
    func testLabels() {
        XCTAssertEqual(Usage.activityLabel("code-review"), "\u{2315} Code review")
        XCTAssertEqual(Usage.activityLabel("unknown"), "Unattributed")
        XCTAssertEqual(Usage.activityLabel(nil), "Unattributed")
        XCTAssertEqual(Usage.activityLabel("other"), "other")
        XCTAssertEqual(Usage.modelLabel(["model": "m", "provider": "p"]), "m (p)")
        XCTAssertEqual(Usage.modelLabel([:]), "unknown")
        XCTAssertEqual(Usage.optionLabel(.project, ["key": "k", "label": "App", "gone": true]), "App (removed)")
        XCTAssertEqual(Usage.optionLabel(.account, ["key": "k"]), "k")
    }
    func testShareSeries() {
        XCTAssertNil(Usage.shareSeries([["totalTokens": 1], ["totalTokens": 1]]))
        XCTAssertNil(Usage.shareSeries([["totalTokens": 0]]))
        let rows: [JSON] = (0..<6).map { ["totalTokens": .number(Double($0 == 2 ? 0 : 10))] }
        let ring = Usage.shareSeries(rows)!
        XCTAssertEqual(ring.slots, [0, 1, nil, 2, 3, 4])
        XCTAssertEqual(ring.slices.map(\.slot), [0, 1, 2, 3, 4])
        XCTAssertEqual(ring.slices.map(\.share), [0.2, 0.2, 0.2, 0.2, 0.2])
    }
    func testVisibleBucketsStopAtToday() {
        let daily: JSON = ["unit": "day", "today": "2026-08-02", "buckets": [["date": "2026-08-01"], ["date": "2026-08-02"], ["date": "2026-08-03"]]]
        XCTAssertEqual(Usage.visibleBuckets(daily).count, 2)
        let monthly: JSON = ["unit": "month", "today": "2026-08-15", "buckets": [["date": "2026-07"], ["date": "2026-08"], ["date": "2026-09"]]]
        XCTAssertEqual(Usage.visibleBuckets(monthly).count, 2)
        XCTAssertEqual(Usage.barTip(["date": "2026-08-01", "turns": 0], month: false, locale: en), "Aug 1: no usage")
        XCTAssertEqual(Usage.barTip(["date": "2026-08-01", "turns": 1, "totalTokens": 1500, "costUsd": 0.5], month: false, locale: en),
                       "Aug 1: 1.5k tok \u{00B7} 1 turn \u{00B7} $0.50")
    }
    func testComparison() {
        let u: JSON = ["costUsd": 15, "totalTokens": 100, "sessions": 3,
                       "comparison": ["from": 0, "to": 86_400_001, "costUsd": 10, "totalTokens": 0, "partial": true]]
        let line = Usage.comparisonLine(u, locale: en, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(line, "Compared with Jan 1, 1970 \u{2013} Jan 2, 1970 (matching elapsed time): Cost: +50.0% \u{00B7} Tokens: new usage (previously zero) \u{00B7} Sessions: unavailable")
        XCTAssertNil(Usage.comparisonLine([:]))
        XCTAssertEqual(Usage.pricingCoverage(["turns": 3, "unpricedTurns": 1]).value, "67%")
        XCTAssertEqual(Usage.pricingCoverage([:]).value, "0%")
    }
    func testQueryArgsAndPicks() {
        var q = UsageQuery()
        XCTAssertEqual(q.args, ["period": "month"])
        q.choose(.project, "a"); q.choose(.project, "b")
        XCTAssertTrue(q.choose(.provider, "x"))
        XCTAssertFalse(q.choose(.provider, "x"))
        XCTAssertEqual(q.args, ["period": "month", "project": ["a", "b"], "provider": "x"])
        q.choose(.project, "a")
        XCTAssertEqual(q.picked(.project), ["b"])
        q.only(.activity, "chat"); XCTAssertEqual(q.picked(.activity), ["chat"])
        q.only(.activity, "chat"); XCTAssertEqual(q.picked(.activity), [])
        let options: JSON = ["projects": [["key": "b", "label": "Bee"]]]
        XCTAssertEqual(q.buttonText(.project, options: options), "Bee \u{25BE}")
        XCTAssertEqual(q.buttonText(.model, options: options), "All models \u{25BE}")
        q.choose(.project, "c")
        XCTAssertEqual(q.buttonText(.project, options: options), "2 projects \u{25BE}")
        q.clearAll()
        XCTAssertFalse(q.anyPick)
    }
    func testSubtitle() {
        let u: JSON = ["period": "all", "turns": 1, "projects": [["turns": 1], ["turns": 0]]]
        var q = UsageQuery(period: 2)
        XCTAssertEqual(q.subtitle(u, options: .null, locale: en), "all time \u{00B7} 1 project with usage \u{00B7} 1 turn")
        q.choose(.activity, "qa")
        XCTAssertEqual(q.subtitle(u, options: .null, locale: en), "all time \u{00B7} only \u{1F50D} QA \u{00B7} 1 turn")
    }
}
