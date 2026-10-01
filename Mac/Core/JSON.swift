// A server payload as it came: extensible, so unknown fields ride along without tying the app to every server release.
import Foundation

enum JSON: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    // MARK: Reading

    /// Subscripts never fail: a missing key, or a non-object, reads as null.
    subscript(key: String) -> JSON {
        get { if case .object(let o) = self { return o[key] ?? .null }; return .null }
        set {
            var o: [String: JSON]
            if case .object(let existing) = self { o = existing } else { o = [:] }
            o[key] = newValue
            self = .object(o)
        }
    }
    subscript(index: Int) -> JSON {
        if case .array(let a) = self, index >= 0, index < a.count { return a[index] }
        return .null
    }

    var isNull: Bool { if case .null = self { return true }; return false }
    var isObject: Bool { if case .object = self { return true }; return false }
    var isArray: Bool { if case .array = self { return true }; return false }

    /// The string, or nil for anything else.
    var string: String? { if case .string(let s) = self { return s }; return nil }
    /// The string when it is not empty, or nil.
    var nonEmpty: String? { if let s = string, !s.isEmpty { return s }; return nil }
    var number: Double? { if case .number(let n) = self { return n }; return nil }
    /// A whole number within Int range, or nil.
    var int: Int? {
        guard let n = number, n.isFinite, n == n.rounded(), abs(n) < 9e15 else { return nil }
        return Int(n)
    }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var array: [JSON]? { if case .array(let a) = self { return a }; return nil }
    var object: [String: JSON]? { if case .object(let o) = self { return o }; return nil }
    /// Elements of an array, or none.
    var items: [JSON] { array ?? [] }
    /// The strings of an array, skipping anything that is not one.
    var strings: [String] { items.compactMap(\.string) }
    /// Elements of an array or values of an object.
    var count: Int {
        switch self { case .array(let a): return a.count; case .object(let o): return o.count; default: return 0 }
    }
    /// Keys of an object, sorted so the order is stable.
    var keys: [String] { (object ?? [:]).keys.sorted() }

    /// JavaScript truthiness, for flags the server sends as a value or leaves null.
    var isSet: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .string(let s): return !s.isEmpty
        case .number(let n): return n != 0
        default: return true
        }
    }
    /// True only for the boolean `expected`.
    func `is`(_ expected: Bool) -> Bool { bool == expected }

    // MARK: Building

    init(_ value: String?) { self = value.map(JSON.string) ?? .null }
    init(_ value: Int) { self = .number(Double(value)) }
    init(_ value: Double) { self = .number(value) }
    init(_ value: Bool) { self = .bool(value) }
    init(_ values: [String]) { self = .array(values.map(JSON.string)) }

    mutating func append(_ value: JSON) {
        if case .array(var a) = self { a.append(value); self = .array(a) } else { self = .array([value]) }
    }
    mutating func remove(_ key: String) {
        if case .object(var o) = self { o.removeValue(forKey: key); self = .object(o) }
    }
    /// Every key of `other` copied in, replacing what was there.
    mutating func merge(_ other: JSON) {
        guard case .object(let from) = other else { return }
        var o = object ?? [:]
        for (k, v) in from { o[k] = v }
        self = .object(o)
    }

    // MARK: Text

    /// Parses one document; nil when the bytes are not JSON.
    static func parse(_ data: Data) -> JSON? {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return JSON(any: any)
    }
    static func parse(_ text: String) -> JSON? { parse(Data(text.utf8)) }

    init?(any: Any) {
        switch any {
        case is NSNull: self = .null
        case let n as NSNumber:
            // JSONSerialization hands booleans over as NSNumber too; only CFBoolean is one.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.compactMap(JSON.init(any:)))
        case let o as [String: Any]:
            var out: [String: JSON] = [:]
            for (k, v) in o { if let j = JSON(any: v) { out[k] = j } }
            self = .object(out)
        default: return nil
        }
    }

    /// Compact text with sorted keys, so equal values are equal bytes.
    func serialized(pretty: Bool = false) -> String {
        var out = ""
        write(into: &out, pretty: pretty, indent: 0)
        return out
    }
    var data: Data { Data(serialized().utf8) }

    private func write(into out: inout String, pretty: Bool, indent: Int) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n):
            if !n.isFinite { out += "null" }
            else if n == n.rounded(), abs(n) < 1e15 { out += String(Int64(n)) }
            else { out += String(n) }
        case .string(let s): JSON.quote(s, into: &out)
        case .array(let a):
            if a.isEmpty { out += "[]"; return }
            out += "["
            for (i, v) in a.enumerated() {
                if i > 0 { out += "," }
                if pretty { out += "\n" + String(repeating: "  ", count: indent + 1) }
                v.write(into: &out, pretty: pretty, indent: indent + 1)
            }
            if pretty { out += "\n" + String(repeating: "  ", count: indent) }
            out += "]"
        case .object(let o):
            if o.isEmpty { out += "{}"; return }
            out += "{"
            for (i, k) in o.keys.sorted().enumerated() {
                if i > 0 { out += "," }
                if pretty { out += "\n" + String(repeating: "  ", count: indent + 1) }
                JSON.quote(k, into: &out)
                out += pretty ? ": " : ":"
                o[k]!.write(into: &out, pretty: pretty, indent: indent + 1)
            }
            if pretty { out += "\n" + String(repeating: "  ", count: indent) }
            out += "}"
        }
    }
    private static func quote(_ s: String, into out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        out += "\""
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral, ExpressibleByFloatLiteral,
                ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(arrayLiteral elements: JSON...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSON)...) {
        var o: [String: JSON] = [:]
        for (k, v) in elements { o[k] = v }
        self = .object(o)
    }
    init(nilLiteral: ()) { self = .null }
}

extension JSON: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}
