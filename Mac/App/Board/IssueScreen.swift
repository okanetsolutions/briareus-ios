// One issue (screen_pulls.c issue_detail_screen_*). The API has no read of one issue, so the screen is the board's row kept
// fresh: the board is read again on a timer and the row, the epic's open sub-issues and the closing pull requests' own rows
// are taken from it; the conversations started on it come from the sessions list.
import SwiftUI

@MainActor
final class IssueModel: ObservableObject {
    let repo: String
    @Published var issue: IssueSummary
    @Published var boardIssues: [(summary: IssueSummary, raw: JSON)] = []
    @Published var boardPulls: [PullSummary] = []
    @Published var boardRead = false
    /// The board was read and this issue is not on it.
    @Published var gone = false
    @Published var loadError: String?
    /// The conversations started on this issue or on a pull request closing it.
    @Published var runs: [Session] = []
    @Published var busy = false
    @Published var uncertain = false
    @Published var writeError: String?
    @Published var closing = false
    /// This screen closed it; the board no longer lists it.
    @Published var closed = false
    @Published var closedReason: String?
    @Published private(set) var readingBoard = false
    private var boardGen = 0, runsGen = 0

    init(repo: String, issue: IssueSummary) {
        self.repo = repo; self.issue = issue
        // The board as last saved fills the sub-issues and pull requests in before the first read answers.
        if let saved = Store.shared.cache.value("pulls:\(repo)") { show(saved, saved: true) }
    }

    var id: String { "issue:\(repo)#\(issue.number)" }

    /// Takes the board's answer: its rows, and this issue's own row when it is still there. A saved board only fills in.
    private func show(_ board: JSON, saved: Bool) {
        boardIssues = board["issues"].items.compactMap { j in IssueSummary(j).map { ($0, j) } }
        boardPulls = PullSummary.parseList(board["pulls"])
        var found = false
        for row in board["issues"].items where row["number"].number.map({ Int($0) }) == issue.number {
            found = true
            if !saved, let fresh = IssueSummary(row) { issue = fresh }
            break
        }
        // A board GitHub refused the issues of says nothing about this one.
        if !saved { gone = !found && !board["issuesError"].isSet }
        boardRead = true
    }

    @discardableResult
    func load(fresh: Bool = false) async -> APIError? {
        if Store.shared.supports("sessions") { Task { await loadRuns() } }
        guard Store.shared.supports("pulls") else { return nil }
        boardGen += 1
        let gen = boardGen
        readingBoard = true
        var args: JSON = ["repo": .string(repo)]
        if fresh { args["fresh"] = "1" }
        let r = await boardCall("pulls", args)
        guard gen == boardGen else { return nil }
        readingBoard = false
        switch r {
        case .success(let v):
            show(v, saved: false)
            loadError = nil
            Store.shared.cache.store(v, "pulls:\(repo)")
            return nil
        case .failure(let e):
            if e.kind == .cancelled { return e }
            if fresh && e.kind == .http && e.status == 400 { return await load(fresh: false) }
            loadError = e.description
            return e
        }
    }
    func loadRuns() async {
        runsGen += 1
        let gen = runsGen
        guard let v = await boardCall("sessions", ["repo": .string(repo)]).value, gen == runsGen, let all = Session.parseList(v) else { return }
        runs = all.filter { issueRunMatches($0, issue: issue, repo: repo) }
    }
    func refresh() { Task { await load(fresh: true) } }

    var runActive: Bool { runs.contains { $0.isActive } }
    /// The parent's own board row, when it is an issue of this repository still open on it.
    var parentRow: (summary: IssueSummary, raw: JSON)? {
        guard let parent = issue.parent, !parent.isForeign(repo) else { return nil }
        return boardIssues.first { $0.summary.number == parent.number }
    }
    /// The board row of a closing pull request of this repository, which carries its checks and reviews.
    func pullRow(_ link: BoardLink) -> PullSummary? { link.isForeign(repo) ? nil : pullsFind(boardPulls, link.number) }

    func start() {
        guard !busy, !uncertain else { return }
        guard Dialogs.confirm("Start a paid session on issue #\(issue.number)?", runActive ? "A session is already working on this issue." : nil,
                              continueLabel: "Start session") else { return }
        busy = true
        let args: JSON = ["repo": .string(repo), "prompt": .string(issuePrompt(issue, repo: repo)), "activity": "issue"]
        Task {
            let r = await boardCall("start_session", args)
            busy = false
            switch r {
            case .success(let v):
                post(.sessionsChanged, ["repo": repo])
                // The new conversation joins the Sessions list on the way back.
                if Store.shared.supports("sessions") { Task { await loadRuns() } }
                if let s = Session(v["session"]) { Navigator.shared.push(.conversation(id: s.id, session: s.raw)) }
            case .failure(let e):
                writeError = e.description
                if !e.isRefusal { uncertain = true }
            }
        }
    }

    /// The ▾ menu: why it is closed, and whether a comment goes first. Then a confirmation naming what stays open.
    func close() {
        guard !closing, !closed else { return }
        let items = [PopupMenu.Item(title: "Close as completed"), PopupMenu.Item(title: "Close as not planned"), .divider,
                     PopupMenu.Item(title: "Close as completed with a comment…"), PopupMenu.Item(title: "Close as not planned with a comment…")]
        guard let chosen = PopupMenu.show(items) else { return }
        let notPlanned = chosen == 1 || chosen == 4
        var comment: String?
        if chosen >= 3 {
            guard let c = Dialogs.text("Comment on #\(issue.number) before closing it", label: "Comment", okLabel: "Next") else { return }
            comment = c.cTrimmed.isEmpty ? nil : c
        }
        let open = issue.subIssues - issue.subIssuesDone
        var why = ""
        if open > 0 { why += "\(open) of its sub-issues \(open == 1 ? "is" : "are") still open and stay\(open == 1 ? "s" : "") open. " }
        if runActive { why += "A session is still working on it; closing does not stop it. " }
        if comment != nil { why += "Your comment is posted first." }
        guard Dialogs.confirm("Close issue #\(issue.number) as \(notPlanned ? "not planned" : "completed")?", why.isEmpty ? nil : why, continueLabel: "Close issue"),
              !closed else { return }
        closing = true; writeError = nil
        var args: JSON = ["issue": JSON(issue.number), "repo": .string(repo), "reason": .string(notPlanned ? "not_planned" : "completed")]
        if let comment { args["comment"] = .string(comment) }
        Task {
            let r = await boardCall("close_issue", args)
            closing = false
            switch r {
            case .success(let v):
                closed = true; gone = false
                closedReason = v["issue"]["stateReason"].string ?? (notPlanned ? "not_planned" : "completed")
                writeError = nil
                // The board drops it; reading it again keeps the epic's counts and its siblings true.
                await load(fresh: true)
            case .failure(let e):
                // Closing twice only restates the reason, so trying again is safe.
                writeError = e.description
            }
        }
    }

    func openPull(_ link: BoardLink) {
        if link.isForeign(repo) || !Store.shared.supports("pull") { openWebURL(link.url); return }
        Navigator.shared.push(.pull(repo: repo, number: link.number, stack: nil, summary: pullRow(link)?.raw))
    }
}

struct IssueScreen: View {
    var repo: String
    var issue: JSON
    @ObservedObject private var model: IssueModel
    @ObservedObject private var store = Store.shared

    init(repo: String, issue: JSON) {
        self.repo = repo; self.issue = issue
        let n = issue["number"].int ?? 0
        model = BoardModels.model("issue:\(repo)#\(n)") {
            IssueModel(repo: repo, issue: IssueSummary(issue) ?? IssueSummary(["number": JSON(max(n, 1))])!)
        }
    }

    var body: some View {
        let issue = model.issue
        VStack(spacing: 0) {
            PaneHeader(title: "#\(issue.number)", subtitle: repo, buttons: [
                HeaderButton(glyph: Glyph.symbol(0xE8C8), tip: "Copy the issue’s link", enabled: safeWebURL(issue.url)) { if safeWebURL(issue.url), let u = issue.url { Clipboard.copy(u) } },
                HeaderButton(glyph: Glyph.symbol(0xE72C), tip: "Read the issue from GitHub again", enabled: !model.readingBoard) { model.refresh() },
            ])
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer().frame(height: 10)
                    notices
                    details(issue)
                    if let parent = issue.parent {
                        SectionTitle(title: "Part of")
                        let row = model.parentRow
                        let linked = row != nil || safeWebURL(parent.url)
                        BoardBox {
                            LinkedRow(link: parent, repo: repo, action: linked ? {
                                if let row { Navigator.shared.push(.issue(repo: repo, issue: row.raw)) } else { openWebURL(parent.url) }
                            } : nil)
                        }
                    }
                    if issue.isEpic { subIssues(issue) }
                    pulls(issue)
                    sessions
                    actions(issue)
                    Spacer().frame(height: 16)
                }
                .padding(.horizontal, Theme.paneMargin)
            }
        }
        .task { await poll(every: 45) { await model.load() } }
        .onReceive(NotificationCenter.default.publisher(for: .refreshScreen)) { _ in model.refresh() }
        .onDisappear { BoardModels.release(model.id) }
    }

    @ViewBuilder private var notices: some View {
        if let e = model.writeError {
            BoardBox {
                Notice(message: e)
                if model.uncertain {
                    Text("The request may have completed. Check the project’s conversations before starting another agent.")
                        .font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                    Button("I have checked") { model.uncertain = false; model.writeError = nil }.dashButton(.bordered).padding(.top, 8)
                }
            }
            .padding(.bottom, 10)
        }
        if let e = model.loadError { Notice(message: e).padding(.bottom, 10) }
        if model.closed {
            BoardBox {
                GlyphLabel(glyph: 0xE73E, text: model.closedReason == "not_planned" ? "Closed as not planned" : "Closed as completed", color: Theme.ok)
                Text("It has left the board. Reopen it on GitHub if it was closed by mistake.").font(Theme.caption).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
            .padding(.bottom, 10)
        } else if model.gone {
            BoardBox {
                GlyphLabel(glyph: 0xE946, text: "This issue is no longer on the board")
                Text("It was closed, or it is past the most recently updated issues the server reads. What is shown is how it was last seen.")
                    .font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
            .padding(.bottom, 10)
        }
    }

    private func details(_ issue: IssueSummary) -> some View {
        var rows: [AnyView] = []
        if !issue.labels.isEmpty { rows.append(AnyView(LabelChips(labels: issue.labels, background: Theme.raise))) }
        if issue.isEpic {
            let open = issue.subIssues - issue.subIssuesDone
            rows.append(AnyView(VStack(alignment: .leading, spacing: 4) {
                LabeledRow(label: "Sub-issues", value: open > 0 ? "\(open) open" : "All closed", valueColor: open > 0 ? Theme.ink : Theme.ok)
                EpicProgress(done: issue.subIssuesDone, total: issue.subIssues)
            }))
        }
        if let a = issue.author { rows.append(AnyView(LabeledRow(label: "Reported by", value: "@\(a)"))) }
        rows.append(AnyView(LabeledRow(label: "Assigned", value: issue.assignees.isEmpty ? "Nobody" : people(issue.assignees, limit: 4))))
        if let m = issue.milestone { rows.append(AnyView(LabeledRow(label: "Milestone", value: m))) }
        if issue.comments > 0 { rows.append(AnyView(LabeledRow(label: "Comments", value: "\(issue.comments)"))) }
        if let at = issue.createdAt { rows.append(AnyView(LabeledRow(label: "Opened", value: "\(formatDateAbbrev(at)) · \(formatRelative(at))", valueColor: Theme.muted))) }
        if let at = issue.updatedAt { rows.append(AnyView(LabeledRow(label: "Updated", value: formatRelative(at), valueColor: Theme.muted))) }
        if safeWebURL(issue.url) {
            rows.append(AnyView(Button { openWebURL(issue.url) } label: { GlyphLabel(glyph: 0xE8A7, text: "Open on GitHub", color: Theme.accent) }.buttonStyle(.plain).handCursor()))
        }
        return BoardBox {
            Text(issue.title).font(Theme.title3).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                Rule().padding(.vertical, 6)
                r
            }
        }
    }

    @ViewBuilder private func subIssues(_ issue: IssueSummary) -> some View {
        let subs = issueOpenSubIssues(model.boardIssues.map(\.summary), epic: issue.number, repo: repo)
        let open = issue.subIssues - issue.subIssuesDone
        SectionTitle(title: "Open sub-issues")
        ForEach(subs, id: \.self) { i in
            IssueRowView(issue: model.boardIssues[i].summary, repo: repo, nested: true) { Navigator.shared.push(.issue(repo: repo, issue: model.boardIssues[i].raw)) }
                .padding(.bottom, 8)
        }
        if subs.isEmpty {
            BoardBox {
                Text(open <= 0 ? "Every sub-issue is closed. The epic itself stays open until it is closed on GitHub."
                     : !model.boardRead ? "Reading the board…" : "None of its open sub-issues is on this project’s board.")
                    .font(Theme.callout).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        if open > 0 && subs.count < open && model.boardRead {
            let missing = open - subs.count
            Text("\(missing) open sub-issue\(missing == 1 ? "" : "s") \(missing == 1 ? "is" : "are") in another repository or past the issues the board reads; GitHub lists them all.")
                .font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).padding(.top, subs.isEmpty ? 6 : 0)
        }
    }

    /// A pull request on the board is drawn as the board draws it, checks and reviews included; the rest as links.
    @ViewBuilder private func pulls(_ issue: IssueSummary) -> some View {
        SectionTitle(title: "Pull requests")
        ForEach(Array(issue.pulls.enumerated()), id: \.offset) { _, link in
            if let row = shownRow(link) {
                let running = model.runs.contains { $0.pullNumber == row.number && $0.isActive }
                PullRow(pull: row, stack: nil, repo: repo, running: running,
                        action: store.supports("pull") || safeWebURL(row.url) ? { model.openPull(link) } : nil)
                    .padding(.bottom, 8)
            }
        }
        let thin = issue.pulls.filter { model.pullRow($0) == nil }
        if !thin.isEmpty || issue.pulls.isEmpty {
            BoardBox {
                ForEach(Array(thin.enumerated()), id: \.offset) { i, link in
                    if i > 0 { Rule().padding(.vertical, 6) }
                    let foreign = link.isForeign(repo) || !store.supports("pull")
                    LinkedRow(link: link, repo: repo, action: !foreign || safeWebURL(link.url) ? { model.openPull(link) } : nil)
                }
                if issue.pulls.isEmpty {
                    Text("No open pull request closes this issue yet").font(Theme.callout).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The board row of a closing pull request; the issues it closes would only name this one again.
    private func shownRow(_ link: BoardLink) -> PullSummary? {
        guard var row = model.pullRow(link) else { return nil }
        row.issues = []
        return row
    }

    @ViewBuilder private var sessions: some View {
        if !model.runs.isEmpty {
            SectionTitle(title: "Sessions")
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.runs, id: \.id) { run in
                    SessionRow(session: run, background: Theme.raise) { Navigator.shared.push(.conversation(id: run.id, session: run.raw)) }
                }
            }
            if let cost = runsCost(model.runs) {
                Text("\(formatCost(cost)) spent across \(model.runs.count) session\(model.runs.count == 1 ? "" : "s"), their workers included")
                    .font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            }
        }
    }

    @ViewBuilder private func actions(_ issue: IssueSummary) -> some View {
        if store.supports("start_session") && !model.closed {
            BoardBox {
                if issue.isEpic {
                    Text("An epic is worked by an orchestrator, one sub-issue at a time. Start it from the web dashboard, where its models are picked, or start one of its sub-issues here.")
                        .font(Theme.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                } else {
                    Button(model.busy ? "Starting…" : "Start a session on this issue") { model.start() }
                        .dashButton(.prominent, stretch: true).disabled(model.busy || model.uncertain)
                    Text(model.runActive ? "A session is already working on this issue; it is listed above. A second one is a paid agent doing the same work."
                         : !issue.pulls.isEmpty ? "A pull request is already answering this issue. A second session is a paid agent working on the same thing."
                         : "The session reads the issue, implements it on a branch of its own and opens a pull request closing it. It runs a paid agent on this project’s configured model.")
                        .font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                }
            }
            .padding(.top, 14)
        }
        if store.supports("close_issue") && !model.closed {
            BoardBox {
                Button(model.closing ? "Closing…" : "Close issue ▾") { model.close() }.dashButton(.bordered).disabled(model.closing)
                Text(!issue.pulls.isEmpty ? "Closes it on GitHub now. The pull requests answering it stay open; merging one later will not close it again."
                     : "Closes it on GitHub, as completed or as not planned, with a comment first if you write one.")
                    .font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }
            .padding(.top, 14)
        }
    }
}
