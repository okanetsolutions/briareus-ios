// The token's own record, what the server can do, and the routes it lists with who may call each.
import Foundation

/// read 0, manage 1, admin 2; nil for a permission this app does not know, which may do nothing.
func permissionRank(_ permission: String?) -> Int? {
    switch permission {
    case "read": return 0
    case "manage": return 1
    case "admin": return 2
    default: return nil
    }
}

/// The token's own record (`client` in what `GET /` answers): this device's token.
struct Device: Equatable, Sendable {
    var id: String
    var label: String
    var permission: String          // read, manage or admin
    var repos: [String]             // empty for an admin token, which is held to no project list
    var expiresAt: Double           // milliseconds since 1970

    init?(_ j: JSON) {
        guard let id = j["id"].string, let label = j["label"].string, let permission = j["permission"].string,
              j["repos"].isArray, let expires = j["expiresAt"].number else { return nil }
        self.id = id; self.label = label; self.permission = permission; repos = j["repos"].strings; expiresAt = expires
    }
    var json: JSON { ["id": .string(id), "label": .string(label), "permission": .string(permission), "repos": JSON(repos), "expiresAt": .number(expiresAt)] }
    /// A manage or admin token may write.
    var canManage: Bool { (permissionRank(permission) ?? -1) >= 1 }
    var isAdmin: Bool { permission == "admin" }
    var expiry: Date { Date(timeIntervalSince1970: expiresAt / 1000) }
    func sameRepos(_ other: Device) -> Bool { Set(repos) == Set(other.repos) && repos.count == other.repos.count }
}

struct Discovery: Sendable {
    var version: Int
    var device: Device
    /// nil when the server left transcription out (a server from before voice notes).
    var transcribe: Bool?

    init?(_ j: JSON) {
        guard let v = j["version"].int, v >= 0, let d = Device(j["client"]) else { return nil }
        version = v; device = d; transcribe = j["transcribe"].bool
    }
    /// What the server's owner has to do before voice notes work, or nil when they do.
    static func voiceNotesOff(_ transcribe: Bool?) -> String? {
        switch transcribe {
        case true: return nil
        case false: return "Voice notes are off: the server needs OPENAI_TRANSCRIBE_API_KEY and OPENAI_TRANSCRIBE_MODEL, and a restart once they are set."
        default: return "This server cannot transcribe voice notes yet. Update Briareus on the server to a version whose client API transcribes."
        }
    }
}

/// One route the server lists: its method, its path with `{...}` for each parameter, and the least permission that may call it.
struct Route: Equatable, Sendable {
    var method: String, path: String, access: String

    /// Reads the server's OpenAPI document (`paths`, with `x-briareus-access` on each operation) or a saved list of routes.
    static func parse(_ value: JSON) -> [Route]? {
        if let saved = value.array {
            var out: [Route] = []
            for entry in saved {
                guard let m = entry["method"].string, let p = entry["path"].string, let a = entry["access"].string else { return nil }
                out.append(Route(method: m, path: p, access: a))
            }
            return out
        }
        guard let paths = value["paths"].object else { return nil }
        var out: [Route] = []
        for path in paths.keys.sorted() {
            for method in ["GET", "POST", "PUT", "PATCH", "DELETE"] {
                let op = paths[path]![method.lowercased()]
                guard op.isObject else { continue }
                // A route that says nothing about who may call it is the operator's.
                out.append(Route(method: method, path: path, access: op["x-briareus-access"].string ?? "admin"))
            }
        }
        return out
    }
    static func json(_ routes: [Route]) -> JSON {
        .array(routes.map { ["method": .string($0.method), "path": .string($0.path), "access": .string($0.access)] })
    }

    /// Segment by segment, a parameter standing for any one segment. Leading and trailing slashes do not count.
    /// nil when the paths differ, else how many segments are a parameter on one side only.
    static func match(_ a: String, _ b: String) -> Int? {
        let sa = a.split(separator: "/", omittingEmptySubsequences: true), sb = b.split(separator: "/", omittingEmptySubsequences: true)
        guard sa.count == sb.count else { return nil }
        var loose = 0
        for (x, y) in zip(sa, sb) {
            let px = x.hasPrefix("{"), py = y.hasPrefix("{")
            if !px && !py && x != y { return nil }
            if px != py { loose += 1 }
        }
        return loose
    }

    /// Whether the server has `method path` (a `{...}` segment on either side matches any) and `permission` ranks high enough.
    static func allow(_ routes: [Route], method: String, path: String, permission: String?) -> Bool {
        guard let rank = permissionRank(permission) else { return false }
        // The closest route speaks for the path, as a server's router picks a literal segment over a parameter.
        var best: Route?, bestLoose = 0
        for r in routes where r.method.caseInsensitiveCompare(method) == .orderedSame {
            if let loose = match(r.path, path), best == nil || loose < bestLoose { best = r; bestLoose = loose }
        }
        guard let best, let needed = permissionRank(best.access) else { return false }
        return rank >= needed
    }
}

/// What pairing learned about this device, saved so the next launch opens without asking again first.
struct Connection: Sendable {
    var device: Device
    var routes: [Route]
    var transcribe: Bool?

    init(device: Device, routes: [Route], transcribe: Bool?) { self.device = device; self.routes = routes; self.transcribe = transcribe }
    init?(_ j: JSON) {
        guard let d = Device(j["device"]), j["routes"].isArray, let r = Route.parse(j["routes"]) else { return nil }
        device = d; routes = r; transcribe = j["transcribe"].bool
    }
    var json: JSON {
        var o: JSON = ["device": device.json, "routes": Route.json(routes)]
        if let transcribe { o["transcribe"] = .bool(transcribe) }
        return o
    }
}
