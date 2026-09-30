import Foundation

// Extensible server payloads preserve unknown fields without tying the app to every dashboard release.
public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> JSONValue {
        if case .object(let v) = self { return v[key] ?? .null }
        return .null
    }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var double: Double? { if case .number(let v) = self { return v }; return nil }
    public var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    public var array: [JSONValue] { if case .array(let v) = self { return v }; return [] }
    /// JavaScript truthiness for flags the server sends as a value or leaves null.
    public var isSet: Bool {
        switch self {
        case .null: return false
        case .bool(let v): return v
        case .string(let v): return !v.isEmpty
        case .number(let v): return v != 0
        default: return true
        }
    }
    public var pretty: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? String(decoding: encoder.encode(self), as: UTF8.self)) ?? ""
    }
}

public struct Device: Codable, Sendable {
    public let id: String
    public let label: String
    public let repos: [String]
    public let permission: String
    public let expiresAt: Double
    public var canManage: Bool { permission == "manage" }
    public var expiry: Date { Date(timeIntervalSince1970: expiresAt / 1000) }
}
public struct Discovery: Decodable, Sendable {
    public let version: Int
    public let device: Device
    /// Whether the server can transcribe voice notes; older servers leave it out.
    public let transcribe: Bool?
    /// What the server's owner has to do before voice notes work, or nil when they do.
    public static func voiceNotesOff(_ transcribe: Bool?) -> String? {
        switch transcribe {
        case true?: return nil
        case false?: return "Voice notes are off: the server needs OPENAI_TRANSCRIBE_API_KEY and OPENAI_TRANSCRIBE_MODEL, and a restart once they are set."
        case nil: return "This server cannot transcribe voice notes yet. Update Briareus on the server to a version with the mobile transcribe endpoint."
        }
    }
}
public struct Operation: Codable, Sendable {
    public let name: String
    public let readOnly: Bool
}
public struct OperationList: Decodable, Sendable { public let operations: [Operation] }
/// What pairing learned about this device, saved so the next launch opens without asking again first.
public struct Connection: Codable, Sendable {
    public let device: Device
    public let operations: [Operation]
    public let transcribe: Bool?
    public init(device: Device, operations: [Operation], transcribe: Bool? = nil) {
        self.device = device; self.operations = operations; self.transcribe = transcribe
    }
}
public struct Project: Codable, Identifiable, Hashable, Sendable {
    public let repo: String
    public let label: String?
    public init(repo: String, label: String? = nil) { self.repo = repo; self.label = label }
    public var id: String { repo }
    public var title: String { label.flatMap { $0.isEmpty ? nil : $0 } ?? repo }
}
public struct ProjectList: Decodable, Sendable { public let projects: [Project] }
public struct Session: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let repo: String?
    public let title: String?
    public let status: String
    public let provider: String?
    public let model: String?
    public let liveInput: Bool?
    public let queued: [JSONValue]?
    public let usage: JSONValue?
    public let prStatus: JSONValue?
    public let startedOnPr: JSONValue?
    public let reviewLoop: JSONValue?
    public let reviewTriage: JSONValue?
    private let reviewBranch: JSONValue?, qaBranch: JSONValue?, autoClose: JSONValue?
    private let loopParentId: JSONValue?, local: JSONValue?, orchestrator: JSONValue?
    public var reviewLoopOn: Bool { reviewLoop.map { $0 != .null } ?? false }
    /// The server arms the review loop only on sessions started from scratch on a task.
    public var canReviewLoop: Bool {
        status != "closed" && ![reviewBranch, qaBranch, autoClose, loopParentId, local, orchestrator].contains { $0?.isSet == true }
    }
    /// A review round waiting for verdicts: a loop's round or a hand-started review.
    public var heldTriage: JSONValue? {
        [reviewTriage, reviewLoop?["triage"]].compactMap { $0 }.first { $0 != .null && !$0["findings"].array.isEmpty }
    }
    /// The pull request this conversation works on, once it has one.
    public var pullNumber: Int? {
        (prStatus?["number"].double ?? startedOnPr?.double).flatMap { $0 >= 1 ? Int($0) : nil }
    }
    /// "PR #123 open · ✓4 ✗1 ●2", as the dashboard's badge reads, once the server has synced the pull request.
    public var pullBadge: String? {
        guard let pr = prStatus, let number = pr["number"].double, number >= 1 else { return nil }
        let checks = [("✓", "passed"), ("✗", "failed"), ("●", "pending")].compactMap { mark, key in
            pr["checks"][key].double.flatMap { $0 > 0 ? "\(mark)\(Int($0))" : nil }
        }
        return (["PR #\(Int(number)) \(pullState)"] + (checks.isEmpty ? [] : [checks.joined(separator: " ")])).joined(separator: " · ")
    }
    /// The synced pull request's state: open, merged or closed.
    public var pullState: String { prStatus?["state"].string ?? "open" }
    /// What the pull request's mark in the list says: merged or closed, or while open, failing, pending or passing checks.
    public var pullTone: String? {
        guard pullBadge != nil else { return nil }
        if pullState != "open" { return pullState }
        let checks = prStatus?["checks"] ?? .null
        if (checks["failed"].double ?? 0) > 0 { return "failing" }
        if (checks["pending"].double ?? 0) > 0 { return "pending" }
        return "passing"
    }
    /// The conversations with a round waiting, the one held longest first, as the dashboard's queue orders them.
    public static func holdingFindings(_ sessions: [Session]) -> [Session] {
        sessions.filter { $0.heldTriage != nil }
            .sorted { ($0.heldTriage?["heldAt"].string ?? "") < ($1.heldTriage?["heldAt"].string ?? "") }
    }
    /// How many conversations are at work on each pull request, by its number.
    public static func activeRuns(_ sessions: [Session]) -> [Int: Int] {
        sessions.reduce(into: [:]) { counts, session in
            if session.isActive, let number = session.pullNumber { counts[number, default: 0] += 1 }
        }
    }
    public var displayTitle: String { title.flatMap { $0.isEmpty ? nil : $0 } ?? "New conversation" }
    public var isActive: Bool { ["queued", "preparing", "running", "starting"].contains(status) }
    public static func == (lhs: Session, rhs: Session) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
public struct SessionList: Decodable, Sendable { public let sessions: [Session] }
public struct SessionResult: Decodable, Sendable {
    public let session: Session
    public let events: [Event]?
}
public struct Event: Codable, Identifiable, Sendable {
    public let seq: Int
    public let kind: String
    /// When the server logged it, as an ISO 8601 date.
    public let t: String?
    public let text: String?
    public let name: String?
    public let summary: String?
    public let question: String?
    public let options: [JSONValue]?
    public let costUsd: Double?
    public let durationMs: Double?
    public let isError: Bool?
    public let attachments: [JSONValue]?
    public var id: Int { seq }
    public var time: Date? { BoardDate.parse(t) }
    /// A conversation is what was said. Status and setup output are dashboard plumbing, and the tools, commands
    /// and git steps an agent ran stay on the dashboard.
    public var visible: Bool {
        !["status", "setup", "tool", "tool_error", "cmd", "git"].contains(kind) && (text != nil || question != nil || kind == "result")
    }
}

// Cursor and transcript have one lifetime: saved events restore both, and an empty transcript starts at zero.
public struct Transcript: Sendable {
    public private(set) var events: [Event] = []
    public private(set) var cursor = 0
    public init() {}
    public mutating func append(_ incoming: [Event]) {
        var existing = Set(events.map(\.seq))
        events.append(contentsOf: incoming.filter { existing.insert($0.seq).inserted })
        events.sort { $0.seq < $1.seq }
        cursor = max(cursor, events.last?.seq ?? 0)
    }
}

// MARK: - Runtimes

public struct RuntimeModel: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String?
    public let efforts: [String]?
    public let defaultEffort: String?
    public var title: String { label.flatMap { $0.isEmpty ? nil : $0 } ?? id }
}
public struct RuntimeProvider: Codable, Identifiable, Equatable, Sendable {
    public let id: Int
    public let label: String
    public let available: Bool?
    public let models: [RuntimeModel]
    public let defaultModel: String?
    /// Only an explicit false greys a provider out; older servers omit the field.
    public var isAvailable: Bool { available != false }
}
/// What `start_session` is asked to run on. The server may still fall back to a default model or effort.
public struct RuntimeChoice: Codable, Equatable, Sendable {
    public let providerId: Int
    public let model: String?
    public let effort: String?
    public init(providerId: Int, model: String? = nil, effort: String? = nil) {
        self.providerId = providerId; self.model = model; self.effort = effort
    }
    public var arguments: [String: JSONValue] {
        var args: [String: JSONValue] = ["providerId": .number(Double(providerId))]
        if let model, !model.isEmpty { args["model"] = .string(model) }
        if let effort, !effort.isEmpty { args["effort"] = .string(effort) }
        return args
    }
}
public struct RuntimeCatalog: Codable, Equatable, Sendable {
    public let `default`: RuntimeChoice?
    public let providers: [RuntimeProvider]
    public func provider(_ id: Int) -> RuntimeProvider? { providers.first { $0.id == id } }
    public func model(of choice: RuntimeChoice) -> RuntimeModel? {
        provider(choice.providerId)?.models.first { $0.id == choice.model }
    }
    public func efforts(for choice: RuntimeChoice) -> [String] { model(of: choice)?.efforts ?? [] }
    /// A provider's model with that model's own default effort, since efforts differ between models.
    public func choice(provider id: Int, model: String? = nil) -> RuntimeChoice? {
        guard let provider = provider(id) else { return nil }
        let picked = provider.models.first { $0.id == model }
            ?? provider.models.first { $0.id == provider.defaultModel } ?? provider.models.first
        return RuntimeChoice(providerId: id, model: picked?.id, effort: picked?.defaultEffort ?? picked?.efforts?.first)
    }
    /// Used when the project has no default runtime and `start_session` therefore needs a provider.
    public var firstAvailable: RuntimeChoice? {
        providers.first(where: \.isAvailable).flatMap { choice(provider: $0.id) }
    }
    public func label(for choice: RuntimeChoice) -> String {
        [provider(choice.providerId)?.label, model(of: choice)?.title ?? choice.model]
            .compactMap { $0.flatMap { $0.isEmpty ? nil : $0 } }.joined(separator: " · ")
    }
}

// MARK: - Pull request files

public struct PullFile: Codable, Identifiable, Sendable {
    public let filename: String
    public let previousFilename: String?
    public let status: String?
    public let additions: Int?
    public let deletions: Int?
    public let patch: String?
    public let url: String?
    public var id: String { filename }
    public var name: String { filename.split(separator: "/").last.map(String.init) ?? filename }
    public var directory: String { filename.split(separator: "/").dropLast().joined(separator: "/") }
}
public struct PullFilesPage: Decodable, Sendable {
    public let pr: JSONValue
    public let files: [PullFile]
    public let nextPage: Int?
    public let truncated: Bool?
}

/// Pages of one pull request revision. Later pages are pinned to page 1's commits.
public struct PullFileList: Codable, Sendable {
    public private(set) var pr: JSONValue = .null
    public private(set) var files: [PullFile] = []
    public private(set) var nextPage: Int? = 1
    public private(set) var truncated = false
    public init() {}
    public func arguments(repo: String, number: Int) -> [String: JSONValue]? {
        guard let page = nextPage else { return nil }
        var args: [String: JSONValue] = ["repo": .string(repo), "pr": .number(Double(number))]
        if page > 1 {
            args["page"] = .number(Double(page))
            if let sha = pr["headSha"].string { args["headSha"] = .string(sha) }
            if let sha = pr["baseSha"].string { args["baseSha"] = .string(sha) }
        }
        return args
    }
    public mutating func append(_ page: PullFilesPage) {
        if files.isEmpty { pr = page.pr }
        var seen = Set(files.map(\.filename))
        files.append(contentsOf: page.files.filter { seen.insert($0.filename).inserted })
        nextPage = page.nextPage; truncated = page.truncated == true
    }
    /// A saved list of the revision this first page belongs to keeps its files and takes the page's details.
    public mutating func confirm(_ page: PullFilesPage) -> Bool {
        guard let head = page.pr["headSha"].string, head == pr["headSha"].string,
              page.pr["baseSha"] == pr["baseSha"] else { return false }
        pr = page.pr
        return true
    }
}
