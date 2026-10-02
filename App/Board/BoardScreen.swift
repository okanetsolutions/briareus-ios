// A project's board on a phone (the Mac's BoardScreen): open pull requests and issues behind a segmented control, the
// author, reviewer and label pickers in the toolbar's filter menu, kept per repository. Each pull request row names the
// errand its state asks for and offers the errands in its context menu. The Mac's SSH and SFTP tabs are left out: they
// drive local ssh and sftp processes a phone does not have.
import SwiftUI

/// The board's pickers, kept on disk per repository as the Mac keeps them. A board never filtered opens on the project's
/// configured author, while they have something open.
@MainActor
final class BoardFilters: ObservableObject {
    let repo: String
    @Published var pulls = BoardFilter()
    @Published var issues = BoardFilter()
    /// The filter the board last opened on, until the server has answered once and the picks are the user's.
    private var opening: BoardFilter?

    init(repo: String) {
        self.repo = repo
        if let saved = Store.shared.cache.value("pulls-filters:\(repo)") {
            read(&pulls, saved["pulls"]); read(&issues, saved["issues"])
        } else {
            opening = BoardFilter()
        }
    }

    private func read(_ f: inout BoardFilter, _ j: JSON) {
        for k in FilterKind.allCases { if let v = j[k.name].string { f.set(k, v) } }
    }
    private func json(_ f: BoardFilter) -> JSON {
        var j: JSON = [:]
        for k in FilterKind.allCases where !f[k].isEmpty { j[k.name] = .string(f[k]) }
        return j
    }
    /// A pick by the user: the board no longer opens on the author, and the picks are saved.
    func picked() {
        opening = nil
        Store.shared.cache.store(["pulls": json(pulls), "issues": json(issues)], "pulls-filters:\(repo)")
    }
    /// A board shown before the server answered may be out of date about who has something open, so the server's answer
    /// opens it again, unless the pickers were touched meanwhile.
    func opened(_ board: JSON, answered: Bool) {
        guard let last = opening, board.isObject else { return }
        let f = BoardFilter.opening(author: board["author"].string, rows: PullSummary.parseList(board["pulls"]).map(BoardRow.init))
        if pulls == last { pulls = f }
        opening = answered ? nil : f
    }
}

struct BoardScreen: View {
    let repo: String
    private enum Tab: Hashable { case pulls, issues }

    @EnvironmentObject private var store: Store
    @ObservedObject private var feed: ProjectFeed
    @ObservedObject private var catalog = ErrandCatalog.shared
    @ObservedObject private var projects = ProjectsModel.shared
    @StateObject private var filters: BoardFilters
    @StateObject private var errands: ErrandRunner
    @State private var tab = Tab.pulls
    @State private var error: String?

    init(repo: String) {
        self.repo = repo
        feed = Store.shared.feed(repo)
        _filters = StateObject(wrappedValue: BoardFilters(repo: repo))
        _errands = StateObject(wrappedValue: ErrandRunner(repo: repo))
    }

    private var board: JSON { feed.board }
    private var pulls: [PullSummary] { PullSummary.parseList(board["pulls"]) }
    private var issues: [(summary: IssueSummary, raw: JSON)] { board["issues"].items.compactMap { j in IssueSummary(j).map { ($0, j) } } }
    private var loaded: Bool { feed.boardLoaded || error != nil }
    private var filter: Binding<BoardFilter> { tab == .pulls ? $filters.pulls : $filters.issues }

    var body: some View {
        let pulls = self.pulls, issues = self.issues
        let rows = tab == .pulls ? pulls.map(BoardRow.init) : issues.map { BoardRow($0.summary) }
        List {
            if let error { Section { ErrorNotice(message: error) }.listRowBackground(Theme.row) }
            ErrandNotice(runner: errands, place: "in the project")
            Picker("Show", selection: $tab) {
                Text("Pull requests (\(pulls.count))").tag(Tab.pulls)
                Text("Issues (\(issues.count))").tag(Tab.issues)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            if filter.wrappedValue.isOn {
                HStack {
                    Text("Showing \(rows.filter { filter.wrappedValue.passes($0) }.count) of \(rows.count)").font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear filters") { filter.wrappedValue = BoardFilter(); filters.picked() }.font(.footnote).buttonStyle(.borderless)
                }
                .listRowBackground(Color.clear)
            }
            if tab == .pulls { pullRows(pulls) } else { issueRows(issues) }
            if !loaded {
                ProgressView("Loading pull requests…").frame(maxWidth: .infinity).padding(.vertical, 24).listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle(projects.project(repo)?.title ?? "Board").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                BoardFilterMenu(filter: filter, rows: rows, kinds: tab == .pulls ? FilterKind.allCases : [.author, .label]) { filters.picked() }
                    .disabled(!loaded || rows.isEmpty && !filter.wrappedValue.isOn)
            }
        }
        .refreshable {
            // Pulling down is how an uncertain start is checked: its conversation shows on its pull request if it began.
            errands.checked()
            async let sessions: Void? = store.supports("sessions") ? try? feed.loadSessions(fresh: true) : nil
            await read(fresh: true)
            _ = await sessions
        }
        .task {
            filters.opened(board, answered: false)
            await catalog.load()
        }
        .task { await poll(every: ProjectFeed.boardEvery) { await reading { try await load() } } }
        // Conversations start and finish faster than the board changes, and reading them asks GitHub nothing.
        .task {
            guard store.supports("sessions") else { return }
            await poll(every: ProjectFeed.sessionsEvery) { await reading { try await feed.loadSessions() } }
        }
        .onChange(of: issues.isEmpty) { _, empty in if empty && tab == .issues && !board["issuesError"].isSet && feed.boardLoaded { tab = .pulls } }
        .errandPrompts(errands)
    }

    private func load(fresh: Bool = false) async throws {
        do {
            try await feed.loadBoard(fresh: fresh)
            filters.opened(board, answered: true)
            error = nil
        } catch {
            if let said = failure(error) { self.error = said }
            throw error
        }
    }
    private func read(fresh: Bool) async { _ = await reading { try await load(fresh: fresh) } }

    // MARK: Pull requests

    @ViewBuilder private func pullRows(_ pulls: [PullSummary]) -> some View {
        let shown = pulls.filter { filters.pulls.passes(BoardRow($0)) }
        Section {
            ForEach(shown, id: \.number) { pull in
                let stack = StackPosition(pull.raw["stack"], stacks: board["stacks"])
                let actions = pull.branch.isEmpty ? [] : boardErrands(catalog: catalog.catalog, pull: pull, failedChecks: 0)
                DestinationLink(destination: .pull(repo: repo, number: pull.number, stack: stack?.json, summary: pull.raw)) {
                    BoardPullRow(pull: pull, stack: stack, repo: repo, activeRuns: activeRuns(pull.number),
                                 suggested: actions.first { $0.id == pull.recommended }?.label)
                }
                .contextMenu { rowMenu(pull, actions: actions) }
            }
        } footer: {
            if let at = boardDateParse(board["syncedAt"].string), !shown.isEmpty { Text("Synced with GitHub \(formatRelative(at)).") }
        }
        if loaded && shown.isEmpty && error == nil {
            ContentUnavailableView(pulls.isEmpty ? "No open pull requests" : "No pull requests match the filters", systemImage: "arrow.triangle.pull")
                .listRowBackground(Color.clear)
        }
    }

    /// The row's errands as the Mac's row buttons offer them, less ▶ Run, which is the pull request's own Run tab.
    @ViewBuilder private func rowMenu(_ pull: PullSummary, actions: [BoardAction]) -> some View {
        let errandList = actions.filter { $0.id != "run" }
        if !errandList.isEmpty {
            Section("Errands") {
                ForEach(errandList, id: \.id) { a in
                    Button(role: a.id == "delete-self-comments" ? .destructive : nil) {
                        errands.ask(a, number: pull.number, branch: pull.branch)
                    } label: {
                        Label(pull.recommended == a.id ? "\(a.label) (suggested)" : a.label, systemImage: pull.recommended == a.id ? "sparkles" : errandSymbol(a.id))
                    }
                    .disabled(errands.busy || errands.uncertain)
                }
            }
        }
        if safeWebURL(pull.url) {
            Button { boardOpenWeb(pull.url) } label: { Label("Open on GitHub", systemImage: "safari") }
            Button { Pasteboard.copy(pull.url ?? "") } label: { Label("Copy link", systemImage: "link") }
        }
        if !pull.branch.isEmpty {
            Button { Pasteboard.copy(pull.branch) } label: { Label("Copy branch name", systemImage: "arrow.triangle.branch") }
        }
    }

    private func activeRuns(_ number: Int) -> Int { feed.sessions.filter { $0.pullNumber == number && $0.isActive }.count }

    // MARK: Issues

    @ViewBuilder private func issueRows(_ issues: [(summary: IssueSummary, raw: JSON)]) -> some View {
        if let refused = board["issuesError"].string {
            Section {
                Text("GitHub would not read this repository’s issues with the server’s token. A fine-grained token needs Issues: read. The pull requests are unaffected.")
                    .font(.footnote).foregroundStyle(.secondary)
                ErrorNotice(message: refused)
            }
            .listRowBackground(Theme.row)
        } else {
            let visible = issues.filter { filters.issues.passes(BoardRow($0.summary)) }
            let nested = issuesNested(visible.map(\.summary), repo: repo)
            Section {
                ForEach(nested, id: \.index) { row in
                    let item = visible[row.index]
                    DestinationLink(destination: .issue(repo: repo, issue: item.raw)) {
                        BoardIssueRow(issue: item.summary, repo: repo, nested: row.depth > 0)
                            .padding(.leading, CGFloat(min(row.depth, 4)) * 14)
                    }
                    .contextMenu {
                        if safeWebURL(item.summary.url) {
                            Button { boardOpenWeb(item.summary.url) } label: { Label("Open on GitHub", systemImage: "safari") }
                            Button { Pasteboard.copy(item.summary.url ?? "") } label: { Label("Copy link", systemImage: "link") }
                        }
                    }
                }
            } footer: {
                if board["issuesTruncated"].is(true) { Text("This repository has more open issues; only the most recently updated are listed.") }
            }
            if loaded && visible.isEmpty && error == nil {
                ContentUnavailableView(issues.isEmpty ? "No open issues" : "No issues match the filters", systemImage: "smallcircle.filled.circle")
                    .listRowBackground(Color.clear)
            }
        }
    }
}

/// The board's pickers in one menu. Each option says how many rows picking it would leave.
private struct BoardFilterMenu: View {
    @Binding var filter: BoardFilter
    let rows: [BoardRow]
    let kinds: [FilterKind]
    let picked: () -> Void

    var body: some View {
        Menu {
            ForEach(kinds, id: \.self) { kind in
                let options = filter.options(kind, rows: rows)
                Picker(selection: Binding(get: { filter[kind] }, set: { filter.set(kind, $0); picked() })) {
                    Text("All \(kind.name)s").tag("")
                    ForEach(options, id: \.value) { Text("\($0.text) (\($0.count))").tag($0.value) }
                } label: {
                    let name = kind.name.asciiCapitalized
                    Label(filter[kind].isEmpty ? name : "\(name): \(options.first { $0.value == filter[kind] }?.text ?? filter[kind])",
                          systemImage: kind == .author ? "person" : kind == .reviewer ? "eye" : "tag")
                }
                .pickerStyle(.menu)
                .disabled(options.isEmpty)
            }
            if filter.isOn {
                Button("Clear filters", systemImage: "xmark.circle", role: .destructive) { filter = BoardFilter(); picked() }
            }
        } label: {
            Image(systemName: filter.isOn ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel(filter.isOn ? "Filters, active" : "Filters")
    }
}
