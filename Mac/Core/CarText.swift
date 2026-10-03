// What a car's screen says of a conversation, a pull request or an issue: a few words, read at a glance. No UI here.
import Foundation

enum CarText {
    /// The words inside inline Markdown: a link by its text, code and emphasis without their marks.
    static func inline(_ text: String) -> String {
        var text = text
        for (pattern, template) in [
            (#"!\[([^\]]*)\]\([^)]*\)"#, "$1"), (#"\[([^\]]+)\]\([^)]*\)"#, "$1"), (#"`([^`]*)`"#, "$1"),
            (#"(\*\*|__)(.+?)\1"#, "$2"), (#"(?<![\w*])[*_](?=\S)(.+?)(?<=\S)[*_](?![\w*])"#, "$1"), (#"~~(.+?)~~"#, "$1"),
        ] {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Conversations

    /// The question still waiting for an answer, which is one nothing was said after. The steps an agent ran and the
    /// workspace's output say nothing to the user.
    static func openQuestion(_ events: [Event]) -> Event? {
        events.filter { $0.isVisible && !isToolEvent($0) && !["setup", "cmd", "git"].contains($0.kind) }
            .last { $0.kind != "result" }.flatMap { $0.kind == "ask" ? $0 : nil }
    }
    /// What a question offers as answers.
    static func options(_ event: Event) -> [String] { (event.options ?? .null).items.compactMap { $0["label"].string } }
    /// A question as one line.
    static func question(_ event: Event) -> String { inline(event.question ?? event.text ?? "") }

    static func count(_ number: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(number) \(number == 1 ? singular : plural ?? singular + "s")"
    }

    /// What a conversation is doing and what it waits for.
    static func status(_ session: Session, asking: Bool = false) -> String {
        var parts: [String]
        switch session.status {
        case "running": parts = ["Working"]
        case "queued", "preparing", "starting": parts = ["Starting"]
        case "closed": parts = ["Closed"]
        case "failed", "error": parts = ["Failed"]
        case "cancelled": parts = ["Stopped"]
        default: parts = [asking ? "Asks you a question" : "Waiting for you"]
        }
        if asking && parts != ["Asks you a question"] { parts.append("Asks you a question") }
        let queued = session.queued.count
        if queued > 0 { parts.append("\(queued) queued") }
        if let findings = session.heldTriage?["findings"].count { parts.append(count(findings, "finding")) }
        return parts.joined(separator: " · ")
    }
    /// What a message sent now does: it goes into the running turn, waits for the next one, or starts one.
    static func sent(_ session: Session?) -> String {
        guard let session, session.isActive else { return "Sent" }
        return session.liveInput ? "Sent into the running turn" : "Queued for the next turn"
    }
    /// The conversations holding a review round with findings for a decision, the oldest hold first.
    static func holdingFindings(_ sessions: [Session]) -> [Session] {
        Session.heldRounds(sessions).map { sessions[$0.index] }.filter { $0.heldTriage != nil }
    }

    // MARK: Pull requests

    /// A board row as the line under its title: number, draft, conflicts, checks and author.
    static func pullLine(_ pr: PullSummary) -> String {
        var said = ["#\(pr.number)"]
        if pr.draft { said.append("Draft") }
        if pr.hasConflicts { said.append("Conflicts") }
        if let checks = pr.checks { said.append(checks == "success" ? "Checks passed" : pr.checksFailed ? "Checks failed" : "Checks running") }
        if let author = pr.author { said.append("@\(author)") }
        return said.joined(separator: " · ")
    }
    /// The counts of a pull request's checks.
    static func checks(_ checks: JSON) -> String {
        let passed = checks["passed"].truncatedInt ?? 0, failed = checks["failed"].truncatedInt ?? 0, pending = checks["pending"].truncatedInt ?? 0
        guard passed + failed + pending > 0 else { return "None" }
        return "\(passed) passed · \(failed) failed · \(pending) running"
    }
    /// Who reviewed and what each said.
    static func reviews(_ pr: JSON) -> [(user: String, state: String)] {
        pr["reviews"].items.compactMap { review in
            let state = (review["state"].string ?? "").lowercased().replacingOccurrences(of: "_", with: " ")
            return review["user"].string.map { ($0, state.prefix(1).uppercased() + state.dropFirst()) }
        }
    }
    /// The verdict the pull request carries: from its board row when there is one, else from its reviews; nil without any.
    static func review(_ pr: JSON, row: PullSummary?) -> String? {
        let status = row.map { ReviewStatus(decision: $0.reviewDecision, reviewers: $0.reviewers) } ?? ReviewStatus(decision: nil, reviews: pr["reviews"])
        return status == .none ? nil : status.text
    }
    /// A finding's verdict, severity and file, as the line under its title.
    static func finding(_ finding: JSON, verdict: String?) -> String {
        [finding["fixed"].bool == true ? "Fixed" : verdict, finding["severity"].string,
         finding["file"].string?.split(separator: "/").last.map(String.init)].compactMap { $0 }.joined(separator: " · ")
    }
    /// The title a verdict's button shows, by its API spelling.
    static func verdictTitle(_ decision: String) -> String? { findingDecisionIndex(decision).map { findingDecisionTitles[$0] } }

    /// A merge is always a squash, unless the repository refuses squashes: then the first method it accepts. Nothing
    /// `allowed` means GitHub did not say, and a squash is tried.
    static func mergeMethod(allowed: [String]) -> String {
        allowed.isEmpty || allowed.contains("squash") ? "squash" : ["merge", "rebase"].first(where: allowed.contains) ?? "squash"
    }
    static func mergeTitle(_ method: String) -> String {
        ["squash": "Merge", "merge": "Create a merge commit", "rebase": "Rebase and merge"][method] ?? method.capitalized
    }
    /// What `merge_pull` answered: merged, queued, or still being finished by GitHub.
    static func merged(_ answer: JSON, base: String) -> String {
        switch answer["status"].string {
        case "enqueued": return "Queued to merge into \(base)"
        case "pending": return "GitHub is finishing the merge into \(base)"
        default: return "Merged into \(base)"
        }
    }

    // MARK: Issues

    /// A board issue as the line under its title: number, epic progress, its epic when nested, and two labels.
    static func issueLine(_ issue: IssueSummary, nested: Bool) -> String {
        var said = ["#\(issue.number)"]
        if issue.isEpic { said.append("Epic \(issue.subIssuesDone)/\(issue.subIssues)") }
        if let parent = issue.parent, nested { said.append("In #\(parent.number)") }
        said += issue.labels.prefix(2).map(\.name)
        return said.joined(separator: " · ")
    }
    /// What is worth a word before an issue is closed: its open sub-issues, a session still on it, a comment going first.
    static func closingIssue(_ issue: IssueSummary, working: Bool, comment: Bool) -> String? {
        let open = issue.subIssues - issue.subIssuesDone
        var why: [String] = []
        if open > 0 { why.append("\(open) of its sub-issues \(open == 1 ? "is" : "are") still open and stay\(open == 1 ? "s" : "") open.") }
        if working { why.append("A session is still working on it; closing does not stop it.") }
        if comment { why.append("Your comment is posted first.") }
        return why.isEmpty ? nil : why.joined(separator: " ")
    }

    // MARK: Dictation

    /// What was dictated as the name of a conversation: one line, without the full stop a transcription ends on.
    static func title(_ dictated: String) -> String {
        var title = dictated.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        while let last = title.last, ".。".contains(last) { title.removeLast() }
        return title
    }
    /// What was dictated, as long as a screen that asks about it has room for: whole, and cut shorter twice.
    static func variants(_ text: String, before: String = "“", after: String = "”") -> [String] {
        var seen = Set<String>()
        return [text.count, 140, 60].map { limit in
            before + (text.count > limit ? String(text.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…" : text) + after
        }.filter { seen.insert($0).inserted }
    }
}
