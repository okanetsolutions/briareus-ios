// What the iPhone app's conversation list and screen work out: the pull request mark, the list's filters, the bulk
// actions' targets and the polling pace.
import XCTest
@testable import BriareusMacCore

final class PhoneConversationsTests: XCTestCase {
    private func session(_ extra: JSON) -> Session {
        var j: JSON = ["id": "s", "status": "idle"]
        j.merge(extra)
        return Session(j)!
    }

    // MARK: Pull request mark

    func testPullBadgeReadsAsTheBadge() {
        XCTAssertNil(session(["startedOnPr": 4]).pullBadge)
        XCTAssertNil(session(["prStatus": .null]).pullBadge)
        XCTAssertEqual(session(["prStatus": ["number": 9, "state": "merged", "checks": .null]]).pullBadge, "PR #9 merged")
        XCTAssertEqual(session(["prStatus": ["number": 9, "state": "open", "checks": ["passed": 4, "failed": 1, "pending": 0]]]).pullBadge,
                       "PR #9 open \u{00B7} \u{2713}4 \u{2717}1")
        XCTAssertEqual(session(["prStatus": ["number": 9]]).pullBadge, "PR #9 open")
    }
    func testPullToneFollowsStateThenChecks() {
        func tone(_ pr: JSON) -> String? { session(["prStatus": pr]).pullTone }
        XCTAssertNil(tone(.null))
        XCTAssertEqual(tone(["number": 9, "state": "merged", "checks": ["failed": 2]]), "merged")
        XCTAssertEqual(tone(["number": 9, "state": "closed"]), "closed")
        XCTAssertEqual(tone(["number": 9, "state": "open", "checks": ["passed": 3, "failed": 1, "pending": 2]]), "failing")
        XCTAssertEqual(tone(["number": 9, "state": "open", "checks": ["passed": 3, "pending": 2]]), "pending")
        XCTAssertEqual(tone(["number": 9, "state": "open", "checks": .null]), "passing")
        XCTAssertEqual(tone(["number": 9, "state": "open", "draft": true, "checks": ["failed": 1]]), "draft")
    }
    func testPullNumberPrefersTheSyncedPullRequest() {
        XCTAssertNil(session([:]).pullNumber)
        XCTAssertNil(session(["prStatus": .null, "startedOnPr": .null]).pullNumber)
        XCTAssertEqual(session(["startedOnPr": 4]).pullNumber, 4)
        XCTAssertEqual(session(["prStatus": ["number": 9, "state": "open"], "startedOnPr": 4]).pullNumber, 9)
    }

    // MARK: Rows

    func testRowDetailListsProviderBranchStateAndAge() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let created = "2023-11-14T22:03:20Z"   // 10 minutes before `now`
        XCTAssertEqual(session(["provider": "Claude", "branch": "feat/x", "createdAt": .string(created)]).conversationRowDetail(now: now),
                       "Claude \u{00B7} feat/x \u{00B7} idle \u{00B7} 10m ago")
        XCTAssertEqual(session(["awaitingAnswer": true, "orchestrator": true, "branch": "b"]).conversationRowDetail(now: now),
                       "\u{1F9ED} orchestrator \u{00B7} waiting")
        XCTAssertEqual(session(["status": "running", "zeus": true]).conversationRowDetail(now: now), "\u{26A1} zeus \u{00B7} running")
    }

    // MARK: The list

    func testShownConversationsHideClosedAndMatchTheSearch() {
        let list = [session(["id": "a", "title": "Fix the login"]), session(["id": "b", "status": "closed", "title": "Old login work"]),
                    session(["id": "c", "title": "Board"])]
        XCTAssertEqual(conversationsShown(list, search: "", showClosed: false).map(\.id), ["a", "c"])
        XCTAssertEqual(conversationsShown(list, search: "", showClosed: true).map(\.id), ["a", "b", "c"])
        XCTAssertEqual(conversationsShown(list, search: " LOGIN ", showClosed: true).map(\.id), ["a", "b"])
        XCTAssertEqual(conversationsShown([session(["id": "d"])], search: "new", showClosed: false).map(\.id), ["d"])
    }
    func testBulkCloseTakesOnlyOpenConversations() {
        let list = [session(["id": "a", "status": "running"]), session(["id": "b", "status": "closed"]),
                    session(["id": "c", "status": "failed"]), session(["id": "d", "status": "idle"])]
        let picked: Set<String> = ["a", "b", "c", "d"]
        XCTAssertEqual(bulkConversationTargets(list, picked: picked, delete: false), ["a", "d"])
        XCTAssertEqual(bulkConversationTargets(list, picked: picked, delete: true), ["a", "b", "c", "d"])
        XCTAssertEqual(bulkConversationTargets(list, picked: ["b"], delete: false), [])
        XCTAssertEqual(bulkConversationQuestion(count: 1, delete: true).title, "Delete 1 conversation and their logs?")
        XCTAssertEqual(bulkConversationQuestion(count: 3, delete: false).title, "Close 3 sessions?")
    }

    // MARK: The conversation

    func testPollingSlowsDownOnceTheAgentStops() {
        XCTAssertEqual(conversationPollInterval(session(["status": "running"])), 2)
        XCTAssertEqual(conversationPollInterval(session(["status": "queued"])), 2)
        XCTAssertEqual(conversationPollInterval(session([:])), 7)
        XCTAssertEqual(conversationPollInterval(session(["status": "closed"])), 60)
    }
    func testActionsThatAskFirst() {
        XCTAssertEqual(conversationActionQuestion("cancel"), "Stop the running agent?")
        XCTAssertNotNil(conversationActionQuestion("delete"))
        XCTAssertNil(conversationActionQuestion("rename"))
    }
    func testCompactionControls() {
        XCTAssertTrue(sessionOffersCompact(["canCompact": true]))
        XCTAssertTrue(sessionOffersCompact(["compacting": true]))
        XCTAssertFalse(sessionOffersCompact([:]))
        XCTAssertTrue(sessionOffersClear(["id": "a", "status": "idle", "kind": "devchat"]))
        XCTAssertFalse(sessionOffersClear(["id": "a", "status": "running", "kind": "devchat"]))
        XCTAssertFalse(sessionOffersClear(["id": "a", "status": "idle", "kind": "task"]))
        XCTAssertTrue(sessionOffersAutoCompact(["autoCompactAt": 150_000]))
        XCTAssertEqual(autoCompactLabel(["autoCompactAt": 150_000]), "Auto-compact at 150k")
        XCTAssertTrue(sessionOffersCompactInstructions(["compactInstructions": "keep the plan"]))
        XCTAssertFalse(sessionOffersCompactInstructions(["compactInstructions": ""]))
    }
    func testStripSumsUpPullContextAndCost() {
        XCTAssertNil(conversationStripText(session([:])))
        let s = session(["prStatus": ["number": 7, "state": "open", "checks": ["passed": 2]], "contextUsage": ["tokens": 50_000, "window": 200_000],
                         "usage": ["costUsd": 1.234]])
        XCTAssertEqual(conversationStripText(s), "PR #7 open \u{00B7} \u{2713}2 \u{00B7} 25% context \u{00B7} $1.23")
        XCTAssertEqual(conversationStripText(session(["contextTokens": 1500])), "1.5k context")
    }
}
