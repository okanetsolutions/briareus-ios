// The voice mode's side of GPT-Live, OpenAI's live voice model: the session it opens, the tools its backend calls on the
// client API, and what each answer becomes for the model to say. No UI and no audio here.
//
// GPT-Live holds the spoken conversation; a Responses model behind it (its "delegation") decides which tool to call. The
// phone runs each call on /api/v1 with its own token and answers with a short JSON summary. A voice conversation belongs
// to one project: no tool names a repository, the phone puts that project's in every call.
import Foundation

enum Voice {
    /// Where a session starts: the phone posts its WebRTC offer with the session, and the answer comes back.
    static let endpoint = URL(string: "https://api.openai.com/v1/live/sessions")!
    /// The data channel GPT-Live sends and takes its JSON events on.
    static let channel = "oai-events"
    static let model = "gpt-live-1"
    static let defaultBackend = "gpt-6-luna"
    static let defaultVoice = "marin"
    /// Marin first, the default; then the voices GPT-Live adds.
    static let voices = ["marin", "gleam", "meridian", "willow", "stone", "vesper", "quartz", "ripple", "bossa", "tempo",
                         "beacon", "delta", "cinder"]

    /// How the voice speaks: short, in the speaker's language, about one project, and never claiming what the backend
    /// has not confirmed.
    static func instructions(project: String) -> String { """
    You are the voice of Briareus, an app that runs coding agents on the user's projects. This conversation is about one \
    project only: \(project). The user talks to you hands-free, often with the phone locked. Answer in the language the \
    user speaks, in one or two short sentences. Speak only when the user has said something; do not volunteer updates. \
    Delegate anything about the project's conversations, agents, pull requests or findings to the backend, and say only \
    what it confirms. If the user asks about another project, say this conversation can only work on \(project). Before \
    the backend starts a conversation, sends a message or stops an agent, read back what will happen in a few words and \
    wait for the user's yes.
    """ }

    /// What the backend model knows of the project, the tools and their rules.
    static func backendInstructions(project: String) -> String { """
    ## Voice conversation context
    You help a voice assistant in a live conversation about one project on the user's Briareus server: \(project). Coding \
    agents work on it in conversations (sessions). Every tool works on this project only; there is no way to reach \
    another. Transcripts can contain mistakes, unfinished phrases and later corrections; use the latest context. If a \
    needed detail is unclear, ask for it instead of guessing.

    ## Tools
    Find conversations with list_conversations before acting on one; never invent an id. Match what the user names \
    against titles loosely. read_conversation tells what an agent did, said or asks. send_message also answers an \
    agent's question.

    ## Confirmation
    start_conversation, send_message and stop_conversation change things. Call them with confirmed=false first: the \
    answer says what to read back. Call again with confirmed=true only after the user clearly agreed to that exact action \
    in their latest turn. Never pass confirmed=true on your own.

    ## Return the result
    Return the relevant facts in a few plain sentences, without Markdown, ids or URLs. Report an action as done only when \
    the tool says it is.
    """ }

    /// What starts a session over WebRTC: the phone's SDP offer, and the voice and the backend with its tools, all on
    /// one project. `project` is how it is named aloud: its label and repository. WebRTC settles the audio format.
    static func create(offer sdp: String, voice: String, backend: String, project: String) -> JSON {
        ["transport": ["type": "webrtc", "sdp": .string(sdp)], "session": [
            "model": .string(model),
            "instructions": .string(instructions(project: project)),
            "audio": ["output": ["voice": .string(voice)]],
            "delegation": ["type": "responses", "responses": [
                "model": .string(backend),
                "instructions": .string(backendInstructions(project: project)),
                "tools": .array(VoiceTool.allCases.map(\.definition)),
                "tool_choice": "auto",
                "parallel_tool_calls": false,
            ]],
        ]]
    }
}

// MARK: - Tools

/// What the backend may call. Each runs one call of the client API on the conversation's project; the ones that change
/// something wait for a yes.
enum VoiceTool: String, CaseIterable, Sendable {
    case listConversations = "list_conversations"
    case readConversation = "read_conversation"
    case listPullRequests = "list_pull_requests"
    case waitingFindings = "waiting_findings"
    case startConversation = "start_conversation"
    case sendMessage = "send_message"
    case stopConversation = "stop_conversation"

    /// The client API call each tool makes.
    var operation: String {
        switch self {
        case .listConversations, .waitingFindings: return "sessions"
        case .readConversation: return "session"
        case .listPullRequests: return "pulls"
        case .startConversation: return "start_session"
        case .sendMessage: return "message"
        case .stopConversation: return "cancel"
        }
    }
    var changes: Bool { [.startConversation, .sendMessage, .stopConversation].contains(self) }
    /// Acts on a conversation named by id, which must be the project's: the phone checks before it answers.
    var namesConversation: Bool { [.readConversation, .sendMessage, .stopConversation].contains(self) }

    /// A Responses function tool.
    var definition: JSON {
        var properties: [String: JSON] = [:]
        var required: [String] = []
        func add(_ name: String, _ type: String, _ about: String, required isRequired: Bool = true) {
            properties[name] = ["type": .string(type), "description": .string(about)]
            if isRequired { required.append(name) }
        }
        let description: String
        switch self {
        case .listConversations:
            description = "The project's conversations, newest first, with their status, whether the agent asks a question, and their pull request."
            add("active_only", "boolean", "Only the conversations an agent is working on or that wait for the user.", required: false)
        case .readConversation:
            description = "A conversation's status and its latest messages: what the user asked, what the agent said, and an open question."
            add("session_id", "string", "The conversation's id, from list_conversations.")
        case .listPullRequests:
            description = "The project's open pull requests with their checks, conflicts and review state."
        case .waitingFindings:
            description = "The project's review rounds waiting for the user's decision."
        case .startConversation:
            description = "Starts an agent on the project with a first prompt."
            add("prompt", "string", "What the agent should do, as the user said it.")
            add("branch", "string", "The branch to start from. Omit for the project's default.", required: false)
            add("confirmed", "boolean", "True only after the user agreed to this exact action.")
        case .sendMessage:
            description = "Sends a message to a conversation's agent, or answers its question. A busy agent gets it in its running turn or the next."
            add("session_id", "string", "The conversation's id, from list_conversations.")
            add("text", "string", "The message, as the user said it.")
            add("confirmed", "boolean", "True only after the user agreed to this exact action.")
        case .stopConversation:
            description = "Stops the agent's running turn. The conversation stays open."
            add("session_id", "string", "The conversation's id, from list_conversations.")
            add("confirmed", "boolean", "True only after the user agreed to this exact action.")
        }
        return ["type": "function", "name": .string(rawValue), "description": .string(description),
                "parameters": ["type": "object", "properties": .object(properties), "required": JSON(required),
                               "additionalProperties": false]]
    }

    /// What a call with these arguments does on `repo`: the client API call to make, a read-back that waits for a yes,
    /// or why it cannot be made.
    func plan(_ args: JSON, repo: String) -> VoicePlan {
        func text(_ key: String) -> String? {
            args[key].string?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyString
        }
        let confirmed = args["confirmed"].is(true)
        switch self {
        case .listConversations, .waitingFindings, .listPullRequests:
            return .call(["repo": .string(repo)])
        case .readConversation:
            guard let id = text("session_id") else { return .refuse("session_id is missing.") }
            return .call(["sessionId": .string(id), "since": 0])
        case .startConversation:
            guard let prompt = text("prompt") else { return .refuse("prompt is missing.") }
            var call: JSON = ["repo": .string(repo), "prompt": .string(prompt)]
            if let branch = text("branch") { call["branch"] = .string(branch) }
            let on = text("branch").map { " from \($0)" } ?? ""
            return confirmed ? .call(call) : .confirm("Start an agent\(on) with: \(prompt)")
        case .sendMessage:
            guard let id = text("session_id"), let message = text("text") else { return .refuse("session_id and text are needed.") }
            return confirmed ? .call(["sessionId": .string(id), "text": .string(message)]) : .confirm("Send: \(message)")
        case .stopConversation:
            guard let id = text("session_id") else { return .refuse("session_id is missing.") }
            return confirmed ? .call(["sessionId": .string(id)]) : .confirm("Stop the agent's running turn.")
        }
    }

    /// The answer of the call, cut to what the backend needs to say it. `args` are the tool's own arguments.
    func summary(_ answer: JSON, args: JSON) -> JSON {
        switch self {
        case .listConversations:
            var sessions = Session.parseList(answer) ?? []
            if args["active_only"].is(true) { sessions = sessions.filter { !["closed", "failed", "error"].contains($0.status) } }
            return ["conversations": .array(sessions.prefix(15).map(Voice.conversation)),
                    "total": JSON(sessions.count)]
        case .readConversation:
            guard let session = Session(answer["session"]) else { return ["error": "The server did not return the conversation."] }
            let events = answer["events"].items.compactMap(Event.init)
            var out = Voice.conversation(session, events: events)
            out["latest"] = .array(Voice.latest(events))
            return out
        case .listPullRequests:
            let pulls = PullSummary.parseList(answer["pulls"])
            return ["pull_requests": .array(pulls.prefix(15).map { pr in
                ["number": JSON(pr.number), "title": .string(CarText.inline(pr.title)), "state": .string(CarText.pullLine(pr))]
            }), "total": JSON(pulls.count)]
        case .waitingFindings:
            let held = CarText.holdingFindings(Session.parseList(answer) ?? [])
            return ["waiting": .array(held.map { s in
                ["session_id": .string(s.id), "title": .string(s.displayTitle),
                 "findings": JSON(s.heldTriage?["findings"].count ?? 0)]
            })]
        case .startConversation:
            guard let session = Session(answer["session"]) else { return ["done": true] }
            return ["done": true, "session_id": .string(session.id), "title": .string(session.displayTitle)]
        case .sendMessage:
            return ["done": true, "delivery": .string(CarText.sent(Session(answer["session"])))]
        case .stopConversation:
            return ["done": true]
        }
    }
}

/// What a tool call becomes on the phone.
enum VoicePlan: Equatable, Sendable {
    /// Make the tool's client API call with these arguments.
    case call(JSON)
    /// Answer the backend with this read-back; nothing is done until the call comes back confirmed.
    case confirm(String)
    /// Answer the backend with what is wrong with the call.
    case refuse(String)
}

extension Voice {
    /// Whether a conversation is one of the project's, by what `sessions` answered for it.
    static func owns(_ sessions: JSON, session id: String) -> Bool {
        (Session.parseList(sessions) ?? []).contains { $0.id == id }
    }
    /// A conversation as the backend reads it.
    static func conversation(_ s: Session) -> JSON { conversation(s, events: []) }
    static func conversation(_ s: Session, events: [Event]) -> JSON {
        let asking = CarText.openQuestion(events)
        var out: JSON = ["session_id": .string(s.id), "title": .string(s.displayTitle),
                         "status": .string(CarText.status(s, asking: asking != nil))]
        if let pr = s.pullNumber { out["pull_request"] = JSON(pr) }
        if let asking {
            out["question"] = .string(CarText.question(asking))
            let options = CarText.options(asking)
            if !options.isEmpty { out["options"] = JSON(options) }
        }
        return out
    }
    /// The last few things said in a conversation, oldest first, each cut short.
    static func latest(_ events: [Event], count: Int = 6, length: Int = 600) -> [JSON] {
        let said = events.filter { ["user", "text", "result", "ask"].contains($0.kind) && ($0.question ?? $0.text)?.isEmpty == false }
        return said.suffix(count).map { e in
            let who = e.kind == "user" ? "user" : "agent"
            var words = CarText.inline(e.question ?? e.text ?? "")
            if words.count > length { words = String(words.prefix(length)) + "…" }
            return ["from": .string(who), "text": .string(words)]
        }
    }
}

private extension String {
    var nonEmptyString: String? { isEmpty ? nil : self }
}
