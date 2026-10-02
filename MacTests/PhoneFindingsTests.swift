// The iPhone's Findings and Usage tabs' pure parts (Mac/Core/PhoneFindings.swift).
import XCTest
@testable import BriareusMacCore

final class PhoneFindingsTests: XCTestCase {
    private func session(_ id: String, repo: String, held: JSON?) -> Session {
        var raw: JSON = ["id": .string(id), "status": "idle", "repo": .string(repo)]
        if let held { raw["reviewTriage"] = held }
        return Session(raw)!
    }

    func testQueueIsOldestFirstGroupedByPullRequestAndNarrowedByProject() {
        let sessions = [
            session("a", repo: "o/app", held: ["prNumber": 4, "heldAt": "2026-01-03"]),
            session("b", repo: "o/app", held: ["prNumber": 5, "heldAt": "2026-01-01"]),
            session("c", repo: "o/app", held: ["prNumber": 5, "heldAt": "2026-01-04"]),
            session("d", repo: "o/web", held: ["prNumber": 1, "heldAt": "2026-01-02"]),
            session("e", repo: "o/app", held: nil),
        ]
        XCTAssertEqual(PhoneFindings.queue(sessions).map(\.id), ["b", "c", "d", "a"])
        XCTAssertEqual(PhoneFindings.queue(sessions, repo: "O/App").map(\.id), ["b", "c", "a"])
        XCTAssertEqual(PhoneFindings.queue(sessions, repo: "o/none"), [])
    }

    func testCountLineNamesTheSevereOnes() {
        XCTAssertEqual(PhoneFindings.countLine(["findings": [["severity": "high"], ["severity": "low"], ["severity": "critical"]]]),
                       "3 findings \u{00B7} 1 CRIT \u{00B7} 1 HIGH")
        XCTAssertEqual(PhoneFindings.countLine(["findings": [["severity": "medium"]]]), "1 finding")
        XCTAssertEqual(PhoneFindings.countLine([:]), "0 findings")
    }

    private let triage: JSON = [
        "round": 2, "prNumber": 9,
        "findings": [["key": "a", "title": "A"], ["key": "b", "title": "B"], ["title": "no key"]],
        "drafts": ["verdicts": ["a": ["decision": "fix", "reason": "saved why"]], "note": "saved note"],
    ]

    func testCompletionMatchesTriageCompletionWithoutTypedComments() {
        XCTAssertEqual(PhoneFindings.completion(triage, picked: ["b": "dismissed"], reasons: [:], note: " go "),
                       triageCompletion(triage, picked: ["b": "dismissed"], note: " go "))
        XCTAssertEqual(PhoneFindings.completion(triage, picked: [:], reasons: [:], note: ""),
                       triageCompletion(triage, picked: [:], note: ""))
    }
    func testCompletionCarriesTypedComments() {
        let c = PhoneFindings.completion(triage, picked: [:], reasons: ["a": "", "b": " typed "], note: "")
        XCTAssertEqual(c, ["verdicts": [["key": "a", "decision": "fix"], ["key": "b", "decision": "optional", "reason": "typed"]]])
    }
    func testCompletionOfSomebodyElsesReviewSendsNothing() {
        var theirs = triage
        theirs["mine"] = false
        XCTAssertEqual(PhoneFindings.completion(theirs, picked: ["a": "fix"], reasons: [:], note: "x"), [:])
    }
    func testSaveSendsNullsCommentsAndTheNote() {
        let s = PhoneFindings.save(triage, picked: ["a": ""], reasons: ["b": "why"], note: "n")
        XCTAssertEqual(s, ["verdicts": [["key": "a", "decision": nil, "reason": "saved why"], ["key": "b", "decision": nil, "reason": "why"]],
                           "note": "n"])
    }
    func testCountsAndNoteFallBackToTheDrafts() {
        XCTAssertEqual(PhoneFindings.fixes(triage, picked: [:]), 1)
        XCTAssertEqual(PhoneFindings.fixes(triage, picked: ["a": "optional", "b": "fix"]), 1)
        XCTAssertEqual(PhoneFindings.unmarked(triage, picked: [:]), 1)
        XCTAssertEqual(PhoneFindings.unmarked(triage, picked: ["b": "fix"]), 0)
        XCTAssertEqual(PhoneFindings.note(triage, typed: nil), "saved note")
        XCTAssertEqual(PhoneFindings.note(triage, typed: ""), "")
        XCTAssertEqual(PhoneFindings.unmarkedLine(0), nil)
        XCTAssertEqual(PhoneFindings.unmarkedLine(1), "1 unmarked finding goes as optional, which the loop never offers again.")
    }
    func testRoundPrefersTheHeldOne() {
        let s = Session(["id": "x", "status": "idle", "reviewLoop": ["triage": ["round": 3]]])!
        XCTAssertEqual(PhoneFindings.round(s)?["round"], 3)
        XCTAssertNil(PhoneFindings.round(Session(["id": "y", "status": "idle"])!))
    }
}

final class PhoneUsageTests: XCTestCase {
    func testBucketDates() {
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(PhoneUsage.bucketDate("2026-08-03", calendar: utc), Date(timeIntervalSince1970: 1785715200))
        XCTAssertEqual(PhoneUsage.bucketDate("2026-08", calendar: utc), Date(timeIntervalSince1970: 1785542400))
        XCTAssertNil(PhoneUsage.bucketDate("2026-13", calendar: utc))
        XCTAssertNil(PhoneUsage.bucketDate("nope", calendar: utc))
        XCTAssertNil(PhoneUsage.bucketDate(nil, calendar: utc))
    }

    func testAddKeepsAnUnpricedTotalNull() {
        let sum = PhoneUsage.add([["turns": 2, "costUsd": nil], ["turns": 1, "costUsd": 0.5], ["turns": 1, "costUsd": 0.25]])
        XCTAssertEqual(sum["turns"], 4)
        XCTAssertEqual(sum["costUsd"], 0.75)
        XCTAssertEqual(PhoneUsage.add([["turns": 1, "costUsd": nil]])["costUsd"], .null)
    }

    func testCombineFoldsEachProjectsMonth() {
        let a: JSON = [
            "turns": 3, "sessions": 2, "inputTokens": 100, "outputTokens": 50, "totalTokens": 150, "durationMs": 1000,
            "costUsd": 1.5, "unpricedTurns": 0, "today": "2026-08-03",
            "daily": [["date": "2026-08-01", "turns": 1, "totalTokens": 50, "costUsd": 0.5], ["date": "2026-08-02", "turns": 2, "totalTokens": 100, "costUsd": 1]],
            "providers": [["provider": "claude", "totalTokens": 150, "costUsd": 1.5]],
            "models": [["key": "claude|opus", "provider": "claude", "model": "opus", "totalTokens": 150]],
            "activities": [["activity": "chat", "totalTokens": 150, "costUsd": 1.5]],
        ]
        let b: JSON = [
            "turns": 1, "sessions": 1, "inputTokens": 400, "outputTokens": 100, "totalTokens": 500, "durationMs": 500,
            "costUsd": nil, "unpricedTurns": 1, "today": "2026-08-03",
            "daily": [["date": "2026-08-01", "turns": 1, "totalTokens": 500, "costUsd": nil, "unpricedTurns": 1], ["date": "2026-08-02", "turns": 0, "totalTokens": 0]],
            "providers": [["provider": "codex", "totalTokens": 500], ["provider": "claude", "totalTokens": 0]],
            "models": [["key": "codex|gpt", "provider": "codex", "model": "gpt", "totalTokens": 500]],
            "activities": [["activity": "issue", "totalTokens": 500, "costUsd": nil]],
        ]
        let u = PhoneUsage.combine([(Project(repo: "o/a", label: "App"), a), (Project(repo: "o/b"), b)])
        XCTAssertEqual(u["turns"], 4)
        XCTAssertEqual(u["totalTokens"], 650)
        XCTAssertEqual(u["costUsd"], 1.5)
        XCTAssertEqual(u["unpricedTurns"], 1)
        XCTAssertEqual(u["period"], "month")
        XCTAssertEqual(u["month"], "2026-08")
        XCTAssertEqual(u["today"], "2026-08-03")
        XCTAssertEqual(u["buckets"].items.map { $0["date"] }, ["2026-08-01", "2026-08-02"])
        XCTAssertEqual(u["buckets"][0]["totalTokens"], 550)
        XCTAssertEqual(u["buckets"][0]["costUsd"], 0.5)
        XCTAssertEqual(u["buckets"][0]["unpricedTurns"], 1)
        XCTAssertEqual(u["projects"].items.map { $0["key"] }, ["o/b", "o/a"])
        XCTAssertEqual(u["projects"][1]["label"], "App")
        XCTAssertEqual(u["projects"][0]["label"], "o/b")
        XCTAssertEqual(u["providers"].items.map { $0["provider"] }, ["codex", "claude"])
        XCTAssertEqual(u["providers"][1]["totalTokens"], 150)
        XCTAssertEqual(u["models"].items.map { $0["key"] }, ["codex|gpt", "claude|opus"])
        XCTAssertEqual(u["activities"].items.map { $0["activity"] }, ["chat", "issue"])
        XCTAssertEqual(Usage.windowName(u, periodLabel: "This month", locale: Locale(identifier: "en_US")), "August 2026")
    }
}
