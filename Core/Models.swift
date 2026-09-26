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
    public var pretty: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? String(decoding: encoder.encode(self), as: UTF8.self)) ?? ""
    }
}

public struct Device: Decodable, Sendable {
    public let id: String
    public let label: String
    public let repos: [String]
    public let permission: String
    public let expiresAt: Double
    public var canManage: Bool { permission == "manage" }
    public var expiry: Date { Date(timeIntervalSince1970: expiresAt / 1000) }
}
public struct Discovery: Decodable, Sendable { public let version: Int; public let device: Device }
public struct Operation: Decodable, Sendable {
    public let name: String
    public let readOnly: Bool
}
public struct OperationList: Decodable, Sendable { public let operations: [Operation] }
public struct Project: Decodable, Identifiable, Hashable, Sendable {
    public let repo: String
    public let label: String?
    public var id: String { repo }
    public var title: String { label.flatMap { $0.isEmpty ? nil : $0 } ?? repo }
}
public struct ProjectList: Decodable, Sendable { public let projects: [Project] }
public struct Session: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let repo: String?
    public let title: String?
    public let status: String
    public let provider: String?
    public let model: String?
    public let liveInput: Bool?
    public let queued: [JSONValue]?
    public let usage: JSONValue?
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
public struct Event: Decodable, Identifiable, Sendable {
    public let seq: Int
    public let kind: String
    public let text: String?
    public let name: String?
    public let question: String?
    public let options: [JSONValue]?
    public let costUsd: Double?
    public let durationMs: Double?
    public let isError: Bool?
    public let attachments: [JSONValue]?
    public var id: Int { seq }
    public var visible: Bool { kind != "status" && (text != nil || question != nil || ["tool", "tool_error", "result"].contains(kind)) }
}

// Cursor and transcript have one lifetime: a fresh screen always starts at zero.
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
