// One pull request in full (screen_pulls.c pull_detail_screen_*): what it is, its conversation, files, commits, checks and
// findings, the conversations already run on it, its errands, the merge, and the Run tab that serves it in a browser.
import Combine
import SwiftUI

enum PullTab: Int { case body, conversation, sessions, files, commits, checks, findings, run }

/// One of the Conversation tab's lists, read page by page: `incoming` fills up and replaces `items` once the last page is in.
struct ConvList {
    var items: JSON = []
    var incoming: JSON?
    var read = false
    var error: String?
    var loading = false
}

@MainActor
final class PullModel: ObservableObject {
    let repo: String
    let number: Int
    let summary: PullSummary?
    /// Its place in a stack, and whether the overview under the title (GitHub's stack popover) is open.
    @Published var stack: StackPosition?
    @Published var stackOpen = false
    @Published var pr: JSON = .null
    @Published var row: PullSummary?
    private var rowRead = false
    @Published var catalog: JSON = []
    @Published var runs: [Session] = []
    private(set) var runsRead = false
    /// The conversation being deleted from the Sessions tab, and why the last delete failed.
    @Published var deletingRun: String?
    @Published var runError: String?
    @Published var findings: JSON = []
    let files: PullFilesModel
    @Published var conv: [ConvList] = Array(repeating: ConvList(), count: ConvFeed.allCases.count)
    @Published var error: String?
    @Published var findingsError: String?
    @Published var writeError: String?
    @Published var mergeError: String?
    @Published var busy = false
    @Published var uncertain = false
    @Published var merging = false
    @Published var tab = PullTab.body
    /// The description, from `pull_description` when `pull` leaves it out.
    @Published var descriptionBody: String?
    @Published var descriptionAuthor: String?
    private(set) var bodyRead = false
    private var readingBody = false
    @Published var deciding: String?
    @Published var openFindings: Set<Int> = []
    @Published var actions: [BoardAction] = []
    @Published private(set) var readingPull = false
    private var pullGen = 0
    var dialogOpen = false
    var shown = false
    private var convTasks: [Task<Void, Never>?] = Array(repeating: nil, count: ConvFeed.allCases.count)

    // The Run tab: opening it serves the pull request (▶ Run) and shows it in an embedded browser. `runSession` is the
    // session serving it, `runProfile` the run profile it serves, `runWant` the one picked in the tab, `runAsked` the one
    // the request in flight asked for.
    @Published var runURL: String?
    @Published var runSession: String?
    @Published var runProfile: String?
    @Published var runWant: String?
    @Published var runAsked: String?
    @Published var serveError: String?
    @Published var runBusy = false
    /// Waits for the Sessions list, in case a Run already serves this pull request.
    private var runPending = false
    /// The project's run profiles, the default first.
    @Published var profiles: [String] = []
    private var profilesRead = false, readingProfiles = false
    /// The log of the Run under way, from its session's transcript: `logSession` is the session followed (found in the
    /// Sessions list while `serve_pull` prepares it).
    @Published var logSession: String?
    @Published var log = RunLog()
    private var readingLog = false
    @Published private(set) var browser: Browser?
    private var browserSink: AnyCancellable?
    /// The Cloudflare Access service token the browser sends to preview hosts, read once before it first opens; without
    /// one (an older server, or none configured) the page asks for a sign-in instead.
    private var access: WebAccess?
    private var accessRead = false, readingAccess = false

    init(repo: String, number: Int, stack: StackPosition?, summary: PullSummary?) {
        self.repo = repo; self.number = number; self.stack = stack; self.summary = summary
        files = PullFilesModel(repo: repo, number: number)
        // The profiles the sidebar already read stand in until this screen reads them.
        profiles = runProfilesParse(ProjectsModel.shared.raw, repo: repo)
    }

    var id: String { "pull:\(repo)#\(number)" }
    var boardRow: PullSummary? { rowRead ? row : (row ?? summary) }
    var isOpen: Bool { pr.isNull ? boardRow != nil : pr["state"].string == "open" }
    var author: String? { pr["author"].string ?? boardRow?.author ?? descriptionAuthor }
    var commitCount: Int { pr["commits"].int32 ?? pr["commitList"].count }

    // MARK: Saving

    private var key: String { "pull:\(repo)#\(number)" }
    private func save() {
        guard !pr.isNull else { return }
        var saved: JSON = ["pr": pr, "findings": findings, "row": boardRow?.raw ?? .null, "stack": stack?.json ?? .null]
        if let descriptionBody { saved["body"] = .string(descriptionBody) }
        if let descriptionAuthor { saved["bodyAuthor"] = .string(descriptionAuthor) }
        Store.shared.cache.store(saved, key)
    }
    private func restore() {
        if let saved = Store.shared.cache.value(key) {
            pr = saved["pr"]
            findings = saved["findings"]
            if descriptionBody == nil { descriptionBody = saved["body"].string }
            if descriptionAuthor == nil { descriptionAuthor = saved["bodyAuthor"].string }
            if row == nil { row = PullSummary(saved["row"]) }
            if stack == nil { stack = StackPosition(restoring: saved["stack"]) }
        }
        if catalog.count == 0, let acts = Store.shared.cache.value("actions") { catalog = acts["actions"] }
        rebuildActions()
    }

    /// The errands on offer: those the server lists for an open pull request with a branch. ▶ Run is the Run tab here.
    func rebuildActions() {
        guard isOpen, pr["headRef"].string != nil else { actions = []; return }
        actions = rowActions(catalog: catalog, pull: boardRow, failedChecks: pr["checks"]["failed"].int32 ?? 0).filter { $0.id != "run" }
    }

    // MARK: Reading

    @discardableResult
    func load() async -> APIError? {
        if pr.isNull { restore() }
        if readingPull { return nil }
        pullGen += 1
        let gen = pullGen
        readingPull = true
        // What the board knows about this pull request beyond its own details.
        if Store.shared.supports("pulls") { Task { await loadRows() } }
        if Store.shared.canManage && Store.shared.supports("actions") { Task { await loadActions() } }
        if Store.shared.supports("sessions") { Task { await loadSessions() } }
        if tab == .conversation { convLoad() }
        let args: JSON = ["repo": .string(repo), "pr": JSON(number)]
        let r = await boardCall("pull", args)
        guard gen == pullGen else { return nil }
        var failure: APIError?
        switch r {
        case .success(let v):
            pr = v["pr"]
            error = nil
            // The description is its own read, once per visit and on refresh.
            if pr["body"].string == nil && !bodyRead && !readingBody && Store.shared.supports("pull_description") { Task { await loadBody() } }
            if Store.shared.supports("findings") {
                let f = await boardCall("findings", args)
                guard gen == pullGen else { return nil }
                switch f {
                case .success(let v): findings = v["findings"]; findingsError = nil
                case .failure(let e): if e.kind != .cancelled { findingsError = e.description }
                }
            }
        case .failure(let e):
            if e.kind == .cancelled { readingPull = false; return e }
            error = e.description
            failure = e
        }
        readingPull = false
        rebuildActions()
        save()
        return failure
    }
    private func loadBody() async {
        readingBody = true
        let r = await boardCall("pull_description", ["repo": .string(repo), "pr": JSON(number)])
        readingBody = false
        if r.error?.kind == .cancelled { return }
        bodyRead = true
        if let v = r.value {
            descriptionBody = v["pr"]["body"].string ?? ""
            if let a = v["pr"]["author"].string { descriptionAuthor = a }
            save()
        }
    }
    private func loadRows() async {
        guard let v = await boardCall("pulls", ["repo": .string(repo)]).value else { return }
        // A pull request the board no longer lists has been merged or closed, and its row went with it.
        let rows = PullSummary.parseList(v["pulls"])
        row = nil
        if let r = rows.first(where: { $0.number == number }) {
            row = r
            // Its place in a stack, with the branches of the rows it is built on; a row no longer stacked drops the overview.
            var s = StackPosition(r.raw["stack"], stacks: v["stacks"])
            s?.fillBranches(rows)
            stack = s
            if s == nil { stackOpen = false }
        }
        rowRead = true
        rebuildActions()
    }
    private func loadActions() async {
        guard let v = await boardCall("actions").value else { return }
        catalog = v["actions"]
        Store.shared.cache.store(v, "actions")
        rebuildActions()
    }
    /// The newest read wins: C cancels the read in flight before each new one, so an older answer never replaces it.
    private var sessionsGen = 0
    func loadSessions() async {
        sessionsGen += 1
        let gen = sessionsGen
        guard let v = await boardCall("sessions", ["repo": .string(repo)]).value, gen == sessionsGen, let all = Session.parseList(v) else { return }
        runs = all.filter { $0.pullNumber == number }
        runsRead = true
        if runPending { runPending = false; runResume() }
    }

    func refresh() {
        // F5 on the Run tab reloads the page, as in a browser.
        if tab == .run, let browser { browser.reload(); return }
        // Refreshing is how an uncertain start is checked: its conversation is listed in the Sessions tab if it began.
        uncertain = false; writeError = nil
        bodyRead = false
        pullGen += 1; readingPull = false
        Task { await load() }
        if files.started { files.refresh() }
    }

    /// The screen came into view: the profiles, the open tab's reads.
    func appeared() {
        shown = true
        profilesLoad()
        if tab == .files { files.load() }
        if tab == .conversation { convLoad() }
        ensureBrowser()
    }
    func disappeared() {
        shown = false
        files.cancel()
        convCancel()
    }

    func select(_ t: PullTab) {
        if t == .run { runOpen(); return }
        tab = t
        if t == .files { files.load() }
        if t == .conversation { convLoad() }
    }

    // MARK: Conversation

    /// Whether every list the server offers has been read once.
    var convRead: Bool { ConvFeed.allCases.allSatisfy { !Store.shared.supports($0.operation) || conv[$0.rawValue].read } }
    /// Reads the comments, reviews and line comments afresh; what was read stays shown until the new lists are in.
    func convLoad() {
        for f in ConvFeed.allCases where !conv[f.rawValue].loading && Store.shared.supports(f.operation) {
            conv[f.rawValue].incoming = []
            conv[f.rawValue].loading = true
            convTasks[f.rawValue] = Task { await convPages(f) }
        }
    }
    private func convPages(_ f: ConvFeed) async {
        var page = 1
        while true {
            let r = await boardCall(f.operation, ["repo": .string(repo), "pr": JSON(number), "page": JSON(page)])
            switch r {
            case .failure(let e):
                conv[f.rawValue].loading = false
                if e.kind == .cancelled { conv[f.rawValue].incoming = nil; return }
                conv[f.rawValue].error = e.description
                conv[f.rawValue].incoming = nil
                conv[f.rawValue].read = true
                return
            case .success(let v):
                var incoming = conv[f.rawValue].incoming ?? []
                for row in v[f.field].items { incoming.append(row) }
                conv[f.rawValue].incoming = incoming
                if let next = v["nextPage"].number, next > Double(page) { page = Int(next); continue }
                conv[f.rawValue].items = incoming
                conv[f.rawValue].incoming = nil
                conv[f.rawValue].read = true
                conv[f.rawValue].error = nil
                conv[f.rawValue].loading = false
                return
            }
        }
    }
    private func convCancel() {
        for i in convTasks.indices { convTasks[i]?.cancel(); convTasks[i] = nil }
    }
    var convComments: JSON { conv[ConvFeed.comments.rawValue].items }
    var convReviews: JSON { conv[ConvFeed.reviews.rawValue].items }
    var convLines: JSON { conv[ConvFeed.reviewComments.rawValue].items }
    /// The messages once they are read; until then the board's count of conversation comments.
    var convCountShown: Int? {
        if convRead { return convCount(comments: convComments, reviews: convReviews, lines: convLines) }
        return boardRow?.raw["comments"].number.map { Int($0) }
    }

    // MARK: Errands

    func startAction(_ action: BoardAction, input: String?) {
        guard !busy, !uncertain, let branch = pr["headRef"].string else { return }
        busy = true
        let args = action.arguments(repo: repo, number: number, branch: branch, input: input)
        Task {
            let r = await boardCall(action.operation, args, timeout: action.timeoutMs.map { TimeInterval($0) / 1000 })
            busy = false
            switch r {
            case .success:
                writeError = nil
                // The pull request stays shown; the new session joins its runs.
                post(.sessionsChanged, ["repo": repo])
                if Store.shared.supports("sessions") { await loadSessions() }
            case .failure(let e):
                writeError = e.description
                // A refusal is definite; anything else may have started the session.
                if !e.isRefusal { uncertain = true }
            }
        }
    }
    func act(_ action: BoardAction) {
        dialogOpen = true
        let answer = actionPrompt(action, number: number)
        dialogOpen = false
        if let input = answer { startAction(action, input: input) }
    }

    /// Solve findings is the board's implement-feedback errand started from the findings themselves: offered on an open
    /// pull request with findings still to fix, to a token that may start errands on a server that lists this one.
    var solveFindingsOffered: Bool {
        guard Store.shared.canManage, Store.shared.supports("action"), catalogLists(catalog, "implement-feedback") else { return false }
        guard pr["state"].string == "open", pr["headRef"].string != nil else { return false }
        return findingsUnfixed(findings) > 0
    }
    func solveFindings() {
        guard solveFindingsOffered, !busy, !uncertain, deciding == nil else { return }
        // The errand as the server words it when it is on offer, else as this app knows it.
        guard let action = actions.first(where: { $0.id == "implement-feedback" }) ?? BoardAction.known.first(where: { $0.id == "implement-feedback" }) else { return }
        let fixes = findingsToFix(findings), open = findingsUnfixed(findings)
        let title = fixes > 0 ? "Start a paid fix session for \(fixes) finding\(fixes == 1 ? "" : "s")?"
                              : "Start a paid fix session for \(open) open finding\(open == 1 ? "" : "s")?"
        let message = "The agent addresses the findings on PR #\(number), pushes the fixes to its branch and has them reviewed again. Uses the provider and model configured for this project."
        dialogOpen = true
        let ok = Dialogs.confirm(title, message, continueLabel: "Solve findings")
        dialogOpen = false
        if ok { startAction(action, input: nil) }
    }

    // MARK: Merge

    var canMerge: Bool {
        Store.shared.supports("merge_pull") && pr["state"].string == "open" && !pr["draft"].is(true)
            && pr["headSha"].string != nil && pr["baseRef"].string != nil
    }
    /// Squash-merges straight away, as the Windows client's Merge button does: no confirmation, the head it was shown
    /// with (`headSha`) guarding against a push meanwhile, and GitHub's refusal shown under the title.
    func merge() {
        guard !merging, let head = pr["headSha"].string, let base = pr["baseRef"].string else { return }
        merging = true; mergeError = nil
        let args: JSON = ["repo": .string(repo), "pr": JSON(number), "headSha": .string(head), "baseRef": .string(base), "method": "squash"]
        Task {
            let r = await boardCall("merge_pull", args)
            merging = false
            if let e = r.error {
                mergeError = e.isRefusal ? e.description : "\(e.description) The merge may still have completed; check the state above before trying again."
            } else { mergeError = nil }
            pullGen += 1; readingPull = false
            await load()
        }
    }

    // MARK: Findings

    func toggleFinding(_ i: Int) { if openFindings.contains(i) { openFindings.remove(i) } else { openFindings.insert(i) } }
    func decide(_ key: String, _ decision: String?) {
        guard deciding == nil else { return }
        deciding = key
        let args: JSON = ["repo": .string(repo), "pr": JSON(number), "key": .string(key), "decision": .string(orNull: decision)]
        Task {
            let r = await boardCall("finding_decision", args)
            deciding = nil
            switch r {
            case .success(let v): findings = v["findings"]; findingsError = nil
            case .failure(let e): findingsError = e.description
            }
        }
    }

    // MARK: Sessions

    func openRun(_ s: Session) { Navigator.shared.push(.conversation(id: s.id, session: s.raw)) }
    func deleteRun(_ s: Session) {
        guard deletingRun == nil, Store.shared.supports("delete") else { return }
        let id = s.id
        dialogOpen = true
        let ok = Dialogs.confirm("Permanently delete this conversation and its transcript?", "\u{201C}\(s.displayTitle)\u{201D}", continueLabel: "Delete", destructive: true)
        dialogOpen = false
        // The list may have been read again while the dialog was open: delete by id, not by row.
        if ok && deletingRun == nil { delete(id) }
    }
    /// The session the Run tab shows: the one serving it, else the one being prepared for it.
    var runTarget: String? { runSession ?? logSession }
    func deleteServed() {
        guard let id = runTarget, deletingRun == nil, Store.shared.supports("delete") else { return }
        dialogOpen = true
        let ok = Dialogs.confirm("Delete this run?", "Its workspace stops serving the pull request, and its conversation and transcript are deleted permanently.",
                                 continueLabel: "Delete", destructive: true)
        dialogOpen = false
        // The run may have changed while the dialog was open: delete the one asked about only if it is still shown.
        if ok && deletingRun == nil && id == runTarget { delete(id) }
    }
    private func delete(_ id: String) {
        deletingRun = id; runError = nil
        Task {
            let r = await boardCall("delete", ["sessionId": .string(id)])
            if let e = r.error { runError = e.description }
            else {
                runError = nil
                if id == runSession || id == logSession { runForget() }
                // The sidebar drops the row now instead of at its next poll, and so does this list.
                post(.sessionForgotten, ["id": id, "repo": repo])
                runs.removeAll { $0.id == id }
            }
            deletingRun = nil
            // A list read while the delete was in flight may still hold the row: read it again.
            if Store.shared.supports("sessions") { await loadSessions() }
        }
    }

    // MARK: Run

    /// The profile the tab shows as chosen: the one picked, else the one served, else the project's default.
    var shownProfile: String? { runWant ?? runProfile ?? profiles.first }

    /// The Run tab's session was deleted, and the workspace serving it with it: the tab forgets it and gives way to the PR
    /// body; opening it again prepares a new one.
    private func runForget() {
        runBusy = false; runPending = false
        runSession = nil; runURL = nil; runProfile = nil; runAsked = nil; serveError = nil
        logSession = nil; log.clear()
        setBrowser(nil)
        if tab == .run { tab = .body }
    }
    private func setBrowser(_ b: Browser?) {
        browser = b
        browserSink = b?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
    private func profilesLoad() {
        guard !profilesRead, !readingProfiles, Store.shared.supports("projects"), Store.shared.supports("serve_pull") else { return }
        readingProfiles = true
        Task {
            let r = await boardCall("projects")
            readingProfiles = false
            guard let v = r.value else { return }
            profilesRead = true
            profiles = runProfilesParse(v, repo: repo)
        }
    }
    /// The Run tab was opened: reads the project's run profiles once, and serves the pull request unless it is served.
    func runOpen() {
        tab = .run
        profilesLoad()
        // Until the Sessions list is read, a Run serving this pull request may be in it.
        if Store.shared.supports("sessions") && !runsRead { runPending = true } else { runResume() }
    }
    private func runResume() {
        if runURL == nil && !runBusy && serveError == nil && !runAdopt() { runStart() }
    }
    /// A Run already serving this pull request (one of its sessions with serve links) is shown as it is.
    private func runAdopt() -> Bool {
        guard let (id, url) = runSessionServing(Session.json(runs), number: number) else { return false }
        runSession = id
        showRun(url)
        return true
    }
    /// Shows the served address, starting the browser again when the address changed.
    private func showRun(_ url: String) {
        if runURL != url { setBrowser(nil); runURL = url }
    }
    /// Serves the pull request: the run's session again, with the picked profile, when there is one; else a new session,
    /// which the server serves with the project's default profile (switched afterwards when another was picked).
    func runStart() {
        guard !runBusy else { return }
        runBusy = true; serveError = nil
        var args: JSON = [:]
        var op = "serve_pull"
        let switched: Bool
        if let session = runSession, Store.shared.supports("serve") {
            op = "serve"
            args["sessionId"] = .string(session)
            if let want = runWant { args["profile"] = .string(want) }
            runAsked = runWant
            switched = true
        } else {
            args["repo"] = .string(repo); args["prNumber"] = JSON(number)
            switched = false
        }
        if let asked = runAsked { log.add("▶ Switching to profile \(asked)", error: false) }
        Task {
            let r = await boardCall(op, args, timeout: 170)
            runDone(r, switched: switched)
        }
    }
    private func runDone(_ r: Result<JSON, APIError>, switched: Bool) {
        runBusy = false
        let asked = runAsked
        runAsked = nil
        switch r {
        case .failure(let e):
            serveError = e.description
            if switched && (e.status == 404 || (e.message ?? "").contains("no live workspace")) {
                // The session closed or expired, and its page with it: the next try prepares a new one.
                runSession = nil; runURL = nil
                setBrowser(nil)
            } else if switched {
                // A refused switch leaves the app serving what it served.
                runWant = runProfile
            }
        case .success(let v):
            if let id = v["session"]["id"].string { runSession = id }
            runProfile = v["profile"].string
            if let url = v["url"].string, safeWebURL(url) {
                let same = url == runURL
                showRun(url)
                // The same address after a restart is a new app behind it.
                if same { browser?.reload() }
            } else { serveError = "The server did not say where it serves the pull request." }
            // A profile picked while this request was out, or a new session served with the default.
            if let want = runWant, runSession != nil, want != asked, want != runProfile { runStart(); return }
            if Store.shared.supports("sessions") { Task { await loadSessions() } }
        }
    }
    func pickProfile() {
        guard !profiles.isEmpty else { return }
        let shown = shownProfile
        let items = profiles.enumerated().map { i, p in BoardPopupMenu.Item(title: i == 0 ? "\(p) (default)" : p, checked: p == shown) }
        guard let chosen = BoardPopupMenu.show(items), profiles[chosen] != shown else { return }
        runWant = profiles[chosen]
        // While a request is out, its answer switches to the new pick.
        if !runBusy { runStart() }
    }

    /// The browser starts once the tab is first on show with an address, and once the service token that lets it past
    /// Cloudflare Access has been read.
    func ensureBrowser() {
        guard shown, tab == .run, let url = runURL, !runBusy, browser == nil else { return }
        if !accessRead && Store.shared.supports("preview_access") {
            guard !readingAccess else { return }
            readingAccess = true
            Task {
                let r = await boardCall("preview_access")
                readingAccess = false
                if r.error?.kind == .cancelled { return }
                accessRead = true
                if let v = r.value, let id = v["clientId"].string, let secret = v["clientSecret"].string, let suffix = v["hostSuffix"].nonEmpty {
                    access = WebAccess(clientID: id, clientSecret: secret, hostSuffix: suffix)
                }
                ensureBrowser()
            }
            return
        }
        let b = Browser(profile: "preview", access: access)
        setBrowser(b)
        b.load(url)
    }
    var pageURL: String? { browser?.url ?? runURL }

    private func logFollow(_ session: String) {
        if logSession == session { return }
        logSession = session
        log.clear()
    }
    /// While `serve_pull` prepares the session, its id is not known yet: the newest ▶ Run session on this pull request is it.
    func runLogTick() async {
        guard runBusy, !readingLog else { return }
        if let s = runSession { logFollow(s) }
        readingLog = true
        defer { readingLog = false }
        if let session = logSession, Store.shared.supports("session") {
            guard let v = await boardCall("session", ["sessionId": .string(session), "since": JSON(log.cursor)]).value, session == logSession else { return }
            log.addEvents(v["events"])
        } else if runSession == nil && Store.shared.supports("sessions") {
            guard let v = await boardCall("sessions", ["repo": .string(repo)]).value, runSession == nil else { return }
            if let id = runSessionPreparing(v, number: number) { logFollow(id) }
        }
    }
}
