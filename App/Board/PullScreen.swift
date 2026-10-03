// One pull request on a phone (the Mac's PullScreen): what it is and where it stands at the top, a scrolling section
// picker in place of GitHub's tabs (description, files, reviews and comments, the issues it closes,
// findings, the conversations run on it, and ▶ Run), the errands in the toolbar, and a squash merge that says first what
// stands in its way.
import SwiftUI

struct PullScreen: View {
    let repo: String
    let number: Int
    let stack: JSON?
    let summary: JSON?

    @EnvironmentObject private var store: Store
    @ObservedObject private var catalog = ErrandCatalog.shared
    @StateObject private var model: PullScreenModel
    @StateObject private var errands: ErrandRunner
    @Environment(\.navigate) private var navigate
    @State private var confirmingSolve: PendingErrand?
    @State private var deleting: Session?
    @State private var deletingServed = false
    @State private var stackOpen = false
    @State private var openFindings: Set<Int> = []

    init(repo: String, number: Int, stack: JSON?, summary: JSON?) {
        self.repo = repo; self.number = number; self.stack = stack; self.summary = summary
        _model = StateObject(wrappedValue: PullScreenModel(repo: repo, number: number, stack: stack.flatMap { StackPosition(restoring: $0) },
                                                           summary: summary.flatMap { PullSummary($0) }))
        _errands = StateObject(wrappedValue: ErrandRunner(repo: repo))
    }

    var body: some View {
        Group {
            if model.section == .run {
                VStack(spacing: 0) {
                    sectionBar.padding(.vertical, 6)
                    PullRunArea(model: model)
                }
                .background(Theme.background)
            } else {
                list
            }
        }
        .navigationTitle(Text(verbatim: "#\(number)")).navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task {
            await poll(every: 30) {
                if errands.busy || model.merging || model.deciding != nil || model.mergeQuestion != nil { return nil }
                return await reading { try await model.load() }
            }
        }
        // The setup's log while a Run is being prepared, every second and a half.
        .task(id: model.runBusy) {
            while model.runBusy && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if Task.isCancelled { return }
                await model.runLogTick()
            }
        }
        .onAppear { model.appeared() }
        .onDisappear { model.disappeared() }
        .errandPrompts(errands)
        .confirmationDialog(model.mergeQuestion.map { "Squash and merge #\(number) into \($0.base)?" } ?? "",
                            isPresented: Binding(get: { model.mergeQuestion != nil }, set: { if !$0 { model.mergeQuestion = nil } }),
                            titleVisibility: .visible, presenting: model.mergeQuestion) { _ in
            Button("Squash and merge") { Task { await model.merge() } }
        } message: { q in
            Text(q.notes.isEmpty ? "Its commits are squashed into one on \(q.base) on GitHub. This cannot be undone from the app." : q.notes.joined(separator: " "))
        }
        .confirmationDialog(solveTitle, isPresented: Binding(get: { confirmingSolve != nil }, set: { if !$0 { confirmingSolve = nil } }),
                            titleVisibility: .visible, presenting: confirmingSolve) { p in
            Button("Solve findings") {
                Task { if let s = await errands.run(p) { navigate(.conversation(id: s.id, session: s.raw)) } }
            }
        } message: { _ in
            Text(verbatim: "The agent addresses the findings on PR #\(number), pushes the fixes to its branch and has them reviewed again. Uses the provider and model configured for this project.")
        }
        .confirmationDialog("Permanently delete this conversation and its transcript?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { s in
            Button("Delete", role: .destructive) { Task { await model.delete(s.id) } }
        } message: { s in Text("\u{201C}\(s.displayTitle)\u{201D}") }
        .confirmationDialog("Delete this run?", isPresented: $deletingServed, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let id = model.runTarget { Task { await model.delete(id) } }
            }
        } message: {
            Text("Its workspace stops serving the pull request, and its conversation and transcript are deleted permanently.")
        }
    }

    private var solveTitle: String {
        let fixes = findingsToFix(model.findings), open = findingsUnfixed(model.findings)
        return fixes > 0 ? "Start a paid fix session for \(fixes) finding\(fixes == 1 ? "" : "s")?"
            : "Start a paid fix session for \(open) open finding\(open == 1 ? "" : "s")?"
    }

    private var list: some View {
        List {
            notices
            header
            sectionBar.listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
            if model.pr.isNull && model.section != .conversations && model.section != .description {
                if model.error == nil { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 12).listRowBackground(Color.clear) }
            } else {
                switch model.section {
                case .description: description
                case .files: files
                case .reviews: reviews
                case .issues: issues
                case .findings: findings
                case .conversations: conversations
                case .run: EmptyView()
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden).background(Theme.background)
        .refreshable {
            // Pulling down is how an uncertain start is checked: its conversation is listed here if it began.
            errands.checked()
            await model.refresh()
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        let actions = model.actions(catalog.catalog)
        let suggested = model.boardRow?.recommended
        if !actions.isEmpty, let branch = model.pr["headRef"].string {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let s = actions.first(where: { $0.id == suggested }) {
                        Section("Suggested") { errandButton(s, branch: branch, suggested: true) }
                    }
                    Section {
                        ForEach(actions.filter { $0.id != suggested }, id: \.id) { errandButton($0, branch: branch, suggested: false) }
                    } footer: {
                        Text("Errands run paid agents on this project’s configured model and may write to GitHub.")
                    }
                } label: {
                    if errands.busy { ProgressView() } else { Image(systemName: "wand.and.stars") }
                }
                .disabled(errands.busy || errands.uncertain)
                .accessibilityLabel("Errands")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if model.section == .run && model.runURL != nil {
                    Section {
                        Button { model.browser?.reload() } label: { Label("Reload page", systemImage: "arrow.clockwise") }
                            .disabled(!(model.browser?.ready ?? false))
                        Button { boardOpenWeb(model.pageURL) } label: { Label("Open page in Safari", systemImage: "safari") }
                    }
                }
                if model.section == .run && !model.profiles.isEmpty {
                    Picker(selection: Binding(get: { model.shownProfile ?? "" }, set: { model.pickProfile($0) })) {
                        ForEach(Array(model.profiles.enumerated()), id: \.offset) { i, p in Text(i == 0 ? "\(p) (default)" : p).tag(p) }
                    } label: {
                        Label("Run profile: \(model.shownProfile ?? "")", systemImage: "slider.horizontal.3")
                    }
                    .pickerStyle(.menu)
                }
                if model.section == .run, model.runTarget != nil, store.supports("delete") {
                    Button(role: .destructive) { deletingServed = true } label: { Label("Delete this run", systemImage: "trash") }
                        .disabled(model.deletingRun != nil)
                }
                if model.canMerge {
                    Button { Task { await model.askMerge() } } label: { Label("Squash and merge…", systemImage: "arrow.triangle.merge") }
                        .disabled(model.merging || errands.busy)
                }
                if store.supports("pull_files") {
                    Button { navigate(.pullFiles(repo: repo, number: number)) } label: { Label("Files changed", systemImage: "doc.on.doc") }
                }
                if safeWebURL(model.url) {
                    Button { boardOpenWeb(model.url) } label: { Label("Open on GitHub", systemImage: "safari") }
                    Button { Pasteboard.copy(model.url ?? "") } label: { Label("Copy link", systemImage: "link") }
                }
                if let head = model.head {
                    Button { Pasteboard.copy(head) } label: { Label("Copy branch name", systemImage: "arrow.triangle.branch") }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More")
        }
    }

    private func errandButton(_ a: BoardAction, branch: String, suggested: Bool) -> some View {
        Button(role: a.id == "delete-self-comments" ? .destructive : nil) {
            errands.ask(a, number: number, branch: branch)
        } label: {
            Label(a.label, systemImage: suggested ? "sparkles" : errandSymbol(a.id))
        }
    }

    // MARK: Top

    @ViewBuilder private var notices: some View {
        if let e = model.error { Section { ErrorNotice(message: e) }.listRowBackground(Theme.row) }
        ErrandNotice(runner: errands, place: "under Conversations")
        if let e = model.mergeError { Section { ErrorNotice(message: e) }.listRowBackground(Theme.row) }
    }

    private var stateText: String {
        if model.draft && model.isOpen { return "Draft" }
        return (model.pr["state"].string ?? (model.boardRow != nil ? "open" : "…")).asciiCapitalized
    }
    private var stateColor: Color {
        let state = model.pr["state"].string
        return state == "merged" ? Theme.accent : state == "closed" ? Theme.danger : model.draft ? .secondary : Theme.success
    }

    private var header: some View {
        let row = model.boardRow
        let checks = model.pr["checks"]
        return Section {
            VStack(alignment: .leading, spacing: 8) {
                (Text(model.title) + Text(verbatim: "  #\(number)").foregroundStyle(.secondary))
                    .font(.title3.weight(.semibold)).textSelection(.enabled)
                BoardFlowLayout(spacing: 6) {
                    BoardBadge(text: stateText, systemImage: model.pr["state"].string == "merged" ? "arrow.triangle.merge" : "arrow.triangle.pull", color: stateColor)
                    if let stack = model.stack {
                        BoardBadge(text: "Stack \(stack.label(number))", systemImage: "square.stack.3d.up.fill", color: Theme.accent)
                    }
                    if let row, row.hasConflicts {
                        BoardBadge(text: "Conflicts with \(model.base ?? "its base")", systemImage: "exclamationmark.triangle.fill", color: Theme.danger)
                    }
                    let review = ReviewStatus(decision: row?.reviewDecision, reviews: model.pr.isNull ? .array((row?.reviewers ?? []).map { ["state": .string($0.state)] }) : model.pr["reviews"])
                    if review != .none { BoardBadge(text: review.text, systemImage: reviewStyle(review).symbol, color: reviewStyle(review).color) }
                    if let add = model.pr["additions"].int, let del = model.pr["deletions"].int {
                        HStack(spacing: 4) {
                            Text("+\(add)").foregroundStyle(Theme.success)
                            Text("\u{2212}\(del)").foregroundStyle(Theme.danger)
                        }
                        .font(.caption.monospacedDigit().weight(.semibold))
                    }
                }
                sentence
                if let row, !row.labels.isEmpty { BoardLabelChips(labels: row.labels) }
            }
            .padding(.vertical, 4)
            if !model.pr.isNull {
                LabeledContent("Checks") {
                    if checks["runs"].count == 0 { Text("None reported") }
                    else { CheckCounts(checks: checks) }
                }
            }
            if let stack = model.stack { stackGroup(stack) }
            suggestedErrand
            if model.canMerge {
                Button { Task { await model.askMerge() } } label: {
                    HStack {
                        Label("Squash and merge", systemImage: "arrow.triangle.merge").fontWeight(.semibold)
                        if model.merging { Spacer(); ProgressView() }
                    }
                }
                .disabled(model.merging || errands.busy)
            }
        }
        .listRowBackground(Theme.row)
    }

    /// The errand the pull request's state asks for, above the merge as the Mac's filled button is: Run opens the
    /// ▶ Run section, any other starts as the toolbar's menu would.
    @ViewBuilder private var suggestedErrand: some View {
        let suggested = model.boardRow?.recommended
        if suggested == "run", sections.contains(.run) {
            Button { withAnimation(.snappy) { model.select(.run) } } label: { suggestedLabel("Run") }
        } else if let a = model.actions(catalog.catalog).first(where: { $0.id == suggested }), let branch = model.pr["headRef"].string {
            Button(role: a.id == "delete-self-comments" ? .destructive : nil) {
                errands.ask(a, number: number, branch: branch)
            } label: { suggestedLabel(a.label) }
            .disabled(errands.busy || errands.uncertain)
        }
    }

    private func suggestedLabel(_ text: String) -> some View {
        HStack {
            Label(text, systemImage: "sparkles").fontWeight(.semibold)
            Spacer()
            Text("Suggested").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// `author wants to merge N commits into base from head`, the branches as chips.
    private var sentence: some View {
        let merged = model.pr["state"].string == "merged"
        let commits = model.commitCount
        var verb = merged ? "merged" : "wants to merge"
        if commits > 0 { verb += " \(commits) commit\(commits == 1 ? "" : "s")" }
        return BoardFlowLayout(spacing: 4) {
            if let author = model.author { Text("@\(author)").font(.footnote.weight(.semibold)) }
            if model.head != nil || model.base != nil {
                Text(verb + " into").font(.footnote).foregroundStyle(.secondary)
                BranchChip(text: model.base ?? "main")
                if let head = model.head {
                    Text("from").font(.footnote).foregroundStyle(.secondary)
                    BranchChip(text: head)
                }
            }
            if let at = model.boardRow?.updatedAt { Text("· updated \(formatRelative(at))").font(.footnote).foregroundStyle(.secondary) }
        }
    }

    /// GitHub's stack popover as a disclosure: the stack top first, this pull request marked, the base branch at the bottom.
    private func stackGroup(_ stack: StackPosition) -> some View {
        DisclosureGroup(isExpanded: $stackOpen) {
            ForEach(stack.topFirst, id: \.self) { i in
                let item = stack.chain[i]
                let row = HStack(spacing: 8) {
                    Text("\(item.depth)").font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(.secondary).frame(minWidth: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).lineLimit(2).fontWeight(item.number == number ? .semibold : .regular)
                        Text("#\(item.number)" + (item.branch.map { " · \($0)" } ?? "") + (item.draft ? " · draft" : ""))
                            .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    if item.number == number { Spacer(); Text("This one").font(.caption).foregroundStyle(Theme.accent) }
                }
                if item.number == number { row } else {
                    DestinationLink(destination: .pull(repo: repo, number: item.number, stack: stack.json, summary: pullsFind(model.rows, item.number)?.raw)) { row }
                }
            }
            if stack.chain.isEmpty { Text("The board did not list the stack's pull requests.").font(.footnote).foregroundStyle(.secondary) }
            Label(stack.base ?? "base branch not on the board", systemImage: "arrow.triangle.branch")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            Text(stack.partial ? "Only part of this stack is on the board; it may be longer. Merge from the bottom up." : "Merge from the bottom up.")
                .font(.footnote).foregroundStyle(.secondary)
        } label: {
            Label("Stack · \(stack.label(number))", systemImage: "square.stack.3d.up")
        }
    }

    // MARK: Section picker

    private var sections: [PullSection] {
        PullSection.allCases.filter { s in
            switch s {
            case .description, .conversations: return true
            case .files: return store.supports("pull_files") || safeWebURL(model.url)
            case .reviews: return !model.pr.isNull
            case .issues: return !model.closes.isEmpty
            case .findings: return store.supports("findings")
            case .run: return model.runOffered && (model.isOpen || model.runURL != nil)
            }
        }
    }
    private func count(_ s: PullSection) -> Int? {
        switch s {
        case .files: return model.pr["changedFiles"].int
        case .reviews: return model.commentCount ?? model.pr["reviews"].count
        case .issues: return model.closes.count
        case .findings: return model.findings.count
        case .conversations: return model.runs.count
        default: return nil
        }
    }

    /// The sections as chips that scroll sideways, the chosen one filled.
    private var sectionBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(sections) { s in
                        let on = model.section == s
                        Button { withAnimation(.snappy) { model.select(s) } } label: {
                            HStack(spacing: 5) {
                                Image(systemName: s.symbol).font(.caption)
                                Text(s.title).font(.subheadline.weight(on ? .semibold : .regular))
                                if let n = count(s) { Text("\(n)").font(.caption.monospacedDigit()).foregroundStyle(on ? .white.opacity(0.85) : .secondary) }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .foregroundStyle(on ? .white : .primary)
                            .background(on ? Theme.accent : Theme.elevated, in: Capsule())
                            .overlay(Capsule().stroke(on ? Color.clear : Theme.border, lineWidth: 0.5))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .id(s)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
            }
            .onAppear { proxy.scrollTo(model.section, anchor: .center) }
            .onChange(of: model.section) { _, s in withAnimation { proxy.scrollTo(s, anchor: .center) } }
        }
    }

    // MARK: Sections

    @ViewBuilder private var description: some View {
        let body = model.pr["body"].string ?? model.descriptionBody
        let loading = body == nil && !model.bodyRead && store.supports("pull_description")
        Section {
            if let body {
                let text = visibleMarkdown(body)
                if text.isEmpty { Text("No description provided.").italic().foregroundStyle(.secondary) }
                else { MarkdownText(text).font(.callout) }
            } else if loading {
                HStack(spacing: 8) { ProgressView(); Text("Loading the description…").foregroundStyle(.secondary) }
            } else {
                Text("No description provided.").italic().foregroundStyle(.secondary)
            }
        } header: {
            if let author = model.author { Text("@\(author)") }
        }
        .listRowBackground(Theme.row)
    }

    @ViewBuilder private var files: some View {
        Section {
            if let n = model.pr["changedFiles"].int { LabeledContent("Files changed", value: "\(n)") }
            if let add = model.pr["additions"].int, let del = model.pr["deletions"].int {
                LabeledContent("Lines") {
                    HStack(spacing: 6) {
                        Text("+\(add)").foregroundStyle(Theme.success)
                        Text("\u{2212}\(del)").foregroundStyle(Theme.danger)
                    }
                    .monospacedDigit()
                }
            }
            if store.supports("pull_files") {
                DestinationLink(destination: .pullFiles(repo: repo, number: number)) {
                    Label("View the changed files", systemImage: "doc.text.magnifyingglass")
                }
            } else if let url = model.url, safeWebURL(url) {
                Button { boardOpenWeb(url + "/files") } label: { Label("Files changed on GitHub", systemImage: "arrow.up.right") }
            }
        }
        .listRowBackground(Theme.row)
    }

    @ViewBuilder private var reviews: some View {
        let row = model.boardRow
        let verdicts = model.pr["reviews"].items
        let requested = (row?.reviewers ?? []).filter { r in r.state == "requested" && !verdicts.contains { foldEqual($0["user"].string, r.user) } }
        Section("Reviewers") {
            ForEach(Array(verdicts.enumerated()), id: \.offset) { _, review in
                let st = ReviewStatus(decision: nil, reviews: .array([review]))
                LabeledContent(review["user"].string ?? "Reviewer") {
                    if st != .none { BoardBadge(text: st.text, systemImage: reviewStyle(st).symbol, color: reviewStyle(st).color) }
                    else { Text(review["state"].string ?? "") }
                }
            }
            ForEach(requested, id: \.user) { r in
                LabeledContent(r.user) { BoardBadge(text: "Review requested", systemImage: "clock", color: .secondary) }
            }
            if verdicts.isEmpty && requested.isEmpty { Text("No reviews").foregroundStyle(.secondary) }
            if let row, !row.assignees.isEmpty { LabeledContent("Assigned", value: people(row.assignees, limit: 4)) }
        }
        .listRowBackground(Theme.row)
        if store.supports(ConvFeed.comments.operation) || store.supports(ConvFeed.reviews.operation) {
            PullTimeline(model: model)
        }
    }

    @ViewBuilder private var issues: some View {
        let onBoard = model.feed.board["issues"].items
        Section {
            ForEach(Array(model.closes.enumerated()), id: \.offset) { _, link in
                if !link.isForeign(repo), let raw = onBoard.first(where: { $0["number"].truncatedInt == link.number }) {
                    DestinationLink(destination: .issue(repo: repo, issue: raw)) { BoardLinkedRow(link: link, repo: repo) }
                } else if safeWebURL(link.url) {
                    Button { boardOpenWeb(link.url) } label: { BoardLinkedRow(link: link, repo: repo) }.foregroundStyle(.primary)
                } else {
                    BoardLinkedRow(link: link, repo: repo)
                }
            }
        } footer: {
            Text("Successfully merging this pull request may close these issues.")
        }
        .listRowBackground(Theme.row)
    }

    private static let decisionIDs = ["", "fix", "optional", "dismissed"]
    private static let decisionTitles = ["Undecided", "Fix", "Optional", "Dismiss"]

    @ViewBuilder private var findings: some View {
        let list = model.findings.items
        let canDecide = store.supports("finding_decision")
        Section {
            if let e = model.findingsError { ErrorNotice(message: e) }
            ForEach(Array(list.enumerated()), id: \.offset) { i, f in
                DisclosureGroup(isExpanded: Binding(get: { openFindings.contains(i) }, set: { if $0 { openFindings.insert(i) } else { openFindings.remove(i) } })) {
                    if let file = f["file"].string {
                        Text(verbatim: f["line"].int.map { "\(file):\($0)" } ?? file).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    if let body = f["body"].string.map(visibleMarkdown), !body.isEmpty { MarkdownText(body).font(.callout) }
                    if safeWebURL(f["url"].string) {
                        Button { boardOpenWeb(f["url"].string) } label: { Label("Open finding on GitHub", systemImage: "arrow.up.right") }
                    }
                    if canDecide, let key = f["key"].string, !f["fixed"].is(true) {
                        Picker("Decision", selection: Binding(
                            get: { f["decision"].string ?? "" },
                            set: { d in Task { await model.decide(key, d.isEmpty ? nil : d) } })) {
                            ForEach(0..<Self.decisionIDs.count, id: \.self) { k in Text(Self.decisionTitles[k]).tag(Self.decisionIDs[k]) }
                        }
                        .pickerStyle(.segmented)
                        .disabled(model.deciding != nil)
                    }
                } label: {
                    findingLabel(f)
                }
            }
            if list.isEmpty && model.findingsError == nil { Text("No findings reported").foregroundStyle(.secondary) }
        } footer: {
            if canDecide && !list.isEmpty { Text("Decisions are saved on the server and mirrored to the pull request’s checklist on GitHub.") }
        }
        .listRowBackground(Theme.row)
        if let solve = model.solveFindings(catalog.catalog) {
            let fixes = findingsToFix(model.findings)
            Section {
                Button { confirmingSolve = solve } label: {
                    HStack {
                        Label(fixes > 0 ? "Solve findings · \(fixes) to fix" : "Solve findings", systemImage: "hammer").fontWeight(.semibold)
                        if errands.busy { Spacer(); ProgressView() }
                    }
                }
                .disabled(errands.busy || errands.uncertain || model.deciding != nil)
            } footer: {
                Text(fixes > 0 ? "Starts a paid session that addresses the findings marked Fix, pushes the fixes and has them reviewed again."
                     : "Starts a paid session that addresses the open findings, pushes the fixes and has them reviewed again. Mark what to fix first to narrow it down.")
            }
            .listRowBackground(Theme.row)
        }
    }

    private func findingLabel(_ f: JSON) -> some View {
        let fixed = f["fixed"].is(true)
        let decision = f["decision"].string
        return VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: f["title"].string ?? "Finding")
            HStack(spacing: 6) {
                if let severity = f["severity"].string {
                    let label = findingSeverityLabel(severity)
                    Text(label).font(.caption2.weight(.bold))
                        .foregroundStyle(label == "CRIT" || label == "HIGH" ? Theme.danger : label == "LOW" ? Color.secondary : Theme.warning)
                }
                if fixed { Text("Fixed").foregroundStyle(Theme.success) }
                else if let d = decision {
                    Text(Self.decisionIDs.firstIndex(of: d).map { Self.decisionTitles[$0] } ?? d.asciiCapitalized)
                        .foregroundStyle(d == "fix" ? Theme.warning : Color.secondary)
                }
                if let key = f["key"].string, model.deciding == key { ProgressView().controlSize(.mini) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var conversations: some View {
        Section {
            if let e = model.runError { ErrorNotice(message: e) }
            ForEach(model.runs, id: \.id) { run in
                DestinationLink(destination: .conversation(id: run.id, session: run.raw)) { BoardSessionRow(session: run) }
                    .swipeActions {
                        if store.supports("delete") {
                            Button(role: .destructive) { deleting = run } label: { Label("Delete", systemImage: "trash") }
                                .disabled(model.deletingRun != nil)
                        }
                    }
            }
            if model.runs.isEmpty { Text("No conversations on this pull request").foregroundStyle(.secondary) }
        } footer: {
            if let cost = runsCost(model.runs) {
                Text("\(formatCost(cost)) spent across \(model.runs.count) conversation\(model.runs.count == 1 ? "" : "s"), their workers included")
            }
        }
        .listRowBackground(Theme.row)
    }
}

/// A branch in small monospaced type on a tint of the accent.
private struct BranchChip: View {
    let text: String
    var body: some View {
        Text(text).font(.caption.monospaced()).foregroundStyle(Theme.accent).lineLimit(1).truncationMode(.middle)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// The checks as counts: passed, failed and pending, each with its symbol.
private struct CheckCounts: View {
    let checks: JSON
    var body: some View {
        let passed = checks["passed"].int32 ?? 0, failed = checks["failed"].int32 ?? 0, pending = checks["pending"].int32 ?? 0
        HStack(spacing: 12) {
            Label("\(passed)", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
            Label("\(failed)", systemImage: "xmark.circle.fill").foregroundStyle(Theme.danger)
            Label("\(pending)", systemImage: "clock.fill").foregroundStyle(Theme.warning)
        }
        .font(.subheadline.weight(.semibold).monospacedDigit())
        .labelStyle(CompactLabelStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(passed) passed, \(failed) failed, \(pending) pending")
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) { configuration.icon; configuration.title }
    }
}

/// GitHub's timeline of comments, reviews and the line comments they carry, oldest first.
private struct PullTimeline: View {
    @ObservedObject var model: PullScreenModel
    var body: some View {
        let comments = model.commentItems, reviews = model.reviewItems, lines = model.lineItems
        let entries = convTimeline(comments: comments, reviews: reviews, lines: lines)
        Section("Conversation") {
            if let e = model.comments.compactMap(\.error).first { ErrorNotice(message: e) }
            if !model.commentsRead {
                HStack(spacing: 8) { ProgressView(); Text("Loading the conversation…").foregroundStyle(.secondary) }
            } else {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, e in entry(e, comments, reviews, lines) }
                if entries.isEmpty { Text("No comments yet").foregroundStyle(.secondary) }
            }
        }
        .listRowBackground(Theme.row)
    }

    private func head(_ v: JSON, _ did: String, _ field: String, symbol: String? = nil, color: Color = .secondary) -> some View {
        let at = convTime(v, field)
        return HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).foregroundStyle(color) }
            Text(v["author"].string ?? "Someone").fontWeight(.semibold)
            Text(did).foregroundStyle(.secondary)
            if at != 0 { Text("· \(formatRelative(Date(timeIntervalSince1970: TimeInterval(at))))").foregroundStyle(.secondary) }
        }
        .font(.caption).lineLimit(1)
    }

    @ViewBuilder private func entry(_ e: ConvEntry, _ comments: JSON, _ reviews: JSON, _ lines: JSON) -> some View {
        switch e.feed {
        case .comments:
            let v = comments[e.index]
            VStack(alignment: .leading, spacing: 6) {
                head(v, "commented", "createdAt")
                let t = visibleMarkdown(v["body"].string ?? "")
                if t.isEmpty { Text("No description provided.").italic().foregroundStyle(.secondary) } else { MarkdownText(t).font(.callout) }
            }
            .padding(.vertical, 2)
            .contextMenu { webMenu(v["url"].string) }
        case .reviews:
            let v = reviews[e.index]
            let verdict = ReviewVerdict(v)
            let style: (String, Color) = verdict == .approved ? ("checkmark.seal.fill", Theme.success)
                : verdict == .changesRequested ? ("xmark.octagon.fill", Theme.danger)
                : verdict == .dismissed ? ("minus.circle", .secondary) : ("text.bubble", .secondary)
            let t = visibleMarkdown(v["body"].string ?? "")
            let threads = convReviewThreads(reviews: reviews, lines: lines, review: e.index)
            VStack(alignment: .leading, spacing: 8) {
                head(v, verdict?.words ?? "reviewed", "submittedAt", symbol: style.0, color: style.1)
                if !t.isEmpty { MarkdownText(t).font(.callout) }
                ForEach(threads, id: \.self) { PullThread(lines: lines, root: $0) }
            }
            .padding(.vertical, 2)
            .contextMenu { webMenu(v["url"].string) }
        case .reviewComments:
            let v = lines[e.index]
            VStack(alignment: .leading, spacing: 8) {
                head(v, "commented on a line", "createdAt")
                PullThread(lines: lines, root: e.index)
            }
            .padding(.vertical, 2)
            .contextMenu { webMenu(v["url"].string) }
        }
    }

    @ViewBuilder private func webMenu(_ url: String?) -> some View {
        if safeWebURL(url) {
            Button { boardOpenWeb(url) } label: { Label("Open on GitHub", systemImage: "safari") }
            Button { Pasteboard.copy(url ?? "") } label: { Label("Copy link", systemImage: "link") }
        }
    }
}

/// A line comment thread: the file and line, then each comment in it with its author and time.
private struct PullThread: View {
    let lines: JSON
    let root: Int
    var body: some View {
        let first = lines[root]
        let path = first["path"].string ?? ""
        let line = first["line"].int ?? first["originalLine"].int
        VStack(alignment: .leading, spacing: 8) {
            Text(line.map { "\(path):\($0)" } ?? path).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            ForEach(convThread(lines: lines, root: root), id: \.self) { i in
                let cm = lines[i]
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(cm["author"].string ?? "Someone").font(.caption.weight(.semibold))
                        let at = convTime(cm, "createdAt")
                        if at != 0 { Text(formatRelative(Date(timeIntervalSince1970: TimeInterval(at)))).font(.caption).foregroundStyle(.secondary) }
                    }
                    let t = visibleMarkdown(cm["body"].string ?? "")
                    if !t.isEmpty { MarkdownText(t).font(.callout) }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.border, lineWidth: 0.5))
    }
}
