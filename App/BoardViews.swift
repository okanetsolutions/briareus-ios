import SwiftUI

/// Lays chips out in rows, wrapping to the next when one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, arrange(subviews, width: bounds.width)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }
    private func arrange(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for subview in subviews {
            let ideal = subview.sizeThatFits(.unspecified)
            let size = CGSize(width: min(ideal.width, width), height: ideal.height)
            if x > 0 && x + size.width > width { x = 0; y += row + spacing; row = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing; row = max(row, size.height)
        }
        return frames
    }
}

/// GitHub's own label colour tints the chip; the name stays in the text colour so a pale label still reads.
struct LabelChip: View {
    let label: PullLabel
    private var color: Color {
        label.rgb.map { Color(red: $0[0], green: $0[1], blue: $0[2]) } ?? .secondary
    }
    var body: some View {
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

struct LabelChips: View {
    let labels: [PullLabel]
    var body: some View {
        FlowLayout(spacing: 5) { ForEach(labels, id: \.self) { LabelChip(label: $0) } }
    }
}

struct ConflictBadge: View {
    var body: some View { Badge(text: "Conflicts", systemImage: "exclamationmark.triangle.fill", color: Theme.danger) }
}

/// The rollup of a pull request's checks, as the board carries it.
struct ChecksBadge: View {
    let state: String
    var body: some View {
        switch state {
        case "success": Badge(text: "Checks", systemImage: "checkmark", color: Theme.success).accessibilityLabel("Checks passed")
        case "failure", "error": Badge(text: "Checks", systemImage: "xmark", color: Theme.danger).accessibilityLabel("Checks failed")
        default: Badge(text: "Checks", systemImage: "clock", color: Theme.warning).accessibilityLabel("Checks running")
        }
    }
}

struct Updated: View {
    let date: Date?
    var body: some View {
        if let date {
            Text(date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

private func people(_ logins: [String], limit: Int = 2) -> String {
    logins.prefix(limit).map { "@\($0)" }.joined(separator: ", ") + (logins.count > limit ? " +\(logins.count - limit)" : "")
}

private func reviewerMark(_ state: String) -> String {
    switch state {
    case "approved": return "✓"
    case "changes_requested": return "✗"
    case "requested": return "○"
    // Not the dot that separates the line's parts, which a comment's mark would read as.
    default: return "✎"
    }
}

/// An issue or pull request named under a row, with the state that says whether it is still open work.
struct LinkedRow: View {
    let link: BoardLink
    let repo: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "link").font(.caption2).foregroundStyle(.tertiary)
            Text(link.reference(in: repo)).font(.caption.monospaced()).foregroundStyle(.secondary)
            Text(link.title).font(.caption).lineLimit(1)
            if link.draft { Text("draft").font(.caption2).foregroundStyle(Theme.warning) }
            if link.notPlanned { Text("not planned").font(.caption2).foregroundStyle(Theme.warning) }
            else if link.state == "open" { Text("open").font(.caption2).foregroundStyle(Theme.success) }
            else if link.state == "closed" { Text("closed").font(.caption2).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
    }
}

struct PullRow: View {
    let pr: PullSummary
    let stack: StackPosition?
    let repo: String
    /// The conversations at work on it right now.
    var activeRuns = 0
    /// The errand this pull request asks for, when this device could start it.
    var suggested: BoardAction? = nil
    private var review: ReviewStatus? {
        ReviewStatus(decision: pr.reviewDecision, reviews: pr.reviewers.map { .object(["state": .string($0.state)]) })
    }
    private var tint: Color { pr.conflicting ? Theme.danger : pr.draft ? .secondary : Theme.success }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "arrow.triangle.pull").font(.subheadline).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 5) {
                Text(pr.title).font(.body.weight(.medium)).lineLimit(2)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // The number is what the pull request is called, so only the branch gives way to large text.
                    Text(verbatim: "#\(pr.number)").font(.caption.monospaced()).foregroundStyle(.secondary).fixedSize()
                    Text(verbatim: pr.branch).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Updated(date: pr.updatedAt)
                }
                if activeRuns > 0 || pr.conflicting || pr.checks != nil || stack != nil || review != nil || pr.draft || suggested != nil {
                    FlowLayout(spacing: 5) {
                        if activeRuns > 0 {
                            Badge(text: "\(activeRuns) active run\(activeRuns == 1 ? "" : "s")", systemImage: "bolt.fill", color: Theme.statusColor("running"))
                        }
                        if pr.conflicting { ConflictBadge() }
                        if let checks = pr.checks { ChecksBadge(state: checks) }
                        if let stack { StackBadge(stack: stack) }
                        if let review { ReviewBadge(status: review) }
                        if pr.draft { Badge(text: "Draft", systemImage: "pencil", color: .secondary) }
                        if let suggested {
                            Badge(text: "Suggested: \(suggested.label)", systemImage: "sparkle", color: Theme.accent)
                                .accessibilityLabel("Suggested action: \(suggested.label)")
                        }
                    }
                }
                if !pr.labels.isEmpty { LabelChips(labels: pr.labels) }
                if pr.author != nil || !pr.assignees.isEmpty || !pr.reviewers.isEmpty {
                    Text(whoLine).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                ForEach(pr.issues, id: \.self) { LinkedRow(link: $0, repo: repo) }
            }
        }.padding(.vertical, 3)
    }
    private var whoLine: String {
        var parts: [String] = []
        if let author = pr.author { parts.append("by @\(author)") }
        parts.append(pr.assignees.isEmpty ? "unassigned" : "assigned \(people(pr.assignees))")
        if !pr.reviewers.isEmpty {
            parts.append("review " + pr.reviewers.prefix(2).map { "\(reviewerMark($0.state)) @\($0.user)" }.joined(separator: ", ")
                         + (pr.reviewers.count > 2 ? " +\(pr.reviewers.count - 2)" : ""))
        }
        return parts.joined(separator: " · ")
    }
}

struct IssueRow: View {
    let issue: IssueSummary
    let repo: String
    /// Set on a row drawn under its epic, where the indent already says whose it is.
    var nested = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: issue.isEpic ? "square.stack.3d.up" : "smallcircle.filled.circle").font(.subheadline)
                .foregroundStyle(issue.pulls.isEmpty ? Theme.success : Theme.accent)
            VStack(alignment: .leading, spacing: 5) {
                Text(issue.title).font(.body.weight(.medium)).lineLimit(2)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(metaLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    Updated(date: issue.updatedAt)
                }
                if issue.isEpic { EpicProgress(issue: issue) }
                if !issue.labels.isEmpty { LabelChips(labels: issue.labels) }
                if !nested, let parent = issue.parent {
                    Label("Part of \(parent.reference(in: repo)) \(parent.title)", systemImage: "arrow.turn.down.right")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                ForEach(issue.pulls, id: \.self) { LinkedRow(link: $0, repo: repo) }
            }
        }.padding(.vertical, 3)
    }
    private var metaLine: String {
        var parts = ["#\(String(issue.number))"]
        if let author = issue.author { parts.append("@\(author)") }
        parts.append(issue.assignees.isEmpty ? "unassigned" : "assigned \(people(issue.assignees))")
        if issue.comments > 0 { parts.append("\(issue.comments) comment\(issue.comments == 1 ? "" : "s")") }
        if let milestone = issue.milestone { parts.append(milestone) }
        return parts.joined(separator: " · ")
    }
}

/// How much of an epic is done, over every sub-issue GitHub knows, which may be more than the rows under it.
struct EpicProgress: View {
    let issue: IssueSummary
    var body: some View {
        HStack(spacing: 8) {
            ProgressView(value: Double(issue.subIssuesDone), total: Double(max(issue.subIssues, 1)))
                .tint(Theme.accent).frame(width: 70)
            Text("\(issue.subIssuesDone)/\(issue.subIssues) done").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(issue.subIssuesDone) of \(issue.subIssues) sub-issues closed")
    }
}

/// The board's three pickers. Each option says how many rows picking it would leave.
struct BoardFilterMenu: View {
    @Binding var filter: BoardFilter
    let rows: [BoardRow]
    let kinds: [BoardFilter.Kind]
    var body: some View {
        Menu {
            ForEach(kinds, id: \.self) { kind in
                let options = filter.options(kind, in: rows)
                Picker(selection: Binding(get: { filter[kind] }, set: { filter[kind] = $0 })) {
                    Text("All \(kind.rawValue)s").tag("")
                    ForEach(options) { Text("\($0.text) (\($0.count))").tag($0.value) }
                } label: {
                    Label(filter[kind].isEmpty ? kind.rawValue.capitalized : "\(kind.rawValue.capitalized): \(options.first { $0.value == filter[kind] }?.text ?? filter[kind])",
                          systemImage: kind == .author ? "person" : kind == .reviewer ? "eye" : "tag")
                }
                .pickerStyle(.menu).disabled(options.isEmpty)
            }
            if filter.isOn { Button("Clear filters", systemImage: "xmark.circle", role: .destructive) { filter = BoardFilter() } }
        } label: {
            Image(systemName: filter.isOn ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel(filter.isOn ? "Filters, active" : "Filters")
    }
}

/// One open issue: who holds it, what is already answering it, and the session that would.
struct IssueDetailView: View {
    let project: Project
    let issue: IssueSummary
    @EnvironmentObject private var store: AppStore
    @State private var confirming = false
    @State private var busy = false
    @State private var uncertain = false
    @State private var writeError: String?
    @State private var started: Session?
    var body: some View {
        List {
            if let writeError {
                Section {
                    ErrorNotice(message: writeError)
                    if uncertain {
                        Text("The request may have completed. Check the project’s conversations before starting another agent.").font(.caption)
                        Button("I have checked") { uncertain = false; self.writeError = nil }.buttonStyle(.bordered).controlSize(.small)
                    }
                }.listRowBackground(Theme.row)
            }
            Section {
                Text(issue.title).font(.title3.bold())
                if issue.isEpic { LabeledContent("Sub-issues") { EpicProgress(issue: issue) } }
                if !issue.labels.isEmpty {
                    LabelChips(labels: issue.labels).padding(.vertical, 2).alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                }
                if let author = issue.author { LabeledContent("Reported by", value: "@\(author)") }
                LabeledContent("Assigned", value: issue.assignees.isEmpty ? "Nobody" : people(issue.assignees, limit: 4))
                if let milestone = issue.milestone { LabeledContent("Milestone", value: milestone) }
                if issue.comments > 0 { LabeledContent("Comments", value: "\(issue.comments)") }
                if let updated = issue.updatedAt { LabeledContent("Updated") { Updated(date: updated) } }
                if let url = safeWebURL(issue.url) { Link("Open on GitHub", destination: url) }
            }.listRowBackground(Theme.row)
            if let parent = issue.parent {
                Section("Part of") {
                    if let url = safeWebURL(parent.url) { Link(destination: url) { LinkedRow(link: parent, repo: project.repo) } }
                    else { LinkedRow(link: parent, repo: project.repo) }
                }.listRowBackground(Theme.row)
            }
            Section {
                ForEach(issue.pulls, id: \.self) { pull in
                    if pull.isForeign(to: project.repo) || !store.supports("pull") {
                        if let url = safeWebURL(pull.url) { Link(destination: url) { LinkedRow(link: pull, repo: project.repo) } }
                        else { LinkedRow(link: pull, repo: project.repo) }
                    } else {
                        NavigationLink { PullDetailView(project: project, number: pull.number) } label: { LinkedRow(link: pull, repo: project.repo) }
                    }
                }
                if issue.pulls.isEmpty { Text("No open pull request closes this issue yet").foregroundStyle(.secondary) }
            } header: { Text("Pull requests") }.listRowBackground(Theme.row)
            if store.supports("start_session") {
                Section {
                    if issue.isEpic {
                        Text("An epic is worked by an orchestrator, one sub-issue at a time. Start it from the web dashboard, where its models are picked, or start one of its sub-issues here.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Button { confirming = true } label: {
                            HStack {
                                Label("Start a session on this issue", systemImage: "play.fill").fontWeight(.semibold)
                                if busy { Spacer(); ProgressView() }
                            }
                        }.disabled(busy || uncertain)
                    }
                } footer: {
                    if !issue.isEpic {
                        Text(issue.pulls.isEmpty ? "The session reads the issue, implements it on a branch of its own and opens a pull request closing it. It runs a paid agent on this project’s configured model."
                             : "A pull request is already answering this issue. A second session is a paid agent working on the same thing.")
                    }
                }.listRowBackground(Theme.row)
            }
        }
        .scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle("#\(String(issue.number))").navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $started) { ConversationView(initial: $0) }
        .confirmationDialog("Start a paid session on issue #\(String(issue.number))?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Start session") { Task { await start() } }
        }
    }
    private func start() async {
        guard !busy, !uncertain else { return }
        busy = true; defer { busy = false }
        do {
            let result: SessionResult = try await store.call("start_session", [
                "repo": .string(project.repo), "prompt": .string(issue.prompt(repo: project.repo)), "activity": .string("issue"),
            ])
            started = result.session
        } catch {
            writeError = error.localizedDescription
            // A refusal is definite; anything else may have started the session.
            if case .http(400..<500, _, _)? = error as? APIError {} else { uncertain = true }
        }
    }
}

/// Asks what an errand needs to be told before it can start, such as the feedback to implement.
struct ActionInputView: View {
    let action: BoardAction
    let number: Int
    let start: (String) -> Void
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField(action.input?.placeholder.isEmpty == false ? action.input?.placeholder ?? "" : action.input?.label ?? "",
                                  text: $text, axis: .vertical)
                            .lineLimit(6...16).focused($focused)
                        if store.canTranscribe { HStack { Spacer(); VoiceNoteButton(text: $text) } }
                    }
                    .padding(14)
                    .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.border, lineWidth: 0.5))
                    Label("\(action.hint). This runs a paid agent on pull request #\(String(number)) and may write to GitHub.", systemImage: "sparkle")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(16)
            }
            .background(Theme.background)
            .navigationTitle(action.label).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.buttonStyle(.automatic) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { dismiss(); start(trimmed) }.bold().buttonStyle(.automatic)
                        .disabled(trimmed.isEmpty && action.input?.required == true)
                }
            }
            .onAppear { focused = true }
        }
    }
}
