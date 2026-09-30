import SwiftUI

struct PullsView: View {
    enum Tab: String { case pulls, issues }
    let project: Project
    @EnvironmentObject private var store: AppStore
    @State private var pulls: [PullSummary] = []
    @State private var issues: [IssueSummary] = []
    @State private var board: JSONValue = .null
    @State private var tab = Tab.pulls
    @State private var pullFilter = BoardFilter()
    @State private var issueFilter = BoardFilter()
    @State private var loaded = false
    /// The filter the board last opened on, until the server has answered once and the picks are the user's.
    @State private var opening: BoardFilter? = BoardFilter()
    @State private var error: String?
    private var filter: Binding<BoardFilter> { tab == .pulls ? $pullFilter : $issueFilter }
    private var rows: [BoardRow] { tab == .pulls ? pulls : issues }
    private var shownPulls: [PullSummary] { pulls.filter { pullFilter.passes($0) } }
    private var shownIssues: [IssueSummary] { issues.filter { issueFilter.passes($0) } }
    var body: some View {
        List {
            if let error { ErrorNotice(message: error) }
            if loaded && (!issues.isEmpty || board["issuesError"].isSet) {
                Picker("Show", selection: $tab) {
                    Text("Pull requests (\(pulls.count))").tag(Tab.pulls)
                    Text("Issues (\(issues.count))").tag(Tab.issues)
                }
                .pickerStyle(.segmented).listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            if filter.wrappedValue.isOn {
                HStack {
                    Text("Showing \(tab == .pulls ? shownPulls.count : shownIssues.count) of \(rows.count)").font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear filters") { filter.wrappedValue = BoardFilter() }.font(.footnote).buttonStyle(.borderless)
                }.listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            if tab == .pulls { pullRows } else { issueRows }
            if !loaded { ProgressView("Loading pull requests…").frame(maxWidth: .infinity).padding(.vertical, 24).listRowBackground(Color.clear) }
        }.scrollContentBackground(.hidden).background(Theme.background)
            .navigationTitle(tab == .pulls ? "Pull requests" : "Issues").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if loaded && !rows.isEmpty {
                    BoardFilterMenu(filter: filter, rows: rows, kinds: tab == .pulls ? BoardFilter.Kind.allCases : [.author, .label])
                }
            }
            .refreshable { do { try await load(fresh: true) } catch { if let said = failure(error) { self.error = said } } }
            .foregroundPoll(every: 45, action: { try await load() }) { error = $0.localizedDescription; loaded = true }
    }
    @ViewBuilder private var pullRows: some View {
        ForEach(shownPulls) { pr in
            let stack = StackPosition(pr.raw["stack"], chain: board["stacks"])
            NavigationLink { PullDetailView(project: project, number: pr.number, stack: stack, summary: pr) } label: {
                PullRow(pr: pr, stack: stack, repo: project.repo)
            }
        }.listRowBackground(Theme.row)
        if loaded && shownPulls.isEmpty && error == nil {
            ContentUnavailableView(pulls.isEmpty ? "No open pull requests" : "No pull requests match the filters", systemImage: "arrow.triangle.pull")
                .listRowBackground(Color.clear)
        }
    }
    @ViewBuilder private var issueRows: some View {
        if let refused = board["issuesError"].string {
            VStack(alignment: .leading, spacing: 6) {
                Text("GitHub would not read this repository’s issues with the server’s token. A fine-grained token needs Issues: read. The pull requests are unaffected.")
                    .font(.footnote).foregroundStyle(.secondary)
                ErrorNotice(message: refused)
            }.listRowBackground(Theme.row)
        } else {
            Section {
                ForEach(IssueSummary.nested(shownIssues, repo: project.repo), id: \.issue.number) { row in
                    NavigationLink { IssueDetailView(project: project, issue: row.issue) } label: {
                        IssueRow(issue: row.issue, repo: project.repo, nested: row.depth > 0)
                            .padding(.leading, CGFloat(min(row.depth, 4)) * 14)
                    }
                }
            } footer: {
                if board["issuesTruncated"].bool == true { Text("This repository has more open issues; only the most recently updated are listed.") }
            }.listRowBackground(Theme.row)
            if loaded && shownIssues.isEmpty && error == nil {
                ContentUnavailableView(issues.isEmpty ? "No open issues" : "No issues match the filters", systemImage: "smallcircle.filled.circle")
                    .listRowBackground(Color.clear)
            }
        }
    }
    private func show(_ result: JSONValue, saved: Bool = false) {
        board = result
        pulls = result["pulls"].array.compactMap(PullSummary.init)
        issues = result["issues"].array.compactMap(IssueSummary.init)
        // A saved board may be out of date about who has something open, so the server's first answer
        // opens the board again, unless the pickers were touched meanwhile.
        if let last = opening {
            let filter = BoardFilter(opening: result["author"].string, rows: pulls)
            if pullFilter == last { pullFilter = filter }
            opening = saved ? filter : nil
        }
        if issues.isEmpty && !result["issuesError"].isSet { tab = .pulls }
        loaded = true
    }
    /// `fresh` has the server ask GitHub again instead of answering from its own short cache.
    private func load(fresh: Bool = false) async throws {
        let key = "pulls:\(project.repo)"
        if !loaded, let saved: JSONValue = await store.cache.value(key), !loaded { show(saved, saved: true) }
        var result: JSONValue
        do { result = try await store.call("pulls", ["repo": .string(project.repo)].merging(fresh ? ["fresh": .string("1")] : [:]) { $1 }) }
        catch APIError.http(400, _, _) where fresh {
            // A server from before `fresh` refuses the argument it does not know.
            result = try await store.call("pulls", ["repo": .string(project.repo)])
        }
        try Task.checkCancellation()
        show(result); error = nil
        await store.cache.store(result, for: key)
    }
}

struct PullDetailView: View {
    let project: Project
    let number: Int
    var stack: StackPosition? = nil
    /// The board's row for this pull request, which is what carries its labels and whether it conflicts.
    var summary: PullSummary? = nil
    @EnvironmentObject private var store: AppStore
    @State private var pr: JSONValue = .null
    @State private var row: PullSummary?
    /// True once the board answered, after which a missing row means the pull request left it.
    @State private var rowRead = false
    @State private var catalog: [JSONValue] = []
    @State private var runs: [Session] = []
    @State private var findings: [JSONValue] = []
    @State private var error: String?
    @State private var findingsError: String?
    @State private var pendingAction: BoardAction?
    @State private var asking: BoardAction?
    @State private var busy = false
    @State private var uncertain = false
    @State private var writeError: String?
    @State private var started: Session?
    @State private var mergeMethod: String?
    @State private var mergeNote: String?
    @State private var mergeError: String?
    @State private var merging = false
    @State private var deciding: String?
    private var canDecide: Bool { store.supports("finding_decision") }
    private static let decisions = [(id: "fix", title: "Fix"), (id: "optional", title: "Optional"), (id: "dismissed", title: "Dismiss")]
    private var board: PullSummary? { rowRead ? row : row ?? summary }
    /// Until the pull request itself answers, being on the board says it is open.
    private var isOpen: Bool { pr == .null ? board != nil : pr["state"].string == "open" }
    private var actions: [BoardAction] {
        guard store.canManage, isOpen, pr["headRef"].string != nil else { return [] }
        return BoardAction.offered(catalog: catalog, pull: board, failedChecks: Int(pr["checks"]["failed"].double ?? 0))
            .filter { store.supports($0.operation) }
    }
    private var canMerge: Bool {
        store.supports("merge_pull") && pr["state"].string == "open" && pr["draft"].bool != true
            && pr["headSha"].string != nil && pr["baseRef"].string != nil
    }
    var body: some View {
        List {
            if let error { ErrorNotice(message: error).listRowBackground(Theme.row) }
            if let writeError {
                ErrorNotice(message: writeError)
                if uncertain { Text("The request may have completed. Pull down to refresh and look for its conversation below before starting another agent.").font(.caption) }
            }
            Section {
                Text(pr["title"].string ?? board?.title ?? "Pull request #\(number)").font(.title3.bold())
                LabeledContent("State", value: (pr["draft"].bool ?? board?.draft) == true && isOpen ? "Draft" : pr["state"].string?.capitalized ?? (board == nil ? "Loading…" : "Open"))
                if isOpen, let board {
                    LabeledContent("Merge") {
                        switch board.mergeable {
                        case "conflicting": Badge(text: "Conflicts with \(pr["baseRef"].string ?? "its base")", systemImage: "exclamationmark.triangle.fill", color: Theme.danger)
                        case "mergeable": Badge(text: "No conflicts", systemImage: "checkmark", color: Theme.success)
                        default: Badge(text: "GitHub is still checking", systemImage: "clock", color: .secondary)
                        }
                    }
                }
                if let board, !board.labels.isEmpty {
                    LabelChips(labels: board.labels).padding(.vertical, 2)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        .accessibilityElement(children: .combine)
                }
                if pr != .null {
                    LabeledContent("Review") {
                        // The board knows who was asked again since their last verdict, as its own row shows.
                        let standing = board.map { $0.reviewers.map { JSONValue.object(["state": .string($0.state)]) } } ?? pr["reviews"].array
                        if let review = ReviewStatus(decision: board?.reviewDecision, reviews: standing) { ReviewBadge(status: review) }
                        else { Text("No reviews yet") }
                    }
                }
                if let author = board?.author { LabeledContent("Author", value: "@\(author)") }
                if let board, !board.assignees.isEmpty { LabeledContent("Assigned", value: board.assignees.map { "@\($0)" }.joined(separator: ", ")) }
                LabeledContent("Branch", value: pr["headRef"].string ?? board?.branch ?? "—")
                LabeledContent("Target", value: pr["baseRef"].string ?? board?.baseBranch ?? "—")
                if let updated = board?.updatedAt { LabeledContent("Updated") { Updated(date: updated) } }
                if let additions = pr["additions"].double, let deletions = pr["deletions"].double {
                    HStack { Text("+\(Int(additions))").foregroundStyle(Theme.success); Text("−\(Int(deletions))").foregroundStyle(Theme.danger) }.font(.callout.monospaced())
                }
                let filesLabel = Label(pr["changedFiles"].double.map { "\(Int($0)) files changed" } ?? "Files changed", systemImage: "doc.on.doc")
                if store.supports("pull_files") {
                    NavigationLink { PullFilesView(project: project, number: number) } label: {
                        Label("Description and changes", systemImage: "doc.text.magnifyingglass")
                        if let count = pr["changedFiles"].double {
                            Spacer()
                            Text("\(Int(count)) files").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                if let url = safeWebURL(pr["url"].string) {
                    if !store.supports("pull_files") {
                        Link(destination: url.appendingPathComponent("files")) {
                            HStack {
                                filesLabel
                                Spacer()
                                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Link("Open on GitHub", destination: url)
                }
            }.listRowBackground(Theme.row)
            if let stack {
                Section {
                    ForEach(stack.chain, id: \.number) { item in
                        let row = HStack(spacing: 8) {
                            Text("\(item.depth)").font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(.secondary).frame(minWidth: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).lineLimit(2).fontWeight(item.number == number ? .semibold : .regular)
                                Text("#\(String(item.number))\(item.draft ? " · draft" : "")").font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            if item.number == number { Spacer(); Text("This PR").font(.caption).foregroundStyle(Theme.accent) }
                        }.padding(.leading, CGFloat(max(0, item.depth - 1)) * 10)
                        if item.number == number { row }
                        else { NavigationLink { PullDetailView(project: project, number: item.number, stack: stack) } label: { row } }
                    }
                } header: {
                    Text("Stack · \(stack.label(of: number))")
                } footer: {
                    Text(stack.partial ? "Bottom first. Only part of this stack is visible; it may be longer." : "Bottom first. Merge from the bottom up.")
                }.listRowBackground(Theme.row)
            }
            // Nothing is known of its checks, reviews or findings until the pull request answers.
            if pr != .null {
                Section("Checks") {
                    HStack(spacing: 14) {
                        Label("\(Int(pr["checks"]["passed"].double ?? 0))", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
                        Label("\(Int(pr["checks"]["failed"].double ?? 0))", systemImage: "xmark.circle.fill").foregroundStyle(Theme.danger)
                        Label("\(Int(pr["checks"]["pending"].double ?? 0))", systemImage: "clock.fill").foregroundStyle(Theme.warning)
                    }
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(Int(pr["checks"]["passed"].double ?? 0)) passed, \(Int(pr["checks"]["failed"].double ?? 0)) failed, \(Int(pr["checks"]["pending"].double ?? 0)) pending")
                    ForEach(Array(pr["checks"]["runs"].array.enumerated()), id: \.offset) { _, check in
                        let result = check["conclusion"].string ?? check["status"].string ?? "Pending"
                        let line = LabeledContent {
                            Text(result.replacingOccurrences(of: "_", with: " ").capitalized)
                        } label: {
                            Label { Text(check["name"].string ?? "Check") } icon: { checkIcon(result) }
                        }
                        if let url = safeWebURL(check["url"].string) { Link(destination: url) { line }.foregroundStyle(.primary) }
                        else { line }
                    }
                }.listRowBackground(Theme.row)
                Section("Reviews") {
                    ForEach(Array(pr["reviews"].array.enumerated()), id: \.offset) { _, review in
                        LabeledContent(review["user"].string ?? "Reviewer") {
                            if let status = ReviewStatus(decision: nil, reviews: [review]) { ReviewBadge(status: status) }
                            else { Text(review["state"].string ?? "") }
                        }
                    }
                    let reviewed = Set(pr["reviews"].array.compactMap { $0["user"].string?.lowercased() })
                    let requested = (board?.reviewers ?? []).filter { $0.state == "requested" && !reviewed.contains($0.user.lowercased()) }
                    ForEach(requested, id: \.self) { reviewer in
                        LabeledContent(reviewer.user) { ReviewBadge(status: .requested) }
                    }
                    if pr["reviews"].array.isEmpty && requested.isEmpty {
                        Text("No reviews reported").foregroundStyle(.secondary)
                    }
                }.listRowBackground(Theme.row)
                let issues = (board?.issues ?? []).isEmpty ? pr["issues"].array.compactMap(BoardLink.init) : board?.issues ?? []
                if !issues.isEmpty {
                    Section("Closes") {
                        ForEach(issues, id: \.self) { issue in
                            if let url = safeWebURL(issue.url) { Link(destination: url) { LinkedRow(link: issue, repo: project.repo) }.foregroundStyle(.primary) }
                            else { LinkedRow(link: issue, repo: project.repo) }
                        }
                    }.listRowBackground(Theme.row)
                }
                if !pr["commitList"].array.isEmpty {
                    Section {
                        let commits = Int(pr["commits"].double ?? Double(pr["commitList"].array.count))
                        DisclosureGroup("\(commits) commit\(commits == 1 ? "" : "s")") {
                            ForEach(Array(pr["commitList"].array.enumerated()), id: \.offset) { _, commit in
                                let line = HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(String((commit["sha"].string ?? "").prefix(7))).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    Text(commit["message"].string ?? "").font(.callout).lineLimit(2)
                                }
                                if let url = safeWebURL(commit["url"].string) { Link(destination: url) { line }.foregroundStyle(.primary) }
                                else { line }
                            }
                        }
                    }.listRowBackground(Theme.row)
                }
                if store.supports("findings") {
                    Section {
                        if let findingsError { ErrorNotice(message: findingsError) }
                        ForEach(Array(findings.enumerated()), id: \.offset) { _, finding in
                            DisclosureGroup {
                                if let file = finding["file"].string {
                                    Text(verbatim: finding["line"].double.map { "\(file):\(Int($0))" } ?? file).font(.caption.monospaced()).textSelection(.enabled)
                                }
                                if let url = safeWebURL(finding["url"].string) { Link("Open finding on GitHub", destination: url) }
                                if canDecide, let key = finding["key"].string, finding["fixed"].bool != true {
                                    Picker("Decision", selection: Binding(
                                        get: { finding["decision"].string ?? "" },
                                        set: { decision in Task { await decide(key, decision.isEmpty ? nil : decision) } })) {
                                        Text("Undecided").tag("")
                                        ForEach(Self.decisions, id: \.id) { Text($0.title).tag($0.id) }
                                    }
                                    .pickerStyle(.segmented)
                                    .disabled(deciding != nil)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(verbatim: finding["title"].string ?? "Finding")
                                    HStack(spacing: 6) {
                                        if let severity = finding["severity"].string { Text(severity) }
                                        if finding["fixed"].bool == true { Text("Fixed").foregroundStyle(Theme.success) }
                                        else if let decision = finding["decision"].string {
                                            Text(Self.decisions.first { $0.id == decision }?.title ?? decision.capitalized)
                                                .foregroundStyle(decision == "fix" ? Theme.warning : Color.secondary)
                                        }
                                        if deciding == finding["key"].string { ProgressView().controlSize(.mini) }
                                    }
                                    .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if findings.isEmpty && findingsError == nil { Text("No findings reported").foregroundStyle(.secondary) }
                    } header: {
                        Text("Findings")
                    } footer: {
                        if canDecide && !findings.isEmpty { Text("Decisions are saved on the dashboard and mirrored to the pull request’s checklist on GitHub.") }
                    }.listRowBackground(Theme.row)
                }
            } else if error == nil {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 12).listRowBackground(Color.clear)
            }
            if canMerge || mergeError != nil {
                Section {
                    if let mergeError { ErrorNotice(message: mergeError) }
                    if canMerge {
                        Button { Task { await prepareMerge() } } label: {
                            HStack {
                                Label("Merge pull request", systemImage: "arrow.triangle.merge").fontWeight(.semibold)
                                if merging { Spacer(); ProgressView() }
                            }
                        }.disabled(merging || busy)
                    }
                } footer: {
                    if canMerge { Text("Merges \(pr["headRef"].string ?? "this branch") into \(pr["baseRef"].string ?? "its base") on GitHub. This cannot be undone from the app.") }
                }.listRowBackground(Theme.row)
            }
            if !actions.isEmpty {
                Section {
                    ForEach(actions) { action in
                        let suggested = board?.recommended == action.id
                        Button { if action.input != nil { asking = action } else { pendingAction = action } } label: {
                            HStack {
                                Label(action.label, systemImage: Self.actionIcons[action.id] ?? "bolt")
                                    .fontWeight(suggested ? .semibold : .regular)
                                Spacer()
                                if suggested { Badge(text: "Suggested", systemImage: "sparkle", color: Theme.accent) }
                            }
                        }
                        .tint(action.id == "delete-self-comments" ? Theme.danger : Theme.accent)
                        .accessibilityHint(action.hint)
                    }
                } header: {
                    HStack { Text("Actions"); if busy { ProgressView().controlSize(.mini) } }
                } footer: { Text("Uses the provider and model configured for this project. These actions run paid agents and may write to GitHub.") }
                    .disabled(busy || uncertain).listRowBackground(Theme.row)
            }
            if !runs.isEmpty {
                Section("Conversations on this pull request") {
                    ForEach(runs) { session in
                        NavigationLink { ConversationView(initial: session) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                StatusDot(status: session.status).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(session.displayTitle).lineLimit(2)
                                        .foregroundStyle(session.status == "closed" ? .secondary : .primary)
                                    Text([session.status.capitalized, session.model].compactMap { $0.flatMap { $0.isEmpty ? nil : $0 } }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }.listRowBackground(Theme.row)
            }
        }
        .scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle("#\(String(number))").navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $started) { ConversationView(initial: $0) }
        .refreshable {
            // Pulling down is how an uncertain start is checked: its conversation is listed below if it began.
            do { try await load(); uncertain = false; writeError = nil } catch { if let said = failure(error) { self.error = said } }
        }
        .foregroundPoll(every: 30, enabled: !busy && !merging && deciding == nil && pendingAction == nil && asking == nil && mergeMethod == nil, action: load) { error = $0.localizedDescription }
        .confirmationDialog("Start a paid \(pendingAction?.label ?? "") session on #\(String(number))?",
                            isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
                            titleVisibility: .visible, presenting: pendingAction) { action in
            Button("Start session", role: action.id == "delete-self-comments" ? .destructive : nil) { Task { await start(action) } }
        } message: { action in if !action.hint.isEmpty { Text("\(action.hint).") } }
        .sheet(item: $asking) { action in
            ActionInputView(action: action, number: number) { input in Task { await start(action, input: input) } }
                .sheetSize(height: 360)
        }
        .confirmationDialog("Are you sure you want to merge #\(String(number)) into \(pr["baseRef"].string ?? "its base")?",
                            isPresented: Binding(get: { mergeMethod != nil }, set: { if !$0 { mergeMethod = nil } }),
                            titleVisibility: .visible, presenting: mergeMethod) { method in
            Button(MergeState.title(method)) { Task { await merge(method) } }
        } message: { _ in if let mergeNote { Text(mergeNote) } }
    }
    private static let actionIcons = [
        "run": "play", "review": "text.magnifyingglass", "solve-conflicts": "arrow.triangle.merge", "fix-checks": "wrench.and.screwdriver",
        "implement-feedback": "hammer", "custom-feedback": "square.and.pencil", "test-sheet": "checklist", "qa": "video",
        "test-run": "play.rectangle", "pr-body-summary": "doc.text", "delete-self-comments": "trash",
    ]
    /// Reads what GitHub allows before asking, so the dialog can say what stands in the way of the squash.
    private func prepareMerge() async {
        guard !merging else { return }
        merging = true; mergeError = nil; defer { merging = false }
        var allowed: [String] = []
        var notes: [String] = []
        if store.supports("pull_files"),
           let page: PullFilesPage = try? await store.call("pull_files", ["repo": .string(project.repo), "pr": .number(Double(number))]) {
            allowed = page.pr["mergeMethods"].array.compactMap(\.string)
            notes += MergeState.warnings(mergeable: page.pr["mergeable"], state: page.pr["mergeableState"].string)
            if let head = page.pr["headSha"].string, head != pr["headSha"].string {
                do { try await load() } catch { mergeError = error.localizedDescription; return }
                notes.append("New commits were pushed; the checks below were refreshed.")
            }
        }
        let failed = Int(pr["checks"]["failed"].double ?? 0), pending = Int(pr["checks"]["pending"].double ?? 0)
        if failed > 0 { notes.append("\(failed) check\(failed == 1 ? " is" : "s are") failing.") }
        if pending > 0 { notes.append("\(pending) check\(pending == 1 ? " is" : "s are") still running.") }
        mergeNote = notes.isEmpty ? nil : notes.joined(separator: " ")
        mergeMethod = MergeState.method(allowed: allowed)
    }
    private func merge(_ method: String) async {
        guard !merging, let head = pr["headSha"].string, let base = pr["baseRef"].string else { return }
        merging = true; mergeError = nil; defer { merging = false }
        do {
            let _: JSONValue = try await store.call("merge_pull", ["repo": .string(project.repo), "pr": .number(Double(number)),
                                                                     "headSha": .string(head), "baseRef": .string(base), "method": .string(method)])
        } catch {
            // A 4xx is a definite refusal; anything else may have merged, which the reload below shows.
            if case .http(400..<500, _, _)? = error as? APIError { mergeError = error.localizedDescription }
            else { mergeError = "\(error.localizedDescription) The merge may still have completed; check the state above before trying again." }
        }
        do { try await load() } catch { self.error = error.localizedDescription }
    }
    private func checkIcon(_ result: String) -> some View {
        switch result.lowercased() {
        case "success", "passed", "neutral", "skipped": return Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
        case "failure", "failed", "timed_out", "action_required", "error": return Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.danger)
        // Neither passed nor failed, as the counts above have it.
        case "cancelled", "stale": return Image(systemName: "minus.circle.fill").foregroundStyle(Color.secondary)
        default: return Image(systemName: "clock.fill").foregroundStyle(Theme.warning)
        }
    }
    private func load() async throws {
        let args: [String: JSONValue] = ["repo": .string(project.repo), "pr": .number(Double(number))]
        let key = "pull:\(project.repo)#\(String(number))"
        if pr == .null, let saved: JSONValue = await store.cache.value(key), pr == .null {
            pr = saved["pr"]; findings = saved["findings"].array
            if row == nil { row = PullSummary(saved["row"]) }
            if let saved: JSONValue = await store.cache.value("actions"), catalog.isEmpty { catalog = saved["actions"].array }
        }
        defer {
            if pr != .null {
                let saved = JSONValue.object(["pr": pr, "findings": .array(findings), "row": board?.raw ?? .null])
                Task { await store.cache.store(saved, for: key) }
            }
        }
        async let around: Void = loadAround()
        let result: JSONValue = try await store.call("pull", args)
        await around
        try Task.checkCancellation()
        pr = result["pr"]; error = nil
        if store.supports("findings") {
            do {
                let result: JSONValue = try await store.call("findings", args)
                try Task.checkCancellation()
                findings = result["findings"].array; findingsError = nil
            } catch {
                if Task.isCancelled { throw error }
                findingsError = error.localizedDescription
            }
        }
    }
    /// What the board knows about this pull request beyond its own details: its row (labels, conflicts,
    /// the errand it asks for), the errands the server offers and the conversations already run on it.
    /// Each is an addition to the screen, so one that cannot be read leaves what was there.
    private func loadAround() async {
        let repo: [String: JSONValue] = ["repo": .string(project.repo)]
        async let rows: JSONValue? = read("pulls", repo)
        async let listed: JSONValue? = read(store.canManage ? "actions" : "", [:])
        async let sessions: SessionList? = read("sessions", repo)
        let (pulls, served, all) = await (rows, listed, sessions)
        guard !Task.isCancelled else { return }
        // A pull request the board no longer lists has been merged or closed, and its row went with it.
        if let pulls { row = pulls["pulls"].array.compactMap(PullSummary.init).first { $0.number == number }; rowRead = true }
        if let served {
            catalog = served["actions"].array
            await store.cache.store(served, for: "actions")
        }
        if let all { runs = all.sessions.filter { $0.pullNumber == number } }
    }
    private func read<T: Decodable>(_ name: String, _ args: [String: JSONValue]) async -> T? {
        store.supports(name) ? try? await store.call(name, args) : nil
    }
    /// Records a verdict on one finding (nil clears it) and shows the list the server returns.
    private func decide(_ key: String, _ decision: String?) async {
        guard deciding == nil else { return }
        deciding = key; defer { deciding = nil }
        do {
            let result: JSONValue = try await store.call("finding_decision", ["repo": .string(project.repo), "pr": .number(Double(number)),
                                                                                "key": .string(key), "decision": decision.map(JSONValue.string) ?? .null])
            findings = result["findings"].array; findingsError = nil
        } catch { findingsError = error.localizedDescription }
    }
    private func start(_ action: BoardAction, input: String? = nil) async {
        guard !busy, !uncertain, let branch = pr["headRef"].string else { return }
        busy = true; defer { busy = false }
        do {
            let result: SessionResult = try await store.call(action.operation, action.arguments(repo: project.repo, number: number, branch: branch, input: input),
                                                             timeout: action.timeout)
            started = result.session; writeError = nil
        } catch {
            writeError = error.localizedDescription
            // A refusal is definite; anything else may have started the session.
            if case .http(400..<500, _, _)? = error as? APIError {} else { uncertain = true }
        }
    }
}

/// The overall verdict a pull request carries, read from GitHub's review decision
/// and, since that is null on repos without required reviews, the reviewers themselves.
enum ReviewStatus: Equatable {
    case approved, changesRequested, feedback, requested
    init?(decision: String?, reviews: [JSONValue]) {
        let states = Set(reviews.compactMap { $0["state"].string?.lowercased() })
        switch decision?.lowercased() {
        case "approved": self = .approved
        case "changes_requested": self = .changesRequested
        default:
            if states.contains("changes_requested") { self = .changesRequested }
            else if states.contains("approved") { self = .approved }
            else if states.contains("commented") { self = .feedback }
            else if decision?.lowercased() == "review_required" || states.contains("requested") { self = .requested }
            else { return nil }
        }
    }
    var text: String {
        switch self {
        case .approved: return "Approved"
        case .changesRequested: return "Changes requested"
        case .feedback: return "Feedback given"
        case .requested: return "Review requested"
        }
    }
    var systemImage: String {
        switch self {
        case .approved: return "checkmark.seal.fill"
        case .changesRequested: return "xmark.octagon.fill"
        case .feedback: return "text.bubble.fill"
        case .requested: return "clock"
        }
    }
    var color: Color {
        switch self {
        case .approved: return Theme.success
        case .changesRequested: return Theme.danger
        case .feedback: return Theme.warning
        case .requested: return .secondary
        }
    }
}

/// Where a pull request sits in a stack of branches built on each other, 1 being the bottom.
struct StackPosition: Hashable {
    struct Item: Hashable { let number: Int; let title: String; let depth: Int; let draft: Bool }
    let position: Int
    let total: Int
    let partial: Bool
    let chain: [Item]
    var label: String { label(of: nil) }
    /// A stack opened from one of its pull requests is walked to the others, each at its own depth.
    func label(of number: Int?) -> String {
        "\(chain.first { $0.number == number }?.depth ?? position)/\(total)\(partial ? "+" : "")"
    }
    init?(_ value: JSONValue, chain stacks: JSONValue) {
        guard let position = value["position"].double, let total = value["total"].double else { return nil }
        self.position = Int(position); self.total = Int(total); partial = value["partial"].bool == true
        let id = value["id"].double.map { String(Int($0)) } ?? value["id"].string ?? ""
        chain = stacks[id].array.compactMap { item in
            guard let number = item["number"].double else { return nil }
            return Item(number: Int(number), title: item["title"].string ?? "Pull request #\(Int(number))",
                        depth: Int(item["depth"].double ?? 1), draft: item["draft"].bool == true)
        }
    }
}

struct Badge: View {
    let text: String
    let systemImage: String
    let color: Color
    @ScaledMetric(relativeTo: .caption2) private var iconSize: CGFloat = 9
    var body: some View {
        // A Label sizes and spaces its icon for a list row, which is too loose inside a capsule.
        HStack(spacing: 3) {
            Image(systemName: systemImage).font(.system(size: iconSize, weight: .semibold))
            Text(text).font(.caption2.weight(.semibold)).monospacedDigit()
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

struct ReviewBadge: View {
    let status: ReviewStatus
    var body: some View { Badge(text: status.text, systemImage: status.systemImage, color: status.color) }
}

struct StackBadge: View {
    let stack: StackPosition
    var body: some View {
        Badge(text: "Stack \(stack.label)", systemImage: "square.stack.3d.up.fill", color: Theme.accent)
            .accessibilityLabel("Stacked pull request \(stack.position) of \(stack.total)\(stack.partial ? " or more" : "")")
    }
}

func safeWebURL(_ value: String?) -> URL? {
    guard let value, let url = URL(string: value), url.scheme == "https", url.host != nil,
          url.user == nil, url.password == nil else { return nil }
    return url
}
