import Foundation

// The project board: what `pulls` answers, read into the rows the dashboard draws.

/// Logins and label names are compared folded: GitHub hands the same person back in either case.
private func fold(_ value: String?) -> String { (value ?? "").lowercased() }

private func names(_ value: JSONValue) -> [String] { value.array.compactMap(\.string) }

public enum BoardDate {
    /// GitHub's timestamps come with and without fractional seconds.
    public static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}

public struct PullLabel: Hashable, Sendable {
    public let name: String
    public let color: String?
    public init?(_ value: JSONValue) {
        guard let name = value["name"].string ?? value.string, !name.isEmpty else { return nil }
        self.name = name; color = value["color"].string
    }
    /// GitHub's own colour as red, green and blue in 0...1, or nil when it sent none that can be read.
    public var rgb: [Double]? {
        guard let color, color.count == 6, let hex = UInt32(color, radix: 16) else { return nil }
        return [16, 8, 0].map { Double((hex >> $0) & 0xFF) / 255 }
    }
}

/// An issue or pull request another row points at.
public struct BoardLink: Hashable, Sendable {
    public let number: Int
    public let title: String
    public let url: String?
    public let repo: String?
    public let draft: Bool
    public let state: String?
    public let stateReason: String?
    public let labels: [PullLabel]
    public init?(_ value: JSONValue) {
        guard let number = value["number"].double else { return nil }
        self.number = Int(number); title = value["title"].string ?? "#\(Int(number))"
        url = value["url"].string; repo = value["repo"].string; draft = value["draft"].bool == true
        state = value["state"].string; stateReason = value["stateReason"].string
        labels = value["labels"].array.compactMap(PullLabel.init)
    }
    public func isForeign(to repo: String) -> Bool { self.repo.map { fold($0) != fold(repo) } ?? false }
    /// "#4" would read as this repository's #4, so one from elsewhere names its own.
    public func reference(in repo: String) -> String { isForeign(to: repo) ? "\(self.repo ?? "")#\(number)" : "#\(number)" }
    public var notPlanned: Bool { state == "closed" && stateReason == "not_planned" }
}

/// What the board's pickers filter on, carried by pull requests and issues alike.
public protocol BoardRow {
    var author: String? { get }
    var reviewerNames: [String] { get }
    var labels: [PullLabel] { get }
}

public struct PullSummary: Identifiable, BoardRow, Sendable {
    public struct Reviewer: Hashable, Sendable {
        public let user: String
        public let state: String
    }
    public let number: Int
    public let title: String
    public let url: String?
    public let branch: String
    public let baseBranch: String
    public let draft: Bool
    public let author: String?
    public let assignees: [String]
    public let reviewers: [Reviewer]
    public let labels: [PullLabel]
    public let issues: [BoardLink]
    /// mergeable, conflicting, or unknown while GitHub is still computing the merge.
    public let mergeable: String
    /// success, failure, error, pending or expected; nil without checks.
    public let checks: String?
    public let reviewDecision: String?
    /// The errand this pull request's state and labels ask for.
    public let recommended: String?
    public let updatedAt: Date?
    /// The row as the server sent it, which is what is saved and what names its stack.
    public let raw: JSONValue
    public init?(_ value: JSONValue) {
        guard let number = value["number"].double, number >= 1 else { return nil }
        self.number = Int(number); raw = value
        title = value["title"].string ?? "Pull request #\(Int(number))"
        url = value["url"].string; branch = value["branch"].string ?? ""; baseBranch = value["baseBranch"].string ?? ""
        draft = value["draft"].bool == true; author = value["author"].string
        assignees = names(value["assignees"])
        reviewers = value["reviewers"].array.compactMap { r in r["user"].string.map { Reviewer(user: $0, state: r["state"].string ?? "") } }
        labels = value["labels"].array.compactMap(PullLabel.init)
        issues = value["issues"].array.compactMap(BoardLink.init)
        mergeable = value["mergeable"].string ?? "unknown"
        checks = value["checks"].string; reviewDecision = value["reviewDecision"].string
        recommended = value["recommended"].string
        updatedAt = BoardDate.parse(value["updatedAt"].string)
    }
    public var id: Int { number }
    public var reviewerNames: [String] { reviewers.map(\.user) }
    public var conflicting: Bool { mergeable == "conflicting" }
    /// The label is set by whoever saw the conflict first and may be ahead of GitHub's own answer.
    public var hasConflicts: Bool { conflicting || carries("has-conflicts") }
    /// Red only: a run still going has nothing to fix yet.
    public var checksFailed: Bool { checks == "failure" || checks == "error" }
    public var awaitsFeedback: Bool { carries("feedback-given") }
    private func carries(_ label: String) -> Bool { labels.contains { fold($0.name) == label } }
}

public struct IssueSummary: Identifiable, BoardRow, Sendable {
    public let number: Int
    public let title: String
    public let url: String?
    public let author: String?
    public let assignees: [String]
    public let labels: [PullLabel]
    public let comments: Int
    public let milestone: String?
    public let updatedAt: Date?
    public let parent: BoardLink?
    /// Sub-issues GitHub tracks under an epic, closed ones included; zero on an ordinary issue.
    public let subIssues: Int
    public let subIssuesDone: Int
    /// The open pull requests that say they close this issue.
    public let pulls: [BoardLink]
    public init?(_ value: JSONValue) {
        guard let number = value["number"].double, number >= 1 else { return nil }
        self.number = Int(number); title = value["title"].string ?? "Issue #\(Int(number))"
        url = value["url"].string; author = value["author"].string
        assignees = names(value["assignees"])
        labels = value["labels"].array.compactMap(PullLabel.init)
        comments = Int(value["comments"].double ?? 0); milestone = value["milestone"].string
        updatedAt = BoardDate.parse(value["updatedAt"].string)
        parent = BoardLink(value["parent"])
        subIssues = Int(value["subIssues"]["total"].double ?? 0)
        subIssuesDone = Int(value["subIssues"]["completed"].double ?? 0)
        pulls = value["pulls"].array.compactMap(BoardLink.init)
    }
    public var id: Int { number }
    public var reviewerNames: [String] { [] }
    public var isEpic: Bool { subIssues > 0 }

    /// Sub-issues drawn under their epic, depth first, each with how deep it sits.
    /// Only a parent on the list itself nests its children; a cycle leaves its rows flat.
    public static func nested(_ issues: [IssueSummary], repo: String) -> [(issue: IssueSummary, depth: Int)] {
        let listed = Set(issues.map(\.number))
        func parent(of issue: IssueSummary) -> Int? {
            guard let parent = issue.parent, parent.number != issue.number, !parent.isForeign(to: repo),
                  listed.contains(parent.number) else { return nil }
            return parent.number
        }
        let children = Dictionary(grouping: issues.filter { parent(of: $0) != nil }) { parent(of: $0)! }
        var drawn = Set<Int>()
        var rows: [(issue: IssueSummary, depth: Int)] = []
        func draw(_ issue: IssueSummary, _ depth: Int) {
            guard drawn.insert(issue.number).inserted else { return }
            rows.append((issue, depth))
            for child in children[issue.number] ?? [] { draw(child, depth + 1) }
        }
        for issue in issues where parent(of: issue) == nil { draw(issue, 0) }
        for issue in issues { draw(issue, 0) }
        return rows
    }

    /// What a session started on this issue is sent, as the dashboard words it. Its first line names the session.
    public func prompt(repo: String) -> String {
        var lines = [
            "Issue #\(number): \(title)", "",
            "Read \(repo) issue #\(number) in full before you change anything: `gh issue view \(number) --repo \(repo) --comments`. Its comments usually carry decisions the description was written before.", "",
        ]
        if let parent {
            lines += ["It is a sub-issue of \(parent.isForeign(to: repo) ? parent.repo ?? repo : repo)#\(parent.number) (\(parent.title)). Read that epic too, for the shape this piece has to fit; implement only this issue.", ""]
        }
        lines += [
            "Then implement it on this session’s own branch, verify the change the way this repository verifies changes, and open a pull request whose body says `Closes #\(number)`, so merging it closes the issue.", "",
            "If the issue is too ambiguous to implement as written, say what is missing and stop rather than guessing at it.",
        ]
        return lines.joined(separator: "\n")
    }
}

/// One author, reviewer and label the board is narrowed to; empty means all.
public struct BoardFilter: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable { case author, reviewer, label }
    public struct Option: Identifiable, Equatable, Sendable {
        public let value: String
        public let text: String
        public let count: Int
        public var id: String { value }
    }
    public var author = ""
    public var reviewer = ""
    public var label = ""
    public init() {}
    /// The board opens on the project's configured author, but only while they have something open.
    public init(opening author: String?, rows: [BoardRow]) {
        let author = fold(author)
        if !author.isEmpty, rows.contains(where: { fold($0.author) == author }) { self.author = author }
    }
    public var isOn: Bool { !(author.isEmpty && reviewer.isEmpty && label.isEmpty) }
    public subscript(kind: Kind) -> String {
        get { kind == .author ? author : kind == .reviewer ? reviewer : label }
        set {
            switch kind {
            case .author: author = fold(newValue)
            case .reviewer: reviewer = fold(newValue)
            case .label: label = fold(newValue)
            }
        }
    }
    private func carried(_ kind: Kind, by row: BoardRow) -> [String] {
        switch kind {
        case .author: return row.author.map { [$0] } ?? []
        case .reviewer: return row.reviewerNames
        case .label: return row.labels.map(\.name)
        }
    }
    /// `skipping` leaves one picker out, which is how each counts what it would show without counting itself.
    public func passes(_ row: BoardRow, skipping: Kind? = nil) -> Bool {
        Kind.allCases.allSatisfy { kind in
            kind == skipping || self[kind].isEmpty || carried(kind, by: row).contains { fold($0) == self[kind] }
        }
    }
    /// What one picker offers, each counted against the other two. A pick they have emptied still lists itself.
    public func options(_ kind: Kind, in rows: [BoardRow]) -> [Option] {
        var counts: [String: (text: String, count: Int)] = [:]
        for row in rows where passes(row, skipping: kind) {
            var seen = Set<String>()
            for text in carried(kind, by: row) where seen.insert(fold(text)).inserted {
                counts[fold(text), default: (text, 0)].count += 1
            }
        }
        if !self[kind].isEmpty, counts[self[kind]] == nil { counts[self[kind]] = (self[kind], 0) }
        return counts.map { Option(value: $0.key, text: $0.value.text, count: $0.value.count) }
            .sorted { $0.text.localizedCaseInsensitiveCompare($1.text) == .orderedAscending }
    }
}

/// An errand the board runs on a pull request: a paid session started with a prompt the server owns.
public struct BoardAction: Identifiable, Hashable, Sendable {
    public struct Input: Hashable, Sendable {
        public let label: String
        public let placeholder: String
        public let required: Bool
    }
    public let id: String
    public let label: String
    public let hint: String
    public let input: Input?
    public init(id: String, label: String, hint: String, input: Input? = nil) {
        self.id = id; self.label = label; self.hint = hint; self.input = input
    }
    public var operation: String { id == "run" ? "serve_pull" : id.replacingOccurrences(of: "-", with: "_") }
    /// Run answers only once the workspace is prepared and serving, which takes longer than a request is given.
    public var timeout: TimeInterval? { id == "run" ? 170 : nil }
    /// Review and QA check the branch out themselves; the rest look the pull request up by number.
    public func arguments(repo: String, number: Int, branch: String?, input: String? = nil) -> [String: JSONValue] {
        var args: [String: JSONValue] = ["repo": .string(repo), "prNumber": .number(Double(number))]
        if ["review", "qa"].contains(id), let branch { args["branch"] = .string(branch) }
        if self.input != nil, let input = input?.trimmingCharacters(in: .whitespacesAndNewlines), !input.isEmpty {
            args["input"] = .string(input)
        }
        return args
    }

    /// The board's errands, in the order the dashboard shows them.
    public static let known: [BoardAction] = [
        .init(id: "run", label: "Run", hint: "Prepare this pull request in a clean workspace and serve the app from it"),
        .init(id: "review", label: "Code review", hint: "Run the provider’s code review on this pull request and publish it"),
        .init(id: "solve-conflicts", label: "Solve conflicts", hint: "Merge the base branch in, resolve the conflicts and push the result"),
        .init(id: "fix-checks", label: "Fix failing checks", hint: "Read this pull request’s failing CI checks, fix what the branch broke and push the fixes"),
        .init(id: "implement-feedback", label: "Implement feedback", hint: "Address the review findings on this pull request, push the fixes, and have those changes reviewed automatically"),
        .init(id: "custom-feedback", label: "Give feedback", hint: "Say in your own words what to change on this pull request, and it is implemented and pushed",
              input: Input(label: "Your feedback", placeholder: "What should change on this pull request?", required: true)),
        .init(id: "test-sheet", label: "Test sheet", hint: "Derive the manual QA checklist from this pull request’s diff and post it as one editable comment"),
        .init(id: "qa", label: "QA", hint: "Write the test sheet for this pull request and execute it in a session of its own"),
        .init(id: "pr-body-summary", label: "PR body", hint: "Rewrite this pull request’s description from its own diff, following the team template"),
        .init(id: "delete-self-comments", label: "Delete my comments", hint: "Remove every comment and review the configured GitHub account left on this pull request"),
    ]

    /// The errands worth offering on one pull request. Three answer a state it is actually in (conflicts, red
    /// checks, a review waiting) and come and go with it; without the board's row nothing is known, so they stay.
    /// `catalog` is what the server's `actions` lists: it words the questions and adds errands this app predates.
    public static func offered(catalog: [JSONValue] = [], pull: PullSummary?, failedChecks: Int = 0) -> [BoardAction] {
        var served: [String: BoardAction] = [:]
        var order: [String] = []
        for entry in catalog {
            guard let id = entry["id"].string, let label = entry["label"].string else { continue }
            let input = entry["input"]["label"].string.map {
                Input(label: $0, placeholder: entry["input"]["placeholder"].string ?? "", required: entry["input"]["required"].bool == true)
            }
            served[id] = BoardAction(id: id, label: label, hint: entry["hint"].string ?? "", input: input)
            order.append(id)
        }
        let listed = known.map { action in
            served[action.id].map { BoardAction(id: action.id, label: action.label, hint: action.hint, input: $0.input) } ?? action
        }
        let added = order.filter { id in !known.contains { $0.id == id } }.compactMap { served[$0] }
        return (listed + added).filter { action in
            switch action.id {
            case "solve-conflicts": return pull?.hasConflicts ?? true
            case "fix-checks": return failedChecks > 0 || (pull?.checksFailed ?? false)
            case "implement-feedback": return pull?.awaitsFeedback ?? true
            default: return true
            }
        }
    }
}

public enum MergeState {
    /// What is worth a word before a merge is confirmed. `mergeable` is null while GitHub is still
    /// computing it and false on conflicts; `state` is GitHub's mergeable_state.
    public static func warnings(mergeable: JSONValue, state: String?) -> [String] {
        var notes: [String] = []
        if mergeable.bool == false { notes.append("This branch has conflicts that must be resolved before it can merge.") }
        if mergeable == .null { notes.append("GitHub is still checking whether this branch can merge.") }
        switch state {
        case "blocked": notes.append("GitHub reports this pull request as blocked: a required review or check is missing.")
        case "behind": notes.append("This branch is behind its base branch and may need updating before it can merge.")
        default: break
        }
        return notes
    }
}
