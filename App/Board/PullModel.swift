// What the pull request screen reads and writes (the Mac's PullModel): the pull request itself, its description, findings
// and conversation, its board row and conversations through the project's feed, the merge, and the Run tab that serves
// it in an embedded browser.
import Combine
import SwiftUI

/// The parts of the pull request screen, as the section picker lists them.
enum PullSection: String, CaseIterable, Identifiable {
    case description, files, checks, reviews, commits, issues, findings, conversations, run
    var id: String { rawValue }
    var title: String {
        switch self {
        case .description: return "Description"
        case .files: return "Files"
        case .checks: return "Checks"
        case .reviews: return "Reviews"
        case .commits: return "Commits"
        case .issues: return "Issues"
        case .findings: return "Findings"
        case .conversations: return "Conversations"
        case .run: return "Run"
        }
    }
    var symbol: String {
        switch self {
        case .description: return "doc.text"
        case .files: return "doc.on.doc"
        case .checks: return "checklist"
        case .reviews: return "text.bubble"
        case .commits: return "smallcircle.filled.circle"
        case .issues: return "link"
        case .findings: return "flag"
        case .conversations: return "bubble.left.and.bubble.right"
        case .run: return "play.fill"
        }
    }
}

/// One of the comment lists, read page by page: `incoming` fills up and replaces `items` once the last page is in.
struct PullCommentList {
    var items: JSON = []
    var incoming: JSON?
    var read = false
    var error: String?
    var loading = false
}

/// What stands in the way of a merge, asked about before it goes ahead.
struct MergeQuestion: Identifiable {
    var base: String
    var notes: [String]
    var id: String { base + notes.joined() }
}

@MainActor
final class PullScreenModel: ObservableObject {
    let repo: String
    let number: Int
    let summary: PullSummary?
    let feed: ProjectFeed

    @Published var section = PullSection.description
    /// The board's rows, and its place in a stack with the branches of the rows it is built on.
    @Published private(set) var rows: [PullSummary] = []
    @Published private(set) var stack: StackPosition?
    /// True once the board was read while on show: a pull request it no longer lists has been merged or closed.
    @Published private(set) var rowRead = false
    private var savedRow: PullSummary?
    @Published private(set) var pr: JSON = .null
    @Published private(set) var descriptionBody: String?
    @Published private(set) var descriptionAuthor: String?
    @Published private(set) var bodyRead = false
    private var readingBody = false
    @Published private(set) var findings: JSON = []
    @Published private(set) var runs: [Session] = []
    @Published var error: String?
    @Published var findingsError: String?
    @Published var mergeError: String?
    @Published private(set) var merging = false
    @Published var mergeQuestion: MergeQuestion?
    @Published private(set) var deciding: String?
    @Published private(set) var readingPull = false
    @Published private(set) var deletingRun: String?
    @Published var runError: String?
    @Published private(set) var comments = Array(repeating: PullCommentList(), count: ConvFeed.allCases.count)
    private var pullGen = 0
    private var commentTasks: [Task<Void, Never>?] = Array(repeating: nil, count: ConvFeed.allCases.count)
    private var sinks: [AnyCancellable] = []

    // The Run tab: opening it serves the pull request (▶ Run) and shows it in an embedded browser. `runSession` is the
    // session serving it, `runProfile` the profile it serves, `runWant` the one picked, `runAsked` the one the request in
    // flight asked for.
    @Published private(set) var runURL: String?
    @Published private(set) var runSession: String?
    @Published private(set) var runProfile: String?
    @Published private(set) var runWant: String?
    @Published private(set) var runAsked: String?
    @Published private(set) var serveError: String?
    @Published private(set) var runBusy = false
    /// Waits for the conversations, in case a Run already serves this pull request.
    private var runPending = false
    /// The project's run profiles, the default first.
    @Published private(set) var profiles: [String] = []
    private var profilesRead = false, readingProfiles = false
    /// The log of the Run being prepared, from its session's transcript: `logSession` is the session followed.
    @Published private(set) var logSession: String?
    @Published private(set) var log = RunLog()
    private var readingLog = false
    @Published private(set) var browser: RunBrowser?
    private var browserSink: AnyCancellable?
    /// The Cloudflare Access service token the browser sends to preview hosts, read once before it first opens.
    private var access: RunWebAccess?
    private var accessRead = false, readingAccess = false
    private var shown = false

    init(repo: String, number: Int, stack: StackPosition?, summary: PullSummary?) {
        self.repo = repo; self.number = number; self.stack = stack; self.summary = summary
        feed = Store.shared.feed(repo)
        profiles = runProfilesParse(ProjectsModel.shared.raw, repo: repo)
        restore()
        take(feed.board)
        runs = feed.sessions.filter { $0.pullNumber == number }
        // The feed is shared with the board: what either reads shows on both.
        sinks.append(feed.$board.dropFirst().sink { [weak self] board in MainActor.assumeIsolated { self?.take(board) } })
        sinks.append(feed.$sessions.dropFirst().sink { [weak self] list in
            MainActor.assumeIsolated {
                guard let self else { return }
                let mine = list.filter { $0.pullNumber == self.number }
                if mine != self.runs { self.runs = mine }
            }
        })
    }

    private func take(_ board: JSON) {
        guard board.isObject else { return }
        rows = PullSummary.parseList(board["pulls"])
        if let r = pullsFind(rows, number) {
            var s = StackPosition(r.raw["stack"], stacks: board["stacks"])
            s?.fillBranches(rows)
            stack = s
        }
    }

    var boardRow: PullSummary? {
        let listed = pullsFind(rows, number)
        return rowRead ? listed : (listed ?? savedRow ?? summary)
    }
    /// Until the pull request itself answers, being on the board says it is open.
    var isOpen: Bool { pr.isNull ? boardRow != nil : pr["state"].string == "open" }
    var draft: Bool { pr["draft"].is(true) || (pr.isNull && (boardRow?.draft ?? false)) }
    var author: String? { pr["author"].string ?? boardRow?.author ?? descriptionAuthor }
    var commitCount: Int { pr["commits"].int32 ?? pr["commitList"].count }
    var title: String { pr["title"].string ?? boardRow?.title ?? "Pull request #\(number)" }
    var url: String? { pr["url"].string ?? boardRow?.url }
    var head: String? { pr["headRef"].string ?? boardRow.flatMap { $0.branch.isEmpty ? nil : $0.branch } }
    var base: String? { pr["baseRef"].string ?? boardRow.flatMap { $0.baseBranch.isEmpty ? nil : $0.baseBranch } }
    /// The issues it closes: the board's links, or what the pull request names.
    var closes: [BoardLink] { boardRow.map(\.issues).flatMap { $0.isEmpty ? nil : $0 } ?? BoardLink.parseList(pr["issues"]) }

    /// The errands on offer: those the server lists for an open pull request with a branch. ▶ Run is the Run tab here.
    func actions(_ catalog: JSON) -> [BoardAction] {
        guard isOpen, pr["headRef"].string != nil else { return [] }
        return boardErrands(catalog: catalog, pull: boardRow, failedChecks: pr["checks"]["failed"].int32 ?? 0).filter { $0.id != "run" }
    }

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
        guard let saved = Store.shared.cache.value(key) else { return }
        pr = saved["pr"]
        findings = saved["findings"]
        descriptionBody = saved["body"].string
        descriptionAuthor = saved["bodyAuthor"].string
        savedRow = PullSummary(saved["row"])
        if stack == nil { stack = StackPosition(restoring: saved["stack"]) }
    }

    // MARK: Reading

    private var args: JSON { ["repo": .string(repo), "pr": JSON(number)] }

    /// The pull request and its findings; the board, the conversations and the errands beside them.
    func load(fresh: Bool = false) async throws {
        let store = Store.shared
        if store.supports("pulls") {
            Task {
                do { try await feed.loadBoard(fresh: fresh); rowRead = true } catch {}
            }
        }
        if store.supports("sessions") { Task { try? await feed.loadSessions(fresh: fresh) } }
        Task { await ErrandCatalog.shared.load() }
        if section == .reviews { commentsLoad() }
        pullGen += 1
        let gen = pullGen
        readingPull = true
        defer { if gen == pullGen { readingPull = false } }
        let v: JSON
        do { v = try await store.call("pull", args) }
        catch {
            if gen == pullGen, let said = failure(error) { self.error = said }
            throw error
        }
        guard gen == pullGen else { return }
        pr = v["pr"]
        error = nil
        // The description is its own read, once per visit and on refresh.
        if pr["body"].string == nil && !bodyRead && !readingBody && store.supports("pull_description") { Task { await loadBody() } }
        if store.supports("findings") {
            do {
                let f = try await store.call("findings", args)
                guard gen == pullGen else { return }
                findings = f["findings"]; findingsError = nil
            } catch {
                if gen == pullGen, let said = failure(error) { findingsError = said }
            }
        }
        save()
    }
    private func loadBody() async {
        readingBody = true
        defer { readingBody = false }
        do {
            let v = try await Store.shared.call("pull_description", args)
            bodyRead = true
            descriptionBody = v["pr"]["body"].string ?? ""
            if let a = v["pr"]["author"].string { descriptionAuthor = a }
            save()
        } catch {
            if !error.isCancellation { bodyRead = true }
        }
    }

    /// Pulling down reads everything again, GitHub included; on the Run tab it reloads the page, as in a browser.
    func refresh() async {
        if section == .run, let browser { browser.reload(); return }
        bodyRead = false
        if section == .reviews { commentsCancel() }
        _ = await reading { try await load(fresh: true) }
    }

    func appeared() {
        shown = true
        profilesLoad()
        if section == .reviews { commentsLoad() }
        ensureBrowser()
    }
    func disappeared() {
        shown = false
        commentsCancel()
    }

    func select(_ s: PullSection) {
        if s == .run { runOpen(); return }
        section = s
        if s == .reviews { commentsLoad() }
    }

    // MARK: Comments and reviews

    /// Whether every list the server offers has been read once.
    var commentsRead: Bool { ConvFeed.allCases.allSatisfy { !Store.shared.supports($0.operation) || comments[$0.rawValue].read } }
    var commentItems: JSON { comments[ConvFeed.comments.rawValue].items }
    var reviewItems: JSON { comments[ConvFeed.reviews.rawValue].items }
    var lineItems: JSON { comments[ConvFeed.reviewComments.rawValue].items }
    /// The messages once they are read; until then the board's count of conversation comments.
    var commentCount: Int? {
        if commentsRead { return convCount(comments: commentItems, reviews: reviewItems, lines: lineItems) }
        return boardRow?.raw["comments"].int
    }

    /// Reads the comments, reviews and line comments afresh; what was read stays shown until the new lists are in.
    func commentsLoad() {
        for f in ConvFeed.allCases where !comments[f.rawValue].loading && Store.shared.supports(f.operation) {
            comments[f.rawValue].incoming = []
            comments[f.rawValue].loading = true
            commentTasks[f.rawValue] = Task { await commentPages(f) }
        }
    }
    private func commentPages(_ f: ConvFeed) async {
        var page = 1
        while true {
            do {
                let v = try await Store.shared.call(f.operation, ["repo": .string(repo), "pr": JSON(number), "page": JSON(page)])
                var incoming = comments[f.rawValue].incoming ?? []
                for row in v[f.field].items { incoming.append(row) }
                comments[f.rawValue].incoming = incoming
                if let next = v["nextPage"].number, next > Double(page) { page = Int(next); continue }
                comments[f.rawValue] = PullCommentList(items: incoming, read: true)
                return
            } catch {
                comments[f.rawValue].loading = false
                comments[f.rawValue].incoming = nil
                guard let said = failure(error) else { return }
                comments[f.rawValue].error = said
                comments[f.rawValue].read = true
                return
            }
        }
    }
    private func commentsCancel() {
        for i in commentTasks.indices { commentTasks[i]?.cancel(); commentTasks[i] = nil }
        for i in comments.indices where comments[i].loading { comments[i].loading = false; comments[i].incoming = nil }
    }

    // MARK: Findings

    func decide(_ key: String, _ decision: String?) async {
        guard deciding == nil else { return }
        deciding = key
        defer { deciding = nil }
        var a = args
        a["key"] = .string(key); a["decision"] = .string(orNull: decision)
        do {
            let v = try await Store.shared.call("finding_decision", a)
            findings = v["findings"]; findingsError = nil
            save()
        } catch {
            if let said = failure(error) { findingsError = said }
        }
    }

    /// Solve findings is the board's implement-feedback errand started from the findings themselves: offered on an open
    /// pull request with findings still to fix, to a token that may start errands on a server that lists this one.
    func solveFindings(_ catalog: JSON) -> PendingErrand? {
        guard Store.shared.canManage, Store.shared.supports("action"), catalogLists(catalog, "implement-feedback") else { return nil }
        guard pr["state"].string == "open", let branch = pr["headRef"].string, findingsUnfixed(findings) > 0 else { return nil }
        // The errand as the server words it when it is on offer, else as this app knows it.
        guard let action = actions(catalog).first(where: { $0.id == "implement-feedback" })
                ?? BoardAction.known.first(where: { $0.id == "implement-feedback" }) else { return nil }
        return PendingErrand(action: action, number: number, branch: branch)
    }

    // MARK: Merge

    var canMerge: Bool {
        Store.shared.supports("merge_pull") && pr["state"].string == "open" && !pr["draft"].is(true)
            && pr["headSha"].string != nil && pr["baseRef"].string != nil
    }
    /// Reads what GitHub says of the merge before asking, so the question can say what stands in the way of it.
    func askMerge() async {
        guard canMerge, !merging else { return }
        merging = true; mergeError = nil
        defer { merging = false }
        var notes: [String] = []
        if Store.shared.supports("pull_files"), let page = try? await Store.shared.call("pull_files", args) {
            let p = page["pr"]
            if p.isObject { notes += mergeWarnings(mergeable: p["mergeable"], state: p["mergeableState"].string) }
            if let methods = p["mergeMethods"].array, !methods.isEmpty, !methods.contains("squash") {
                notes.append("This repository does not allow squash merges; GitHub will refuse this one.")
            }
            if let head = p["headSha"].string, head != pr["headSha"].string {
                do { try await load() } catch { mergeError = failure(error); return }
                notes.append("New commits were pushed since this screen was read; it has been read again.")
            }
        }
        let failed = pr["checks"]["failed"].int32 ?? 0, pending = pr["checks"]["pending"].int32 ?? 0
        if failed > 0 { notes.append("\(failed) check\(failed == 1 ? " is" : "s are") failing.") }
        if pending > 0 { notes.append("\(pending) check\(pending == 1 ? " is" : "s are") still running.") }
        if case .changesRequested = ReviewStatus(decision: boardRow?.reviewDecision, reviews: pr["reviews"]) {
            notes.append("A reviewer has requested changes.")
        }
        mergeQuestion = MergeQuestion(base: pr["baseRef"].string ?? "its base", notes: notes)
    }
    /// Squash-merges the head this screen was shown with (`headSha` guards against a push meanwhile).
    func merge() async {
        guard !merging, let head = pr["headSha"].string, let base = pr["baseRef"].string else { return }
        merging = true; mergeError = nil
        var a = args
        a["headSha"] = .string(head); a["baseRef"] = .string(base); a["method"] = "squash"
        do {
            try await Store.shared.call("merge_pull", a)
        } catch {
            if let said = failure(error) {
                mergeError = (error as? APIError)?.isRefusal == true ? said
                    : "\(said) The merge may still have completed; check the state above before trying again."
            }
        }
        merging = false
        // The board still lists what was just merged until GitHub is asked again.
        _ = await reading { try await load(fresh: true) }
    }

    // MARK: Conversations

    func delete(_ id: String) async {
        guard deletingRun == nil, Store.shared.supports("delete") else { return }
        deletingRun = id; runError = nil
        defer { deletingRun = nil }
        do {
            try await Store.shared.call("delete", ["sessionId": .string(id)])
            if id == runSession || id == logSession { runForget() }
            feed.drop(id)
        } catch {
            if let said = failure(error) { runError = said }
        }
        // A list read while the delete was in flight may still hold the row.
        if Store.shared.supports("sessions") { try? await feed.loadSessions(fresh: true) }
    }

    // MARK: Run

    /// The profile the tab shows as chosen: the one picked, else the one served, else the project's default.
    var shownProfile: String? { runWant ?? runProfile ?? profiles.first }
    /// The session the Run tab shows: the one serving it, else the one being prepared for it.
    var runTarget: String? { runSession ?? logSession }
    var pageURL: String? { browser?.url ?? runURL }
    var runOffered: Bool { Store.shared.supports("serve_pull") || runURL != nil }

    /// The Run tab's session was deleted, and the workspace serving it with it: the tab gives way to the description.
    private func runForget() {
        runBusy = false; runPending = false
        runSession = nil; runURL = nil; runProfile = nil; runAsked = nil; serveError = nil
        logSession = nil; log.clear()
        setBrowser(nil)
        if section == .run { section = .description }
    }
    private func setBrowser(_ b: RunBrowser?) {
        browser = b
        browserSink = b?.objectWillChange.sink { [weak self] _ in MainActor.assumeIsolated { self?.objectWillChange.send() } }
    }
    private func profilesLoad() {
        guard !profilesRead, !readingProfiles, Store.shared.supports("projects"), Store.shared.supports("serve_pull") else { return }
        readingProfiles = true
        Task {
            defer { readingProfiles = false }
            guard let v = try? await Store.shared.call("projects") else { return }
            profilesRead = true
            profiles = runProfilesParse(v, repo: repo)
        }
    }
    /// The Run tab was opened: reads the project's run profiles once, and serves the pull request unless it is served.
    func runOpen() {
        section = .run
        profilesLoad()
        // Until the conversations are read, a Run serving this pull request may be among them.
        if Store.shared.supports("sessions") && !feed.sessionsLoaded {
            guard !runPending else { return }
            runPending = true
            Task {
                try? await feed.loadSessions()
                guard runPending else { return }
                runPending = false
                runResume()
            }
        } else { runResume() }
        ensureBrowser()
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
    private func showRun(_ url: String) {
        if runURL != url { setBrowser(nil); runURL = url }
        ensureBrowser()
    }
    /// Serves the pull request: the run's session again, with the picked profile, when there is one; else a new session,
    /// which the server serves with the project's default profile.
    func runStart() {
        guard !runBusy else { return }
        runBusy = true; serveError = nil
        var a: JSON = [:]
        var op = "serve_pull"
        let switched: Bool
        if let session = runSession, Store.shared.supports("serve") {
            op = "serve"
            a["sessionId"] = .string(session)
            if let want = runWant { a["profile"] = .string(want) }
            runAsked = runWant
            switched = true
        } else {
            a["repo"] = .string(repo); a["prNumber"] = JSON(number)
            switched = false
        }
        if let asked = runAsked { log.add("▶ Switching to profile \(asked)", error: false) }
        Task {
            do { runDone(.success(try await Store.shared.call(op, a, timeout: 170)), switched: switched) }
            catch { runDone(.failure(error), switched: switched) }
        }
    }
    private func runDone(_ r: Result<JSON, Error>, switched: Bool) {
        runBusy = false
        let asked = runAsked
        runAsked = nil
        switch r {
        case .failure(let error):
            guard let said = failure(error) else { return }
            serveError = said
            let e = error as? APIError
            if switched && (e?.status == 404 || (e?.message ?? "").contains("no live workspace")) {
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
            if Store.shared.supports("sessions") { Task { try? await feed.loadSessions(fresh: true) } }
        }
        ensureBrowser()
    }
    func pickProfile(_ profile: String) {
        guard profile != shownProfile else { return }
        runWant = profile
        // While a request is out, its answer switches to the new pick.
        if !runBusy { runStart() }
    }

    /// The browser starts once the tab is on show with an address, and once the service token that lets it past
    /// Cloudflare Access has been read.
    func ensureBrowser() {
        guard shown, section == .run, let url = runURL, !runBusy, browser == nil else { return }
        if !accessRead && Store.shared.supports("preview_access") {
            guard !readingAccess else { return }
            readingAccess = true
            Task {
                defer { readingAccess = false }
                do {
                    let v = try await Store.shared.call("preview_access")
                    if let id = v["clientId"].string, let secret = v["clientSecret"].string, let suffix = v["hostSuffix"].nonEmpty {
                        access = RunWebAccess(clientID: id, clientSecret: secret, hostSuffix: suffix)
                    }
                } catch {
                    if error.isCancellation { return }
                }
                accessRead = true
                ensureBrowser()
            }
            return
        }
        let b = RunBrowser(profile: "preview", access: access)
        setBrowser(b)
        b.load(url)
    }

    private func logFollow(_ session: String) {
        if logSession == session { return }
        logSession = session
        log.clear()
    }
    /// While `serve_pull` prepares the session its id is not known yet: the newest ▶ Run session on this pull request is it.
    func runLogTick() async {
        guard runBusy, !readingLog else { return }
        if let s = runSession { logFollow(s) }
        readingLog = true
        defer { readingLog = false }
        if let session = logSession, Store.shared.supports("session") {
            guard let v = try? await Store.shared.call("session", ["sessionId": .string(session), "since": JSON(log.cursor)]), session == logSession else { return }
            log.addEvents(v["events"])
        } else if runSession == nil && Store.shared.supports("sessions") {
            guard let v = try? await Store.shared.call("sessions", ["repo": .string(repo)]), runSession == nil else { return }
            if let id = runSessionPreparing(v, number: number) { logFollow(id) }
        }
    }
}
