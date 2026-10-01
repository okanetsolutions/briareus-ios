// The project board (screen_pulls.c pulls_screen_*): open pull requests and issues as tabs, with the project's SSH and SFTP
// sessions beside them for a token that may read the servers. Each pull request row carries the errands its state offers,
// the suggested one filled; author, reviewer and label pickers narrow the lists, and are kept per repository.
import SwiftUI

enum BoardTab: Int { case pulls, issues, ssh, sftp }

@MainActor
final class BoardModel: ObservableObject {
    let repo: String
    @Published var board: JSON = .null
    @Published var pulls: [PullSummary] = []
    /// The issue rows with what the server sent for each, which is what the issue screen opens with.
    @Published var issues: [(summary: IssueSummary, raw: JSON)] = []
    @Published var tab = BoardTab.pulls
    @Published var runs: [Session] = []
    @Published var syncedAt: Date?
    @Published var pullFilter = BoardFilter()
    @Published var issueFilter = BoardFilter()
    @Published var loaded = false
    @Published var error: String?
    @Published var catalog: JSON = []
    @Published var busy = false
    @Published var uncertain = false
    @Published var startingNumber = 0
    @Published var startingID: String?
    @Published var writeError: String?
    @Published private(set) var reading = false
    var dialogOpen = false
    private var hasOpening = false
    private var opening = BoardFilter()
    private var readGen = 0
    private var readingActions = false, readingRuns = false

    init(repo: String) {
        self.repo = repo
        hasOpening = !filtersRestore()
    }

    var title: String { ProjectsModel.shared.project(repo)?.title ?? repo }
    var filter: BoardFilter {
        get { tab == .pulls ? pullFilter : issueFilter }
        set { if tab == .pulls { pullFilter = newValue } else { issueFilter = newValue } }
    }
    var rows: [BoardRow] { tab == .pulls ? pulls.map(BoardRow.init) : issues.map { BoardRow($0.summary) } }

    // MARK: Filters, kept on disk per repository

    private func filterJSON(_ f: BoardFilter) -> JSON {
        var j: JSON = [:]
        for k in FilterKind.allCases where !f[k].isEmpty { j[k.name] = .string(f[k]) }
        return j
    }
    private func filterRead(_ f: inout BoardFilter, _ j: JSON) {
        for k in FilterKind.allCases { if let v = j[k.name].string { f.set(k, v) } }
    }
    func filtersSave() {
        Store.shared.cache.store(["pulls": filterJSON(pullFilter), "issues": filterJSON(issueFilter)], "pulls-filters:\(repo)")
    }
    /// A board never filtered opens on the project's author; one with saved picks opens on them.
    private func filtersRestore() -> Bool {
        guard let saved = Store.shared.cache.value("pulls-filters:\(repo)") else { return false }
        filterRead(&pullFilter, saved["pulls"]); filterRead(&issueFilter, saved["issues"])
        return true
    }

    // MARK: Reading

    private func show(_ result: JSON, saved: Bool) {
        board = result
        pulls = PullSummary.parseList(result["pulls"])
        issues = result["issues"].items.compactMap { j in IssueSummary(j).map { ($0, j) } }
        // A saved board may be out of date about who has something open, so the server's first answer opens the board
        // again, unless the pickers were touched meanwhile.
        if hasOpening {
            let f = BoardFilter.opening(author: result["author"].string, rows: pulls.map(BoardRow.init))
            if pullFilter == opening { pullFilter = f }
            if saved { opening = f } else { hasOpening = false; opening = BoardFilter() }
        }
        if tab == .issues && issues.isEmpty && !result["issuesError"].isSet { tab = .pulls }
        loaded = true
    }

    /// Reads the board (`fresh` asks GitHub rather than the server's copy), the errands and the project's conversations.
    @discardableResult
    func load(fresh: Bool = false) async -> APIError? {
        if !loaded {
            if let saved = Store.shared.cache.value("pulls:\(repo)") { show(saved, saved: true) }
            if catalog.count == 0, let acts = Store.shared.cache.value("actions") { catalog = acts["actions"] }
        }
        if Store.shared.canManage && Store.shared.supports("actions") && !readingActions {
            readingActions = true
            Task {
                let r = await boardCall("actions")
                readingActions = false
                if let v = r.value { catalog = v["actions"]; Store.shared.cache.store(v, "actions") }
            }
        }
        if Store.shared.supports("sessions") && !readingRuns { Task { await loadRuns() } }
        readGen += 1
        let gen = readGen
        reading = true
        var args: JSON = ["repo": .string(repo)]
        if fresh { args["fresh"] = "1" }
        let r = await boardCall("pulls", args)
        guard gen == readGen else { return nil }
        reading = false
        switch r {
        case .success(let v):
            show(v, saved: false)
            error = nil
            syncedAt = Date()
            Store.shared.cache.store(v, "pulls:\(repo)")
            return nil
        case .failure(let e):
            if e.kind == .cancelled { return e }
            // A server from before `fresh` refuses the argument it does not know.
            if fresh && e.kind == .http && e.status == 400 { return await load(fresh: false) }
            error = e.description
            loaded = true
            return e
        }
    }
    func loadRuns() async {
        readingRuns = true
        let r = await boardCall("sessions", ["repo": .string(repo)])
        readingRuns = false
        if let v = r.value, let list = Session.parseList(v) { runs = list }
    }
    /// Refreshing is how an uncertain start is checked: its conversation is listed in the project if it began.
    func refresh() {
        switch tab {
        case .ssh: RemoteSessions.sshRefresh(repo)
        case .sftp: RemoteSessions.sftpRefresh(repo)
        default:
            uncertain = false; writeError = nil
            Task { await load(fresh: true) }
        }
    }

    func runsOn(_ number: Int) -> Int { runs.filter { $0.pullNumber == number }.count }
    func runActiveOn(_ number: Int) -> Bool { runs.contains { $0.pullNumber == number && $0.isActive } }
    func stack(of pull: PullSummary) -> StackPosition? { StackPosition(pull.raw["stack"], stacks: board["stacks"]) }

    // MARK: Errands

    func start(_ pull: PullSummary, _ action: BoardAction, input: String?) {
        guard !busy, !uncertain, !pull.branch.isEmpty else { return }
        busy = true; startingNumber = pull.number; startingID = action.id
        let args = action.arguments(repo: repo, number: pull.number, branch: pull.branch, input: input)
        Task {
            let r = await boardCall(action.operation, args, timeout: action.timeoutMs.map { TimeInterval($0) / 1000 })
            busy = false
            switch r {
            case .success:
                writeError = nil
                // The list stays shown; the new session joins the runs counted on its pull request.
                post(.sessionsChanged, ["repo": repo])
                if Store.shared.supports("sessions") { await loadRuns() }
            case .failure(let e):
                writeError = e.description
                // A refusal is definite; anything else may have started the session.
                if !e.isRefusal { uncertain = true }
            }
        }
    }
    func act(_ pull: PullSummary, _ action: BoardAction) {
        guard !busy, !uncertain else { return }
        if action.id == "run" { openRun(pull); return }
        dialogOpen = true
        let answer = actionPrompt(action, number: pull.number)
        dialogOpen = false
        if let input = answer { start(pull, action, input: input) }
    }

    // MARK: Opening

    func openPull(_ pull: PullSummary) {
        Navigator.shared.push(.pull(repo: repo, number: pull.number, stack: stack(of: pull)?.json, summary: pull.raw))
    }
    /// "N runs ›" opens the pull request, its stack left to be read there.
    func openRuns(_ pull: PullSummary) {
        Navigator.shared.push(.pull(repo: repo, number: pull.number, stack: nil, summary: pull.raw))
    }
    /// ▶ Run opens the pull request on its Run tab.
    func openRun(_ pull: PullSummary) {
        let screen = Screen.pull(repo: repo, number: pull.number, stack: stack(of: pull)?.json, summary: pull.raw)
        let model = PullModel(repo: repo, number: pull.number, stack: stack(of: pull), summary: pull)
        model.runOpen()
        BoardModels.adopt(screen.id, model)
        Navigator.shared.push(screen)
    }
    func openIssue(_ raw: JSON) { Navigator.shared.push(.issue(repo: repo, issue: raw)) }

    // MARK: Pickers

    /// One picker's menu: `All <kind>s`, then each option with how many rows it would show.
    func pick(_ kind: FilterKind) {
        var f = filter
        let options = f.options(kind, rows: rows)
        let current = f[kind]
        var items = [PopupMenu.Item(title: "All \(kind.name)s", checked: current.isEmpty)]
        for o in options { items.append(PopupMenu.Item(title: "\(o.text) (\(o.count))", checked: current == o.value)) }
        guard let chosen = PopupMenu.show(items, rightAligned: true) else { return }
        f.set(kind, chosen == 0 ? "" : options[chosen - 1].value)
        filter = f
        hasOpening = false
        filtersSave()
    }
    func clearFilters() {
        filter = BoardFilter()
        hasOpening = false
        filtersSave()
    }
}

struct BoardScreen: View {
    var repo: String
    @ObservedObject private var model: BoardModel
    @ObservedObject private var store = Store.shared
    @State private var remoteRevision = 0

    init(repo: String) {
        self.repo = repo
        model = BoardModels.model("pulls:\(repo)") { BoardModel(repo: repo) }
    }

    /// SSH and SFTP sessions only for a token that may read the servers (project_ssh_offered).
    private var remoteOffered: Bool { store.supports("settings_ssh_servers") }

    var body: some View {
        VStack(spacing: 0) {
            header
            switch model.tab {
            case .ssh, .sftp:
                VStack(alignment: .leading, spacing: 0) {
                    tabs.padding(.horizontal, Theme.paneMargin)
                    Spacer().frame(height: 14)
                    Group {
                        if model.tab == .ssh { ProjectSSHTab(repo: repo) } else { ProjectSFTPTab(repo: repo) }
                    }
                    .padding(.horizontal, Theme.paneMargin)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            default:
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        tabs
                        Spacer().frame(height: 14)
                        lists
                        Spacer().frame(height: 16)
                    }
                    .padding(.horizontal, Theme.paneMargin)
                }
            }
        }
        .task {
            await poll(every: 45) {
                if model.dialogOpen { return nil }
                return await model.load()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshScreen)) { _ in model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .remoteSessionsChanged)) { _ in remoteRevision += 1 }
        .onReceive(NotificationCenter.default.publisher(for: .sessionForgotten)) { note in
            if let id = note.userInfo?["id"] as? String { model.runs.removeAll { $0.id == id } }
        }
        .onDisappear { BoardModels.release("pulls:\(repo)") }
    }

    // MARK: Header

    private var header: some View {
        var sub = repo
        if model.loaded { sub += " · \(model.pulls.count) open pull request\(model.pulls.count == 1 ? "" : "s")" }
        if let at = model.syncedAt { sub += " · synced \(formatRelative(at))" }
        var status: String?
        var buttons: [HeaderButton] = []
        let refresh = HeaderButton(glyph: Glyph.symbol(0xE72C), tip: "Read the pull requests from GitHub again", enabled: !model.reading) { model.refresh() }
        switch model.tab {
        case .ssh, .sftp:
            _ = remoteRevision
            let h = model.tab == .ssh ? RemoteSessions.sshHeader(repo) : RemoteSessions.sftpHeader(repo)
            if let s = h?.subtitle { sub = s }
            status = h?.status
            buttons = h?.buttons ?? []
            buttons.append(HeaderButton(glyph: Glyph.symbol(0xE72C),
                                        tip: model.tab == .ssh ? "Read the project's SSH servers again" : "Read the servers and the folder on show again") { model.refresh() })
        default:
            // The pickers, as the dashboard's selects, and ⟳.
            let f = model.filter
            buttons.append(HeaderButton(glyph: "line.3.horizontal.decrease", label: "\(f.author.isEmpty ? "All authors" : f.author) ▾",
                                        tip: "Filter by author", enabled: model.loaded) { model.pick(.author) })
            if model.tab == .pulls {
                buttons.append(HeaderButton(glyph: "person.crop.circle.badge.checkmark", label: "\(f.reviewer.isEmpty ? "All reviewers" : f.reviewer) ▾",
                                            tip: "Filter by reviewer", enabled: model.loaded) { model.pick(.reviewer) })
            }
            buttons.append(HeaderButton(glyph: "tag", label: "\(f.label.isEmpty ? "All labels" : f.label) ▾",
                                        tip: "Filter by label", enabled: model.loaded) { model.pick(.label) })
            buttons.append(refresh)
        }
        return PaneHeader(title: model.title, subtitle: sub, status: status, buttons: buttons)
    }

    // MARK: Tabs

    /// `#proj-tabs`: 13px, `px-2 py-2`, the open one underlined in the accent.
    private var tabs: some View {
        _ = remoteRevision
        let open = RemoteSessions.sshCount(repo), files = RemoteSessions.sftpCount(repo)
        var labels: [(BoardTab, String)] = [(.pulls, "⇅ Pull requests"), (.issues, "⊙ Issues")]
        if remoteOffered {
            labels.append((.ssh, open > 0 ? "❯ SSH sessions \(open)" : "❯ SSH sessions"))
            labels.append((.sftp, files > 0 ? "⇵ SFTP sessions \(files)" : "⇵ SFTP sessions"))
        }
        return VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(labels, id: \.0) { tab, label in BoardTabButton(label: label, active: model.tab == tab) { select(tab) } }
                Spacer(minLength: 0)
            }
            Rule().padding(.horizontal, -Theme.paneMargin)
        }
    }
    private func select(_ tab: BoardTab) {
        model.tab = tab == .issues || ((tab == .ssh || tab == .sftp) && remoteOffered) ? tab : .pulls
    }

    // MARK: Lists

    @ViewBuilder private var lists: some View {
        if let e = model.error { Notice(message: e); Spacer().frame(height: 10) }
        if let e = model.writeError {
            Notice(message: e)
            if model.uncertain {
                Text("The request may have completed. Refresh (F5) and look for its conversation in the project before starting another agent.")
                    .font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
            Spacer().frame(height: 10)
        }
        let filter = model.filter
        let rows = model.rows
        let shown = rows.filter { filter.passes($0) }.count
        if filter.isOn {
            HStack {
                Text("Showing \(shown) of \(rows.count)").font(Theme.caption).foregroundStyle(Theme.muted)
                Spacer(minLength: 8)
                Button("Clear filters") { model.clearFilters() }.buttonStyle(.plain).font(Theme.caption).foregroundStyle(Theme.accent).handCursor()
            }
            .frame(height: 20).padding(.bottom, 8)
        }
        if model.tab == .pulls { pullList(filter: filter, shown: shown) } else { issueList(filter: filter, shown: shown) }
        if !model.loaded { LoadingNote(text: "Loading pull requests…").padding(.horizontal, -8) }
    }

    @ViewBuilder private func pullList(filter: BoardFilter, shown: Int) -> some View {
        ForEach(Array(model.pulls.enumerated()), id: \.element.number) { _, pull in
            if filter.passes(BoardRow(pull)) {
                PullRow(pull: pull, stack: model.stack(of: pull), repo: repo, running: model.runActiveOn(pull.number), action: { model.openPull(pull) }) {
                    rowButtons(pull)
                }
                .padding(.bottom, 8)
            }
        }
        if model.loaded && shown == 0 && model.error == nil {
            Text(model.pulls.isEmpty ? "No open pull requests." : "No pull requests match the filters.").font(Theme.footnote).foregroundStyle(Theme.muted)
        }
    }

    /// The dashboard's buttons: the errands its state offers, the suggested one filled. Clicking the row opens the PR.
    @ViewBuilder private func rowButtons(_ pull: PullSummary) -> some View {
        let actions = pull.branch.isEmpty ? [] : rowActions(catalog: model.catalog, pull: pull, failedChecks: 0)
        let runs = model.runsOn(pull.number)
        if !actions.isEmpty || runs > 0 {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(actions, id: \.id) { a in
                    let starting = model.busy && model.startingNumber == pull.number && model.startingID == a.id
                    Button(starting ? "Starting…" : "\(actionIcon(a.id)) \(a.label)") { model.act(pull, a) }
                        .dashButton(pull.recommended == a.id ? .prominent : .bordered)
                        .disabled(model.busy || model.uncertain)
                        .help(a.hint)
                }
                if runs > 0 {
                    Button("\(runs) run\(runs == 1 ? "" : "s") ›") { model.openRuns(pull) }.dashButton(.plain)
                }
            }
            .padding(.top, 8)
        }
    }

    @ViewBuilder private func issueList(filter: BoardFilter, shown: Int) -> some View {
        if let refused = model.board["issuesError"].string {
            BoardBox(padding: 12, radius: 10) {
                Text("GitHub would not read this repository’s issues with the server’s token. A fine-grained token needs Issues: read. The pull requests are unaffected.")
                    .font(Theme.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                Notice(message: refused).padding(.top, 6)
            }
        } else {
            let visible = model.issues.indices.filter { filter.passes(BoardRow(model.issues[$0].summary)) }
            let nested = issuesNested(visible.map { model.issues[$0].summary }, repo: repo)
            ForEach(Array(nested.enumerated()), id: \.offset) { _, row in
                let i = visible[row.index]
                let depth = min(row.depth, 4)
                IssueRowView(issue: model.issues[i].summary, repo: repo, nested: depth > 0) { model.openIssue(model.issues[i].raw) }
                    .padding(.leading, CGFloat(depth) * 18)
                    .padding(.bottom, 8)
            }
            if model.board["issuesTruncated"].is(true) {
                Text("This repository has more open issues; only the most recently updated are listed.")
                    .font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            if model.loaded && shown == 0 && model.error == nil {
                Text(model.issues.isEmpty ? "No open issues." : "No issues match the filters.").font(Theme.footnote).foregroundStyle(Theme.muted)
            }
        }
    }
}

/// One of `#proj-tabs`: 13px, the open one underlined in the accent, 34px tall.
private struct BoardTabButton: View {
    var label: String
    var active: Bool
    var action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            Text(label).font(Theme.footnote).foregroundStyle(active || hovered ? Theme.ink : Theme.muted)
                .padding(.horizontal, 8).frame(height: 34)
                .overlay(alignment: .bottom) { if active { Rectangle().fill(Theme.accent).frame(height: 2) } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
