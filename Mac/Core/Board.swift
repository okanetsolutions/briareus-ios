// The project board: what `pulls` answers, read into the rows the Windows client draws.
import Foundation

// MARK: - Labels and links

struct PullLabel: Equatable, Sendable {
    var name: String
    var color: String?

    init(name: String, color: String? = nil) { self.name = name; self.color = color }
    /// An object with a `name`, or a bare name; an empty name is no label.
    init?(_ j: JSON) {
        guard let name = j["name"].string ?? j.string, !name.isEmpty else { return nil }
        self.name = name; color = j["color"].string
    }
    /// GitHub's own colour as red, green and blue in 0...255; nil when it sent none that can be read (six bare hex digits).
    var rgb: (red: Int, green: Int, blue: Int)? {
        guard let color, color.utf8.count == 6 else { return nil }
        var v = 0
        for c in color.utf8 {
            let d: Int
            switch c {
            case 48...57: d = Int(c) - 48
            case 97...102: d = Int(c) - 97 + 10
            case 65...70: d = Int(c) - 65 + 10
            default: return nil
            }
            v = v * 16 + d
        }
        return ((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
    }

    static func parseList(_ value: JSON) -> [PullLabel] { value.items.compactMap(PullLabel.init) }
}

/// An issue or pull request another row points at.
struct BoardLink: Equatable, Sendable {
    var number: Int
    var title: String
    var url: String?
    var repo: String?
    var state: String?
    var stateReason: String?
    var draft: Bool
    var labels: [PullLabel]

    /// Needs a numeric `number`; a missing title reads as "#N".
    init?(_ j: JSON) {
        guard let number = j["number"].truncatedInt else { return nil }
        self.number = number
        title = j["title"].string ?? "#\(number)"
        url = j["url"].string; repo = j["repo"].string
        draft = j["draft"].is(true)
        state = j["state"].string; stateReason = j["stateReason"].string
        labels = PullLabel.parseList(j["labels"])
    }
    /// A link that names no repository is this one's; a name is compared folded.
    func isForeign(_ repo: String?) -> Bool { self.repo.map { !foldEqual($0, repo) } ?? false }
    /// "#4" would read as this repository's #4, so one from elsewhere names its own.
    func reference(_ repo: String?) -> String { isForeign(repo) ? "\(self.repo ?? "")#\(number)" : "#\(number)" }
    var notPlanned: Bool { state == "closed" && stateReason == "not_planned" }

    static func parseList(_ value: JSON) -> [BoardLink] { value.items.compactMap(BoardLink.init) }
}

// MARK: - Pull requests

struct Reviewer: Equatable, Sendable {
    var user: String
    var state: String

    init(user: String, state: String = "") { self.user = user; self.state = state }
}

struct PullSummary: Equatable, Sendable {
    var number: Int
    var title: String
    var url: String?
    /// Never nil: "" when the server sent none.
    var branch: String
    var baseBranch: String
    var author: String?
    var draft: Bool
    var assignees: [String]
    var reviewers: [Reviewer]
    var labels: [PullLabel]
    var issues: [BoardLink]
    /// mergeable, conflicting, or unknown while GitHub is still computing the merge.
    var mergeable: String
    /// success, failure, error, pending or expected; nil without checks.
    var checks: String?
    var reviewDecision: String?
    /// The errand this pull request's state and labels ask for.
    var recommended: String?
    var updatedAt: Date?
    /// The row as the server sent it, which is what is saved and what names its stack.
    var raw: JSON

    /// Needs a numeric `number` of at least 1 (cut to a whole number).
    init?(_ j: JSON) {
        guard let n = j["number"].number, n >= 1, let number = j["number"].truncatedInt else { return nil }
        self.number = number; raw = j
        title = j["title"].string ?? "Pull request #\(number)"
        url = j["url"].string
        branch = j["branch"].string ?? ""
        baseBranch = j["baseBranch"].string ?? ""
        draft = j["draft"].is(true)
        author = j["author"].string
        assignees = j["assignees"].strings
        reviewers = j["reviewers"].items.compactMap { r in r["user"].string.map { Reviewer(user: $0, state: r["state"].string ?? "") } }
        labels = PullLabel.parseList(j["labels"])
        issues = BoardLink.parseList(j["issues"])
        mergeable = j["mergeable"].string ?? "unknown"
        checks = j["checks"].string
        reviewDecision = j["reviewDecision"].string
        recommended = j["recommended"].string
        updatedAt = boardDateParse(j["updatedAt"].string)
    }
    private func carries(_ label: String) -> Bool { labels.contains { foldEqual($0.name, label) } }
    var conflicting: Bool { mergeable == "conflicting" }
    /// The label is set by whoever saw the conflict first and may be ahead of GitHub's own answer.
    var hasConflicts: Bool { conflicting || carries("has-conflicts") }
    /// Red only: a run still going has nothing to fix yet.
    var checksFailed: Bool { checks == "failure" || checks == "error" }
    var awaitsFeedback: Bool { carries("feedback-given") }

    /// Every valid row of a `pulls` array.
    static func parseList(_ array: JSON) -> [PullSummary] { array.items.compactMap(PullSummary.init) }
}

/// The board row of this repository's pull request `number`, or nil.
func pullsFind(_ pulls: [PullSummary], _ number: Int) -> PullSummary? { pulls.first { $0.number == number } }

// MARK: - Issues

struct IssueSummary: Equatable, Sendable {
    var number: Int
    var title: String
    var url: String?
    var author: String?
    var milestone: String?
    var assignees: [String]
    var labels: [PullLabel]
    var comments: Int
    var createdAt: Date?
    var updatedAt: Date?
    var parent: BoardLink?
    /// Sub-issues GitHub tracks under an epic, closed ones included; zero on an ordinary issue.
    var subIssues: Int
    var subIssuesDone: Int
    /// The open pull requests that say they close this issue.
    var pulls: [BoardLink]

    /// Needs a numeric `number` of at least 1.
    init?(_ j: JSON) {
        guard let n = j["number"].number, n >= 1, let number = j["number"].truncatedInt else { return nil }
        self.number = number
        title = j["title"].string ?? "Issue #\(number)"
        url = j["url"].string; author = j["author"].string
        assignees = j["assignees"].strings
        labels = PullLabel.parseList(j["labels"])
        comments = j["comments"].int32 ?? 0
        milestone = j["milestone"].string
        createdAt = boardDateParse(j["createdAt"].string)
        updatedAt = boardDateParse(j["updatedAt"].string)
        parent = BoardLink(j["parent"])
        subIssues = j["subIssues"]["total"].int32 ?? 0
        subIssuesDone = j["subIssues"]["completed"].int32 ?? 0
        pulls = BoardLink.parseList(j["pulls"])
    }
    var isEpic: Bool { subIssues > 0 }

    static func parseList(_ array: JSON) -> [IssueSummary] { array.items.compactMap(IssueSummary.init) }
}

struct IssueRow: Equatable, Sendable {
    var index: Int
    var depth: Int
}

/// Sub-issues drawn under their epic, depth first, each with how deep it sits.
/// Only a parent on the list itself nests its children; a cycle leaves its rows flat.
func issuesNested(_ issues: [IssueSummary], repo: String?) -> [IssueRow] {
    func parentOf(_ issue: IssueSummary) -> Int {
        guard let parent = issue.parent, parent.number != issue.number, !parent.isForeign(repo) else { return 0 }
        return issues.contains { $0.number == parent.number } ? parent.number : 0
    }
    var rows: [IssueRow] = []
    var drawn = [Bool](repeating: false, count: issues.count)
    func draw(_ index: Int, _ depth: Int) {
        if drawn[index] { return }
        drawn[index] = true
        rows.append(IssueRow(index: index, depth: depth))
        for i in issues.indices where parentOf(issues[i]) == issues[index].number { draw(i, depth + 1) }
    }
    for i in issues.indices where parentOf(issues[i]) == 0 { draw(i, 0) }
    for i in issues.indices { draw(i, 0) }
    return rows
}

/// What a session started on this issue is sent, as the Windows client words it. Its first line names the session.
func issuePrompt(_ issue: IssueSummary, repo: String) -> String {
    var s = "Issue #\(issue.number): \(issue.title)\n\n"
    s += "Read \(repo) issue #\(issue.number) in full before you change anything: `gh issue view \(issue.number) --repo \(repo) --comments`. Its comments usually carry decisions the description was written before.\n\n"
    if let parent = issue.parent {
        let parentRepo = parent.isForeign(repo) ? (parent.repo ?? repo) : repo
        s += "It is a sub-issue of \(parentRepo)#\(parent.number) (\(parent.title)). Read that epic too, for the shape this piece has to fit; implement only this issue.\n\n"
    }
    s += "Then implement it on this session\u{2019}s own branch, verify the change the way this repository verifies changes, and open a pull request whose body says `Closes #\(issue.number)`, so merging it closes the issue.\n\n"
    s += "If the issue is too ambiguous to implement as written, say what is missing and stop rather than guessing at it."
    return s
}

/// The board row of issue `number`, or nil when it is not on the list (closed, or past the issue walk's last page).
func issuesFind(_ issues: [IssueSummary], _ number: Int) -> IssueSummary? { issues.first { $0.number == number } }

/// The rows on the list that are sub-issues of `epic` in `repo`, as indices in list order. Closed ones are never there.
func issueOpenSubIssues(_ issues: [IssueSummary], epic: Int, repo: String?) -> [Int] {
    issues.indices.filter { i in
        guard let parent = issues[i].parent else { return false }
        return parent.number == epic && issues[i].number != epic && !parent.isForeign(repo)
    }
}

// MARK: - Filters

/// What the board's pickers filter on, carried by pull requests and issues alike.
struct BoardRow: Equatable, Sendable {
    var author: String?
    var reviewers: [Reviewer]
    var labels: [PullLabel]

    init(author: String?, reviewers: [Reviewer] = [], labels: [PullLabel] = []) { self.author = author; self.reviewers = reviewers; self.labels = labels }
    init(_ pull: PullSummary) { self.init(author: pull.author, reviewers: pull.reviewers, labels: pull.labels) }
    /// Issues have no reviewers.
    init(_ issue: IssueSummary) { self.init(author: issue.author, labels: issue.labels) }

    fileprivate func carried(_ kind: FilterKind) -> [String] {
        switch kind {
        case .author: return author.map { [$0] } ?? []
        case .reviewer: return reviewers.map(\.user)
        case .label: return labels.map(\.name)
        }
    }
}

enum FilterKind: Int, CaseIterable, Sendable {
    case author, reviewer, label
    var name: String {
        switch self { case .author: return "author"; case .reviewer: return "reviewer"; case .label: return "label" }
    }
}

struct FilterOption: Equatable, Sendable {
    /// Folded, as the filter keeps its pick.
    var value: String
    /// As first seen.
    var text: String
    var count: Int
}

/// One author, reviewer and label the board is narrowed to; empty means all. Values are kept folded.
struct BoardFilter: Equatable, Sendable {
    private(set) var author = ""
    private(set) var reviewer = ""
    private(set) var label = ""

    init() {}
    /// The board opens on the project's configured author, but only while they have something open.
    static func opening(author: String?, rows: [BoardRow]) -> BoardFilter {
        var f = BoardFilter()
        guard let author, !author.isEmpty else { return f }
        if rows.contains(where: { foldEqual($0.author, author) }) { f.author = author.asciiFolded }
        return f
    }
    var isOn: Bool { !(author.isEmpty && reviewer.isEmpty && label.isEmpty) }
    /// Setting folds the value; nil clears the pick.
    subscript(kind: FilterKind) -> String {
        get { switch kind { case .author: return author; case .reviewer: return reviewer; case .label: return label } }
        set { set(kind, newValue) }
    }
    mutating func set(_ kind: FilterKind, _ value: String?) {
        let v = (value ?? "").asciiFolded
        switch kind { case .author: author = v; case .reviewer: reviewer = v; case .label: label = v }
    }
    /// `skipping` leaves one picker out, which is how each counts what it would show without counting itself.
    func passes(_ row: BoardRow, skipping: FilterKind? = nil) -> Bool {
        for kind in FilterKind.allCases where kind != skipping {
            let pick = self[kind]
            if pick.isEmpty { continue }
            if !row.carried(kind).contains(where: { foldEqual($0, pick) }) { return false }
        }
        return true
    }
    /// What one picker offers, each counted against the other two. A pick they have emptied still lists itself.
    /// Case variants fold into one option named as first seen, a value twice on one row counts once, and options sort
    /// ignoring case.
    func options(_ kind: FilterKind, rows: [BoardRow]) -> [FilterOption] {
        var options: [FilterOption] = []
        for row in rows where passes(row, skipping: kind) {
            var seen: [String] = []
            for value in row.carried(kind) {
                if seen.contains(where: { foldEqual($0, value) }) { continue }
                seen.append(value)
                if let k = options.firstIndex(where: { foldEqual($0.value, value) }) { options[k].count += 1 }
                else { options.append(FilterOption(value: value.asciiFolded, text: value, count: 1)) }
            }
        }
        let pick = self[kind]
        if !pick.isEmpty, !options.contains(where: { $0.value == pick }) { options.append(FilterOption(value: pick, text: pick, count: 0)) }
        return options.sorted { a, b in
            let fa = a.text.asciiFolded, fb = b.text.asciiFolded
            if !fa.utf8.elementsEqual(fb.utf8) { return fa.bytesPrecede(fb) }
            return a.text.bytesPrecede(b.text)
        }
    }
}

// MARK: - Actions

/// The question an errand asks before it starts.
struct ActionInput: Equatable, Sendable {
    var label: String
    var placeholder: String
    var required: Bool
}

/// An errand the board runs on a pull request: a paid session started with a prompt the server owns.
struct BoardAction: Equatable, Sendable {
    var id: String
    var label: String
    var hint: String
    var input: ActionInput?

    init(id: String, label: String, hint: String = "", input: ActionInput? = nil) { self.id = id; self.label = label; self.hint = hint; self.input = input }

    /// The call that starts it: `serve_pull` for Run, `review` for Code review, and `action` (with the errand's id) for the rest.
    var operation: String { id == "run" ? "serve_pull" : id == "review" ? "review" : "action" }
    /// Run answers only once the workspace is prepared and serving, which takes longer than a request is given. Nil = default.
    var timeoutMs: Int? { id == "run" ? 170_000 : nil }
    /// Review checks the branch out itself; the rest look the pull request up by number. Input is sent trimmed, and only to
    /// an errand that asks for it.
    func arguments(repo: String, number: Int, branch: String? = nil, input: String? = nil) -> JSON {
        var args: JSON = ["repo": .string(repo), "prNumber": JSON(number)]
        if id == "review" { if let branch { args["branch"] = .string(branch) } }
        else if id != "run" { args["action"] = .string(id) }
        if self.input != nil, let input {
            let trimmed = input.cTrimmed
            if !trimmed.isEmpty { args["input"] = .string(trimmed) }
        }
        return args
    }

    /// The board's errands, in the order the Windows client shows them.
    static let known: [BoardAction] = [
        BoardAction(id: "run", label: "Run", hint: "Prepare this pull request in a clean workspace and serve the app from it"),
        BoardAction(id: "review", label: "Code review", hint: "Run the provider\u{2019}s code review on this pull request and publish it"),
        BoardAction(id: "solve-conflicts", label: "Solve conflicts", hint: "Merge the base branch in, resolve the conflicts and push the result"),
        BoardAction(id: "fix-checks", label: "Fix failing checks", hint: "Read this pull request\u{2019}s failing CI checks, fix what the branch broke and push the fixes"),
        BoardAction(id: "implement-feedback", label: "Implement feedback", hint: "Address the review findings on this pull request, push the fixes, and have those changes reviewed automatically"),
        BoardAction(id: "custom-feedback", label: "Give feedback", hint: "Say in your own words what to change on this pull request, and it is implemented and pushed",
                    input: ActionInput(label: "Your feedback", placeholder: "What should change on this pull request?", required: true)),
        BoardAction(id: "pr-body-summary", label: "PR body", hint: "Rewrite this pull request\u{2019}s description from its own diff, following the team template"),
        BoardAction(id: "delete-self-comments", label: "Delete my comments", hint: "Remove every comment and review the configured GitHub account left on this pull request"),
    ]
    /// Errands this app no longer offers, even when the server still lists them.
    private static let dropped: Set<String> = ["qa", "test-sheet", "test-run"]

    /// The errands worth offering on one pull request. `catalog` is what the server's `actions` lists; null or empty before it
    /// is known, when every errand this app knows is offered. `failedChecks` is the Checks tab's count of failed checks.
    static func offered(catalog: JSON, pull: PullSummary?, failedChecks: Int) -> [BoardAction] {
        // What the server lists, by id, in its order; a later entry for one id replaces the earlier one in its place.
        var served: [BoardAction] = []
        for entry in catalog.items {
            guard let id = entry["id"].string, let label = entry["label"].string else { continue }
            var a = BoardAction(id: id, label: label, hint: entry["hint"].string ?? "")
            if let inputLabel = entry["input"]["label"].string {
                a.input = ActionInput(label: inputLabel, placeholder: entry["input"]["placeholder"].string ?? "", required: entry["input"]["required"].is(true))
            }
            if let k = served.firstIndex(where: { $0.id == id }) { served[k] = a } else { served.append(a) }
        }
        var out: [BoardAction] = []
        for k in known {
            let s = served.first { $0.id == k.id }
            let offered: Bool
            // Run and Review have routes of their own; the rest are errands the server has to list.
            if !served.isEmpty && s == nil && k.id != "run" && k.id != "review" { offered = false }
            else if k.id == "solve-conflicts" { offered = pull?.hasConflicts ?? true }
            else if k.id == "fix-checks" { offered = failedChecks > 0 || (pull?.checksFailed ?? false) }
            else if k.id == "implement-feedback" { offered = pull?.awaitsFeedback ?? true }
            else { offered = true }
            guard offered else { continue }
            // The server words the question and adds errands this app predates.
            var a = k
            if let s, s.input != nil { a.input = s.input }
            out.append(a)
        }
        for s in served where !known.contains(where: { $0.id == s.id }) && !dropped.contains(s.id) { out.append(s) }
        return out
    }
}

// MARK: - Merge

/// What is worth a word before a merge is confirmed. `mergeable` is GitHub's answer (null while it is still checking).
func mergeWarnings(mergeable: JSON, state: String?) -> [String] {
    var notes: [String] = []
    if mergeable.is(false) { notes.append("This branch has conflicts that must be resolved before it can merge.") }
    if mergeable.isNull { notes.append("GitHub is still checking whether this branch can merge.") }
    if state == "blocked" { notes.append("GitHub reports this pull request as blocked: a required review or check is missing.") }
    else if state == "behind" { notes.append("This branch is behind its base branch and may need updating before it can merge.") }
    return notes
}

// MARK: - Reviews

/// The overall verdict a pull request carries, read from GitHub's review decision and the reviewers themselves.
enum ReviewStatus: Equatable, Sendable {
    case none, approved, changesRequested, feedback, requested

    /// GitHub's own decision wins; without one, changes outweigh approval, approval feedback, and feedback a request.
    init(decision: String?, reviews: JSON) {
        var changes = false, approved = false, commented = false, requested = false
        for r in reviews.items {
            switch (r["state"].string ?? "").asciiFolded {
            case "changes_requested": changes = true
            case "approved": approved = true
            case "commented": commented = true
            case "requested": requested = true
            default: break
            }
        }
        let d = (decision ?? "").asciiFolded
        if d == "approved" { self = .approved }
        else if d == "changes_requested" { self = .changesRequested }
        else if changes { self = .changesRequested }
        else if approved { self = .approved }
        else if commented { self = .feedback }
        else if d == "review_required" || requested { self = .requested }
        else { self = .none }
    }
    init(decision: String?, reviewers: [Reviewer]) {
        self.init(decision: decision, reviews: .array(reviewers.map { ["state": .string($0.state)] }))
    }
    var text: String {
        switch self {
        case .approved: return "Approved"
        case .changesRequested: return "Changes requested"
        case .feedback: return "Feedback given"
        case .requested: return "Review requested"
        case .none: return ""
        }
    }
}

// MARK: - Stacks

/// One pull request of a stack: `depth` 1 is the bottom.
struct StackItem: Equatable, Sendable {
    var number: Int
    var title: String
    /// Nil until the board's rows fill it in, when the chain does not name it.
    var branch: String?
    var depth: Int
    var draft: Bool
}

/// Where a pull request sits in a stack of branches built on each other, 1 being the bottom. `branch` and `base` (the
/// branch the bottom merges into) are nil until the board's rows fill them in.
struct StackPosition: Equatable, Sendable {
    var position: Int
    var total: Int
    var partial: Bool
    var base: String?
    var chain: [StackItem]

    private init?(header value: JSON) {
        guard let position = value["position"].truncatedInt, let total = value["total"].truncatedInt else { return nil }
        self.position = position; self.total = total; partial = value["partial"].is(true); base = nil; chain = []
    }
    private static func chain(_ value: JSON) -> [StackItem] {
        value.items.compactMap { item in
            guard let number = item["number"].truncatedInt else { return nil }
            return StackItem(number: number, title: item["title"].string ?? "Pull request #\(number)",
                             branch: item["branch"].nonEmpty ?? item["headRef"].nonEmpty,
                             depth: item["depth"].int32 ?? 1, draft: item["draft"].is(true))
        }
    }
    /// A row's `stack` with its chain looked up in the answer's `stacks` by the stack's id, a number or a string.
    init?(_ value: JSON, stacks: JSON) {
        self.init(header: value)
        let id: String
        if let n = value["id"].truncatedInt { id = String(n) } else { id = value["id"].string ?? "" }
        chain = StackPosition.chain(stacks[id])
    }
    /// What `json` saved.
    init?(restoring value: JSON) {
        self.init(header: value)
        base = value["base"].nonEmpty
        chain = StackPosition.chain(value["chain"])
    }
    /// The stack as one object, chain and branches included, so a saved pull request opens with its overview.
    var json: JSON {
        var value: JSON = ["position": JSON(position), "total": JSON(total), "partial": .bool(partial)]
        if let base { value["base"] = .string(base) }
        value["chain"] = .array(chain.map { item in
            var o: JSON = ["number": JSON(item.number), "title": .string(item.title), "depth": JSON(item.depth)]
            if let branch = item.branch { o["branch"] = .string(branch) }
            if item.draft { o["draft"] = true }
            return o
        })
        return value
    }
    /// "2/3" or "2/3+"; nil `number` (or one not in the chain) asks for the stack's own position.
    func label(_ number: Int? = nil) -> String {
        let depth = chain.first { number != nil && number != 0 && $0.number == number }?.depth ?? position
        return "\(depth)/\(total)\(partial ? "+" : "")"
    }
    /// Each item's branch, and the branch the bottom one merges into, from the rows the board lists them on.
    mutating func fillBranches(_ rows: [PullSummary]) {
        var bottom: Int?
        for i in chain.indices {
            if chain[i].branch == nil, let row = pullsFind(rows, chain[i].number), !row.branch.isEmpty { chain[i].branch = row.branch }
            if bottom == nil || chain[i].depth < chain[bottom!].depth { bottom = i }
        }
        // A chain only partly visible may not reach the bottom, whose base is then unknown.
        guard let bottom, !(partial && chain[bottom].depth > 1) else { return }
        if let row = pullsFind(rows, chain[bottom].number), !row.baseBranch.isEmpty { base = row.baseBranch }
    }
    /// The chain top first, as GitHub's stack popover lists it: the index of the item at each row. Items of one depth keep
    /// the server's order.
    var topFirst: [Int] {
        var order = Array(chain.indices)
        for i in 1..<max(order.count, 1) {
            let v = order[i]; var k = i
            while k > 0, chain[order[k - 1]].depth < chain[v].depth { order[k] = order[k - 1]; k -= 1 }
            order[k] = v
        }
        return order
    }
}

/// An https URL with a host and no credentials.
func safeWebURL(_ value: String?) -> Bool {
    guard let value, value.utf8.starts(with: "https://".utf8) else { return false }
    let authority = value.utf8.dropFirst(8).prefix { $0 != UInt8(ascii: "/") && $0 != UInt8(ascii: "?") && $0 != UInt8(ascii: "#") }
    return !authority.isEmpty && !authority.contains(UInt8(ascii: "@"))
}

// MARK: - ▶ Run

/// A project's run profiles, the default first, from what `projects` answers (the object or its array). Empty when the
/// project lists none or is not listed.
func runProfilesParse(_ projects: JSON, repo: String) -> [String] {
    guard let row = listOf(projects, "projects").items.first(where: { $0["repo"].string == repo }) else { return [] }
    return row["runProfiles"].items.compactMap(\.nonEmpty)
}
/// The session a ▶ Run on pull request `number` is preparing while `serve_pull` waits: the newest of its sessions titled
/// "Run: #…", from what `sessions` answers. Nil without one.
func runSessionPreparing(_ sessions: JSON, number: Int) -> String? {
    var best: String?, bestAt = ""
    for raw in listOf(sessions, "sessions").items {
        let s = Session(raw: raw)
        guard (s.pullNumber ?? 0) == number, let title = raw["title"].string, title.utf8.starts(with: "Run: #".utf8) else { continue }
        let at = raw["createdAt"].string ?? ""
        if best == nil || bestAt.bytesPrecede(at) { best = s.id; bestAt = at }
    }
    return best
}
/// A ▶ Run already serving pull request `number`: one of its sessions with an https serve link.
func runSessionServing(_ sessions: JSON, number: Int) -> (sessionId: String, url: String)? {
    for raw in listOf(sessions, "sessions").items {
        let s = Session(raw: raw)
        let url = raw["serveLinks"][0]["url"].string
        guard (s.pullNumber ?? 0) == number, safeWebURL(url), let url else { continue }
        return (s.id, url)
    }
    return nil
}
