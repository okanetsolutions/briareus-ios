// The rows several screens share, as common.c draws them: a session, a linked issue or pull request, a line of facts, label
// chips, a pull request and an issue on the board, and an epic's progress; with the glyphs and colours that go with them.
import SwiftUI

// MARK: - Glyphs and colours

/// A GitHub label's colour for the chips, or the secondary colour.
func labelColor(_ label: PullLabel) -> Color {
    guard let rgb = label.rgb else { return Theme.muted }
    return Color(.sRGB, red: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255)
}
/// A finding's severity pill colour (CRIT and HIGH red, MED amber, LOW grey).
func severityColor(_ severity: String?) -> Color {
    switch severity?.lowercased() {
    case "critical", "high": return Theme.danger
    case "low": return Theme.muted
    default: return Theme.warn
    }
}
func reviewGlyph(_ status: ReviewStatus) -> (symbol: String?, color: Color) {
    switch status {
    case .approved: return (Glyph.symbol(0xE73E), Theme.ok)
    case .changesRequested: return (Glyph.symbol(0xE711), Theme.danger)
    case .feedback: return (Glyph.symbol(0xE8BD), Theme.warn)
    case .requested: return (Glyph.symbol(0xE823), Theme.muted)
    case .none: return (nil, Theme.muted)
    }
}
/// The glyph for a check conclusion.
func checkGlyph(_ result: String?) -> (symbol: String, color: Color) {
    switch result?.lowercased() {
    case "success", "passed", "neutral", "skipped": return (Glyph.symbol(0xE930), Theme.ok)
    case "failure", "failed", "timed_out", "action_required", "error": return (Glyph.symbol(0xEA39), Theme.danger)
    case "cancelled", "stale": return (Glyph.symbol(0xE738), Theme.muted)
    default: return (Glyph.symbol(0xE823), Theme.warn)
    }
}
/// The glyph a tool event shows, from its name.
func toolGlyph(kind: String?, name: String?, isError: Bool) -> String {
    if isError { return Glyph.symbol(0xE7BA) }
    if kind == "cmd" { return Glyph.symbol(0xE756) }
    if kind == "git" { return Glyph.symbol(0xE8AB) }
    let n = (name ?? "").lowercased()
    func has(_ s: String...) -> Bool { s.contains { n.contains($0) } }
    if has("bash", "shell", "exec") { return Glyph.symbol(0xE756) }
    if has("read", "view") { return Glyph.symbol(0xE8A5) }
    if has("todo", "plan") { return Glyph.symbol(0xE9D5) }
    if has("edit", "write", "patch") { return Glyph.symbol(0xE70F) }
    if has("grep", "glob", "search", "find") { return Glyph.symbol(0xE721) }
    if has("web", "fetch") { return Glyph.symbol(0xE774) }
    if has("task", "agent") { return Glyph.symbol(0xE716) }
    return Glyph.symbol(0xE90F)
}

struct BadgeSpec: Hashable {
    var glyph: String?
    var text: String
    var color: Color
    var chip = false
}
/// A pull request's badges (conflicts, checks, stack, review, draft).
func pullBadges(_ pull: PullSummary, stack: StackPosition?) -> [BadgeSpec] {
    var out: [BadgeSpec] = []
    if pull.conflicting { out.append(BadgeSpec(glyph: Glyph.symbol(0xE7BA), text: "Conflicts", color: Theme.danger)) }
    if let checks = pull.checks {
        if checks == "success" { out.append(BadgeSpec(glyph: Glyph.symbol(0xE73E), text: "Checks", color: Theme.ok)) }
        else if checks == "failure" || checks == "error" { out.append(BadgeSpec(glyph: Glyph.symbol(0xE711), text: "Checks", color: Theme.danger)) }
        else { out.append(BadgeSpec(glyph: Glyph.symbol(0xE823), text: "Checks", color: Theme.warn)) }
    }
    if let stack { out.append(BadgeSpec(glyph: Glyph.symbol(0xE81E), text: "Stack \(stack.label())", color: Theme.accent)) }
    let review = ReviewStatus(decision: pull.reviewDecision, reviewers: pull.reviewers)
    if review != .none { let g = reviewGlyph(review); out.append(BadgeSpec(glyph: g.symbol, text: review.text, color: g.color)) }
    if pull.draft { out.append(BadgeSpec(glyph: Glyph.symbol(0xE70F), text: "Draft", color: Theme.muted)) }
    return out
}

/// A line of wrapped badges and chips.
struct Badges: View {
    var specs: [BadgeSpec]
    var background: Color = Theme.raise
    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 4) {
            ForEach(Array(specs.enumerated()), id: \.offset) { _, s in
                if s.chip { Chip(name: s.text, color: s.color, background: background) }
                else { Badge(glyph: s.glyph, text: s.text, color: s.color, background: background) }
            }
        }
    }
}
/// Chips for GitHub labels.
struct LabelChips: View {
    var labels: [PullLabel]
    var background: Color = Theme.raise
    var body: some View {
        if !labels.isEmpty {
            Badges(specs: labels.map { BadgeSpec(text: $0.name, color: labelColor($0), chip: true) }, background: background)
        }
    }
}

// MARK: - Session row

/// A session row: status dot, title and subtitle ("Status · model"), clickable; the selected one on the raised colour.
struct SessionRow: View {
    var session: Session
    var selected = false
    var background: Color = .clear
    /// Room kept at the right for a control laid over the row.
    var trailing: CGFloat = 0
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    StatusDot(status: session.status).frame(width: 8)
                    Text(session.displayTitle).font(Theme.subheadline).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
                }
                .frame(height: 23)
                Text(sessionSubtitle(session)).font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
            }
            .padding(.horizontal, 8).padding(.vertical, 7).padding(.trailing, trailing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.raise : hovered ? Theme.raise.opacity(0.6) : background))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - Linked rows and facts

/// The linked issue or pull request row under a board row: ↳, its reference, its title and its state.
struct LinkedRow: View {
    var link: BoardLink
    var repo: String?
    var action: (() -> Void)? = nil
    var body: some View {
        let content = HStack(spacing: 5) {
            Text("↳").font(Theme.caption).foregroundStyle(Theme.tertiary).frame(width: 12, alignment: .leading)
            Text(link.reference(repo)).font(Theme.monoCaption2).foregroundStyle(Theme.muted)
            Text(link.title).font(Theme.caption).foregroundStyle(action != nil ? Theme.ink : Theme.muted).lineLimit(1).truncationMode(.tail)
            if let state = linkedStateText(link) {
                Text(state).font(Theme.caption2).foregroundStyle(state == "open" ? Theme.ok : state == "closed" ? Theme.muted : Theme.warn)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 20)
        if let action { Button(action: action) { content.contentShape(Rectangle()) }.buttonStyle(.plain) } else { content }
    }
}

/// One part of a line of facts.
struct MetaPart: Hashable {
    var text: String
    var color: Color = Theme.muted
    var mono = false
}
/// One 12px muted line of facts, `·` between them, the last one pushed to the right edge.
struct MetaLine: View {
    var parts: [MetaPart]
    var right: String? = nil
    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(Array(parts.enumerated()), id: \.offset) { i, p in
                    if i > 0 { Text("·").font(Theme.caption).foregroundStyle(Theme.line) }
                    Text(p.text).font(p.mono ? Theme.monoCaption2 : Theme.caption).foregroundStyle(p.color).lineLimit(1).truncationMode(.tail)
                }
            }
            .layoutPriority(0)
            Spacer(minLength: 8)
            if let right { Text(right).font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1).fixedSize().layoutPriority(1) }
        }
        .frame(height: 20)
    }
}

// MARK: - Board rows

/// A row's box: `p-3 rounded-xl bg-raise border`, the accent's dim border while it runs, clickable as a whole.
private struct RowBox<Content: View>: View {
    var running = false
    var action: (() -> Void)?
    @ViewBuilder var content: Content
    @State private var hovered = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(hovered && action != nil ? Theme.field.opacity(0.5) : Theme.raise))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(running ? Theme.accentDim : Theme.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onTapGesture { action?() }
            .onHover { hovered = $0 }
    }
}

/// The row of a pull request on the board: its title, a line of facts, its labels, the issues it closes and its errand buttons.
struct PullRow<Buttons: View>: View {
    var pull: PullSummary
    var stack: StackPosition?
    var repo: String?
    var running = false
    var action: (() -> Void)?
    @ViewBuilder var buttons: Buttons

    private var facts: [MetaPart] {
        var d: [MetaPart] = [MetaPart(text: "#\(pull.number)")]
        if pull.draft { d.append(MetaPart(text: "draft")) }
        if pull.hasConflicts { d.append(MetaPart(text: "⚠ conflicts", color: Theme.danger)) }
        if let checks = pull.checks {
            if checks == "success" { d.append(MetaPart(text: "✓ checks", color: Theme.ok)) }
            else if checks == "failure" || checks == "error" { d.append(MetaPart(text: "✗ checks", color: Theme.danger)) }
            else { d.append(MetaPart(text: "… checks", color: Theme.warn)) }
        }
        let review = ReviewStatus(decision: pull.reviewDecision, reviewers: pull.reviewers)
        if review != .none { d.append(MetaPart(text: review.text, color: reviewGlyph(review).color)) }
        if let stack { d.append(MetaPart(text: "stack \(stack.label())", color: Theme.accent)) }
        if !pull.assignees.isEmpty { d.append(MetaPart(text: people(pull.assignees, limit: 2))) }
        else { d.append(MetaPart(text: "unassigned", color: Theme.tertiary)) }
        if let author = pull.author { d.append(MetaPart(text: "@\(author)")) }
        if !pull.branch.isEmpty { d.append(MetaPart(text: pull.branch, mono: true)) }
        return d
    }

    var body: some View {
        RowBox(running: running, action: action) {
            Text(pull.title).font(Theme.bodySemibold).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
            MetaLine(parts: facts, right: pull.updatedAt.map { formatRelative($0) }).padding(.top, 4)
            if !pull.labels.isEmpty { LabelChips(labels: pull.labels).padding(.top, 6) }
            ForEach(Array(pull.issues.enumerated()), id: \.offset) { _, link in LinkedRow(link: link, repo: repo).padding(.top, 4) }
            buttons
        }
    }
}
extension PullRow where Buttons == EmptyView {
    init(pull: PullSummary, stack: StackPosition?, repo: String?, running: Bool = false, action: (() -> Void)?) {
        self.init(pull: pull, stack: stack, repo: repo, running: running, action: action) { EmptyView() }
    }
}

/// An epic's bar of closed sub-issues against all of them, with "N/M done" after it.
struct EpicProgress: View {
    var done: Int
    var total: Int
    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.accent.opacity(0.15))
                Capsule().fill(Theme.accent).frame(width: 70 * CGFloat(min(done, max(total, 1))) / CGFloat(max(total, 1)))
            }
            .frame(width: 70, height: 6)
            Text("\(done)/\(total) done").font(Theme.caption2).foregroundStyle(Theme.muted)
        }
        .frame(height: 17)
    }
}

/// The row of an issue on the board.
struct IssueRowView: View {
    var issue: IssueSummary
    var repo: String?
    var nested = false
    var action: (() -> Void)?

    private var facts: [MetaPart] {
        var d: [MetaPart] = [MetaPart(text: "#\(issue.number)")]
        if let author = issue.author { d.append(MetaPart(text: "@\(author)")) }
        if !issue.assignees.isEmpty { d.append(MetaPart(text: people(issue.assignees, limit: 2))) }
        else { d.append(MetaPart(text: "unassigned", color: Theme.tertiary)) }
        if issue.comments > 0 { d.append(MetaPart(text: "\(issue.comments) comment\(issue.comments == 1 ? "" : "s")")) }
        if let m = issue.milestone { d.append(MetaPart(text: m)) }
        if !issue.pulls.isEmpty { d.append(MetaPart(text: issue.pulls.count == 1 ? "1 pull request" : "pull requests", color: Theme.ok)) }
        return d
    }

    var body: some View {
        RowBox(action: action) {
            Text((issue.isEpic ? "◎ " : "") + issue.title).font(Theme.bodySemibold).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
            MetaLine(parts: facts, right: issue.updatedAt.map { formatRelative($0) }).padding(.top, 4)
            if issue.isEpic { EpicProgress(done: issue.subIssuesDone, total: issue.subIssues).padding(.top, 4) }
            if !issue.labels.isEmpty { LabelChips(labels: issue.labels).padding(.top, 6) }
            if !nested, let parent = issue.parent {
                Text("Part of \(parent.reference(repo)) \(parent.title)").font(Theme.caption).foregroundStyle(Theme.muted)
                    .lineLimit(1).truncationMode(.tail).padding(.top, 4)
            }
            ForEach(Array(issue.pulls.enumerated()), id: \.offset) { _, link in LinkedRow(link: link, repo: repo).padding(.top, 4) }
        }
    }
}
