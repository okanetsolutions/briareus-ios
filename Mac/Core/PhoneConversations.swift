// What the iPhone app's conversation list and conversation screen work out for themselves: the pull request mark that
// takes a row's status dot, which conversations a search and the closed switch leave, what a bulk Close or Delete works
// through, and how often an open conversation is read again. No UI here.
import Foundation

// MARK: - The pull request mark

extension Session {
    /// "PR #123 open · ✓4 ✗1 ●2", as the Windows client's badge reads, once the server has synced the pull request.
    var pullBadge: String? {
        let pr = raw["prStatus"]
        guard let number = pr["number"].truncatedInt, number >= 1 else { return nil }
        let checks = [("\u{2713}", "passed"), ("\u{2717}", "failed"), ("\u{25CF}", "pending")].compactMap { mark, key -> String? in
            guard let n = pr["checks"][key].truncatedInt, n > 0 else { return nil }
            return "\(mark)\(n)"
        }
        return (["PR #\(number) \(pullState)"] + (checks.isEmpty ? [] : [checks.joined(separator: " ")])).joined(separator: " \u{00B7} ")
    }
    /// The synced pull request's state: open, merged or closed.
    var pullState: String { raw["prStatus"]["state"].string ?? "open" }
    /// What the pull request's mark in the list says: merged or closed; while open, a draft, or failing, pending or
    /// passing checks. Nil without a synced pull request.
    var pullTone: String? {
        guard pullBadge != nil else { return nil }
        if pullState != "open" { return pullState }
        let pr = raw["prStatus"]
        if pr["draft"].is(true) { return "draft" }
        if (pr["checks"]["failed"].number ?? 0) > 0 { return "failing" }
        if (pr["checks"]["pending"].number ?? 0) > 0 { return "pending" }
        return "passing"
    }

    /// The Windows client's `sessionState`: an idle conversation with a question up is "waiting".
    var conversationState: String { status == "idle" && raw["awaitingAnswer"].is(true) ? "waiting" : status }
    /// A row's second line: provider, branch (an orchestrator's role in its place), state and age, the empty ones left out.
    func conversationRowDetail(now: Date = Date()) -> String {
        var parts: [String] = []
        if let provider { parts.append(provider) }
        if raw["zeus"].is(true) { parts.append("\u{26A1} zeus") }
        else if raw["orchestrator"].is(true) { parts.append("\u{1F9ED} orchestrator") }
        else if let branch = raw["branch"].nonEmpty { parts.append(branch) }
        parts.append(conversationState)
        if let created = boardDateParse(raw["createdAt"].string) { parts.append(formatRelative(created, now: now)) }
        return parts.joined(separator: " \u{00B7} ")
    }
}

// MARK: - The list

/// The conversations a project's list shows: closed ones only when asked for, and those whose title holds the search.
func conversationsShown(_ sessions: [Session], search: String, showClosed: Bool) -> [Session] {
    let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return sessions.filter { s in
        (showClosed || s.status != "closed") && (needle.isEmpty || s.displayTitle.localizedCaseInsensitiveContains(needle))
    }
}

/// Still holding a workspace and a database: the only kind a Close has anything to release.
func conversationIsOpen(_ s: Session) -> Bool { ["queued", "preparing", "running", "idle"].contains(s.status) }

/// The picked conversations a bulk action works through, in the list's order: every picked one for Delete, the open
/// ones for Close.
func bulkConversationTargets(_ sessions: [Session], picked: Set<String>, delete: Bool) -> [String] {
    sessions.filter { picked.contains($0.id) && (delete || conversationIsOpen($0)) }.map(\.id)
}
/// The question before a bulk action, as the Mac's ☑ Select asks it.
func bulkConversationQuestion(count n: Int, delete: Bool) -> (title: String, message: String) {
    delete
        ? ("Delete \(n) conversation\(n == 1 ? "" : "s") and their logs?", "This cannot be undone.")
        : ("Close \(n) session\(n == 1 ? "" : "s")?", "Each one releases its workspace and database; the conversation stays readable.")
}

// MARK: - The conversation

/// Seconds between reads of an open conversation: often while the agent works, less while it waits, rarely once closed,
/// since nothing happens there until it is reopened.
func conversationPollInterval(_ s: Session) -> TimeInterval {
    if s.isActive { return 2 }
    return s.status == "closed" ? 60 : 7
}

/// The question before a conversation's action, as the Mac asks it; nil for one that needs none.
func conversationActionQuestion(_ action: String) -> String? {
    switch action {
    case "delete": return "Permanently delete this conversation and its transcript?"
    case "cancel": return "Stop the running agent?"
    case "close": return "Close this conversation?"
    case "reopen": return "Reopen this conversation?"
    case "compact": return "Compact this conversation? It summarizes the conversation to free context, which uses the provider and may incur usage."
    case "clear": return "Clear the transcript? It hides the transcript so far from this chat. Nothing is deleted and the agent\u{2019}s context is unchanged."
    default: return nil
    }
}

/// Whether the session offers compaction: it can compact, or is compacting now.
func sessionOffersCompact(_ raw: JSON) -> Bool { raw["canCompact"].is(true) || raw["compacting"].is(true) }
/// Whether Clear applies: a developer chat that is neither working nor compacting.
func sessionOffersClear(_ raw: JSON) -> Bool {
    raw["kind"].string == "devchat" && !Session(raw: raw).isActive && !raw["compacting"].is(true)
}
/// Whether the session has an auto-compact threshold to switch.
func sessionOffersAutoCompact(_ raw: JSON) -> Bool { (raw["autoCompactAt"].number ?? 0) > 0 }
/// Whether the session takes compaction instructions, or has some.
func sessionOffersCompactInstructions(_ raw: JSON) -> Bool {
    raw["compactTakesInstructions"].is(true) || raw["compactInstructions"].nonEmpty != nil
}
/// "Auto-compact at 150k".
func autoCompactLabel(_ raw: JSON) -> String {
    "Auto-compact at \(Int(((raw["autoCompactAt"].number ?? 0) / 1000 + 0.5).rounded(.down)))k"
}

/// The strip over a conversation: its pull request badge, the share of the context window in use, and what it cost,
/// the missing ones left out; nil with none of them.
func conversationStripText(_ s: Session) -> String? {
    var parts: [String] = []
    if let badge = s.pullBadge { parts.append(badge) }
    if let context = sessionContextSize(s.raw) {
        parts.append(context.window > 0 ? "\(Int((context.used / context.window * 100 + 0.5).rounded(.down)))% context"
                                        : "\(formatTokens(context.used)) context")
    }
    if let cost = sessionUsage(s.raw)["costUsd"].number { parts.append(formatCost(cost)) }
    return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
}
