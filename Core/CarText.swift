import Foundation

// What a car's screen says of a conversation, a pull request or an issue: a few words, read at a glance.
public enum CarText {
    /// The words inside inline Markdown: a link by its text, code and emphasis without their marks.
    public static func inline(_ text: String) -> String {
        var text = text
        for (pattern, template) in [
            (#"!\[([^\]]*)\]\([^)]*\)"#, "$1"), (#"\[([^\]]+)\]\([^)]*\)"#, "$1"), (#"`([^`]*)`"#, "$1"),
            (#"(\*\*|__)(.+?)\1"#, "$2"), (#"(?<![\w*])[*_](?=\S)(.+?)(?<=\S)[*_](?![\w*])"#, "$1"), (#"~~(.+?)~~"#, "$1"),
        ] {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// The question still waiting for an answer, which is one nothing was said after.
    public static func openQuestion(_ events: [Event]) -> Event? {
        events.filter(\.visible).last { $0.kind != "result" }.flatMap { $0.kind == "ask" ? $0 : nil }
    }
    /// What a question offers as answers.
    public static func options(_ event: Event) -> [String] { (event.options ?? []).compactMap { $0["label"].string } }
    /// A question as one line.
    public static func question(_ event: Event) -> String { inline(event.question ?? event.text ?? "") }

    public static func count(_ number: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(number) \(number == 1 ? singular : plural ?? singular + "s")"
    }

    /// What a conversation is doing and what it waits for.
    public static func status(_ session: Session, asking: Bool = false) -> String {
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
        let queued = session.queued?.count ?? 0
        if queued > 0 { parts.append("\(queued) queued") }
        if let findings = session.heldTriage?["findings"].array.count { parts.append(count(findings, "finding")) }
        return parts.joined(separator: " · ")
    }

    /// The counts of a pull request's checks.
    public static func checks(_ checks: JSONValue) -> String {
        let passed = Int(checks["passed"].double ?? 0), failed = Int(checks["failed"].double ?? 0), pending = Int(checks["pending"].double ?? 0)
        guard passed + failed + pending > 0 else { return "None" }
        return "\(passed) passed · \(failed) failed · \(pending) running"
    }
    /// Who reviewed and what each said.
    public static func reviews(_ pr: JSONValue) -> [(user: String, state: String)] {
        pr["reviews"].array.compactMap { review in
            let state = (review["state"].string ?? "").lowercased().replacingOccurrences(of: "_", with: " ")
            return review["user"].string.map { ($0, state.prefix(1).uppercased() + state.dropFirst()) }
        }
    }
    /// A finding's verdict, severity and file, as the line under its title.
    public static func finding(_ finding: JSONValue, verdict: String?) -> String {
        [finding["fixed"].bool == true ? "Fixed" : verdict, finding["severity"].string,
         finding["file"].string?.split(separator: "/").last.map(String.init)].compactMap { $0 }.joined(separator: " · ")
    }

    /// What was dictated as the name of a conversation: one line, without the full stop a transcription ends on.
    public static func title(_ dictated: String) -> String {
        var title = dictated.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        while let last = title.last, ".。".contains(last) { title.removeLast() }
        return title
    }
    /// What was dictated, as long as a screen that asks about it has room for: whole, and cut shorter twice.
    public static func variants(_ text: String, before: String = "“", after: String = "”") -> [String] {
        var seen = Set<String>()
        return [text.count, 140, 60].map { limit in
            before + (text.count > limit ? String(text.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…" : text) + after
        }.filter { seen.insert($0).inserted }
    }
}
