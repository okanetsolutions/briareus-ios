import Foundation

/// One spoken conversation with GPT-Realtime about one project: the WebRTC call, the captions, and
/// the tools it calls, each held to that project. It outlives the screen that started it, so it goes on from
/// any tab and with the phone locked, and ends when the user ends it or after a silence.
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
    /// The voice is saying something, as its transcript arrives.
    @Published private(set) var speaking = false
    @Published private(set) var muted = false
    @Published private(set) var lines: [Line] = []
    @Published private(set) var steps: [Step] = []
    @Published private(set) var started: Date?
    /// Why the last conversation failed or ended by itself.
    @Published private(set) var notice: String?

    private var call: LiveCall?
    private var reader: Task<Void, Never>?
    private var hush: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var lastActivity = Date()
    /// How many pieces of the user's speech have been heard: a yes must come after the read-back it answers.
    private var heard = 0
    /// The function calls of each response, by response id, answered together once the response is done.
    private var calls: [String: [Task<(id: String, output: String), Never>]] = [:]
    private var seenCalls: Set<String> = []
    /// The changes read back to the user, with how much had been heard at the time.
    private var readBacks: [String: Int] = [:]
    private var sequence = 0

    private init() {}

    var isOn: Bool { phase != .off }

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
        lines = []; steps = []; heard = 0; calls = [:]; seenCalls = []; readBacks = [:]; muted = false; started = nil
        let call = LiveCall()
        self.call = call
        let named = project.title == project.repo ? project.repo : "\(project.title) (\(project.repo))"
        let session = Voice.session(voice: settings.voice, project: named)
        reader = Task { [weak self] in
            do {
                let events = try await call.open(key: key, session: session)
                for try await event in events { self?.handle(event) }
                self?.ended(nil)
            } catch {
                self?.ended(errorText(error))
            }
        }
    }

    /// Hangs up: closing the WebRTC call ends the Realtime session.
    func stop(reason: String? = nil) {
        guard phase == .connecting || phase == .live else { return }
        if let reason { notice = reason }
        phase = .closing
        speaking = false
        ended(nil)
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
        phase = .off
    }

    private func nextID() -> String { sequence += 1; return "briareus_\(sequence)" }
    private func touch() { lastActivity = Date() }

    // MARK: Events

    private func handle(_ event: JSON) {
        switch event["type"].string {
        case "session.created":
            guard phase == .connecting else { return }
            phase = .live
            started = Date()
            touch()
            watch()
        case "input_audio_buffer.committed":
            // A piece of the user's speech the model hears, transcribed or not.
            heard += 1
            touch()
        case "conversation.item.input_audio_transcription.completed":
            caption(user: true, event["transcript"].string)
            touch()
        case "response.output_audio_transcript.delta":
            caption(user: false, event["delta"].string)
            talking()
            touch()
        case "response.output_item.done", "response.done":
            tools(event)
        case "error":
            notice = event["error"]["message"].string ?? "GPT-Realtime reported an error."
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

    /// Ends the conversation after the silence the settings allow, as GPT-Realtime bills the audio it hears and says.
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

    /// A response's event: a finished function call starts running at once; when the response is done, every call
    /// it made is answered and the model is told to go on.
    private func tools(_ event: JSON) {
        switch event["type"].string {
        case "response.output_item.done":
            let item = event["item"], response = event["response_id"].string ?? ""
            guard item["type"].string == "function_call", let id = item["call_id"].string, let name = item["name"].string,
                  seenCalls.insert(id).inserted else { return }
            let args = item["arguments"].string.flatMap(JSON.parse) ?? [:]
            let step = Step(tool: VoiceTool(rawValue: name), name: name, args: args, state: .running)
            steps.append(step)
            touch()
            calls[response, default: []].append(Task { (id, await self.run(step)) })
        case "response.done":
            let response = event["response"]["id"].string ?? ""
            guard let pending = calls[response], !pending.isEmpty, let call else { return }
            calls[response] = nil
            // A response cut off by the user does not go on by itself; what its calls did is still told.
            let goOn = response.isEmpty || event["response"]["status"].string == "completed"
            Task {
                var outputs: [(id: String, output: String)] = []
                for call in pending { outputs.append(await call.value) }
                guard self.call === call else { return }
                for (id, output) in outputs {
                    call.send(["type": "conversation.item.create", "event_id": .string(nextID()),
                               "item": ["type": "function_call_output", "call_id": .string(id), "output": .string(output)]])
                }
                if goOn { call.send(["type": "response.create", "event_id": .string(nextID())]) }
            }
        default:
            break
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
                if tool.changes { Task { try? await Store.shared.feed(repo).loadSessions(fresh: true) } }
                return finish(.done, tool.summary(answer, args: step.args, sessions: sessions))
            } catch {
                let said = errorText(error)
                return finish(.failed(said), ["error": .string(said)])
            }
        }
    }

    /// The same change asked twice: the tool, its conversation or branch, and its words without case, spacing or punctuation.
    static func readBackKey(_ tool: VoiceTool, _ args: JSON) -> String {
        let words = { (s: String?) in
            (s ?? "").lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        }
        return [tool.rawValue, args["session_id"].string ?? "", args["branch"].string ?? "", args["issue"].int.map(String.init) ?? "",
                words(args["text"].string ?? args["prompt"].string)].joined(separator: "|")
    }
}
