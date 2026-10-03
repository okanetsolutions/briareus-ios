// What the board's screens share on a phone: the errand catalog and the runner that starts an errand (its confirmation,
// its question in a sheet), the rows of pull requests, issues and conversations, and the badges and chips they carry.
import SwiftUI
import UIKit

// MARK: - Links

/// Opens an https address in Safari; anything else is refused.
@MainActor
func boardOpenWeb(_ url: String?) {
    guard safeWebURL(url), let url, let u = URL(string: url) else { return }
    UIApplication.shared.open(u)
}

// MARK: - Errands

/// The errands the server lists (`actions`), read once in a while and shared by every board screen.
@MainActor
final class ErrandCatalog: ObservableObject {
    static let shared = ErrandCatalog()
    @Published private(set) var catalog: JSON = []
    private var readAt: Date?
    private var reading = false

    private init() {
        if let saved = Store.shared.cache.value("actions") { catalog = saved["actions"] }
    }

    /// The list changes with a server release, so it is read again only after a few minutes.
    func load() async {
        guard Store.shared.canManage, Store.shared.supports("actions"), !reading else { return }
        if let readAt, Date().timeIntervalSince(readAt) < 300 { return }
        reading = true
        defer { reading = false }
        guard let v = try? await Store.shared.call("actions") else { return }
        readAt = Date()
        if v["actions"] != catalog { catalog = v["actions"] }
        Store.shared.cache.store(v, "actions")
    }
}

/// The errands this device can start on a pull request: what the server offers for it, less what the token or server lacks.
@MainActor
func boardErrands(catalog: JSON, pull: PullSummary?, failedChecks: Int) -> [BoardAction] {
    guard Store.shared.canManage else { return [] }
    return BoardAction.offered(catalog: catalog, pull: pull, failedChecks: failedChecks).filter { Store.shared.supports($0.operation) }
}

/// The symbol before an errand's label.
func errandSymbol(_ id: String) -> String {
    switch id {
    case "run": return "play.fill"
    case "review": return "text.magnifyingglass"
    case "solve-conflicts": return "arrow.triangle.merge"
    case "fix-checks": return "wrench.and.screwdriver"
    case "implement-feedback": return "hammer"
    case "custom-feedback": return "square.and.pencil"
    case "pr-body-summary": return "doc.text"
    case "delete-self-comments": return "trash"
    default: return "bolt"
    }
}

/// One errand about to start on one pull request.
struct PendingErrand: Identifiable {
    var action: BoardAction
    var number: Int
    var branch: String
    var input: String?
    var id: String { "\(number):\(action.id)" }
}

/// Starts errands: every one is a paid session, so each asks first, in a dialog or in the sheet that takes its input. A
/// start that may have gone through (anything but a refusal) holds further starts until the user has looked.
@MainActor
final class ErrandRunner: ObservableObject {
    let repo: String
    @Published var confirming: PendingErrand?
    @Published var asking: PendingErrand?
    @Published private(set) var busy = false
    @Published private(set) var starting: PendingErrand?
    @Published var uncertain = false
    @Published var writeError: String?

    init(repo: String) { self.repo = repo }

    /// Asks for the errand's input when it takes one, else for a yes.
    func ask(_ action: BoardAction, number: Int, branch: String) {
        guard !busy, !uncertain, !branch.isEmpty else { return }
        let p = PendingErrand(action: action, number: number, branch: branch)
        if action.input != nil { asking = p } else { confirming = p }
    }

    /// Starts it; the session it started, when the server named one.
    func run(_ p: PendingErrand) async -> Session? {
        guard !busy, !uncertain else { return nil }
        busy = true; starting = p
        defer { busy = false; starting = nil }
        let args = p.action.arguments(repo: repo, number: p.number, branch: p.branch, input: p.input)
        do {
            let v = try await Store.shared.call(p.action.operation, args, timeout: p.action.timeoutMs.map { TimeInterval($0) / 1000 })
            writeError = nil
            if Store.shared.supports("sessions") { try? await Store.shared.feed(repo).loadSessions(fresh: true) }
            return Session(v["session"])
        } catch {
            guard let said = failure(error) else { return nil }
            writeError = said
            // A refusal is definite; anything else may have started the session.
            if (error as? APIError)?.isRefusal != true { uncertain = true }
            return nil
        }
    }

    /// Looking at the project's conversations is how an uncertain start is checked.
    func checked() { uncertain = false; writeError = nil }
}

extension View {
    /// The runner's dialog and input sheet; a started session is opened.
    func errandPrompts(_ runner: ErrandRunner) -> some View { modifier(ErrandPrompts(runner: runner)) }
}

private struct ErrandPrompts: ViewModifier {
    @ObservedObject var runner: ErrandRunner
    @Environment(\.navigate) private var navigate

    func body(content: Content) -> some View {
        content
            .alert(runner.confirming.map { "Start \($0.action.label) on #\($0.number)?" } ?? "",
                   isPresented: Binding(get: { runner.confirming != nil }, set: { if !$0 { runner.confirming = nil } }), presenting: runner.confirming) { p in
                Button("Start paid session", role: p.action.id == "delete-self-comments" ? .destructive : nil) { start(p) }
                Button("Cancel", role: .cancel) {}
            } message: { p in
                Text(paidNote(p))
            }
            .sheet(item: $runner.asking) { p in
                ErrandInputSheet(pending: p) { text in
                    var p = p
                    p.input = text
                    start(p)
                }
                .presentationDetents([.medium, .large])
            }
    }

    private func start(_ p: PendingErrand) {
        Task {
            if let s = await runner.run(p) { navigate(.conversation(id: s.id, session: s.raw)) }
        }
    }
}

private func paidNote(_ p: PendingErrand) -> String {
    let hint = p.action.hint.isEmpty ? "" : "\(p.action.hint). "
    return "\(hint)This runs a paid agent on pull request #\(p.number) and may write to GitHub."
}

/// The errand's question: a box for the answer, what it costs, and Start, off while a required answer is empty.
private struct ErrandInputSheet: View {
    let pending: PendingErrand
    let start: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool
    private var trimmed: String { text.cTrimmed }
    private var input: ActionInput? { pending.action.input }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(input.flatMap { $0.placeholder.isEmpty ? nil : $0.placeholder } ?? input?.label ?? "", text: $text, axis: .vertical)
                        .lineLimit(5...14).focused($focused)
                } header: {
                    Text(input?.label ?? "")
                } footer: {
                    Text(paidNote(pending))
                }
                .listRowBackground(Theme.row)
            }
            .scrollContentBackground(.hidden).background(Theme.background)
            .navigationTitle(pending.action.label).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { dismiss(); start(trimmed) }.bold()
                        .disabled(trimmed.isEmpty && input?.required == true)
                }
            }
            .onAppear { focused = true }
        }
    }
}

/// What an errand start left to say: why it failed, and whether it may have started anyway.
struct ErrandNotice: View {
    @ObservedObject var runner: ErrandRunner
    var place: String
    var body: some View {
        if let e = runner.writeError {
            Section {
                ErrorNotice(message: e)
                if runner.uncertain {
                    Text("The request may have completed. Look for its conversation \(place) before starting another agent.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("I have checked") { runner.checked() }.font(.callout)
                }
            }
            .listRowBackground(Theme.row)
        }
    }
}

// MARK: - Badges and chips

/// A small capsule: a symbol and a word in one colour on its tint.
struct BoardBadge: View {
    let text: String
    let systemImage: String?
    let color: Color
    @ScaledMetric(relativeTo: .caption2) private var iconSize: CGFloat = 9
    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: iconSize, weight: .semibold)) }
            Text(text).font(.caption2.weight(.semibold)).monospacedDigit().lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// Lays its subviews out left to right, wrapping when a line is full.
struct BoardFlowLayout: Layout {
    var spacing: CGFloat = 5
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (v, f) in zip(subviews, arrange(subviews, width: bounds.width)) {
            v.place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), proposal: ProposedViewSize(f.size))
        }
    }
    private func arrange(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let ideal = v.sizeThatFits(.unspecified)
            let size = CGSize(width: min(ideal.width, width), height: ideal.height)
            if x > 0 && x + size.width > width { x = 0; y += row + spacing; row = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing; row = max(row, size.height)
        }
        return frames
    }
}

/// GitHub's own colour, or secondary when it sent none that reads.
func boardLabelColor(_ label: PullLabel) -> Color {
    guard let rgb = label.rgb else { return .secondary }
    return Color(.sRGB, red: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255)
}

/// GitHub labels as chips: the label's colour tints the chip, the name stays in the text colour so a pale one still reads.
struct BoardLabelChips: View {
    let labels: [PullLabel]
    var body: some View {
        BoardFlowLayout(spacing: 5) {
            ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                let color = boardLabelColor(label)
                HStack(spacing: 4) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Text(label.name).font(.caption2.weight(.medium)).lineLimit(1)
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(color.opacity(0.14), in: Capsule())
                .overlay(Capsule().stroke(color.opacity(0.45), lineWidth: 0.5))
                .accessibilityElement(children: .ignore).accessibilityLabel("Label \(label.name)")
            }
        }
    }
}

/// A review verdict's symbol and colour.
func reviewStyle(_ status: ReviewStatus) -> (symbol: String, color: Color) {
    switch status {
    case .approved: return ("checkmark.seal.fill", Theme.success)
    case .changesRequested: return ("xmark.octagon.fill", Theme.danger)
    case .feedback: return ("text.bubble.fill", Theme.warning)
    case .requested, .none: return ("clock", .secondary)
    }
}

/// A board row's checks rollup as a badge.
struct ChecksBadge: View {
    let state: String
    var body: some View {
        switch state {
        case "success": BoardBadge(text: "Checks", systemImage: "checkmark", color: Theme.success).accessibilityLabel("Checks passed")
        case "failure", "error": BoardBadge(text: "Checks", systemImage: "xmark", color: Theme.danger).accessibilityLabel("Checks failed")
        default: BoardBadge(text: "Checks", systemImage: "clock", color: Theme.warning).accessibilityLabel("Checks running")
        }
    }
}

/// When a row last changed, short.
struct BoardUpdated: View {
    let date: Date?
    var body: some View {
        if let date { Text(formatRelative(date)).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
    }
}

// MARK: - Rows

/// An issue or pull request named under a row, with the state that says whether it is still open work.
struct BoardLinkedRow: View {
    let link: BoardLink
    let repo: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "link").font(.caption2).foregroundStyle(.tertiary)
            Text(link.reference(repo)).font(.caption.monospaced()).foregroundStyle(.secondary)
            Text(link.title).font(.caption).lineLimit(1)
            if let state = linkedStateText(link) {
                Text(state).font(.caption2).foregroundStyle(state == "open" ? Theme.success : state == "closed" ? Color.secondary : Theme.warning)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private func reviewerMark(_ state: String) -> String {
    switch state.asciiFolded {
    case "approved": return "✓"
    case "changes_requested": return "✗"
    case "requested": return "○"
    default: return "✎"
    }
}

/// A pull request as the board shows it: title, number and branch, its standing as badges, the errand it asks for, its
/// labels, who wrote, holds and reviews it, and the issues it closes.
struct BoardPullRow: View {
    let pull: PullSummary
    let stack: StackPosition?
    let repo: String
    /// The conversations at work on it right now.
    var activeRuns = 0
    /// The label of the errand its state asks for, when this device could start it.
    var suggested: String? = nil
    var showsIssues = true

    private var review: ReviewStatus { ReviewStatus(decision: pull.reviewDecision, reviewers: pull.reviewers) }
    private var tint: Color { pull.hasConflicts ? Theme.danger : pull.draft ? .secondary : Theme.success }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "arrow.triangle.pull").font(.subheadline).foregroundStyle(tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(pull.title).font(.body.weight(.medium)).lineLimit(2)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: "#\(pull.number)").font(.caption.monospaced()).foregroundStyle(.secondary).fixedSize()
                    Text(verbatim: pull.branch).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    BoardUpdated(date: pull.updatedAt)
                }
                if activeRuns > 0 || pull.hasConflicts || pull.checks != nil || stack != nil || review != .none || pull.draft || suggested != nil {
                    BoardFlowLayout(spacing: 5) {
                        if activeRuns > 0 {
                            BoardBadge(text: "\(activeRuns) running", systemImage: "bolt.fill", color: Theme.statusColor("running"))
                                .accessibilityLabel("\(activeRuns) conversation\(activeRuns == 1 ? "" : "s") at work")
                        }
                        if pull.hasConflicts { BoardBadge(text: "Conflicts", systemImage: "exclamationmark.triangle.fill", color: Theme.danger) }
                        if let checks = pull.checks { ChecksBadge(state: checks) }
                        if let stack {
                            BoardBadge(text: "Stack \(stack.label(pull.number))", systemImage: "square.stack.3d.up.fill", color: Theme.accent)
                                .accessibilityLabel("Stacked pull request \(stack.label(pull.number))")
                        }
                        if review != .none { BoardBadge(text: review.text, systemImage: reviewStyle(review).symbol, color: reviewStyle(review).color) }
                        if pull.draft { BoardBadge(text: "Draft", systemImage: "pencil", color: .secondary) }
                        if let suggested {
                            BoardBadge(text: "Suggested: \(suggested)", systemImage: "sparkles", color: Theme.accent)
                                .accessibilityLabel("Suggested errand: \(suggested)")
                        }
                    }
                }
                if !pull.labels.isEmpty { BoardLabelChips(labels: pull.labels) }
                Text(whoLine).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if showsIssues { ForEach(Array(pull.issues.enumerated()), id: \.offset) { _, link in BoardLinkedRow(link: link, repo: repo) } }
            }
        }
        .padding(.vertical, 3)
    }

    private var whoLine: String {
        var parts: [String] = []
        if let author = pull.author { parts.append("by @\(author)") }
        parts.append(pull.assignees.isEmpty ? "unassigned" : "assigned \(people(pull.assignees, limit: 2))")
        if !pull.reviewers.isEmpty {
            parts.append("review " + pull.reviewers.prefix(2).map { "\(reviewerMark($0.state)) @\($0.user)" }.joined(separator: ", ")
                         + (pull.reviewers.count > 2 ? " +\(pull.reviewers.count - 2)" : ""))
        }
        return parts.joined(separator: " · ")
    }
}

/// How much of an epic is done, over every sub-issue GitHub knows, which may be more than the rows under it.
struct BoardEpicProgress: View {
    let done: Int
    let total: Int
    var body: some View {
        HStack(spacing: 8) {
            ProgressView(value: Double(min(done, max(total, 1))), total: Double(max(total, 1))).tint(Theme.accent).frame(width: 70)
            Text("\(done)/\(total) done").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(done) of \(total) sub-issues closed")
    }
}

/// An issue as the board shows it: who holds it, the epic's progress, its labels, its epic, and what answers it.
struct BoardIssueRow: View {
    let issue: IssueSummary
    let repo: String
    /// Set on a row drawn under its epic, where the indent already says whose it is.
    var nested = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: issue.isEpic ? "square.stack.3d.up" : "smallcircle.filled.circle").font(.subheadline)
                .foregroundStyle(issue.pulls.isEmpty ? Theme.success : Theme.accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(issue.title).font(.body.weight(.medium)).lineLimit(2)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(metaLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    BoardUpdated(date: issue.updatedAt)
                }
                if issue.isEpic { BoardEpicProgress(done: issue.subIssuesDone, total: issue.subIssues) }
                if !issue.labels.isEmpty { BoardLabelChips(labels: issue.labels) }
                if !nested, let parent = issue.parent {
                    Label("Part of \(parent.reference(repo)) \(parent.title)", systemImage: "arrow.turn.down.right")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                ForEach(Array(issue.pulls.enumerated()), id: \.offset) { _, link in BoardLinkedRow(link: link, repo: repo) }
            }
        }
        .padding(.vertical, 3)
    }
    private var metaLine: String {
        var parts = ["#\(issue.number)"]
        if let author = issue.author { parts.append("@\(author)") }
        parts.append(issue.assignees.isEmpty ? "unassigned" : "assigned \(people(issue.assignees, limit: 2))")
        if issue.comments > 0 { parts.append("\(issue.comments) comment\(issue.comments == 1 ? "" : "s")") }
        if let milestone = issue.milestone { parts.append(milestone) }
        return parts.joined(separator: " · ")
    }
}

/// A conversation run on a pull request or issue: its status, title, and status · model.
struct BoardSessionRow: View {
    let session: Session
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            StatusDot(status: session.status).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayTitle).lineLimit(2).foregroundStyle(session.status == "closed" ? .secondary : .primary)
                Text(sessionSubtitle(session)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
