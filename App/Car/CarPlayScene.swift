#if os(iOS)
import CarPlay
import Combine
import SwiftUI

/// The car's screen. CarPlay lists the app as a voice-based conversational one, which iOS 26.4 introduced.
final class CarPlayScene: UIResponder, CPTemplateApplicationSceneDelegate {
    private var assistant: AnyObject?
    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect controller: CPInterfaceController) {
        CarScreen.connected = true
        #if compiler(>=6.3)
        guard #available(iOS 26.4, *) else { return }
        let assistant = CarAssistant(controller: controller)
        self.assistant = assistant
        assistant.start()
        #endif
    }
    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didDisconnectInterfaceController controller: CPInterfaceController) {
        #if compiler(>=6.3)
        if #available(iOS 26.4, *) { (assistant as? CarAssistant)?.stop() }
        #endif
        assistant = nil
        CarScreen.connected = false
    }
}

// What follows needs the iOS 26.4 SDK, which came with the Swift 6.3 compiler. An older Xcode builds the app without its car.
#if compiler(>=6.3)
/// Briareus in a car. The screen that stays is the voice one: it carries the conversation, pull request or
/// issue in hand, and what the agent is told is dictated to it. A car has no keyboard, so dictating is the only
/// way to write; what was understood is shown and sent on a yes. The app listens and never speaks. Lists choose
/// what is in hand and what to do with it, two screens deep at most, which is as deep as CarPlay lets an app
/// of this kind go.
@available(iOS 26.4, *)
@MainActor
final class CarAssistant: NSObject, CPInterfaceControllerDelegate {
    enum Focus {
        case nothing, conversation, pull(Int), issue(IssueSummary)
    }
    enum Phase: String, CaseIterable { case ready, listening, working, notice }
    /// What a dictation is for, which is what confirming it does.
    enum Purpose {
        case message, prompt, rename, note, feedback(BoardAction)
        /// A comment posted on the issue before it is closed, as not planned or as completed.
        case comment(IssueSummary, notPlanned: Bool)
        /// What the screen says while listening.
        var invitation: String {
            switch self {
            case .message: return "Your message…"
            case .prompt: return "What should the agent work on?"
            case .rename: return "The new name…"
            case .note: return "Your note for the fix session…"
            case .feedback(let action): return (action.input?.label ?? "Your feedback") + "…"
            case .comment: return "Your comment on the issue…"
            }
        }
        /// What comes before the dictated words when they are shown, and the button that accepts them.
        var confirmation: (before: String, yes: String) {
            switch self {
            case .message: return ("Send “", "Send")
            case .prompt: return ("Start a paid conversation on “", "Start")
            case .rename: return ("Rename to “", "Rename")
            case .note: return ("Note for the fix session: “", "Keep")
            case .feedback(let action): return ("Start a paid \(action.label) session with “", "Start")
            case .comment(let issue, _): return ("Comment on #\(issue.number) before closing it: “", "Next")
            }
        }
    }
    /// What a new conversation starts on; nil is the project's own.
    struct Plan { var branch = ""; var runtime: RuntimeChoice?; var catalog: RuntimeCatalog? }

    let store = Store.shared
    let ears = CarDictation()
    let controller: CPInterfaceController
    private var root: CPVoiceControlTemplate?
    private(set) var phase = Phase.ready
    private var paired = false
    private var watching: AnyCancellable?
    private var watcher: Task<Void, Never>?
    private var work: Task<Void, Never>?
    /// Counts the pieces of work begun, so that one ending late does not take the next one for its own.
    private var turn = 0
    private var settle: Task<Void, Never>?
    private var fading: Task<Void, Never>?
    /// What the screen says while listening and after something was done.
    private var invitation = "Listening…"
    private var notice = ""
    /// What the voice screen last said of what is in hand, to draw it again only when that changed.
    private var drawn: [String] = []
    /// True once the listening in hand was dropped by its button, which is not the same as hearing nothing.
    private var dropped = false

    var project: Project? { didSet { UserDefaults.standard.set(project?.repo, forKey: "carProject") } }
    var focus = Focus.nothing
    var plan = Plan()
    // The conversation in hand.
    var session: Session?
    var transcript = Transcript()
    private var unsaved = false
    /// Verdicts chosen in the car on the round in hand, and the note that goes with them.
    var verdicts: [String: String] = [:]
    var note = ""
    // The pull request in hand.
    var pull: JSON = .null
    var row: PullSummary?
    var findings: JSON = []
    var catalog: JSON = .null
    var runs: [Session] = []

    init(controller: CPInterfaceController) {
        self.controller = controller
        super.init()
        controller.delegate = self
    }

    func start() {
        show()
        // Pairing, a revoked token and forgetting the connection all happen on the phone or on the server.
        watching = store.$client.map { $0 != nil }.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] connected in
            MainActor.assumeIsolated {
                guard let self, connected != self.paired else { return }
                self.paired = connected
                if !connected { self.leave() }
                else if self.project == nil, let repo = UserDefaults.standard.string(forKey: "carProject"), self.readable(repo) {
                    self.project = ProjectsModel.shared.project(repo) ?? Project(repo: repo)
                }
                self.show()
            }
        }
        Task { await store.restore() }
    }
    func stop() {
        watching = nil
        watcher?.cancel(); work?.cancel(); settle?.cancel(); fading?.cancel()
        ears.drop()
    }
    private func leave() {
        watcher?.cancel(); work?.cancel(); ears.drop()
        focus = .nothing; session = nil; transcript = Transcript(); phase = .ready
    }
    /// Whether this device's token may read a project: an admin token is held to none.
    private func readable(_ repo: String) -> Bool {
        guard let device = store.device else { return false }
        return device.isAdmin || device.repos.contains(repo)
    }

    // MARK: The voice screen

    /// Draws the voice screen for what is in hand. Its words cannot change once shown, so it is drawn again.
    func show() {
        let template = CPVoiceControlTemplate(voiceControlStates: states())
        if store.connected {
            var buttons = [CPBarButton(title: "Browse") { [weak self] _ in self?.browse() }]
            if case .nothing = focus {} else { buttons.append(CPBarButton(title: "Actions") { [weak self] _ in self?.actions() }) }
            template.trailingNavigationBarButtons = buttons
        }
        root = template
        drawn = titles
        controller.setRootTemplate(template, animated: false) { [weak self] _, _ in
            guard let self, self.root === template else { return }
            template.activateVoiceControlState(withIdentifier: self.phase.rawValue)
        }
    }
    /// Draws the screen again when what it says of what is in hand is out of date and nothing covers or uses it.
    func redraw() {
        if drawn != titles && controller.templates.count == 1 && phase == .ready { show() }
    }
    private func states() -> [CPVoiceControlState] {
        guard store.connected else {
            return [CPVoiceControlState(identifier: Phase.ready.rawValue, titleVariants: ["Open Briareus on your iPhone to connect", "Connect on your iPhone"],
                                        image: Self.symbol("iphone.gen3"), repeats: false)]
        }
        return Phase.allCases.map { phase in
            let state: CPVoiceControlState
            switch phase {
            case .ready: state = CPVoiceControlState(identifier: phase.rawValue, titleVariants: titles, image: Self.symbol(icon), repeats: false)
            case .listening: state = CPVoiceControlState(identifier: phase.rawValue, titleVariants: [invitation, "Listening…"], image: Self.moving("waveform"), repeats: true)
            case .working: state = CPVoiceControlState(identifier: phase.rawValue, titleVariants: ["Working…"], image: Self.symbol("ellipsis"), repeats: false)
            case .notice: state = CPVoiceControlState(identifier: phase.rawValue, titleVariants: [notice, "Done"], image: Self.symbol("checkmark.circle.fill"), repeats: false)
            }
            state.actionButtons = Array(buttons(phase).prefix(CPVoiceControlState.maximumActionButtonCount))
            return state
        }
    }
    /// The name of what is in hand with what it is doing, and shorter where the car has less room.
    private var titles: [String] {
        switch focus {
        case .conversation:
            guard let session else { return ["Conversation"] }
            return ["\(session.displayTitle) · \(CarText.status(session, asking: CarText.openQuestion(transcript.events) != nil))", session.displayTitle, "Conversation"]
        case .pull(let number):
            return [row?.title ?? pull["title"].string ?? "Pull request #\(number)", "Pull request #\(number)", "#\(number)"]
        case .issue(let issue): return [issue.title, "Issue #\(issue.number)", "#\(issue.number)"]
        case .nothing: return [project?.title ?? "Choose a project in Browse", "Briareus"]
        }
    }
    private var icon: String {
        switch focus {
        case .conversation: return "bubble.left.and.text.bubble.right.fill"
        case .pull: return "arrow.triangle.pull"
        case .issue: return "smallcircle.filled.circle"
        case .nothing: return "square.stack.3d.up.fill"
        }
    }
    private func buttons(_ phase: Phase) -> [CPButton] {
        func button(_ title: String, _ symbol: String, _ action: @escaping (CarAssistant) -> Void) -> CPButton {
            let button = CPButton(image: Self.symbol(symbol, size: 28)) { [weak self] _ in if let self { action(self) } }
            button.title = title
            return button
        }
        switch phase {
        case .ready, .notice: return talks == nil ? [] : [button("Talk", "mic.fill") { $0.talk() }]
        case .listening: return [button("Done", "checkmark") { $0.ears.finish() }, button("Cancel", "xmark") { $0.dropped = true; $0.ears.drop() }]
        case .working: return [button("Cancel", "xmark") { $0.abandon() }]
        }
    }
    /// What the Talk button dictates for what is in hand, or nil where there is nothing to say to it.
    private var talks: Purpose? {
        switch focus {
        case .conversation: return canMessage ? .message : nil
        case .pull: return offered.first { $0.id == "custom-feedback" }.map(Purpose.feedback)
        case .issue: return nil
        case .nothing: return project != nil && store.supports("start_session") ? .prompt : nil
        }
    }
    var canMessage: Bool { store.supports("message") && session.map { $0.status != "closed" } == true }

    func enter(_ phase: Phase) {
        self.phase = phase
        root?.activateVoiceControlState(withIdentifier: phase.rawValue)
        // CarPlay passes over a change that follows another too closely, which would leave the wrong buttons up.
        settle?.cancel()
        settle = Task { [weak self] in
            for _ in 0..<4 {
                guard (try? await Task.sleep(for: .seconds(1))) != nil, let self, let root = self.root else { return }
                if root.activeStateIdentifier == self.phase.rawValue { return }
                root.activateVoiceControlState(withIdentifier: self.phase.rawValue)
            }
        }
    }
    nonisolated func templateDidAppear(_ aTemplate: CPTemplate, animated: Bool) {
        // A state chosen while a list covered the voice screen only shows once the screen is back.
        Task { @MainActor in
            guard aTemplate === self.root else { return }
            self.root?.activateVoiceControlState(withIdentifier: self.phase.rawValue)
            self.redraw()
        }
    }

    /// Back to the voice screen from whichever list is showing.
    func home() async {
        guard controller.templates.count > 1 else { return }
        await withCheckedContinuation { done in controller.popToRootTemplate(animated: true) { _, _ in done.resume() } }
    }
    /// Shows for a moment what was done, in place of the name of what is in hand.
    func tell(_ words: String) {
        notice = words; phase = .notice
        show()
        fading?.cancel()
        fading = Task { [weak self] in
            guard (try? await Task.sleep(for: .seconds(4))) != nil, let self, self.phase == .notice else { return }
            self.enter(.ready)
            self.redraw()
        }
    }
    /// Something that went wrong, which stays up until it was seen.
    func warn(_ words: String) {
        let alert = CPAlertTemplate(titleVariants: [words, String(words.prefix(80))], actions: [
            CPAlertAction(title: "OK", style: .cancel) { [weak self] _ in self?.controller.dismissTemplate(animated: true) { _, _ in } },
        ])
        controller.presentTemplate(alert, animated: true) { _, _ in }
    }
    func ask(_ questions: [String], yes: String, no: String = "Cancel", destructive: Bool = false, then: @escaping () -> Void) {
        let alert = CPAlertTemplate(titleVariants: questions, actions: [
            CPAlertAction(title: yes, style: destructive ? .destructive : .default) { [weak self] _ in
                self?.controller.dismissTemplate(animated: true) { _, _ in then() }
            },
            CPAlertAction(title: no, style: .cancel) { [weak self] _ in self?.controller.dismissTemplate(animated: true) { _, _ in } },
        ])
        controller.presentTemplate(alert, animated: true) { _, _ in }
    }

    // MARK: Dictating

    private func talk() { if let purpose = talks { dictate(purpose) } }
    /// Listens, has the server write out what was said, shows it and waits for a yes.
    func dictate(_ purpose: Purpose) {
        guard phase == .ready || phase == .notice else { return }
        work?.cancel()
        turn += 1
        work = Task { [weak self, turn] in
            guard let self else { return }
            defer { if self.turn == turn { self.work = nil } }
            await self.home()
            if let refused = await self.store.voiceNotesOff() { self.warn(refused); return }
            guard self.store.canTranscribe, !Task.isCancelled else { return }
            self.dropped = false
            self.invitation = purpose.invitation; self.phase = .listening
            self.show()
            do {
                guard let audio = try await self.ears.listen() else {
                    if self.dropped || Task.isCancelled { self.enter(.ready) } else { self.tell("Nothing was heard") }
                    return
                }
                self.enter(.working)
                let text = try await self.store.transcribe(audio).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !Task.isCancelled else { return }
                self.enter(.ready)
                guard !text.isEmpty else { self.tell("Nothing was understood"); return }
                let words = purpose.confirmation
                self.ask(CarText.variants(text, before: words.before, after: "”?"), yes: words.yes, no: "Discard") { [weak self] in self?.accept(purpose, text) }
            } catch {
                guard !Task.isCancelled, !error.isCancellation else { return }
                self.enter(.ready)
                self.warn(errorText(error))
            }
        }
    }
    private func abandon() {
        work?.cancel(); work = nil
        enter(.ready)
    }
    private func accept(_ purpose: Purpose, _ text: String) {
        switch purpose {
        case .message: send(text)
        case .prompt: begin(text)
        case .rename: rename(CarText.title(text))
        case .note: note = text; tell("Noted. Complete the triage in Actions")
        case .feedback(let action): run(action, input: text)
        case .comment(let issue, let notPlanned): closeIssue(issue, notPlanned: notPlanned, comment: text)
        }
    }

    /// A write and what the screen says of it, which `write` answers (nil says nothing). One that failed without a
    /// refusal may have gone through all the same, so nothing is sent again by itself: what happened is looked at first.
    func perform(_ write: @escaping () async throws -> String?) {
        guard work == nil else { return }
        turn += 1
        work = Task { [weak self, turn] in
            guard let self else { return }
            defer { if self.turn == turn { self.work = nil } }
            await self.home()
            self.enter(.working)
            do {
                let done = try await write()
                guard !Task.isCancelled else { return }
                if let done { self.tell(done) } else { self.enter(.ready); self.redraw() }
            } catch {
                guard !Task.isCancelled, !error.isCancellation else { return }
                self.enter(.ready)
                var words = errorText(error)
                if (error as? APIError)?.isRefusal != true { words += " It may have gone through all the same. Check before trying again." }
                try? await self.refresh()
                self.redraw()
                self.warn(words)
            }
        }
    }
    /// The project's conversations read again, so the phone's lists show what the car did.
    private func resync(_ repo: String?) async {
        guard let repo, store.supports("sessions") else { return }
        try? await store.feed(repo).loadSessions(fresh: true)
    }

    // MARK: The conversation in hand

    func open(_ session: Session) {
        watcher?.cancel(); work?.cancel(); work = nil; ears.drop()
        focus = .conversation; self.session = session
        transcript = Transcript(); unsaved = false; verdicts = [:]; note = ""
        if let repo = session.repo, project?.repo != repo { project = ProjectsModel.shared.project(repo) ?? Project(repo: repo) }
        phase = .ready
        show()
        // Saved events show at once and move the cursor, so only what happened since is downloaded.
        transcript.append(.array(store.cache.lines("transcript:\(session.id)")))
        watcher = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self else { return }
                var failure: APIError?
                if self.work == nil {
                    failure = await reading { try await self.refresh() }
                    if failure == nil { self.redraw() }
                }
                if Task.isCancelled || failure?.unauthorized == true { return }
                if let failure, failure.kind != .cancelled { failures += 1 } else { failures = 0 }
                let delay = pollDelay(base: self.session?.isActive == true ? 2 : 7, failures: failures, retryAfter: failure?.retryAfter)
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
    }
    /// Reads what happened since the last event the phone saved, as the conversation's own screen does.
    func refresh() async throws {
        guard case .conversation = focus, let id = session?.id else {
            if case .pull(let number) = focus { try await load(pull: number) }
            return
        }
        let key = "transcript:\(id)"
        let answer = try await store.call("session", ["sessionId": .string(id), "since": JSON(transcript.cursor)])
        try Task.checkCancellation()
        guard session?.id == id else { return }
        if let next = Session(answer["session"]) { session = next }
        let events = answer["events"]
        transcript.append(events)
        if unsaved { unsaved = !store.cache.replace(transcript.json.items, key) }
        else if events.count > 0 { unsaved = !store.cache.append(events.items, key) }
    }

    func send(_ text: String) {
        guard let id = session?.id else { return }
        let done = CarText.sent(session)
        perform { [weak self] in
            try await self?.store.call("message", ["sessionId": .string(id), "text": .string(text)])
            try? await self?.refresh()
            return done
        }
    }
    /// Stop, close, reopen, the review loop, dropping a queued message: what is done to the conversation in hand.
    func change(_ operation: String, _ extra: JSON = [:], done: String) {
        guard let id = session?.id else { return }
        var args: JSON = ["sessionId": .string(id)]
        args.merge(extra)
        let repo = session?.repo
        perform { [weak self] in
            try await self?.store.call(operation, args)
            try? await self?.refresh()
            await self?.resync(repo)
            return done
        }
    }
    private func rename(_ title: String) {
        if !title.isEmpty { change("rename", ["title": .string(title)], done: "Renamed") }
    }
    func delete() {
        guard let id = session?.id else { return }
        let repo = session?.repo
        perform { [weak self] in
            guard let self else { return nil }
            try await self.store.call("delete", ["sessionId": .string(id)])
            self.store.cache.remove("transcript:\(id)")
            if let repo { self.store.feed(repo).drop(id) }
            self.put()
            return "The conversation is deleted"
        }
    }
    /// Puts down what is in hand, without drawing the screen.
    private func put() {
        watcher?.cancel()
        focus = .nothing; session = nil; transcript = Transcript(); pull = .null; row = nil; findings = []; runs = []
    }
    /// Puts down what is in hand.
    func close() {
        put(); phase = .ready
        show()
    }
    private func begin(_ prompt: String) {
        guard let project else { return }
        var args: JSON = ["repo": .string(project.repo), "prompt": .string(prompt)]
        if !plan.branch.isEmpty { args["branch"] = .string(plan.branch) }
        if let runtime = plan.runtime { args.merge(runtime.arguments) }
        start(args)
    }
    /// Starts a conversation and takes it in hand.
    private func start(_ args: JSON) {
        perform { [weak self] in
            guard let self else { return nil }
            let answer = try await self.store.call("start_session", args)
            guard let started = Session(answer["session"]) else { throw APIError(.nonJSON) }
            self.plan = Plan()
            self.open(started)
            await self.resync(started.repo)
            return nil
        }
    }
    func begin(on issue: IssueSummary) {
        guard let project else { return }
        start(["repo": .string(project.repo), "prompt": .string(issuePrompt(issue, repo: project.repo)), "activity": "issue"])
    }
    /// Completes the round held in the conversation: every finding with its verdict (optional when none was chosen) and
    /// the note, or, on somebody else's pull request, only takes it off the queue.
    func triage() {
        guard let session, let held = session.heldTriage else { return }
        var args: JSON = ["sessionId": .string(session.id)]
        args.merge(triageCompletion(held, picked: verdicts, note: note))
        let mine = triageTakesVerdicts(held)
        perform { [weak self] in
            guard let self else { return nil }
            let answer = try await self.store.call("complete_findings", args)
            self.verdicts = [:]; self.note = ""
            try? await self.refresh()
            await self.resync(session.repo)
            return mine ? triageOutcomeText(answer).text : "The review is off the queue"
        }
    }

    // MARK: The pull request or issue in hand

    func open(pull number: Int, row: PullSummary? = nil) {
        watcher?.cancel(); work?.cancel(); work = nil; ears.drop()
        focus = .pull(number); session = nil; pull = .null; self.row = row; findings = []; runs = []
        catalog = store.cache.value("actions")?["actions"] ?? .null
        phase = .ready
        show()
        watcher = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.load(pull: number)
                // Its state and what may be dictated to it are known only now.
                if !Task.isCancelled && self.controller.templates.count == 1 && self.phase == .ready { self.show() }
            } catch {
                if !Task.isCancelled, let words = failure(error) { self.warn(words) }
            }
        }
    }
    func open(issue: IssueSummary) {
        watcher?.cancel(); work?.cancel(); work = nil; ears.drop()
        focus = .issue(issue); session = nil
        phase = .ready
        show()
        if let repo = project?.repo, store.supports("sessions") { Task { try? await store.feed(repo).loadSessions() } }
    }
    /// The pull request, with what the board, the errand list and the project's conversations say of it.
    func load(pull number: Int) async throws {
        guard let project else { return }
        let args: JSON = ["repo": .string(project.repo), "pr": JSON(number)]
        let feed = store.feed(project.repo)
        let store = store
        let board = Task { if store.supports("pulls") { try? await feed.loadBoard() } }
        let sessions = Task { if store.supports("sessions") { try? await feed.loadSessions() } }
        let listed = Task { () -> JSON? in
            guard store.canManage, store.supports("actions"), let answer = try? await store.call("actions") else { return nil }
            store.cache.store(answer, "actions")
            return answer
        }
        let answer = try await store.call("pull", args)
        _ = await board.value; _ = await sessions.value
        let served = await listed.value
        try Task.checkCancellation()
        guard case .pull(number) = focus else { return }
        pull = answer["pr"]
        if feed.boardLoaded { row = pullsFind(PullSummary.parseList(feed.board["pulls"]), number) }
        if let served { catalog = served["actions"] }
        if feed.sessionsLoaded { runs = feed.sessions.filter { $0.pullNumber == number } }
        if store.supports("findings"), let found = try? await store.call("findings", args), case .pull(number) = focus { findings = found["findings"] }
    }
    /// The errands worth offering on the pull request in hand: an open one with a branch, to a token that may start them.
    var offered: [BoardAction] {
        guard case .pull = focus, store.canManage, pull["headRef"].string != nil, pull["state"].string == "open" else { return [] }
        return BoardAction.offered(catalog: catalog, pull: row, failedChecks: pull["checks"]["failed"].truncatedInt ?? 0)
            .filter { store.supports($0.operation) }
    }
    func run(_ action: BoardAction, input: String? = nil) {
        guard case .pull(let number) = focus, let project, let branch = pull["headRef"].string else { return }
        let args = action.arguments(repo: project.repo, number: number, branch: branch, input: input)
        perform { [weak self] in
            guard let self else { return nil }
            let answer = try await self.store.call(action.operation, args, timeout: action.timeoutMs.map { TimeInterval($0) / 1000 })
            await self.resync(project.repo)
            guard let started = Session(answer["session"]) else { return "\(action.label) started" }
            self.open(started)
            return nil
        }
    }
    func decide(_ key: String, _ decision: String?) {
        guard case .pull(let number) = focus, let project else { return }
        let args: JSON = ["repo": .string(project.repo), "pr": JSON(number), "key": .string(key), "decision": .string(orNull: decision)]
        perform { [weak self] in
            guard let answer = try await self?.store.call("finding_decision", args) else { return nil }
            self?.findings = answer["findings"]
            return decision == nil ? "The decision is cleared" : "The decision is recorded"
        }
    }
    func merge(_ method: String) {
        guard case .pull(let number) = focus, let project, let head = pull["headSha"].string, let base = pull["baseRef"].string else { return }
        let args: JSON = ["repo": .string(project.repo), "pr": JSON(number), "headSha": .string(head), "baseRef": .string(base), "method": .string(method)]
        perform { [weak self] in
            guard let self else { return nil }
            let answer = try await self.store.call("merge_pull", args)
            try? await self.store.feed(project.repo).loadBoard(fresh: true)
            try? await self.load(pull: number)
            return CarText.merged(answer, base: base)
        }
    }
    /// Closes the issue on GitHub, after a comment when one was dictated, and puts it down: the board no longer lists it.
    func closeIssue(_ issue: IssueSummary, notPlanned: Bool, comment: String? = nil) {
        guard let project else { return }
        let feed = store.feed(project.repo)
        let working = feed.sessions.contains { $0.isActive && issueRunMatches($0, issue: issue, repo: project.repo) }
        let question = "Close issue #\(issue.number) as \(notPlanned ? "not planned" : "completed")?"
        let why = CarText.closingIssue(issue, working: working, comment: comment != nil)
        var args: JSON = ["issue": JSON(issue.number), "repo": .string(project.repo), "reason": .string(notPlanned ? "not_planned" : "completed")]
        if let comment { args["comment"] = .string(comment) }
        ask(why.map { [question + " " + $0, question] } ?? [question], yes: "Close issue") { [weak self] in
            self?.perform { [weak self] in
                guard let self else { return nil }
                try await self.store.call("close_issue", args)
                if case .issue(let held) = self.focus, held.number == issue.number { self.put() }
                try? await feed.loadBoard(fresh: true)
                return "Issue #\(issue.number) is closed"
            }
        }
    }

    // MARK: Images

    static func symbol(_ name: String, size: CGFloat = 64, value: Double? = nil) -> UIImage {
        let configuration = UIImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        let image = value.flatMap { UIImage(systemName: name, variableValue: $0, configuration: configuration) }
            ?? UIImage(systemName: name, withConfiguration: configuration) ?? UIImage()
        return image.withTintColor(UIColor(Theme.accent), renderingMode: .alwaysOriginal)
    }
    /// A symbol filling up and emptying, for a state in which something is going on.
    static func moving(_ name: String) -> UIImage {
        let frames = [0.2, 0.4, 0.6, 0.8, 1, 0.8, 0.6, 0.4].map { value -> UIImage in
            // Every frame has to have the size of the fullest, or the symbol would jump as it fills.
            let full = symbol(name, value: 1)
            return UIGraphicsImageRenderer(size: full.size).image { _ in symbol(name, value: value).draw(in: CGRect(origin: .zero, size: full.size)) }
        }
        return UIImage.animatedImage(with: frames, duration: 1.2) ?? symbol(name)
    }
}
#endif
#endif
