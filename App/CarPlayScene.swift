#if os(iOS)
import CarPlay
import Combine
import SwiftUI

/// The car's screen. CarPlay lists the app as a voice-based conversational one, which iOS 26.4 introduced.
final class CarPlayScene: UIResponder, CPTemplateApplicationSceneDelegate {
    private var assistant: AnyObject?
    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect controller: CPInterfaceController) {
        guard #available(iOS 26.4, *) else { return }
        let assistant = CarAssistant(controller: controller)
        self.assistant = assistant
        assistant.start()
    }
    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didDisconnectInterfaceController controller: CPInterfaceController) {
        if #available(iOS 26.4, *) { (assistant as? CarAssistant)?.stop() }
        assistant = nil
    }
}

/// Briareus by voice. The screen that stays is the voice one: it carries the conversation, pull request or issue
/// in hand, messages to the agent are dictated to it and the agent's replies are read aloud from it. Lists only
/// choose what is in hand and what to do with it, two screens deep at most, which is as deep as CarPlay lets
/// an app of this kind go.
@available(iOS 26.4, *)
@MainActor
final class CarAssistant: NSObject, CPInterfaceControllerDelegate {
    enum Focus {
        case nothing, conversation, pull(Int), issue(IssueSummary)
    }
    enum Phase: String, CaseIterable { case ready, listening, working, speaking, confirm }
    /// What a dictation is for, which is what confirming it does.
    enum Purpose {
        case message, prompt, rename, note, feedback(BoardAction)
        var question: String {
            switch self {
            case .message: return "Send it?"
            case .prompt: return "Start a paid conversation with it?"
            case .rename: return "Rename the conversation to it?"
            case .note: return "Keep it as the note for the fix session?"
            case .feedback: return "Start a paid session with this feedback?"
            }
        }
        var invitation: String {
            switch self {
            case .message: return "Your message."
            case .prompt: return "What should the agent work on?"
            case .rename: return "The new name."
            case .note: return "Your note for the fix session."
            case .feedback(let action): return action.input?.label ?? "Your feedback."
            }
        }
    }
    struct Draft { let purpose: Purpose; let text: String }
    /// What a new conversation starts on; nil is the project's own.
    struct Plan { var branch = ""; var runtime: RuntimeChoice?; var catalog: RuntimeCatalog? }

    let store = AppStore.shared
    let voice = CarVoice()
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
    private var draft: Draft?
    /// True once the listening in hand was dropped by its button, which is not the same as hearing nothing.
    private var dropped = false

    var project: Project? { didSet { UserDefaults.standard.set(project?.repo, forKey: "carProject") } }
    var focus = Focus.nothing
    var plan = Plan()
    // The conversation in hand.
    var session: Session?
    var transcript = Transcript()
    private var unsaved = false
    /// The last event said aloud or passed over.
    private var announced = 0
    var announces: Bool {
        get { UserDefaults.standard.object(forKey: "carAnnounces") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "carAnnounces") }
    }
    /// Verdicts chosen in the car on the round in hand, and the note that goes with them.
    var verdicts: [String: String] = [:]
    var note = ""
    // The pull request in hand.
    var pull: JSONValue = .null
    var row: PullSummary?
    var findings: [JSONValue] = []
    var catalog: [JSONValue] = []
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
            guard let self, connected != self.paired else { return }
            self.paired = connected
            if !connected { self.leave() }
            self.show()
            if connected { Task { await self.greet() } }
        }
        Task { await store.restore() }
    }
    func stop() {
        watching = nil
        watcher?.cancel(); work?.cancel(); settle?.cancel()
        voice.silence()
    }
    private func leave() {
        watcher?.cancel(); work?.cancel(); voice.silence()
        focus = .nothing; session = nil; transcript = Transcript(); draft = nil; phase = .ready
    }
    private func greet() async {
        if project == nil, let repo = UserDefaults.standard.string(forKey: "carProject"), store.device?.repos.contains(repo) == true {
            project = Project(repo: repo); show()
        }
        guard let project else { await say("Briareus. Choose a project in Browse."); return }
        var words = "Briareus. \(project.title)."
        if let sessions: SessionList = try? await store.call("sessions", ["repo": .string(project.repo)]) {
            await store.cache.store(sessions.sessions, for: "sessions:\(project.repo)")
            let running = sessions.sessions.filter(\.isActive).count, held = Session.holdingFindings(sessions.sessions).count
            if running > 0 { words += " \(Spoken.count(running, "conversation")) running." }
            if held > 0 && store.supports("complete_findings") { words += " Findings wait in \(Spoken.count(held, "conversation"))." }
        }
        guard phase == .ready, case .nothing = focus else { return }
        await say(words)
    }

    // MARK: The voice screen

    /// Draws the voice screen for what is in hand. Its titles cannot change once shown, so it is drawn again.
    func show() {
        let template = CPVoiceControlTemplate(voiceControlStates: states())
        if store.client != nil {
            var buttons = [CPBarButton(title: "Browse") { [weak self] _ in self?.browse() }]
            if case .nothing = focus {} else { buttons.append(CPBarButton(title: "Actions") { [weak self] _ in self?.actions() }) }
            template.trailingNavigationBarButtons = buttons
        }
        root = template
        controller.setRootTemplate(template, animated: false) { [weak self] _, _ in
            guard let self, self.root === template else { return }
            template.activateVoiceControlState(withIdentifier: self.phase.rawValue)
        }
    }
    private func states() -> [CPVoiceControlState] {
        guard store.client != nil else {
            return [CPVoiceControlState(identifier: Phase.ready.rawValue, titleVariants: ["Open Briareus on your iPhone to connect", "Connect on your iPhone"],
                                        image: Self.symbol("iphone.gen3"), repeats: false)]
        }
        return Phase.allCases.map { phase in
            let state: CPVoiceControlState
            switch phase {
            case .ready: state = CPVoiceControlState(identifier: phase.rawValue, titleVariants: titles, image: Self.symbol(icon), repeats: false)
            case .listening: state = CPVoiceControlState(identifier: phase.rawValue, titleVariants: ["Listening…"], image: Self.moving("waveform"), repeats: true)
            case .working: state = CPVoiceControlState(identifier: phase.rawValue, titleVariants: ["Working…"], image: Self.symbol("ellipsis"), repeats: false)
            case .speaking: state = CPVoiceControlState(identifier: phase.rawValue, titleVariants: titles, image: Self.moving("speaker.wave.3.fill"), repeats: true)
            case .confirm: state = CPVoiceControlState(identifier: phase.rawValue, titleVariants: ["Is that right?"], image: Self.symbol("questionmark.bubble.fill"), repeats: false)
            }
            state.actionButtons = Array(buttons(phase).prefix(CPVoiceControlState.maximumActionButtonCount))
            return state
        }
    }
    private var titles: [String] {
        switch focus {
        case .conversation: return [session?.displayTitle ?? "Conversation", "Conversation"]
        case .pull(let number): return [row?.title ?? pull["title"].string ?? "Pull request #\(number)", "Pull request #\(number)", "#\(number)"]
        case .issue(let issue): return [issue.title, "Issue #\(issue.number)", "#\(issue.number)"]
        case .nothing: return [project?.title ?? "Briareus", "Briareus"]
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
        case .ready:
            var buttons: [CPButton] = []
            if talks != nil { buttons.append(button("Talk", "mic.fill") { $0.talk() }) }
            if reads { buttons.append(button("Read", "speaker.wave.2.fill") { $0.read() }) }
            return buttons
        case .listening: return [button("Done", "checkmark") { $0.voice.finish() }, button("Cancel", "xmark") { $0.dropped = true; $0.voice.drop() }]
        case .working: return [button("Cancel", "xmark") { $0.abandon() }]
        case .speaking:
            var buttons = [button("Stop", "stop.fill") { $0.voice.stopSpeaking() }]
            if talks != nil { buttons.append(button("Talk", "mic.fill") { $0.talk() }) }
            return buttons
        case .confirm: return [button("Yes", "checkmark") { $0.confirm() }, button("No", "xmark") { $0.discard() }]
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
    private var reads: Bool { if case .nothing = focus { return false }; return true }
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
        Task { @MainActor in if aTemplate === self.root { self.root?.activateVoiceControlState(withIdentifier: self.phase.rawValue) } }
    }

    /// Back to the voice screen from whichever list is showing.
    func home() async {
        guard controller.templates.count > 1 else { return }
        await withCheckedContinuation { done in controller.popToRootTemplate(animated: true) { _, _ in done.resume() } }
    }
    /// Says it. The screen shows that it is speaking unless it is `beside` what the screen is asking.
    func say(_ words: String, beside: Bool = false) async {
        guard !words.isEmpty, !voice.isListening else { return }
        if !beside { enter(.speaking) }
        await voice.speak(words)
        if phase == .speaking { enter(draft != nil ? .confirm : .ready) }
    }

    // MARK: Dictating

    private func talk() { if let purpose = talks { dictate(purpose) } }
    /// Listens, has the server write out what was said, reads it back and waits for a yes.
    func dictate(_ purpose: Purpose) {
        guard phase == .ready || phase == .speaking else { return }
        work?.cancel()
        turn += 1
        work = Task { [weak self, turn] in
            guard let self else { return }
            defer { if self.turn == turn { self.work = nil } }
            await self.home()
            self.draft = nil
            if let refused = await self.store.voiceNotesOff() { await self.say(refused); return }
            guard self.store.canTranscribe else { await self.say("This device is read only."); return }
            await self.say(purpose.invitation)
            guard !Task.isCancelled else { return }
            self.dropped = false
            self.enter(.listening)
            do {
                guard let audio = try await self.voice.listen() else {
                    self.enter(.ready)
                    if !self.dropped && !Task.isCancelled { await self.say("I did not hear anything.") }
                    return
                }
                self.enter(.working)
                let text = try await self.store.transcribe(audio).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !Task.isCancelled else { return }
                guard !text.isEmpty else { self.enter(.ready); await self.say("I did not catch that."); return }
                self.draft = Draft(purpose: purpose, text: text)
                self.enter(.confirm)
                // Read back beside the question, so that yes can be answered before the reading ends.
                Task { await self.say("You said: \(text) \(purpose.question)", beside: true) }
            } catch {
                guard !Task.isCancelled else { return }
                self.enter(.ready)
                await self.say(error.localizedDescription)
            }
        }
    }
    private func abandon() {
        work?.cancel(); work = nil; draft = nil
        enter(.ready)
    }
    private func discard() {
        voice.stopSpeaking(); draft = nil
        enter(.ready)
    }
    private func confirm() {
        guard let draft, work == nil else { return }
        voice.stopSpeaking()
        self.draft = nil
        switch draft.purpose {
        case .message: send(draft.text)
        case .prompt: begin(draft.text)
        case .rename: rename(Spoken.title(draft.text))
        case .note: note = draft.text; enter(.ready); Task { await say("Noted. Complete the triage from Actions.") }
        case .feedback(let action): run(action, input: draft.text)
        }
    }

    /// A write and what is said of it. One that failed without a refusal may have gone through all the same,
    /// so nothing is sent again by itself: what happened is looked at first.
    func perform(_ done: String?, _ write: @escaping () async throws -> Void) {
        guard work == nil else { return }
        turn += 1
        work = Task { [weak self, turn] in
            guard let self else { return }
            defer { if self.turn == turn { self.work = nil } }
            await self.home()
            self.enter(.working)
            do {
                try await write()
                guard !Task.isCancelled else { return }
                self.enter(.ready)
                if let done { await self.say(done) }
            } catch {
                guard !Task.isCancelled else { return }
                self.enter(.ready)
                var words = error.localizedDescription
                if case .http(400..<500, _, _)? = error as? APIError {} else { words += " It may have gone through all the same. Check before trying again." }
                try? await self.refresh()
                await self.say(words)
            }
        }
    }

    // MARK: The conversation in hand

    func open(_ session: Session) {
        watcher?.cancel(); work?.cancel(); work = nil; voice.silence()
        focus = .conversation; self.session = session
        transcript = Transcript(); unsaved = false; announced = 0; draft = nil; verdicts = [:]; note = ""
        if let repo = session.repo, project?.repo != repo { project = Project(repo: repo) }
        phase = .ready
        show()
        watcher = Task { [weak self] in
            guard let self else { return }
            let saved: [Event] = await self.store.cache.lines("transcript:\(session.id)")
            guard !Task.isCancelled else { return }
            self.transcript.append(saved)
            var opened = false, failures = 0
            while !Task.isCancelled {
                var delay: Double = self.session?.isActive == true ? 2 : 7
                do {
                    if self.work == nil { try await self.refresh() }
                    failures = 0
                    if !opened {
                        opened = true
                        self.announced = self.transcript.cursor
                        var words = self.session.map(Spoken.status) ?? ""
                        if let question = Spoken.openQuestion(self.transcript.events) { words += " " + Spoken.say([question]) }
                        if self.phase == .ready { await self.say(words) }
                    } else { await self.announce() }
                } catch {
                    if Task.isCancelled || error is CancellationError { return }
                    failures += 1
                    if (error as? APIError)?.isUnauthorized == true { return }
                    if !opened, failures == 1, self.phase == .ready { await self.say(error.localizedDescription) }
                    delay = max(min(60, pow(2, Double(min(failures, 6)))), (error as? APIError)?.retryDelay ?? 0)
                }
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
        let result: SessionResult = try await store.call("session", ["sessionId": .string(id), "since": .number(Double(transcript.cursor))])
        try Task.checkCancellation()
        guard session?.id == id else { return }
        let renamed = result.session.displayTitle != session?.displayTitle
        let events = result.events ?? []
        session = result.session; transcript.append(events)
        if unsaved { unsaved = !(await store.cache.replace(transcript.events, in: key)) }
        else if !events.isEmpty { unsaved = !(await store.cache.append(events, to: key)) }
        if renamed && controller.templates.count == 1 && phase == .ready { show() }
    }
    /// Says what the agent said since the last time, unless something else is being said or heard.
    private func announce() async {
        let fresh = transcript.events.filter { $0.seq > announced && $0.kind != "user" }
        guard !fresh.isEmpty else { return }
        guard announces else { announced = transcript.cursor; return }
        guard phase == .ready, work == nil else { return }
        announced = transcript.cursor
        // A turn that only ran tools so far has nothing to say yet.
        guard fresh.contains(where: { $0.visible && !TranscriptRow.toolKinds.contains($0.kind) && !["stderr", "claude"].contains($0.kind) }) else { return }
        await say(Spoken.say(fresh))
    }
    private func read() {
        Task {
            switch focus {
            case .conversation:
                let latest = Spoken.latest(transcript.events)
                announced = transcript.cursor
                await say(latest.isEmpty ? (session.map(Spoken.status) ?? "") + " Nothing was said yet." : Spoken.say(latest))
            case .pull(let number): await say(Spoken.pull(number: number, row: row, details: pull, review: review))
            case .issue(let issue): await say(Spoken.issue(issue))
            case .nothing: break
            }
        }
    }
    var review: String? {
        let standing = row.map { $0.reviewers.map { JSONValue.object(["state": .string($0.state)]) } } ?? pull["reviews"].array
        return ReviewStatus(decision: row?.reviewDecision, reviews: standing)?.text
    }

    func send(_ text: String) {
        guard let id = session?.id else { return }
        let live = session?.isActive == true ? (session?.liveInput == true ? "Sent into the running turn." : "Queued for the next turn.") : "Sent."
        perform(live) { [weak self] in
            let _: JSONValue = try await self?.store.call("message", ["sessionId": .string(id), "text": .string(text)]) ?? .null
            try? await self?.refresh()
        }
    }
    /// Stop, close, reopen, the review loop, dropping a queued message: what is done to the conversation in hand.
    func change(_ operation: String, _ extra: [String: JSONValue] = [:], done: String) {
        guard let id = session?.id else { return }
        perform(done) { [weak self] in
            let _: JSONValue = try await self?.store.call(operation, ["sessionId": .string(id)].merging(extra) { $1 }) ?? .null
            try? await self?.refresh()
        }
    }
    private func rename(_ title: String) {
        guard !title.isEmpty else { enter(.ready); return }
        change("rename", ["title": .string(title)], done: "Renamed to \(title).")
    }
    func delete() {
        guard let id = session?.id else { return }
        perform("The conversation is deleted.") { [weak self] in
            let _: JSONValue = try await self?.store.call("delete", ["sessionId": .string(id)]) ?? .null
            await self?.store.cache.remove("transcript:\(id)")
            self?.close()
        }
    }
    /// Puts down what is in hand.
    func close() {
        watcher?.cancel(); voice.stopSpeaking()
        focus = .nothing; session = nil; transcript = Transcript(); draft = nil; pull = .null; row = nil; findings = []; runs = []
        show()
    }
    private func begin(_ prompt: String) {
        guard let project else { return }
        var args: [String: JSONValue] = ["repo": .string(project.repo), "prompt": .string(prompt)]
        if !plan.branch.isEmpty { args["branch"] = .string(plan.branch) }
        if let runtime = plan.runtime { args.merge(runtime.arguments) { $1 } }
        perform(nil) { [weak self] in
            guard let result: SessionResult = try await self?.store.call("start_session", args) else { return }
            self?.plan = Plan()
            self?.open(result.session)
        }
    }
    func begin(on issue: IssueSummary) {
        guard let project else { return }
        perform(nil) { [weak self] in
            guard let result: SessionResult = try await self?.store.call("start_session", ["repo": .string(project.repo), "prompt": .string(issue.prompt(repo: project.repo))]) else { return }
            self?.open(result.session)
        }
    }
    func triage() {
        guard let session, let triage = session.heldTriage else { return }
        let mine = triage["mine"].bool ?? true
        var args: [String: JSONValue] = ["sessionId": .string(session.id)]
        let sent: [JSONValue] = !mine ? [] : triage["findings"].array.compactMap { finding in
            guard let key = finding["key"].string else { return nil }
            let chosen = verdicts[key] ?? triage["drafts"]["verdicts"][key]["decision"].string ?? ""
            var verdict: [String: JSONValue] = ["key": .string(key), "decision": .string(chosen.isEmpty ? "optional" : chosen)]
            if let reason = triage["drafts"]["verdicts"][key]["reason"].string, !reason.isEmpty { verdict["reason"] = .string(reason) }
            return .object(verdict)
        }
        if !sent.isEmpty { args["verdicts"] = .array(sent) }
        if mine, !note.isEmpty { args["note"] = .string(note) }
        perform(mine ? "The triage is complete." : "The findings are cleared.") { [weak self] in
            let _: JSONValue = try await self?.store.call("complete_findings", args) ?? .null
            self?.verdicts = [:]; self?.note = ""
            try? await self?.refresh()
        }
    }

    // MARK: The pull request or issue in hand

    func open(pull number: Int, row: PullSummary? = nil) {
        watcher?.cancel(); work?.cancel(); work = nil; voice.silence()
        focus = .pull(number); session = nil; pull = .null; self.row = row; findings = []; runs = []; draft = nil
        phase = .ready
        show()
        watcher = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.load(pull: number)
                guard !Task.isCancelled else { return }
                // Its name and what may be dictated to it are known only now.
                if self.controller.templates.count == 1 && self.phase == .ready { self.show() }
                if self.phase == .ready { await self.say(Spoken.pull(number: number, row: self.row, details: self.pull, review: self.review)) }
            } catch {
                if !Task.isCancelled && self.phase == .ready { await self.say(error.localizedDescription) }
            }
        }
    }
    func open(issue: IssueSummary) {
        watcher?.cancel(); work?.cancel(); work = nil; voice.silence()
        focus = .issue(issue); session = nil; draft = nil
        phase = .ready
        show()
        Task { await say(Spoken.issue(issue)) }
    }
    func load(pull number: Int) async throws {
        guard let project else { return }
        let args: [String: JSONValue] = ["repo": .string(project.repo), "pr": .number(Double(number))]
        let repo: [String: JSONValue] = ["repo": .string(project.repo)]
        async let rows: JSONValue? = read("pulls", repo)
        async let listed: JSONValue? = read(store.canManage ? "actions" : "", [:])
        async let sessions: SessionList? = read("sessions", repo)
        let result: JSONValue = try await store.call("pull", args)
        let (board, served, all) = await (rows, listed, sessions)
        try Task.checkCancellation()
        guard case .pull(number) = focus else { return }
        pull = result["pr"]
        if let board { row = board["pulls"].array.compactMap(PullSummary.init).first { $0.number == number } }
        if let served { catalog = served["actions"].array }
        if let all { runs = all.sessions.filter { $0.pullNumber == number } }
        if store.supports("findings"), let found: JSONValue = try? await store.call("findings", args) { findings = found["findings"].array }
    }
    private func read<T: Decodable>(_ name: String, _ args: [String: JSONValue]) async -> T? {
        store.supports(name) ? try? await store.call(name, args) : nil
    }
    /// The errands worth offering on the pull request in hand.
    var offered: [BoardAction] {
        guard case .pull = focus, store.canManage, pull["headRef"].string != nil,
              pull == .null ? row != nil : pull["state"].string == "open" else { return [] }
        return BoardAction.offered(catalog: catalog, pull: row, failedChecks: Int(pull["checks"]["failed"].double ?? 0))
            .filter { store.supports($0.operation) }
    }
    func run(_ action: BoardAction, input: String? = nil) {
        guard case .pull(let number) = focus, let project, let branch = pull["headRef"].string else { return }
        perform(nil) { [weak self] in
            guard let result: SessionResult = try await self?.store.call(action.operation, action.arguments(repo: project.repo, number: number, branch: branch, input: input),
                                                                           timeout: action.timeout) else { return }
            self?.open(result.session)
        }
    }
    func decide(_ key: String, _ decision: String?) {
        guard case .pull(let number) = focus, let project else { return }
        perform(decision.map { "Marked \($0 == "dismissed" ? "dismissed" : $0)." } ?? "The decision is cleared.") { [weak self] in
            guard let result: JSONValue = try await self?.store.call("finding_decision", ["repo": .string(project.repo), "pr": .number(Double(number)),
                                                                                           "key": .string(key), "decision": decision.map(JSONValue.string) ?? .null]) else { return }
            self?.findings = result["findings"].array
        }
    }
    func merge(_ method: String) {
        guard case .pull(let number) = focus, let project, let head = pull["headSha"].string, let base = pull["baseRef"].string else { return }
        perform("Pull request \(number) is merged into \(base).") { [weak self] in
            let _: JSONValue = try await self?.store.call("merge_pull", ["repo": .string(project.repo), "pr": .number(Double(number)),
                                                                          "headSha": .string(head), "baseRef": .string(base), "method": .string(method)]) ?? .null
            try? await self?.load(pull: number)
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
