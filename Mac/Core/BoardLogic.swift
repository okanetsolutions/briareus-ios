// What the board, the pull request screen and the issue screen work out without drawing anything: a description as GitHub
// shows it, the Conversation tab's timeline, the Files changed tree, the findings counts and an issue's own conversations.
// Ported from the Windows client's screen_pulls.c and screen_files.c.
import Foundation

// MARK: - Descriptions

/// What GitHub shows of a description: without HTML comments and raw HTML lines (bots' badges and footers), code blocks
/// kept whole. An unterminated comment hides the rest. The result is trimmed.
func visibleMarkdown(_ body: String) -> String {
    var bare = ""
    var rest = Substring(body)
    while !rest.isEmpty {
        if rest.hasPrefix("<!--") {
            guard let end = rest.dropFirst(4).range(of: "-->") else { break }
            rest = rest[end.upperBound...]
            continue
        }
        bare.append(rest.removeFirst())
    }
    var out = ""
    var fenced = false
    // By scalars: a CR LF is one Character, and C splits on the LF alone.
    for scalars in bare.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(String.UnicodeScalarView(scalars))
        let t = line.cTrimmed
        let fence = t.hasPrefix("```")
        if fence { fenced.toggle() }
        if fenced || fence || !t.hasPrefix("<") { out += line + "\n" }
    }
    return out.cTrimmed
}

// MARK: - Conversation

/// The Conversation tab's lists, in the order their entries sort on a tie.
enum ConvFeed: Int, CaseIterable, Sendable {
    case comments, reviews, reviewComments
    /// The call that reads it and the field its rows come in.
    var operation: String { ["pull_comments", "pull_reviews", "pull_review_comments"][rawValue] }
    var field: String { ["comments", "reviews", "reviewComments"][rawValue] }
}

/// When a comment or review was made, as seconds since 1970; 0 when the server left it out.
func convTime(_ v: JSON, _ field: String) -> Int { boardDateEpoch(v[field].string) ?? 0 }

private func convFind(_ list: JSON, _ id: JSON) -> Int? {
    guard let want = id.number else { return nil }
    return list.items.firstIndex { $0["id"].number == want }
}
/// The comment a line comment's thread starts with: each reply points at the comment it answers.
func convThreadRoot(_ lines: JSON, _ index: Int) -> Int {
    var i = index
    for _ in 0..<64 {
        guard let parent = convFind(lines, lines[i]["inReplyTo"]), parent != i else { break }
        i = parent
    }
    return i
}
/// The submitted review a thread is shown under, when the server listed it.
func convThreadReview(reviews: JSON, lines: JSON, root: Int) -> Int? {
    guard let r = convFind(reviews, lines[root]["reviewId"]), !foldEqual(reviews[r]["state"].string, "pending") else { return nil }
    return r
}

/// A review's verdict, as its header words it.
enum ReviewVerdict: Equatable, Sendable {
    case approved, changesRequested, dismissed
    init?(_ review: JSON) {
        let state = review["state"].string
        if foldEqual(state, "approved") { self = .approved }
        else if foldEqual(state, "changes_requested") { self = .changesRequested }
        else if foldEqual(state, "dismissed") { self = .dismissed }
        else { return nil }
    }
    var words: String {
        switch self {
        case .approved: return "approved these changes"
        case .changesRequested: return "requested changes"
        case .dismissed: return "reviewed (dismissed)"
        }
    }
}
private func hasVisibleBody(_ v: JSON) -> Bool { v["body"].string.map { !visibleMarkdown($0).isEmpty } ?? false }
/// A review says something of its own with a verdict or a summary; one that only holds line comments is shown for them.
func reviewSpeaks(_ review: JSON) -> Bool {
    if foldEqual(review["state"].string, "pending") { return false }
    return ReviewVerdict(review) != nil || hasVisibleBody(review)
}
private func reviewHasThreads(reviews: JSON, lines: JSON, _ r: Int) -> Bool {
    lines.items.indices.contains { i in convThreadRoot(lines, i) == i && convThreadReview(reviews: reviews, lines: lines, root: i) == r }
}
/// The messages in the conversation: every comment, every line comment and each review with a verdict or summary.
func convCount(comments: JSON, reviews: JSON, lines: JSON) -> Int {
    comments.count + lines.count + reviews.items.filter(reviewSpeaks).count
}

/// One entry of the timeline: a comment, a review, or a line comment thread whose review is not listed.
struct ConvEntry: Equatable, Sendable {
    var feed: ConvFeed
    var index: Int
    var at: Int
}
/// The timeline, oldest first; a tie sorts comments, then reviews, then line comments, each in list order.
func convTimeline(comments: JSON, reviews: JSON, lines: JSON) -> [ConvEntry] {
    var e: [ConvEntry] = []
    for (i, c) in comments.items.enumerated() { e.append(ConvEntry(feed: .comments, index: i, at: convTime(c, "createdAt"))) }
    for (i, r) in reviews.items.enumerated() {
        if foldEqual(r["state"].string, "pending") { continue }
        if reviewSpeaks(r) || reviewHasThreads(reviews: reviews, lines: lines, i) { e.append(ConvEntry(feed: .reviews, index: i, at: convTime(r, "submittedAt"))) }
    }
    for i in lines.items.indices where convThreadRoot(lines, i) == i && convThreadReview(reviews: reviews, lines: lines, root: i) == nil {
        e.append(ConvEntry(feed: .reviewComments, index: i, at: convTime(lines[i], "createdAt")))
    }
    return e.sorted { x, y in
        if x.at != y.at { return x.at < y.at }
        if x.feed != y.feed { return x.feed.rawValue < y.feed.rawValue }
        return x.index < y.index
    }
}
/// The roots of the line comment threads shown under review `review`, in list order.
func convReviewThreads(reviews: JSON, lines: JSON, review: Int) -> [Int] {
    lines.items.indices.filter { i in convThreadRoot(lines, i) == i && convThreadReview(reviews: reviews, lines: lines, root: i) == review }
}
/// The comments of the thread starting at `root`, in list order.
func convThread(lines: JSON, root: Int) -> [Int] { lines.items.indices.filter { convThreadRoot(lines, $0) == root } }

// MARK: - Findings

/// The findings not yet fixed.
func findingsUnfixed(_ findings: JSON) -> Int { findings.items.filter { !$0["fixed"].is(true) }.count }
/// The findings not yet fixed that the user marked fix.
func findingsToFix(_ findings: JSON) -> Int { findings.items.filter { !$0["fixed"].is(true) && $0["decision"].string == "fix" }.count }
/// Whether the server's errand list has one; before the list is read, every errand this app knows is taken as offered.
func catalogLists(_ catalog: JSON, _ id: String) -> Bool { catalog.count == 0 || catalog.items.contains { $0["id"].string == id } }

// MARK: - Diffstat

/// `.diffstat-block-*`: of five squares, how many are green and how many red.
func diffstatBlocks(additions: Int, deletions: Int) -> (green: Int, red: Int) {
    let total = additions + deletions
    guard total > 0 else { return (0, 0) }
    return (5 * additions / total, 5 * deletions / total)
}

// MARK: - Files changed tree

/// The tree of a pull request's changed paths, as GitHub's file tree: directories first, then by name ignoring case; a
/// directory holding only one directory is shown as one row, `a/b/c`.
struct FileTree: Equatable, Sendable {
    struct Node: Equatable, Sendable {
        var name: String
        /// The full directory path (files: the filename).
        var path: String
        /// The index into the file list; nil for a directory.
        var file: Int?
        var kids: [Int] = []
        var depth: Int
        /// Taken into its parent by compaction.
        var dropped = false
    }
    /// One visible row: its node and how far it is indented (0 for the top level).
    struct Row: Equatable, Sendable {
        var node: Int
        var indent: Int
    }
    private(set) var nodes: [Node] = []

    init(_ files: [PullFile]) {
        nodes = [Node(name: "", path: "", file: nil, depth: 0)]
        for (i, f) in files.enumerated() {
            let parts = f.filename.split(separator: "/", omittingEmptySubsequences: false)
            var parent = 0, prefix = ""
            for (k, part) in parts.enumerated() {
                if part.isEmpty && k == parts.count - 1 && k > 0 { break }   // a trailing slash names nothing more
                prefix = k == 0 ? String(part) : prefix + "/" + part
                let isDir = k < parts.count - 1
                var found: Int?
                if isDir { found = nodes[parent].kids.first { nodes[$0].file == nil && nodes[$0].name == part } }
                if found == nil {
                    nodes.append(Node(name: String(part), path: prefix, file: isDir ? nil : i, depth: nodes[parent].depth + 1))
                    found = nodes.count - 1
                    nodes[parent].kids.append(found!)
                }
                parent = found!
            }
        }
        compact(0)
        depths(0, 0)
        sort(0)
    }
    private mutating func compact(_ index: Int) {
        while nodes[index].file == nil, nodes[index].depth > 0, nodes[index].kids.count == 1, nodes[nodes[index].kids[0]].file == nil {
            let only = nodes[index].kids[0]
            nodes[index].name += "/" + nodes[only].name
            nodes[index].path = nodes[only].path
            nodes[index].kids = nodes[only].kids
            nodes[only].kids = []; nodes[only].dropped = true
        }
        for k in nodes[index].kids { compact(k) }
    }
    private mutating func depths(_ index: Int, _ depth: Int) {
        nodes[index].depth = depth
        for k in nodes[index].kids { depths(k, depth + 1) }
    }
    private mutating func sort(_ index: Int) {
        let n = nodes
        nodes[index].kids.sort { a, b in
            let x = n[a], y = n[b]
            if (x.file == nil) != (y.file == nil) { return x.file == nil }
            return x.name.asciiFolded.bytesPrecede(y.name.asciiFolded)
        }
        for k in nodes[index].kids { sort(k) }
    }
    /// The rows shown, depth first, skipping what folded directories (by path) hold.
    func rows(collapsed: Set<String>) -> [Row] {
        var out: [Row] = []
        func walk(_ i: Int) {
            let n = nodes[i]
            if n.dropped { return }
            if n.depth > 0 {
                out.append(Row(node: i, indent: n.depth - 1))
                if n.file == nil && collapsed.contains(n.path) { return }
            }
            for k in n.kids { walk(k) }
        }
        if !nodes.isEmpty { walk(0) }
        return out
    }
}

// MARK: - Issues

/// Whether a conversation belongs on an issue's screen: started on the issue, or on one of this repository's pull requests
/// closing it.
func issueRunMatches(_ run: Session, issue: IssueSummary, repo: String) -> Bool {
    guard run.repo == repo else { return false }
    if run.onIssue(issue.number) { return true }
    guard let pr = run.pullNumber else { return false }
    return issue.pulls.contains { $0.number == pr && !$0.isForeign(repo) }
}
/// What the conversations spent, each counted with the workers it ordered; nil when none was priced.
func runsCost(_ runs: [Session]) -> Double? {
    var total = 0.0, any = false
    for r in runs {
        if let c = r.raw["usage"]["costUsd"].number ?? r.raw["costUsd"].number { total += c; any = true }
    }
    return any ? total : nil
}
