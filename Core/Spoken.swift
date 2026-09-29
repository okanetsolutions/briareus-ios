import Foundation

// What is read aloud where a screen cannot be read, as in a car: the words of a reply without its Markdown,
// and the state of a conversation or a pull request as a sentence.
public enum Spoken {
    /// Past this a reply is cut short; the rest waits on the phone.
    public static let limit = 1_800

    /// A Markdown reply as it is said. Code and tables are named, not read: they mean nothing by ear.
    public static func text(_ markdown: String) -> String {
        var parts: [String] = []
        func add(_ part: String) {
            let part = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if !part.isEmpty && parts.last != part { parts.append(part) }
        }
        for block in MarkdownBlock.parse(markdown) {
            switch block {
            case .paragraph(let text):
                let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                if lines.allSatisfy({ $0.hasPrefix("|") }) { add("A table is left out.") }
                else { add(sentence(inline(lines.joined(separator: " ")))) }
            case .heading(_, let text), .quote(let text): add(sentence(inline(text.replacingOccurrences(of: "\n", with: " "))))
            case .bullet(_, _, let text): add(sentence(inline(text.replacingOccurrences(of: "\n", with: " "))))
            case .code: add("A code block is left out.")
            case .rule: break
            }
        }
        return parts.joined(separator: " ")
    }

    /// The words inside inline Markdown: a link by its text, code and emphasis without their marks.
    public static func inline(_ text: String) -> String {
        var text = text
        for (pattern, template) in [
            (#"!\[([^\]]*)\]\([^)]*\)"#, "$1"), (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),
            (#"<?https?://[^\s>)]+>?"#, "a link"), (#"`([^`]*)`"#, "$1"),
            (#"(\*\*|__)(.+?)\1"#, "$2"), (#"(?<![\w*])[*_](?=\S)(.+?)(?<=\S)[*_](?![\w*])"#, "$1"), (#"~~(.+?)~~"#, "$1"),
            (#"(?<!\w)#(\d+)"#, "number $1"),
        ] {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    private static func sentence(_ text: String) -> String {
        guard let last = text.last else { return "" }
        return ".!?:;…".contains(last) ? text : text + "."
    }

    /// The agent's latest turn: what came after the user's last message.
    public static func latest(_ events: [Event]) -> [Event] {
        let visible = events.filter(\.visible)
        guard let asked = visible.lastIndex(where: { $0.kind == "user" }) else { return visible }
        return Array(visible[(asked + 1)...])
    }

    /// The question still waiting for an answer, which is one nothing was said after.
    public static func openQuestion(_ events: [Event]) -> Event? {
        events.filter(\.visible).last { !["result", "tool", "tool_error", "cmd", "git"].contains($0.kind) }
            .flatMap { $0.kind == "ask" ? $0 : nil }
    }

    /// What a question offers as answers.
    public static func options(_ event: Event) -> [String] { (event.options ?? []).compactMap { $0["label"].string } }

    /// Events as they are said: replies and questions in full, tool activity as a count, plumbing not at all.
    public static func say(_ events: [Event], limit: Int = Spoken.limit) -> String {
        var parts: [String] = []
        var tools = 0
        func flush() {
            if tools > 0 { parts.append(tools == 1 ? "One tool was used." : "\(tools) tools were used.") }
            tools = 0
        }
        for event in events where event.visible {
            switch event.kind {
            case "tool", "tool_error", "cmd", "git": tools += 1
            case "stderr", "claude": break
            case "user": flush(); parts.append("You said: \(sentence(inline(event.text ?? "")))")
            case "ask":
                flush()
                var question = "A question for you: " + text(event.question ?? event.text ?? "")
                let offered = options(event)
                if !offered.isEmpty { question += " The answers offered are: " + list(offered.map(inline)) + "." }
                parts.append(question)
            case "result": flush(); parts.append(event.isError == true ? "The turn failed." : "The turn is complete.")
            default: flush(); parts.append(text(event.text ?? ""))
            }
        }
        flush()
        return cut(parts.filter { !$0.isEmpty }.joined(separator: " "), limit: limit)
    }

    /// Cut at the end of a sentence where there is one, and said to be cut.
    public static func cut(_ text: String, limit: Int = Spoken.limit) -> String {
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit))
        let end = head.lastIndex { ".!?".contains($0) }.map { head[...$0] } ?? head[...]
        return String(end.count > limit / 2 ? end : head[...]) + " The rest is on your phone."
    }

    /// "a, b and c".
    public static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }

    public static func count(_ number: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(number) \(number == 1 ? singular : plural ?? singular + "s")"
    }

    /// A conversation by its name and what it is doing.
    public static func status(_ session: Session) -> String {
        var parts = ["\(sentence(inline(session.displayTitle)))"]
        switch session.status {
        case "running": parts.append("The agent is working.")
        case "queued", "preparing", "starting": parts.append("The agent is starting.")
        case "closed": parts.append("It is closed.")
        case "failed", "error": parts.append("It failed.")
        case "cancelled": parts.append("It was stopped.")
        default: parts.append("It is waiting for you.")
        }
        let queued = session.queued?.count ?? 0
        if queued > 0 { parts.append("\(count(queued, "message")) queued.") }
        if let findings = session.heldTriage?["findings"].array.count {
            parts.append("\(count(findings, "finding")) \(findings == 1 ? "waits" : "wait") for a decision.")
        }
        return parts.joined(separator: " ")
    }

    /// A pull request as the board and its own details know it. `review` is the verdict in words, when there is one.
    public static func pull(number: Int, row: PullSummary?, details pr: JSONValue, review: String? = nil) -> String {
        var parts = ["Pull request \(number): \(sentence(inline(pr["title"].string ?? row?.title ?? "")))"]
        let open = pr == .null ? row != nil : pr["state"].string == "open"
        if !open { parts.append("It is \(pr["merged"].bool == true ? "merged" : pr["state"].string ?? "closed").") }
        else if (pr["draft"].bool ?? row?.draft) == true { parts.append("It is a draft.") }
        if let author = row?.author { parts.append("By \(author).") }
        if let head = pr["headRef"].string ?? row?.branch, let base = pr["baseRef"].string ?? row?.baseBranch, !head.isEmpty, !base.isEmpty {
            parts.append("From \(head) into \(base).")
        }
        if open, let row {
            if row.hasConflicts { parts.append("It conflicts with its base.") }
            else if row.mergeable == "mergeable" { parts.append("It has no conflicts.") }
        }
        if pr != .null { parts.append(checks(pr["checks"])) }
        else if let state = row?.checks { parts.append(state == "success" ? "Its checks passed." : row?.checksFailed == true ? "Its checks failed." : "Its checks are running.") }
        if let review { parts.append("Review: \(review).") }
        if let row, !row.labels.isEmpty { parts.append("Labelled \(list(row.labels.map(\.name))).") }
        if let row, !row.issues.isEmpty { parts.append("It closes \(list(row.issues.map { "issue \($0.number)" })).") }
        return parts.joined(separator: " ")
    }

    /// The counts of a pull request's checks, and which of them failed.
    public static func checks(_ checks: JSONValue) -> String {
        let passed = Int(checks["passed"].double ?? 0), failed = Int(checks["failed"].double ?? 0), pending = Int(checks["pending"].double ?? 0)
        guard passed + failed + pending > 0 else { return "It has no checks." }
        var parts = ["\(count(passed, "check")) passed, \(failed) failed, \(pending) still running."]
        let broken = checks["runs"].array.filter { run in
            ["failure", "failed", "timed_out", "action_required", "error"].contains((run["conclusion"].string ?? run["status"].string ?? "").lowercased())
        }.compactMap { $0["name"].string }
        if !broken.isEmpty { parts.append("Failing: \(list(Array(broken.prefix(5)))).") }
        return parts.joined(separator: " ")
    }

    public static func reviews(_ pr: JSONValue) -> String {
        let said = pr["reviews"].array.compactMap { review -> String? in
            guard let user = review["user"].string else { return nil }
            let state = (review["state"].string ?? "").lowercased().replacingOccurrences(of: "_", with: " ")
            return state.isEmpty ? user : "\(user), \(state)"
        }
        return said.isEmpty ? "No reviews yet." : "Reviews: \(said.joined(separator: "; "))."
    }

    public static func finding(_ finding: JSONValue) -> String {
        var parts = [sentence(inline(finding["title"].string ?? "Finding"))]
        if let severity = finding["severity"].string { parts.append("Severity \(severity).") }
        if let file = finding["file"].string { parts.append("In \(file.split(separator: "/").last.map(String.init) ?? file).") }
        if finding["fixed"].bool == true { parts.append("It is fixed.") }
        else if let decision = finding["decision"].string { parts.append("Decided: \(decision).") }
        if let why = finding["parkedWhy"].string { parts.append(sentence(inline(why))) }
        return parts.joined(separator: " ")
    }

    public static func issue(_ issue: IssueSummary) -> String {
        var parts = ["Issue \(issue.number): \(sentence(inline(issue.title)))"]
        if let author = issue.author { parts.append("By \(author).") }
        if issue.isEpic { parts.append("An epic with \(issue.subIssuesDone) of \(count(issue.subIssues, "sub-issue")) done.") }
        if let parent = issue.parent { parts.append("Part of issue \(parent.number).") }
        if !issue.labels.isEmpty { parts.append("Labelled \(list(issue.labels.map(\.name))).") }
        if issue.comments > 0 { parts.append("\(count(issue.comments, "comment")).") }
        if !issue.pulls.isEmpty { parts.append("Answered by \(list(issue.pulls.map { "pull request \($0.number)" })).") }
        return parts.joined(separator: " ")
    }

    /// What was dictated as the name of a conversation: one line, without the full stop a transcription ends on.
    public static func title(_ dictated: String) -> String {
        var title = dictated.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        while let last = title.last, ".。".contains(last) { title.removeLast() }
        return title
    }
}
