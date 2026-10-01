// The board screens' own logic: descriptions as GitHub shows them, the conversation timeline, the files tree and the counts.
import XCTest
@testable import BriareusMacCore

final class BoardLogicTests: XCTestCase {
    func testVisibleMarkdownDropsCommentsAndRawHTMLButKeepsCode() {
        XCTAssertEqual(visibleMarkdown("Hello <!-- hidden --> world"), "Hello  world")
        XCTAssertEqual(visibleMarkdown("Keep\n<!-- open forever\nlost"), "Keep")
        XCTAssertEqual(visibleMarkdown("<img src=x>\nText\n  <details>\nMore"), "Text\nMore")
        XCTAssertEqual(visibleMarkdown("```\n<div>\n```\n<p>"), "```\n<div>\n```")
        XCTAssertEqual(visibleMarkdown("  \n\n"), "")
        XCTAssertEqual(visibleMarkdown("a\r\n<b>\r\nc"), "a\r\nc")
    }

    func testTimelineSortsByTimeAndNestsThreadsUnderTheirReview() {
        let comments = j(#"[{"id":1,"body":"hi","createdAt":"2024-01-01T10:00:00Z"}]"#)
        let reviews = j(#"[{"id":10,"state":"APPROVED","body":"","submittedAt":"2024-01-01T09:00:00Z"},{"id":11,"state":"COMMENTED","body":"","submittedAt":"2024-01-01T11:00:00Z"},{"id":12,"state":"PENDING","body":"x"}]"#)
        let lines = j(#"[{"id":100,"reviewId":11,"createdAt":"2024-01-01T11:00:00Z"},{"id":101,"inReplyTo":100,"createdAt":"2024-01-01T12:00:00Z"},{"id":102,"createdAt":"2024-01-01T08:00:00Z"}]"#)
        let t = convTimeline(comments: comments, reviews: reviews, lines: lines)
        XCTAssertEqual(t.map(\.feed), [.reviewComments, .reviews, .comments, .reviews])
        XCTAssertEqual(t.map(\.index), [2, 0, 0, 1])
        XCTAssertEqual(convThreadRoot(lines, 1), 0)
        XCTAssertEqual(convReviewThreads(reviews: reviews, lines: lines, review: 1), [0])
        XCTAssertEqual(convThread(lines: lines, root: 0), [0, 1])
        // One comment, three line comments and the approval; the bare comment review and the pending one say nothing.
        XCTAssertEqual(convCount(comments: comments, reviews: reviews, lines: lines), 5)
        XCTAssertEqual(ReviewVerdict(j(#"{"state":"changes_requested"}"#)), .changesRequested)
        XCTAssertNil(ReviewVerdict(j(#"{"state":"COMMENTED"}"#)))
    }

    func testThreadRootStopsOnCycles() {
        let lines = j(#"[{"id":1,"inReplyTo":2},{"id":2,"inReplyTo":1}]"#)
        XCTAssertTrue([0, 1].contains(convThreadRoot(lines, 0)))
    }

    func testFileTreeCompactsSortsAndFolds() {
        let files = ["src/b.swift", "src/App/Views/A.swift", "README.md", "src/a.swift", "docs/x/y/z.md"].map(PullFile.init(filename:))
        let tree = FileTree(files)
        let rows = tree.rows(collapsed: [])
        let names = rows.map { tree.nodes[$0.node].name }
        XCTAssertEqual(names, ["docs/x/y", "z.md", "src", "App/Views", "A.swift", "a.swift", "b.swift", "README.md"])
        XCTAssertEqual(rows.map(\.indent), [0, 1, 0, 1, 2, 1, 1, 0])
        let src = rows[2].node
        XCTAssertEqual(tree.nodes[src].path, "src")
        XCTAssertEqual(tree.nodes[rows[3].node].path, "src/App/Views")
        XCTAssertEqual(tree.rows(collapsed: ["src"]).map { tree.nodes[$0.node].name }, ["docs/x/y", "z.md", "src", "README.md"])
        XCTAssertEqual(tree.nodes[rows[4].node].file, 1)
    }

    func testFindingsCountsAndCatalog() {
        let f = j(#"[{"fixed":true,"decision":"fix"},{"decision":"fix"},{"decision":"optional"},{}]"#)
        XCTAssertEqual(findingsUnfixed(f), 3)
        XCTAssertEqual(findingsToFix(f), 1)
        XCTAssertTrue(catalogLists(.null, "implement-feedback"))
        XCTAssertFalse(catalogLists(j(#"[{"id":"review"}]"#), "implement-feedback"))
        XCTAssertTrue(diffstatBlocks(additions: 30, deletions: 10) == (3, 1))
        XCTAssertTrue(diffstatBlocks(additions: 0, deletions: 0) == (0, 0))
    }

    func testIssueRunsMatchTheIssueOrItsPullRequests() {
        let issue = IssueSummary(j(#"{"number":7,"title":"x","pulls":[{"number":9},{"number":3,"repo":"other/repo"}]}"#))!
        XCTAssertTrue(issueRunMatches(Session(raw: j(#"{"repo":"a/b","title":"Issue #7: x"}"#)), issue: issue, repo: "a/b"))
        XCTAssertTrue(issueRunMatches(Session(raw: j(#"{"repo":"a/b","startedOnPr":9}"#)), issue: issue, repo: "a/b"))
        XCTAssertFalse(issueRunMatches(Session(raw: j(#"{"repo":"a/b","startedOnPr":3}"#)), issue: issue, repo: "a/b"))
        XCTAssertFalse(issueRunMatches(Session(raw: j(#"{"repo":"c/d","title":"Issue #7: x"}"#)), issue: issue, repo: "a/b"))
        XCTAssertEqual(runsCost([Session(raw: j(#"{"usage":{"costUsd":1.5}}"#)), Session(raw: j(#"{"costUsd":0.5}"#)), Session(raw: j("{}"))]), 2)
        XCTAssertNil(runsCost([Session(raw: j("{}"))]))
    }
}
