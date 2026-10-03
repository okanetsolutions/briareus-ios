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
    against titles loosely. Each conversation carries its pull_request with its state (open, merged or closed) and \
    checks, and each open pull request names the conversations working on it: use these links to answer whether a \
    conversation's pull request was merged or closed. list_pull_requests lists open pull requests only; one missing \
    from it was merged or closed, and the conversation's pull_request says which. read_conversation tells what an \
    agent did, said or asks. send_message also answers an agent's question. For what a pull request changes (how \
    many files, which ones, lines added and removed), use read_pull_request with its number; a conversation's \
    pull_request gives the number.

    ## Issues
    list_issues lists the project's open issues with their labels, epic progress, the pull requests that close them \
    and the conversations started on them. read_issue reads one in full: its description, its latest comments, its \
    epic or sub-issues and the pull requests that close it; use it whenever the user asks what an issue says or wants. \
    To have an agent do an issue, use work_on_issue with its number: it starts a conversation that reads the issue in \
    full, implements it and opens a pull request that closes it. Before starting one, say if a conversation or a pull \
    request is already on that issue.

    ## Ready to merge
    A pull request is ready to be merged only when list_pull_requests marks it ready_to_merge: it carries the \
    code-approved label, its checks passed, and it has no conflicts and is not a draft. Never call one ready on its \
    checks or reviews alone; say what it still lacks instead.

    ## Merging
    merge_pull_request merges one of the project's pull requests, squashed unless the repository refuses squashes. \
    Its first call answers a read_back with what stands in its way: failing or running checks, conflicts, a missing \
    code-approved label, requested changes. Read all of it to the user; they may still choose to merge.

    ## Confirmation
    start_conversation, work_on_issue, send_message, stop_conversation and merge_pull_request change things. Call them with confirmed=false first: the \
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
    case readPullRequest = "read_pull_request"
    case mergePullRequest = "merge_pull_request"
    case waitingFindings = "waiting_findings"
    case listIssues = "list_issues"
    case readIssue = "read_issue"
    case startConversation = "start_conversation"
    case workOnIssue = "work_on_issue"
    case sendMessage = "send_message"
    case stopConversation = "stop_conversation"

    /// The client API call each tool makes.
    var operation: String {
        switch self {
        case .listConversations, .waitingFindings: return "sessions"
        case .readConversation: return "session"
        case .listPullRequests, .listIssues: return "pulls"
        case .readIssue: return "issue"
        case .readPullRequest: return "pull_files"
        case .mergePullRequest: return "merge_pull"
        case .startConversation, .workOnIssue: return "start_session"
        case .sendMessage: return "message"
        case .stopConversation: return "cancel"
        }
    }
    var changes: Bool { [.startConversation, .workOnIssue, .sendMessage, .stopConversation, .mergePullRequest].contains(self) }
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
            description = "The project's conversations, newest first, with their status, whether the agent asks a question, and their pull request with its state (open, merged or closed) and checks."
            add("active_only", "boolean", "Only the conversations an agent is working on or that wait for the user.", required: false)
        case .readConversation:
            description = "A conversation's status and its latest messages: what the user asked, what the agent said, and an open question."
            add("session_id", "string", "The conversation's id, from list_conversations.")
        case .listPullRequests:
            description = "The project's open pull requests with their checks, conflicts, labels and review state, whether each is ready to merge, and the conversations working on it."
        case .mergePullRequest:
            description = "Merges one of the project's open pull requests into its base branch. The first call reads it and answers what to read back, with what stands in the way."
            add("number", "integer", "The pull request's number.")
            add("confirmed", "boolean", "True only after the user agreed to this exact action.")
        case .readPullRequest:
            description = "What one of the project's pull requests changes: how many files, lines added and removed, the files by folder, and each file's path and change."
            add("number", "integer", "The pull request's number.")
        case .waitingFindings:
            description = "The project's review rounds waiting for the user's decision."
        case .listIssues:
            description = "The project's open issues with their labels, epic progress, the pull requests that close them and the conversations started on them."
        case .readIssue:
            description = "One of the project's issues in full: its state, type, labels, description and latest comments, its epic or sub-issues, the pull requests that close it and the conversations started on it."
            add("issue", "integer", "The issue's number, from list_issues or as the user said it.")
        case .workOnIssue:
            description = "Starts an agent on one of the project's open issues: it reads the issue in full, implements it and opens a pull request that closes it."
            add("issue", "integer", "The issue's number, from list_issues.")
            add("confirmed", "boolean", "True only after the user agreed to this exact action.")
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
        case .listConversations, .waitingFindings, .listPullRequests, .listIssues:
            return .call(["repo": .string(repo)])
        case .readIssue:
            guard let number = args["issue"].int, number >= 1 else { return .refuse("issue is missing.") }
            return .call(["repo": .string(repo), "issue": JSON(number)])
        case .workOnIssue:
            guard let number = args["issue"].int, number >= 1 else { return .refuse("issue is missing.") }
            // The board is read first: the conversation's prompt is made from the issue's row there.
            return confirmed ? .call(["repo": .string(repo), "issue": JSON(number)]) : .confirm("Start an agent on issue #\(number).")
        case .readPullRequest:
            guard let number = args["number"].int, number >= 1 else { return .refuse("number is missing.") }
            return .call(["repo": .string(repo), "pr": JSON(number)])
        case .mergePullRequest:
            // The phone reads the pull request before either answer: the read-back says what stands in the way, and the
            // merge is pinned to the head the user heard about.
            guard let number = args["number"].int, number >= 1 else { return .refuse("number is missing.") }
            return confirmed ? .call(["repo": .string(repo), "pr": JSON(number)]) : .confirm("Merge pull request #\(number).")
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

    /// Reads the project's conversations too, to link each pull request or issue to the conversations working on it.
    var readsConversations: Bool { [.listPullRequests, .listIssues, .readIssue].contains(self) }

    /// The answer of the call, cut to what the backend needs to say it. `args` are the tool's own arguments, and
    /// `sessions` the project's conversations when `readsConversations`. A `read_issue` answer carries the timeline
    /// rows the phone read after it as `timeline`.
    func summary(_ answer: JSON, args: JSON, sessions: [Session] = []) -> JSON {
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
                ["number": JSON(pr.number), "title": .string(CarText.inline(pr.title)), "state": .string(CarText.pullLine(pr)),
                 "labels": JSON(pr.labels.map(\.name)), "ready_to_merge": .bool(Voice.readyToMerge(pr)),
                 "conversations": .array(sessions.filter { $0.pullNumber == pr.number }.map { s in
                     ["session_id": .string(s.id), "title": .string(s.displayTitle)]
                 })]
            }), "total": JSON(pulls.count)]
        case .mergePullRequest:
            return ["done": true, "result": .string(CarText.merged(answer, base: args["base"].string ?? "its base"))]
        case .readPullRequest:
            guard let page = PullFilesPage(answer) else { return ["error": "The server did not return the pull request's files."] }
            return Voice.changes(page)
        case .waitingFindings:
            let held = CarText.holdingFindings(Session.parseList(answer) ?? [])
            return ["waiting": .array(held.map { s in
                ["session_id": .string(s.id), "title": .string(s.displayTitle),
                 "findings": JSON(s.heldTriage?["findings"].count ?? 0)]
            })]
        case .listIssues:
            let issues = IssueSummary.parseList(answer["issues"])
            return ["issues": .array(issues.prefix(20).map { issue in
                var out: JSON = ["number": JSON(issue.number), "title": .string(CarText.inline(issue.title)),
                                 "labels": JSON(issue.labels.map(\.name)),
                                 "pull_requests": .array(issue.pulls.map { JSON($0.number) }),
                                 "conversations": .array(sessions.filter { $0.onIssue(issue.number) }.map { s in
                                     ["session_id": .string(s.id), "title": .string(s.displayTitle), "status": .string(CarText.status(s))]
                                 })]
                if issue.isEpic { out["sub_issues"] = .string("\(issue.subIssuesDone) of \(issue.subIssues) done") }
                if let parent = issue.parent { out["epic"] = JSON(parent.number) }
                return out
            }), "total": JSON(issues.count)]
        case .readIssue:
            let raw = answer["issue"]
            guard let issue = IssueSummary(raw) else { return ["error": "The server did not return the issue."] }
            let pulls: [JSON] = issue.pulls.map { pr in
                var link: JSON = ["number": JSON(pr.number), "title": .string(CarText.inline(pr.title))]
                if let state = pr.state { link["state"] = .string(state) }
                if pr.draft { link["draft"] = true }
                return link
            }
            let working: [JSON] = sessions.filter { $0.onIssue(issue.number) }.map { s in
                ["session_id": .string(s.id), "title": .string(s.displayTitle), "status": .string(CarText.status(s))]
            }
            var out: JSON = ["number": JSON(issue.number), "title": .string(CarText.inline(issue.title)),
                             "state": .string(Voice.issueState(raw)), "labels": JSON(issue.labels.map(\.name)),
                             "description": .string(Voice.cut(CarText.inline(raw["body"].string ?? ""), 4000)),
                             "pull_requests": .array(pulls), "conversations": .array(working)]
            if let type = raw["type"].nonEmpty { out["type"] = .string(type) }
            if let author = issue.author { out["author"] = .string(author) }
            if !issue.assignees.isEmpty { out["assignees"] = JSON(issue.assignees) }
            if let parent = issue.parent { out["epic"] = ["number": JSON(parent.number), "title": .string(CarText.inline(parent.title))] }
            if issue.isEpic {
                out["sub_issues"] = .string("\(issue.subIssuesDone) of \(issue.subIssues) done")
                let open = raw["subIssues"]["items"].items.compactMap(BoardLink.init).filter { $0.state == "open" }
                out["open_sub_issues"] = .array(open.prefix(10).map { ["number": JSON($0.number), "title": .string(CarText.inline($0.title))] })
            }
            let comments = answer["timeline"].items.filter { $0["kind"].string == "commented" && $0["body"].nonEmpty != nil }
            out["comments"] = .array(comments.suffix(5).map { c in
                ["from": .string(c["actor"].string ?? "a deleted account"), "text": .string(Voice.cut(CarText.inline(c["body"].string ?? ""), 800))]
            })
            out["comments_total"] = JSON(issue.comments)
            return out
        case .startConversation, .workOnIssue:
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
    /// What `start_session` is sent for an agent on issue `number`, from the board the project's `pulls` answered; nil
    /// when the issue is not open on it.
    static func issueStart(_ board: JSON, number: Int, repo: String) -> JSON? {
        guard let issue = issuesFind(IssueSummary.parseList(board["issues"]), number) else { return nil }
        return ["repo": .string(repo), "prompt": .string(issuePrompt(issue, repo: repo)), "activity": "issue"]
    }
    /// How many timeline pages `read_issue` reads at most: 100 rows each, oldest first, so its latest comments are on the last.
    static let issueTimelinePages = 5
    /// An issue's state in words: open, closed, or closed with its reason.
    static func issueState(_ issue: JSON) -> String {
        guard issue["state"].string == "closed" else { return issue["state"].string ?? "open" }
        switch issue["stateReason"].string {
        case "not_planned": return "closed as not planned"
        case "duplicate": return "closed as a duplicate"
        case "completed": return "closed as completed"
        default: return "closed"
        }
    }
    /// `text` cut to `length` characters, with an ellipsis when it was longer.
    static func cut(_ text: String, _ length: Int) -> String {
        text.count > length ? String(text.prefix(length)) + "…" : text
    }
    /// What a pull request changes, from the first page of its files: the totals, the files by top folder, and the
    /// files themselves, as many as are worth reading aloud.
    static func changes(_ page: PullFilesPage, listed: Int = 40) -> JSON {
        let pr = page.pr
        let more = page.nextPage != nil || page.truncated
        var out: JSON = ["changed_files": JSON(pr["changedFiles"].int ?? page.files.count)]
        if let added = pr["additions"].int { out["lines_added"] = JSON(added) }
        if let removed = pr["deletions"].int { out["lines_removed"] = JSON(removed) }
        if let commits = pr["commits"].int { out["commits"] = JSON(commits) }
        if let title = pr["title"].nonEmpty { out["title"] = .string(CarText.inline(title)) }
        var folders: [String: Int] = [:]
        for file in page.files { folders[file.filename.split(separator: "/").first.map(String.init) ?? file.filename, default: 0] += 1 }
        out["by_folder"] = .array(folders.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(8).map {
            ["folder": .string($0.key), "files": JSON($0.value)]
        })
        out["files"] = .array(page.files.prefix(listed).map { file in
            var f: JSON = ["path": .string(file.filename), "change": .string(file.status ?? "modified")]
            if let added = file.additions { f["added"] = JSON(added) }
            if let removed = file.deletions { f["removed"] = JSON(removed) }
            return f
        })
        if more || page.files.count > listed { out["files_listed"] = .string("the first \(min(listed, page.files.count)) only") }
        return out
    }
    /// The label a reviewer sets once the code is approved.
    static let approvedLabel = "code-approved"
    /// Ready to merge: approved by its label, checks passed, no conflicts, not a draft.
    static func readyToMerge(_ pr: PullSummary) -> Bool {
        pr.labels.contains { foldEqual($0.name, approvedLabel) } && pr.checks == "success" && !pr.hasConflicts && !pr.draft
    }
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
        if let pr = pullRequest(s) { out["pull_request"] = pr }
        if let asking {
            out["question"] = .string(CarText.question(asking))
            let options = CarText.options(asking)
            if !options.isEmpty { out["options"] = JSON(options) }
        }
        return out
    }
    /// A conversation's pull request as the server last synced it: its number, state and checks. A conversation started
    /// on a pull request the server has not synced yet has its number alone.
    static func pullRequest(_ s: Session) -> JSON? {
        guard let number = s.pullNumber else { return nil }
        let pr = s.raw["prStatus"]
        guard pr["number"].truncatedInt == number else { return ["number": JSON(number)] }
        var out: JSON = ["number": JSON(number), "state": .string(s.pullState)]
        if let title = pr["title"].nonEmpty { out["title"] = .string(CarText.inline(title)) }
        if pr["draft"].is(true) { out["draft"] = true }
        let checks = pr["checks"]
        if checks.isObject { out["checks"] = .string(CarText.checks(checks)) }
        return out
    }
    /// The last few things said in a conversation, oldest first, each cut short.
    static func latest(_ events: [Event], count: Int = 6, length: Int = 600) -> [JSON] {
        let said = events.filter { ["user", "text", "result", "ask"].contains($0.kind) && ($0.question ?? $0.text)?.isEmpty == false }
        return said.suffix(count).map { e in
            let who = e.kind == "user" ? "user" : "agent"
            return ["from": .string(who), "text": .string(cut(CarText.inline(e.question ?? e.text ?? ""), length))]
        }
    }
}

private extension String {
    var nonEmptyString: String? { isEmpty ? nil : self }
}

// MARK: - Cost

/// What a voice conversation has cost so far: GPT-Live's voice time, billed by the second, and the backend model's
/// tokens, at the prices OpenAI publishes. An estimate: OpenAI's own bill is the reference.
struct VoiceCost: Equatable, Sendable {
    /// Dollars per minute of voice.
    static let voicePerMinute = 0.05
    /// Dollars per million tokens: input, cached input, output.
    static let backendPrices: [String: (input: Double, cached: Double, output: Double)] = [
        "gpt-6-luna": (0.1, 0.01, 0.5),
        "gpt-6-sol": (2, 0.2, 10),
    ]

    /// The voice seconds GPT-Live last reported: each report replaces the one before.
    private(set) var seconds: Double = 0
    private(set) var inputTokens = 0
    private(set) var cachedTokens = 0
    private(set) var outputTokens = 0
    private var counted: Set<String> = []

    /// Reads a `session.usage.updated` or `session.closed` event's voice seconds.
    mutating func voice(_ event: JSON) {
        if let s = event["usage"]["seconds"].number, s.isFinite, s >= 0 { seconds = s }
    }
    /// Counts a backend response's tokens, from its `response.completed` event, once per response.
    mutating func backend(_ response: JSON) {
        let usage = response["usage"]
        guard usage.isObject, counted.insert(response["id"].string ?? UUID().uuidString).inserted else { return }
        let input = usage["input_tokens"].int ?? 0
        let cached = min(usage["input_tokens_details"]["cached_tokens"].int ?? 0, input)
        inputTokens += input - cached
        cachedTokens += cached
        outputTokens += usage["output_tokens"].int ?? 0
    }

    var tokens: Int { inputTokens + cachedTokens + outputTokens }
    /// The voice's dollars for `seconds` of conversation, at least the last reported.
    func voiceDollars(seconds elapsed: Double = 0) -> Double { max(seconds, elapsed) / 60 * Self.voicePerMinute }
    /// The backend's dollars for `model`; nil for a model whose price is not known here.
    func backendDollars(_ model: String) -> Double? {
        guard let price = Self.backendPrices[model] else { return tokens == 0 ? 0 : nil }
        return (Double(inputTokens) * price.input + Double(cachedTokens) * price.cached + Double(outputTokens) * price.output) / 1_000_000
    }

    /// "$0.0123", with more places while it is under a cent.
    static func dollars(_ amount: Double) -> String {
        String(format: amount < 0.01 ? "$%.4f" : amount < 1 ? "$%.3f" : "$%.2f", amount)
    }
    /// What the screen shows under the controls: the total, then the voice and the backend apart.
    func line(model: String, elapsed: Double = 0) -> String {
        let voice = voiceDollars(seconds: elapsed)
        let shown = Int(max(seconds, elapsed).rounded(.down))
        let time = String(format: "%d:%02d", shown / 60, shown % 60)
        let tokenText = tokens >= 1000 ? String(format: "%.1fk tokens", Double(tokens) / 1000) : "\(tokens) tokens"
        guard let backend = backendDollars(model) else {
            return "≈ \(Self.dollars(voice)) voice (\(time)) + \(tokenText) on \(model)"
        }
        return "≈ \(Self.dollars(voice + backend)) · voice \(time) \(Self.dollars(voice)) · backend \(tokenText) \(Self.dollars(backend))"
    }
}

// MARK: - Merging

/// What merging a pull request takes, as the phone read it before the read-back.
enum VoiceMerge: Equatable, Sendable {
    case refuse(String)
    /// The `merge_pull` arguments, pinned to the head read now; the base it goes into; and what to read back.
    case ready(arguments: JSON, base: String, readBack: String)

    /// Reads `pull`'s answer, the first page of `pull_files` when there is one, and the board row when it is on the
    /// board: an open, non-draft pull request merges, with what stands in its way said first.
    static func check(number: Int, repo: String, pull: JSON, files: JSON?, row: PullSummary?) -> VoiceMerge {
        let pr = pull["pr"], live = files?["pr"] ?? .null
        let state = pr["state"].string ?? "open"
        guard state == "open" else { return .refuse("Pull request #\(number) is already \(state).") }
        if pr["draft"].is(true) || row?.draft == true { return .refuse("Pull request #\(number) is a draft; it cannot merge until it is marked ready.") }
        guard let head = live["headSha"].string ?? pr["headSha"].string, let base = pr["baseRef"].string else {
            return .refuse("Pull request #\(number) could not be read.")
        }
        var notes = live.isObject ? mergeWarnings(mergeable: live["mergeable"], state: live["mergeableState"].string) : []
        let failed = pr["checks"]["failed"].truncatedInt ?? 0, pending = pr["checks"]["pending"].truncatedInt ?? 0
        if failed > 0 { notes.append("\(failed) check\(failed == 1 ? " is" : "s are") failing.") }
        if pending > 0 { notes.append("\(pending) check\(pending == 1 ? " is" : "s are") still running.") }
        if let row, !row.labels.contains(where: { foldEqual($0.name, Voice.approvedLabel) }) {
            notes.append("It does not carry the \(Voice.approvedLabel) label.")
        }
        if case .changesRequested = ReviewStatus(decision: row?.reviewDecision, reviews: pr["reviews"]) {
            notes.append("A reviewer has requested changes.")
        }
        let method = CarText.mergeMethod(allowed: live["mergeMethods"].strings)
        let title = pr["title"].nonEmpty.map { ", \(CarText.inline($0))," } ?? ""
        let how = ["merge": "with a merge commit", "rebase": "rebased"][method] ?? "squashed"
        let readBack = (["Merge pull request #\(number)\(title) into \(base), \(how)."] + notes).joined(separator: " ")
        return .ready(arguments: ["repo": .string(repo), "pr": JSON(number), "headSha": .string(head), "baseRef": .string(base),
                                  "method": .string(method)], base: base, readBack: readBack)
    }
}
