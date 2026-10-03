import Foundation

/// One spoken conversation about one project, with GPT-Live or GPT-Realtime as Settings choose: the WebRTC call, the
/// captions, and the tools called, each held to that project. It outlives the screen that started it, so it goes on
/// from any tab and with the phone locked, and ends when the user ends it or after a silence. What it cost and how
/// long it ran are kept, to compare the two models.
@MainActor
final class VoiceSession: ObservableObject {
    static let shared = VoiceSession()

    enum Phase: Equatable { case off, connecting, live, closing }
    struct Line: Identifiable, Equatable {
        let id = UUID()
        var user: Bool
        var text: String
    }
    /// A tool call, as the screen lists it.
    struct Step: Identifiable, Equatable {
        enum State: Equatable { case running, waiting, done, failed(String) }
        let id = UUID()
        var tool: VoiceTool?
        var name: String
        var args: JSON
        var state: State
    }

    @Published private(set) var phase = Phase.off
    /// The project the conversation is about; nil before the first one.
    @Published private(set) var repo: String?
    /// The model the conversation is with.
    @Published private(set) var engine = VoiceEngine.live
    /// The voice is saying something, as its transcript arrives.
    @Published private(set) var speaking = false
    @Published private(set) var muted = false
    @Published private(set) var lines: [Line] = []
    @Published private(set) var steps: [Step] = []
    @Published private(set) var started: Date?
    /// When the conversation ended; with `started`, how long it ran.
    @Published private(set) var finished: Date?
    /// What the conversation has cost so far, from the usage OpenAI reports.
    @Published private(set) var cost = VoiceCost()
    /// Why the last conversation failed or ended by itself.
    @Published private(set) var notice: String?

    private var call: LiveCall?
    private var reader: Task<Void, Never>?
    private var hush: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var lastActivity = Date()
    /// How many pieces of the user's speech have been heard: a yes must come after the read-back it answers.
    private var heard = 0
    /// The function calls of each response, answered together once the response is done: by GPT-Live's delegation
    /// id, or by GPT-Realtime's response id.
    private var calls: [String: [Task<(id: String, output: String), Never>]] = [:]
    private var seenCalls: Set<String> = []
    /// The changes read back to the user, with how much had been heard at the time.
    private var readBacks: [String: Int] = [:]
    /// The merges read back, by the same key: the call pinned to the head the user heard about, and its base.
    private var merges: [String: (arguments: JSON, base: String)] = [:]
    private var sequence = 0

    private init() {}

    var isOn: Bool { phase != .off }
    /// How long the conversation has run, or ran, at `now`.
    func elapsed(at now: Date = Date()) -> Double {
        guard let started else { return 0 }
        return (finished ?? now).timeIntervalSince(started)
    }

    func start(_ project: Project) {
        guard phase == .off else { return }
        notice = nil
        let settings = VoiceSettings.shared
        let key: String
        do {
            guard let saved = try settings.key() else { notice = "Add your OpenAI API key in Settings › Voice."; return }
            key = saved
        } catch { notice = error.localizedDescription; return }
        phase = .connecting
        repo = project.repo
        engine = settings.engine
        lines = []; steps = []; heard = 0; calls = [:]; seenCalls = []; readBacks = [:]; merges = [:]; muted = false
        started = nil; finished = nil
        cost = VoiceCost(engine: engine, backend: settings.backendModel)
        let call = LiveCall()
        self.call = call
        let named = project.title == project.repo ? project.repo : "\(project.title) (\(project.repo))"
        let session = engine == .live
            ? Voice.liveSession(voice: settings.voice, backend: settings.backendModel, project: named)
            : Voice.realtimeSession(voice: settings.voice, project: named)
        let engine = self.engine
        reader = Task { [weak self] in
            do {
                let events = try await call.open(key: key, engine: engine, session: session)
                for try await event in events { self?.handle(event) }
                self?.ended(nil)
            } catch {
                self?.ended(errorText(error))
            }
        }
    }

    /// Ends the conversation. GPT-Live is asked to close, which settles its bill, and let go once it has or after a
    /// few seconds; hanging up the WebRTC call ends a GPT-Realtime session.
    func stop(reason: String? = nil) {
        guard phase == .connecting || phase == .live else { return }
        if let reason { notice = reason }
        phase = .closing
        speaking = false
        guard engine == .live else { ended(nil); return }
        call?.send(["type": "session.close", "event_id": .string(nextID())])
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if self?.phase == .closing { self?.ended(nil) }
        }
    }

    func toggleMute() {
        muted.toggle()
        call?.mute(muted)
    }

    private func ended(_ failure: String?) {
        guard phase != .off else { return }
        if let failure, phase != .closing { notice = failure }
        reader?.cancel(); reader = nil
        watchdog?.cancel(); watchdog = nil
        calls.values.joined().forEach { $0.cancel() }; calls = [:]
        hush?.cancel(); hush = nil
        call?.close(); call = nil
        speaking = false
        if let started {
            let now = Date()
            finished = now
            let elapsed = now.timeIntervalSince(started)
            let seconds = engine == .live ? max(cost.seconds, elapsed) : elapsed
            VoiceHistory.shared.add(VoiceRecord(engine: engine, seconds: seconds, dollars: cost.dollars(elapsed: elapsed), date: now))
        }
        phase = .off
    }

    private func nextID() -> String { sequence += 1; return "briareus_\(sequence)" }
    private func touch() { lastActivity = Date() }

    // MARK: Events

    private func handle(_ event: JSON) {
        switch event["type"].string {
        // Both
        case "session.started", "session.created":
            guard phase == .connecting else { return }
            phase = .live
            started = Date()
            touch()
            watch()
        case "error":
            notice = event["error"]["message"].string ?? "\(engine.title) reported an error."
        // GPT-Live
        case "session.input_transcript.delta":
            heard += 1
            caption(user: true, event["delta"].string)
            touch()
        case "session.output_transcript.delta":
            caption(user: false, event["delta"].string)
            talking()
            touch()
        case "response.event":
            backend(event["delegation_id"].string ?? "", event["event"])
        case "session.usage.updated":
            cost.voice(event)
        case "session.closed":
            cost.voice(event)
            ended(nil)
        // GPT-Realtime
        case "input_audio_buffer.committed":
            // A piece of the user's speech the model hears, transcribed or not.
            heard += 1
            touch()
        case "conversation.item.input_audio_transcription.completed":
            caption(user: true, event["transcript"].string)
            cost.add(transcription: event["usage"])
            touch()
        case "response.output_audio_transcript.delta":
            caption(user: false, event["delta"].string)
            talking()
            touch()
        case "response.output_item.done":
            called(event["item"], in: event["response_id"].string ?? "")
        case "response.done":
            cost.add(response: event["response"]["usage"])
            // A response cut off by the user does not go on by itself; what its calls did is still told.
            let response = event["response"]
            answer(response["id"].string ?? "", goOn: response["status"].string == "completed" || response["id"].isNull)
        default:
            break
        }
    }

    /// WebRTC plays the voice itself; it reads as speaking while its words keep coming.
    private func talking() {
        speaking = true
        hush?.cancel()
        hush = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { self?.speaking = false }
        }
    }

    /// Ends the conversation after the silence the settings allow, as either model bills a conversation left open.
    private func watch() {
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, self.phase == .live else { continue }
                if self.speaking || !self.calls.isEmpty { self.touch(); continue }
                let minutes = VoiceSettings.shared.idleMinutes
                if minutes > 0, Date().timeIntervalSince(self.lastActivity) > Double(minutes * 60) {
                    self.stop(reason: "Ended after \(minutes) minute\(minutes == 1 ? "" : "s") of silence.")
                }
            }
        }
    }

    private func caption(user: Bool, _ delta: String?) {
        guard let delta, !delta.isEmpty else { return }
        if let last = lines.last, last.user == user {
            lines[lines.count - 1].text += delta
        } else {
            lines.append(Line(user: user, text: delta.trimmingCharacters(in: .whitespaces)))
            if lines.count > 60 { lines.removeFirst(lines.count - 60) }
        }
    }

    // MARK: Tools

    /// GPT-Live's backend event: a function call starts running at once; when the response completes, every call it
    /// made is answered and the backend goes on.
    private func backend(_ delegation: String, _ event: JSON) {
        switch event["type"].string {
        case "response.output_item.done":
            called(event["item"], in: delegation)
        case "response.completed", "response.done":
            cost.backend(event["response"])
            answer(delegation, goOn: true)
        case "response.failed", "response.incomplete":
            calls[delegation] = nil
        default:
            break
        }
    }

    /// A finished output item: a function call starts running at once, under the response it belongs to.
    private func called(_ item: JSON, in response: String) {
        guard item["type"].string == "function_call", let id = item["call_id"].string, let name = item["name"].string,
              seenCalls.insert(id).inserted else { return }
        let args = item["arguments"].string.flatMap(JSON.parse) ?? [:]
        let step = Step(tool: VoiceTool(rawValue: name), name: name, args: args, state: .running)
        steps.append(step)
        touch()
        calls[response, default: []].append(Task { (id, await self.run(step)) })
    }

    /// Once a response is done, answers every call it made, each model in its own words, and has it go on.
    private func answer(_ response: String, goOn: Bool) {
        guard let pending = calls[response], !pending.isEmpty, let call else { return }
        calls[response] = nil
        let live = engine == .live
        Task {
            var outputs: [(id: String, output: String)] = []
            for call in pending { outputs.append(await call.value) }
            guard self.call === call else { return }
            for (id, output) in outputs {
                call.send(["type": live ? "response.item.create" : "conversation.item.create", "event_id": .string(nextID()),
                           "item": ["type": "function_call_output", "call_id": .string(id), "output": .string(output)]])
            }
            if goOn { call.send(["type": "response.create", "event_id": .string(nextID())]) }
        }
    }

    /// Runs one tool call and answers with what the model should know, as JSON text.
    private func run(_ step: Step) async -> String {
        func finish(_ state: Step.State, _ answer: JSON) -> String {
            if let i = steps.firstIndex(where: { $0.id == step.id }) { steps[i].state = state }
            touch()
            return answer.serialized()
        }
        guard let tool = step.tool else { return finish(.failed("Unknown tool"), ["error": .string("There is no tool named \(step.name).")]) }
        guard let repo else { return finish(.failed("No project"), ["error": "The conversation has no project."]) }
        let key = Self.readBackKey(tool, step.args)
        var plan = tool.plan(step.args, repo: repo)
        // A change goes through only on a yes the user said after hearing it read back; the model's word is not enough.
        if case .call = plan, tool.changes, !(readBacks[key].map { heard > $0 } ?? false) {
            var unconfirmed = step.args
            unconfirmed["confirmed"] = false
            plan = tool.plan(unconfirmed, repo: repo)
        }
        if tool == .mergePullRequest {
            if case .refuse(let why) = plan { return finish(.failed(why), ["error": .string(why)]) }
            let (state, answer) = await merge(step, plan: plan, key: key, repo: repo)
            return finish(state, answer)
        }
        switch plan {
        case .refuse(let why):
            return finish(.failed(why), ["error": .string(why)])
        case .confirm(let readBack):
            readBacks[key] = heard
            return finish(.waiting, ["needs_confirmation": true, "read_back": .string(readBack),
                                     "next": "Read this back to the user. Call again with confirmed=true only if they say yes."])
        case .call(var arguments):
            guard Store.shared.supports(tool.operation) else {
                return finish(.failed("Not allowed"), ["error": "This device's token cannot do that on the server."])
            }
            do {
                // A conversation named by id is acted on only when it is the project's.
                if tool.namesConversation, let id = arguments["sessionId"].string,
                   !Voice.owns(try await Store.shared.call("sessions", ["repo": .string(repo)]), session: id) {
                    let why = "That conversation is not one of this project's."
                    return finish(.failed(why), ["error": .string(why)])
                }
                if tool == .workOnIssue, let number = arguments["issue"].int {
                    let board = try await Store.shared.call("pulls", ["repo": .string(repo)])
                    guard let start = Voice.issueStart(board, number: number, repo: repo) else {
                        let why = "Issue #\(number) is not open on this project."
                        return finish(.failed(why), ["error": .string(why)])
                    }
                    arguments = start
                }
                var answer = try await Store.shared.call(tool.operation, arguments, timeout: 60)
                // A pull request's description is read apart from its files.
                if tool == .readPullRequest, Store.shared.supports("pull_description"),
                   let body = (try? await Store.shared.call("pull_description", arguments))?["pr"]["body"].string {
                    answer["description"] = .string(body)
                }
                // An issue's comments are on its timeline, oldest first: its pages are read up to a few, for the latest.
                if tool == .readIssue, Store.shared.supports("issue_timeline") {
                    var rows: [JSON] = [], read = arguments
                    read["page"] = 1
                    for _ in 0..<Voice.issueTimelinePages {
                        guard let timeline = try? await Store.shared.call("issue_timeline", read, timeout: 60) else { break }
                        rows += timeline["events"].items
                        guard let next = timeline["nextPage"].int else { break }
                        read["page"] = JSON(next)
                    }
                    answer["timeline"] = .array(rows)
                }
                let sessions = tool.readsConversations
                    ? (try? await Store.shared.call("sessions", ["repo": .string(repo)])).flatMap(Session.parseList) ?? []
                    : []
                readBacks[key] = nil
                if tool == .deleteConversation, let id = arguments["sessionId"].string {
                    Store.shared.cache.remove("transcript:\(id)")
                    Store.shared.feed(repo).drop(id)
                }
                if tool.changes { Task { try? await Store.shared.feed(repo).loadSessions(fresh: true) } }
                return finish(.done, tool.summary(answer, args: step.args, sessions: sessions))
            } catch {
                let said = errorText(error)
                return finish(.failed(said), ["error": .string(said)])
            }
        }
    }

    /// Merges a pull request: the first call reads it and reads back what stands in the way; the confirmed one merges
    /// the head the user heard about, so a push in between makes GitHub refuse it.
    private func merge(_ step: Step, plan: VoicePlan, key: String, repo: String) async -> (Step.State, JSON) {
        guard Store.shared.supports("merge_pull"), Store.shared.supports("pull") else {
            return (.failed("Not allowed"), ["error": "This device's token cannot merge pull requests on the server."])
        }
        guard let number = step.args["number"].int else { return (.failed("No number"), ["error": "number is missing."]) }
        do {
            if case .call = plan, let held = merges[key] {
                let answer = try await Store.shared.call("merge_pull", held.arguments, timeout: 60)
                readBacks[key] = nil; merges[key] = nil
                Task {
                    try? await Store.shared.feed(repo).loadBoard(fresh: true)
                    try? await Store.shared.feed(repo).loadSessions(fresh: true)
                }
                var args = step.args
                args["base"] = .string(held.base)
                return (.done, VoiceTool.mergePullRequest.summary(answer, args: args))
            }
            let place: JSON = ["repo": .string(repo), "pr": JSON(number)]
            let pull = try await Store.shared.call("pull", place)
            let files = Store.shared.supports("pull_files") ? try? await Store.shared.call("pull_files", place) : nil
            let board = Store.shared.supports("pulls") ? try? await Store.shared.call("pulls", ["repo": .string(repo)]) : nil
            let row = PullSummary.parseList(board?["pulls"] ?? .null).first { $0.number == number }
            switch VoiceMerge.check(number: number, repo: repo, pull: pull, files: files, row: row) {
            case .refuse(let why):
                return (.failed(why), ["error": .string(why)])
            case .ready(let arguments, let base, let readBack):
                readBacks[key] = heard
                merges[key] = (arguments, base)
                return (.waiting, ["needs_confirmation": true, "read_back": .string(readBack),
                                   "next": "Read all of this to the user. Call again with confirmed=true only if they say yes."])
            }
        } catch {
            let said = errorText(error)
            return (.failed(said), ["error": .string(said)])
        }
    }

    /// The same change asked twice: the tool, its conversation or branch, and its words without case, spacing or punctuation.
    static func readBackKey(_ tool: VoiceTool, _ args: JSON) -> String {
        let words = { (s: String?) in
            (s ?? "").lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        }
        return [tool.rawValue, args["session_id"].string ?? "", args["branch"].string ?? "", args["issue"].int.map(String.init) ?? "", args["number"].int.map(String.init) ?? "",
                words(args["text"].string ?? args["prompt"].string)].joined(separator: "|")
    }
}
