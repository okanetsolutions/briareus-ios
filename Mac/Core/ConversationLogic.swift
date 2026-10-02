// What a conversation shows, worded as the Windows client's screen_conversation.c, screen_panel.c and attach_list.c word
// it: the header's status line, a turn's footer, the transcript folded into preparation and tool blocks, the composer's
// chips, an attachment's chip, and the panel's section labels. No UI here.
import Foundation

// MARK: - Header

/// `#chat-sub`: provider · model · effort · state · 🔁 loop round · branch · tokens · cost · session id · the pull request.
func conversationStatusLine(_ s: Session) -> String {
    var sub = ""
    for part in [s.provider, s.model, s.raw["effort"].nonEmpty] { if let part { sub += (sub.isEmpty ? "" : " \u{00B7} ") + part } }
    let state = s.status == "idle" && s.raw["awaitingAnswer"].is(true) ? "waiting" : s.status
    sub += (sub.isEmpty ? "" : " \u{00B7} ") + state
    let loop = s.raw["reviewLoop"]
    if loop.isObject {
        if let round = loop["rounds"].truncatedInt { sub += " \u{00B7} \u{1F501} loop round \(round)" } else { sub += " \u{00B7} \u{1F501} loop" }
    }
    if let branch = s.raw["branch"].nonEmpty { sub += " \u{00B7} \(branch)" }
    let input = s.raw["inputTokens"].number, output = s.raw["outputTokens"].number
    if input != nil || output != nil { sub += " \u{00B7} \(formatTokens((input ?? 0) + (output ?? 0))) tok" }
    if let cost = s.raw["costUsd"].number { sub += " \u{00B7} \(formatCost(cost))" }
    sub += " \u{00B7} session \(s.id)"
    let pr = s.raw["prStatus"]
    if pr.isObject, let number = pr["number"].truncatedInt {
        let state = pr["state"].string
        let draft = pr["draft"].is(true)
        let light = state == "merged" ? "\u{1F7E3}" : state == "closed" ? "\u{1F534}" : draft ? "\u{26AA}" : "\u{1F7E2}"
        sub += " \u{00B7} \(light) PR #\(number) \(draft && state == "open" ? "draft" : state ?? "")"
        let checks = pr["checks"]
        let failed = checks["failed"].int32 ?? 0, pending = checks["pending"].int32 ?? 0, passed = checks["passed"].int32 ?? 0
        if failed != 0 { sub += " \u{00B7} \u{2717}\(failed)" }
        else if pending != 0 { sub += " \u{00B7} \u{2026}\(pending)" }
        else if passed != 0 { sub += " \u{00B7} \u{2713}\(passed)" }
    }
    return sub
}

// MARK: - Transcript

/// "— $2.9565 · 455s · 57 turns · 5.6M in / 36.4k out · 151.6k context", or "— turn done".
func turnFooterText(_ e: Event) -> String {
    var bits = ""
    func add(_ s: String) { bits += (bits.isEmpty ? "" : " \u{00B7} ") + s }
    if let cost = e.costUsd { add(String(format: "$%.4f", cost)) }
    if let ms = e.durationMs { add("\(Int((ms / 1000).rounded(.towardZero)))s") }
    if let turns = e.raw["numTurns"].truncatedInt { add("\(turns) turns") }
    let input = e.raw["inputTokens"].number, output = e.raw["outputTokens"].number
    if input != nil || output != nil { add("\(formatTokens(input ?? 0)) in / \(formatTokens(output ?? 0)) out") }
    if let tokens = e.raw["tokens"].number { add("\(formatTokens(tokens)) context") }
    return "\u{2014} " + (bits.isEmpty ? "turn done" : bits)
}

/// A tool step's name: its own, else what kind of step it was.
func toolTitle(_ e: Event) -> String {
    if let name = e.name, !name.isEmpty { return name }
    switch e.kind {
    case "cmd": return "Command"
    case "git": return "Git"
    case "tool_error": return "Tool error"
    default: return "Tool"
    }
}
/// The first line of a text, trimmed.
func firstLine(_ text: String?) -> String {
    let trimmed = (text ?? "").cTrimmed
    let first = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
    return first.cTrimmed
}
func isToolEvent(_ e: Event) -> Bool { e.kind == "tool" || e.kind == "tool_error" }
/// Workspace preparation output (`setup` is a setup command's own output; a failed step's last lines are there).
func isPrepLine(_ e: Event) -> Bool { ["info", "cmd", "git", "setup", "stdout"].contains(e.kind) && e.text != nil }
/// Info lines that belong to the conversation rather than to workspace preparation.
func prepClosed(_ e: Event) -> Bool {
    let t = e.text ?? ""
    if t.hasPrefix("Starting ") || t.hasPrefix("Started worker ") || t.hasPrefix("Worker ") { return true }
    return t.range(of: "session started", options: .caseInsensitive) != nil
}
/// A log line as the transcript shows it: a command with `$ ` before it.
func logLineText(_ e: Event) -> String { e.kind == "cmd" ? "$ \(e.text ?? "")" : (e.text ?? "") }

/// What the transcript lays out: workspace preparation folded into one block per turn, each run of tool calls into another,
/// and the visible events between them.
enum TranscriptBlock: Equatable {
    case preparation([Event])
    case tools([Event])
    case event(Event)

    /// The sequence that names the block, which its open-or-closed state is kept by.
    var seq: Int {
        switch self {
        case .preparation(let e), .tools(let e): return e.first?.seq ?? 0
        case .event(let e): return e.seq
        }
    }
    /// "Preparing workspace… (3 steps)" or "2 steps · Bash".
    var summary: String? {
        switch self {
        case .preparation(let e): return "Preparing workspace\u{2026} (\(e.count) step\(e.count == 1 ? "" : "s"))"
        case .tools(let e): return "\(e.count) step\(e.count == 1 ? "" : "s") \u{00B7} \(e.last.map(toolTitle) ?? "Tool")"
        case .event: return nil
        }
    }
}

func transcriptBlocks(_ events: [Event]) -> [TranscriptBlock] {
    var out: [TranscriptBlock] = []
    var prepDone = false
    var i = 0
    while i < events.count {
        let e = events[i]
        if e.kind == "user" || e.kind == "result" { prepDone = false }
        if !prepDone && isPrepLine(e) && !prepClosed(e) {
            var j = i
            while j < events.count && isPrepLine(events[j]) && !prepClosed(events[j]) { j += 1 }
            out.append(.preparation(Array(events[i..<j])))
            i = j
            continue
        }
        if isPrepLine(e) && prepClosed(e) { prepDone = true }
        if isToolEvent(e) {
            var j = i
            while j < events.count && isToolEvent(events[j]) { j += 1 }
            out.append(.tools(Array(events[i..<j])))
            i = j
            continue
        }
        if e.isVisible { out.append(.event(e)) }
        i += 1
    }
    return out
}

/// Whether a transcript holds only events without a time: saved before messages showed theirs, it is read again once.
func transcriptNeedsRetime(_ events: [Event]) -> Bool { !events.isEmpty && events.allSatisfy { $0.t == nil } }

/// A voice note's text appended to what the composer holds, a space between unless it already ends in one.
func appendDictation(_ current: String, _ text: String) -> String {
    guard !text.isEmpty else { return current }
    let gap = current.isEmpty || current.hasSuffix(" ") || current.hasSuffix("\n") || current.hasSuffix("\t") ? "" : " "
    return current + gap + text
}

// MARK: - Review findings held in the conversation

/// The round's title: "Round 2 findings · PR #70", or "Review findings".
func triageTitle(_ triage: JSON) -> String {
    var title = triage["round"].truncatedInt.map { "Round \($0) findings" } ?? "Review findings"
    if let pr = triage["prNumber"].truncatedInt { title += " \u{00B7} PR #\(pr)" }
    return title
}
/// A round takes verdicts unless the server says it is not this user's (`mine: false`).
func triageTakesVerdicts(_ triage: JSON) -> Bool { triage["mine"].bool != false }
/// "file.ts:12", or nil without a file.
func findingLocation(_ finding: JSON) -> String? {
    guard let file = finding["file"].string else { return nil }
    if let line = finding["line"].truncatedInt { return "\(file):\(line)" }
    return file
}
/// The Complete button's title.
func triageCompleteTitle(takesVerdicts: Bool, fixes: Int) -> String {
    guard takesVerdicts else { return "Complete" }
    return fixes > 0 ? "Complete \u{00B7} send \(fixes) to be fixed" : "Complete \u{00B7} nothing to fix, approve and close"
}
/// The confirmation before completing.
func triageConfirmTitle(takesVerdicts: Bool, fixes: Int) -> String {
    if !takesVerdicts { return "Take this review off the queue?" }
    if fixes == 0 { return "Complete with nothing to fix?" }
    return "Start a paid fix session for \(fixes) finding\(fixes == 1 ? "" : "s")?"
}
/// A finding's verdict: the one picked here, else the round's saved draft, else "".
func triageDecision(_ triage: JSON, _ finding: JSON, picked: [String: String]) -> String {
    guard let key = finding["key"].string else { return "" }
    if let d = picked[key] { return d }
    return triage["drafts"]["verdicts"][key]["decision"].string ?? ""
}
/// What `complete_findings` is sent: every keyed finding's verdict (optional when none was picked) with its draft reason,
/// and the trimmed note.
func triageCompletion(_ triage: JSON, picked: [String: String], note: String) -> JSON {
    var extra: JSON = [:]
    guard triageTakesVerdicts(triage) else { return extra }
    var verdicts: [JSON] = []
    for f in triage["findings"].items {
        guard let key = f["key"].string else { continue }
        let chosen = triageDecision(triage, f, picked: picked)
        var v: JSON = ["key": .string(key), "decision": .string(chosen.isEmpty ? "optional" : chosen)]
        if let reason = triage["drafts"]["verdicts"][key]["reason"].nonEmpty { v["reason"] = .string(reason) }
        verdicts.append(v)
    }
    if !verdicts.isEmpty { extra["verdicts"] = .array(verdicts) }
    let trimmed = note.cTrimmed
    if !trimmed.isEmpty { extra["note"] = .string(trimmed) }
    return extra
}

// MARK: - Composer

/// The composer's chips, in their order.
enum ComposerChip: CaseIterable { case workspace, project, branch, provider, model, effort, loop }

/// A conversation's chip text; empty hides it (the loop chip is shown by the caller's rule).
func conversationChipText(_ s: Session, _ chip: ComposerChip) -> String {
    switch chip {
    case .workspace:
        return s.raw["local"].is(true) ? "\u{2302} Local" : s.raw["orchestrator"].is(true) ? "\u{1F9ED} Orchestrator" : "\u{2317} Worktree"
    case .project:
        guard let repo = s.repo else { return "" }
        return repo.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? repo
    case .branch: return s.raw["branch"].nonEmpty ?? ""
    case .provider: return s.provider ?? ""
    case .model: return s.model ?? ""
    case .effort: return s.raw["effort"].nonEmpty ?? ""
    case .loop: return reviewLoopChipText(s.reviewLoopOn)
    }
}
func reviewLoopChipText(_ on: Bool) -> String { on ? "\u{1F501} Review loop: on" : "\u{1F501} Review loop" }

/// What a message sent now does, under the conversation's composer.
func conversationComposerNote(active: Bool, liveInput: Bool, uploading: Bool, files: Int, empty: Bool) -> String {
    if active { return liveInput ? "Sent into the running turn" : "Queued for the next turn" }
    if uploading { return "Uploading\u{2026}" }
    if files > 0 && empty { return "Add a few words to send the files" }
    return ""
}

/// An attachment's chip: 📎 (… while uploading), its name and its size.
func attachmentChipLabel(name: String, size: Int, uploaded: Bool) -> String {
    "\(uploaded ? "\u{1F4CE}" : "\u{2026}") \(name) \u{00B7} \(formatFileSize(size))"
}
/// The most files one message takes, as the Windows client's "At most 10 files per message".
let attachmentsMax = 10
/// Why a file could not be attached: "name why." lines.
func attachmentRefusal(_ name: String, _ why: String) -> String { "\(name) \(why)." }

// MARK: - Panel

/// "Findings (3 · all fixed)", "Findings (3 · 1 fixed)", "Findings (3)" or "Findings".
func panelFindingsLabel(count: Int, fixed: Int) -> String {
    guard count > 0 else { return "Findings" }
    if fixed == count { return "Findings (\(count) \u{00B7} all fixed)" }
    if fixed > 0 { return "Findings (\(count) \u{00B7} \(fixed) fixed)" }
    return "Findings (\(count))"
}
/// A pull request's state tag in the panel: draft for an open draft, else its state (open when unknown).
func panelStateText(_ pr: JSON) -> String {
    let state = pr["state"].string
    if pr["draft"].is(true) && state == "open" { return "draft" }
    return state ?? "open"
}
/// "Context" in the usage section: "12.0k / 200.0k (6%)", or "12.0k tokens" without a window.
func contextHeadline(used: Double, window: Double) -> String {
    if window > 0 { return "\(formatTokens(used)) / \(formatTokens(window)) (\(Int((used / window * 100 + 0.5).rounded(.down)))%)" }
    return "\(formatTokens(used)) tokens"
}
/// What the session spent with everything it ordered, or its own figures from a server without `usage`.
func sessionUsage(_ raw: JSON) -> JSON { raw["usage"].isObject ? raw["usage"] : raw }
/// The context in use and the model's window (0 when unknown); nil without a figure for what is used.
func sessionContextSize(_ raw: JSON) -> (used: Double, window: Double)? {
    let cu = raw["contextUsage"]
    let window = cu["window"].number ?? raw["contextWindow"].number ?? 0
    guard let used = cu["tokens"].number ?? raw["contextTokens"].number else { return nil }
    return (used, window)
}
func sessionUsageRowsPresent(_ raw: JSON) -> Bool {
    let u = sessionUsage(raw)
    return ["inputTokens", "outputTokens", "durationMs", "costUsd"].contains { u[$0].number != nil }
}
