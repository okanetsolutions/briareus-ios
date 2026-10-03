// One issue on a phone (the Mac's IssueScreen). The API has no read of one issue, so the screen is the board's row kept
// fresh through the project's feed: the epic's open sub-issues and the closing pull requests' rows come from the same
// board, and the conversations started on it from the project's conversations. A session can be started on it, and it
// can be closed as completed or not planned, with a comment first.
import SwiftUI

struct IssueScreen: View {
    let repo: String
    let issue: JSON

    @EnvironmentObject private var store: Store
    @ObservedObject private var feed: ProjectFeed
    @Environment(\.navigate) private var navigate
    /// The board was read while on show, after which an issue missing from it has left it.
    @State private var boardRead = false
    @State private var loadError: String?
    @State private var busy = false
    @State private var uncertain = false
    @State private var writeError: String?
    @State private var confirmingStart = false
    @State private var closing = false
    @State private var closeReason: CloseReason?
    @State private var commenting: CloseReason?
    @State private var comment: String?
    /// The close the comment sheet leads to, asked once the sheet is down.
    @State private var pendingClose: CloseReason?
    /// This screen closed it, and how; the board no longer lists it.
    @State private var closedReason: String?

    fileprivate enum CloseReason: String, Identifiable {
        case completed, notPlanned = "not_planned"
        var id: String { rawValue }
        var words: String { self == .completed ? "completed" : "not planned" }
    }

    init(repo: String, issue: JSON) {
        self.repo = repo; self.issue = issue
        feed = Store.shared.feed(repo)
    }

    private var number: Int { issue["number"].truncatedInt ?? 0 }
    private var boardIssues: [(summary: IssueSummary, raw: JSON)] { feed.board["issues"].items.compactMap { j in IssueSummary(j).map { ($0, j) } } }
    private var boardPulls: [PullSummary] { PullSummary.parseList(feed.board["pulls"]) }
    /// The board's row when it lists it, else what the screen was opened with.
    private var row: IssueSummary {
        boardIssues.first { $0.summary.number == number }?.summary ?? IssueSummary(issue) ?? IssueSummary(["number": JSON(max(number, 1))])!
    }
    /// The board was read and this issue is not on it; a board GitHub refused the issues of says nothing about it.
    private var gone: Bool {
        boardRead && closedReason == nil && !feed.board["issuesError"].isSet && !boardIssues.contains { $0.summary.number == number }
    }
    private var runs: [Session] { feed.sessions.filter { issueRunMatches($0, issue: row, repo: repo) } }
    private var runActive: Bool { runs.contains { $0.isActive } }

    var body: some View {
        let issue = row
        List {
            notices
            details(issue)
            if let body = self.issue["body"].string.map(visibleMarkdown), !body.isEmpty {
                Section("Description") { MarkdownText(body).font(.callout) }.listRowBackground(Theme.row)
            }
            if let parent = issue.parent { parentSection(parent) }
            if issue.isEpic { subIssues(issue) }
            pulls(issue)
            sessions
            actions(issue)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle(Text(verbatim: "#\(issue.number)")).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if safeWebURL(issue.url) {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { boardOpenWeb(issue.url) } label: { Label("Open on GitHub", systemImage: "safari") }
                        Button { Pasteboard.copy(issue.url ?? "") } label: { Label("Copy link", systemImage: "link") }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("More")
                }
            }
        }
        .refreshable {
            uncertain = false; writeError = nil
            async let sessions: Void? = store.supports("sessions") ? try? feed.loadSessions(fresh: true) : nil
            _ = await reading { try await load(fresh: true) }
            _ = await sessions
        }
        .task { await poll(every: ProjectFeed.boardEvery) { await reading { try await load() } } }
        .task {
            guard store.supports("sessions") else { return }
            await poll(every: ProjectFeed.sessionsEvery) { await reading { try await feed.loadSessions() } }
        }
        .alert("Start a paid session on issue #\(issue.number)?" as String, isPresented: $confirmingStart) {
            Button("Start session") { Task { await start() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(runActive ? "A session is already working on this issue." : "It runs a paid agent on this project’s configured model.")
        }
        .alert(closeReason.map { "Close issue #\(issue.number) as \($0.words)?" } ?? "",
               isPresented: Binding(get: { closeReason != nil }, set: { if !$0 { closeReason = nil } }), presenting: closeReason) { reason in
            Button("Close issue", role: .destructive) { Task { await close(reason) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            if let why = closeNote(issue) { Text(why) }
        }
        .sheet(item: $commenting, onDismiss: {
            if let p = pendingClose { pendingClose = nil; closeReason = p }
        }) { reason in
            CloseCommentSheet(number: issue.number, reason: reason.words) { text in
                comment = text.cTrimmed.isEmpty ? nil : text
                pendingClose = reason
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func load(fresh: Bool = false) async throws {
        guard store.supports("pulls") else { return }
        do {
            try await feed.loadBoard(fresh: fresh)
            boardRead = true
            loadError = nil
        } catch {
            if let said = failure(error) { loadError = said }
            throw error
        }
    }

    // MARK: Sections

    @ViewBuilder private var notices: some View {
        if let e = writeError {
            Section {
                ErrorNotice(message: e)
                if uncertain {
                    Text("The request may have completed. Check the project’s conversations before starting another agent.").font(.footnote).foregroundStyle(.secondary)
                    Button("I have checked") { uncertain = false; writeError = nil }.font(.callout)
                }
            }
            .listRowBackground(Theme.row)
        }
        if let e = loadError { Section { ErrorNotice(message: e) }.listRowBackground(Theme.row) }
        if let reason = closedReason {
            Section {
                Label(reason == "not_planned" ? "Closed as not planned" : "Closed as completed", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
                Text("It has left the board. Reopen it on GitHub if it was closed by mistake.").font(.footnote).foregroundStyle(.secondary)
            }
            .listRowBackground(Theme.row)
        } else if gone {
            Section {
                Label("This issue is no longer on the board", systemImage: "info.circle")
                Text("It was closed, or it is past the most recently updated issues the server reads. What is shown is how it was last seen.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .listRowBackground(Theme.row)
        }
    }

    private func details(_ issue: IssueSummary) -> some View {
        Section {
            Text(issue.title).font(.title3.bold()).textSelection(.enabled)
            if !issue.labels.isEmpty {
                BoardLabelChips(labels: issue.labels).padding(.vertical, 2).alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            }
            if issue.isEpic {
                let open = issue.subIssues - issue.subIssuesDone
                LabeledContent("Sub-issues") {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(open > 0 ? "\(open) open" : "All closed").foregroundStyle(open > 0 ? Color.secondary : Theme.success)
                        BoardEpicProgress(done: issue.subIssuesDone, total: issue.subIssues)
                    }
                }
            }
            if let author = issue.author { LabeledContent("Reported by", value: "@\(author)") }
            LabeledContent("Assigned", value: issue.assignees.isEmpty ? "Nobody" : people(issue.assignees, limit: 4))
            if let milestone = issue.milestone { LabeledContent("Milestone", value: milestone) }
            if issue.comments > 0 { LabeledContent("Comments", value: "\(issue.comments)") }
            if let at = issue.createdAt { LabeledContent("Opened", value: "\(formatDateAbbrev(at)) · \(formatRelative(at))") }
            if let at = issue.updatedAt { LabeledContent("Updated", value: formatRelative(at)) }
            if safeWebURL(issue.url) {
                Button { boardOpenWeb(issue.url) } label: { Label("Open on GitHub", systemImage: "safari") }
            }
        }
        .listRowBackground(Theme.row)
    }

    private func parentSection(_ parent: BoardLink) -> some View {
        Section("Part of") {
            if !parent.isForeign(repo), let row = boardIssues.first(where: { $0.summary.number == parent.number }) {
                DestinationLink(destination: .issue(repo: repo, issue: row.raw)) { BoardLinkedRow(link: parent, repo: repo) }
            } else if safeWebURL(parent.url) {
                Button { boardOpenWeb(parent.url) } label: { BoardLinkedRow(link: parent, repo: repo) }.foregroundStyle(.primary)
            } else {
                BoardLinkedRow(link: parent, repo: repo)
            }
        }
        .listRowBackground(Theme.row)
    }

    @ViewBuilder private func subIssues(_ issue: IssueSummary) -> some View {
        let all = boardIssues
        let subs = issueOpenSubIssues(all.map(\.summary), epic: issue.number, repo: repo)
        let open = issue.subIssues - issue.subIssuesDone
        Section {
            ForEach(subs, id: \.self) { i in
                DestinationLink(destination: .issue(repo: repo, issue: all[i].raw)) { BoardIssueRow(issue: all[i].summary, repo: repo, nested: true) }
            }
            if subs.isEmpty {
                Text(open <= 0 ? "Every sub-issue is closed. The epic itself stays open until it is closed on GitHub."
                     : !feed.boardLoaded ? "Reading the board…" : "None of its open sub-issues is on this project’s board.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text("Open sub-issues")
        } footer: {
            if open > 0 && subs.count < open && feed.boardLoaded {
                let missing = open - subs.count
                Text("\(missing) open sub-issue\(missing == 1 ? "" : "s") \(missing == 1 ? "is" : "are") in another repository or past the issues the board reads; GitHub lists them all.")
            }
        }
        .listRowBackground(Theme.row)
    }

    /// A pull request on the board is drawn as the board draws it; the rest as links.
    @ViewBuilder private func pulls(_ issue: IssueSummary) -> some View {
        let rows = boardPulls
        Section("Pull requests") {
            ForEach(Array(issue.pulls.enumerated()), id: \.offset) { _, link in
                if !link.isForeign(repo), store.supports("pull"), let pull = pullsFind(rows, link.number) {
                    let stack = StackPosition(pull.raw["stack"], stacks: feed.board["stacks"])
                    DestinationLink(destination: .pull(repo: repo, number: pull.number, stack: stack?.json, summary: pull.raw)) {
                        BoardPullRow(pull: pull, stack: stack, repo: repo,
                                     activeRuns: feed.sessions.filter { $0.pullNumber == pull.number && $0.isActive }.count, showsIssues: false)
                    }
                } else if !link.isForeign(repo), store.supports("pull") {
                    DestinationLink(destination: .pull(repo: repo, number: link.number, stack: nil, summary: nil)) { BoardLinkedRow(link: link, repo: repo) }
                } else if safeWebURL(link.url) {
                    Button { boardOpenWeb(link.url) } label: { BoardLinkedRow(link: link, repo: repo) }.foregroundStyle(.primary)
                } else {
                    BoardLinkedRow(link: link, repo: repo)
                }
            }
            if issue.pulls.isEmpty { Text("No open pull request closes this issue yet").foregroundStyle(.secondary) }
        }
        .listRowBackground(Theme.row)
    }

    @ViewBuilder private var sessions: some View {
        let runs = self.runs
        if !runs.isEmpty {
            Section {
                ForEach(runs, id: \.id) { run in
                    DestinationLink(destination: .conversation(id: run.id, session: run.raw)) { BoardSessionRow(session: run) }
                }
            } header: {
                Text("Conversations")
            } footer: {
                if let cost = runsCost(runs) {
                    Text("\(formatCost(cost)) spent across \(runs.count) session\(runs.count == 1 ? "" : "s"), their workers included")
                }
            }
            .listRowBackground(Theme.row)
        }
    }

    @ViewBuilder private func actions(_ issue: IssueSummary) -> some View {
        if store.supports("start_session") && closedReason == nil {
            Section {
                if issue.isEpic {
                    Text("An epic is worked by an orchestrator, one sub-issue at a time. It is not started from this app; start one of its sub-issues here.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Button { confirmingStart = true } label: {
                        HStack {
                            Label("Start a session on this issue", systemImage: "play.fill").fontWeight(.semibold)
                            if busy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(busy || uncertain)
                }
            } footer: {
                if !issue.isEpic {
                    Text(runActive ? "A session is already working on this issue; it is listed above. A second one is a paid agent doing the same work."
                         : !issue.pulls.isEmpty ? "A pull request is already answering this issue. A second session is a paid agent working on the same thing."
                         : "The session reads the issue, implements it on a branch of its own and opens a pull request closing it. It runs a paid agent on this project’s configured model.")
                }
            }
            .listRowBackground(Theme.row)
        }
        if store.supports("close_issue") && closedReason == nil {
            Section {
                Menu {
                    Button("Close as completed", systemImage: "checkmark.circle") { comment = nil; closeReason = .completed }
                    Button("Close as not planned", systemImage: "nosign") { comment = nil; closeReason = .notPlanned }
                    Section {
                        Button("Completed, with a comment…", systemImage: "text.bubble") { commenting = .completed }
                        Button("Not planned, with a comment…", systemImage: "text.bubble") { commenting = .notPlanned }
                    }
                } label: {
                    HStack {
                        Label("Close issue", systemImage: "xmark.circle").foregroundStyle(Theme.danger)
                        if closing { Spacer(); ProgressView() }
                    }
                }
                .disabled(closing)
            } footer: {
                Text(!issue.pulls.isEmpty ? "Closes it on GitHub now. The pull requests answering it stay open; merging one later will not close it again."
                     : "Closes it on GitHub, as completed or as not planned, with a comment first if you write one.")
            }
            .listRowBackground(Theme.row)
        }
    }

    // MARK: Writes

    private func start() async {
        guard !busy, !uncertain else { return }
        busy = true
        defer { busy = false }
        let args: JSON = ["repo": .string(repo), "prompt": .string(issuePrompt(row, repo: repo)), "activity": "issue"]
        do {
            let v = try await store.call("start_session", args)
            writeError = nil
            if store.supports("sessions") { try? await feed.loadSessions(fresh: true) }
            if let s = Session(v["session"]) { navigate(.conversation(id: s.id, session: s.raw)) }
        } catch {
            guard let said = failure(error) else { return }
            writeError = said
            if (error as? APIError)?.isRefusal != true { uncertain = true }
        }
    }

    /// What stays open once it is closed, and that a comment goes first.
    private func closeNote(_ issue: IssueSummary) -> String? {
        let open = issue.subIssues - issue.subIssuesDone
        var why = ""
        if open > 0 { why += "\(open) of its sub-issues \(open == 1 ? "is" : "are") still open and stay\(open == 1 ? "s" : "") open. " }
        if runActive { why += "A session is still working on it; closing does not stop it. " }
        if comment != nil { why += "Your comment is posted first." }
        return why.isEmpty ? nil : why.cTrimmed
    }

    private func close(_ reason: CloseReason) async {
        guard !closing, closedReason == nil else { return }
        closing = true; writeError = nil
        defer { closing = false }
        var args: JSON = ["issue": JSON(number), "repo": .string(repo), "reason": .string(reason.rawValue)]
        if let comment { args["comment"] = .string(comment) }
        do {
            let v = try await store.call("close_issue", args)
            closedReason = v["issue"]["stateReason"].string ?? reason.rawValue
            comment = nil
            // The board drops it; reading it again keeps the epic's counts and its siblings true.
            _ = await reading { try await load(fresh: true) }
        } catch {
            // Closing twice only restates the reason, so trying again is safe.
            if let said = failure(error) { writeError = said }
        }
    }
}

/// The comment posted on an issue before it is closed.
private struct CloseCommentSheet: View {
    let number: Int
    let reason: String
    let next: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Why it is being closed", text: $text, axis: .vertical).lineLimit(5...14).focused($focused)
                } footer: {
                    Text(verbatim: "Posted on #\(number) before it is closed as \(reason). You confirm the close next.")
                }
                .listRowBackground(Theme.row)
            }
            .scrollContentBackground(.hidden).background(Theme.background)
            .navigationTitle("Comment").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Next") { dismiss(); next(text) }.bold().disabled(text.cTrimmed.isEmpty)
                }
            }
            .onAppear { focused = true }
        }
    }
}
