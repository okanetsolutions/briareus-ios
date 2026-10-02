// The client API (/api/v1) over HTTPS: one token, no cookies, no cache, no redirects, no automatic retries.
import Foundation

// MARK: - Errors

struct APIError: Error, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case invalidAddress, invalidToken, redirected, nonJSON, incompatibleVersion, oversizedRequest
        case http        // status and message set
        case network     // could not reach or finish talking to the server; message says why
        case cancelled   // the screen that asked went away
    }
    var kind: Kind
    var status = 0
    var message: String?
    /// Seconds to wait; nil without a Retry-After header.
    var retryAfter: Double?

    init(_ kind: Kind, status: Int = 0, message: String? = nil, retryAfter: Double? = nil) {
        self.kind = kind; self.status = status; self.message = message; self.retryAfter = retryAfter
    }
    static func refused(_ message: String) -> APIError { APIError(.http, status: 403, message: message) }

    var unauthorized: Bool { kind == .http && status == 401 }
    /// A 4xx is a definite refusal; anything else may have gone through.
    var isRefusal: Bool { kind == .http && status >= 400 && status < 500 }

    /// What the user is told.
    var description: String {
        switch kind {
        case .invalidAddress: return "Enter an HTTPS server address, optionally ending in /api/v1, without credentials or query parameters."
        case .invalidToken: return "Paste the complete token from Settings → Devices and clients."
        case .redirected: return "The server redirected this request. Check the Cloudflare Access exception for /api/v1 and /api/v1/*."
        case .nonJSON: return "The server returned an unexpected response. Check that the client API is deployed and reachable through Cloudflare Access."
        case .incompatibleVersion: return "This server uses an unsupported client API version."
        case .oversizedRequest: return "This message exceeds the server’s 1 MiB request limit. Shorten it before sending."
        case .network: return message ?? "The server could not be reached."
        case .cancelled: return "Cancelled."
        case .http:
            if status == 401 { return "This token has expired or was revoked. Reconnect with a new token." }
            if status == 403 { return "Access denied: \(message ?? "")" }
            if status == 429 { return "The server is rate limiting requests. Updates will resume after a delay." }
            return "\(message ?? "Request failed") (HTTP \(status))"
        }
    }

    static func statusText(_ status: Int) -> String {
        switch status {
        case 400: return "bad request"; case 401: return "unauthorized"; case 403: return "forbidden"; case 404: return "not found"
        case 405: return "method not allowed"; case 408: return "request timeout"; case 409: return "conflict"; case 413: return "request too large"
        case 422: return "unprocessable entity"; case 429: return "too many requests"; case 500: return "internal server error"
        case 502: return "bad gateway"; case 503: return "service unavailable"; case 504: return "gateway timeout"
        default: return "request failed"
        }
    }
}

extension APIError: LocalizedError { var errorDescription: String? { description } }

// MARK: - Address

/// An HTTPS origin and the client API base beneath it.
struct ServerAddress: Equatable, Sendable {
    var baseURL: String
    var origin: String
    var host: String
    var port: Int   // 0 for the default

    init?(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8, trimmed.prefix(8).lowercased() == "https://" else { return nil }
        let rest = String(trimmed.dropFirst(8))
        if rest.contains("?") || rest.contains("#") { return nil }
        let authority: String, path: String
        if let slash = rest.firstIndex(of: "/") { authority = String(rest[..<slash]); path = String(rest[slash...]) }
        else { authority = rest; path = "" }
        if authority.isEmpty || authority.contains("@") { return nil }
        var host: String, port = 0
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            host = String(authority[...close])
            let after = authority[authority.index(after: close)...]
            if after.hasPrefix(":") {
                guard let n = Int(after.dropFirst()), n >= 1, n <= 65535 else { return nil }
                port = n
            } else if !after.isEmpty { return nil }
        } else if let colon = authority.firstIndex(of: ":") {
            host = String(authority[..<colon])
            guard let n = Int(authority[authority.index(after: colon)...]), n >= 1, n <= 65535 else { return nil }
            port = n
        } else { host = authority }
        if host.isEmpty { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-.[]:_"))
        if host.unicodeScalars.contains(where: { !allowed.contains($0) || !$0.isASCII }) { return nil }
        host = host.lowercased()
        guard ["", "/", "/api/v1", "/api/v1/"].contains(path) else { return nil }
        if port == 443 { port = 0 }
        self.host = host; self.port = port
        origin = port != 0 ? "https://\(host):\(port)" : "https://\(host)"
        baseURL = origin + "/api/v1/"
    }
}

/// Whether a ▶ Run preview's Cloudflare Access service token (`GET /preview/access`) may go with a request to `url`: only
/// over HTTPS, to a host ending in `.` + `hostSuffix`, so the secret never reaches any other site.
func previewAccessApplies(url: String, hostSuffix: String) -> Bool {
    guard url.count > 8, url.prefix(8).lowercased() == "https://", !hostSuffix.isEmpty else { return false }
    let rest = url.dropFirst(8)
    var authority = String(rest.prefix { !"/?#".contains($0) })
    // Credentials in the address would let it name one host and reach another.
    if authority.contains("@") { return false }
    if let colon = authority.firstIndex(of: ":") { authority = String(authority[..<colon]) }
    while authority.hasSuffix(".") { authority.removeLast() }
    var suffix = hostSuffix.lowercased()
    if suffix.hasPrefix(".") { suffix.removeFirst() }
    let host = authority.lowercased()
    return !suffix.isEmpty && host.count > suffix.count + 1 && host.hasSuffix("." + suffix)
}

func apiTokenValid(_ token: String) -> Bool {
    guard token.hasPrefix("brm_"), token.utf8.count == 47 else { return false }
    return token.dropFirst(4).unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-") }
}

/// Seconds to wait from a Retry-After header, or nil when it cannot be read.
func retryAfterSeconds(_ value: String?, now: Date = Date()) -> Double? {
    guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
    if let seconds = Double(value), seconds.isFinite { return max(0, seconds) }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "GMT")
    f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    guard let when = f.date(from: value) else { return nil }
    return max(0, when.timeIntervalSince(now))
}

// MARK: - Routes

/// One of the calls this app makes, and the route that answers it. A `{name}` in `path` is filled with the argument of
/// that name, URL-encoded; the other arguments go in the query of a GET or DELETE and in the JSON body otherwise. `set`
/// names a body flag the call always sends as true. `filter` names an argument the route has no parameter for: it is
/// kept back, and the answer's `list` is cut to the rows whose field of that name equals it.
struct APIRoute: Sendable {
    let name: String, method: String, path: String
    var set: String? = nil, filter: String? = nil, list: String? = nil

    static func named(_ name: String) -> APIRoute? { table[name] }

    // Every call the app makes, on the /api/v1 route that answers it.
    static let all: [APIRoute] = [
        // The token itself: revoking it signs this device out on the server (the iPhone app's Settings).
        .init(name: "revoke_token", method: "DELETE", path: "token"),
        // Projects
        .init(name: "projects", method: "GET", path: "projects"),
        .init(name: "branches", method: "GET", path: "branches"),
        .init(name: "runtimes", method: "GET", path: "runtimes"),
        .init(name: "usage", method: "GET", path: "usage"),
        .init(name: "usage_all", method: "GET", path: "usage/all"),   // every project's spend; a filter given as an array repeats
        .init(name: "actions", method: "GET", path: "actions"),
        .init(name: "action", method: "POST", path: "actions"),       // an errand on a pull request, named in `action`
        // Pull requests
        .init(name: "pulls", method: "GET", path: "pulls"),
        .init(name: "pull", method: "GET", path: "pulls/{pr}"),
        .init(name: "pull_description", method: "GET", path: "pulls/{pr}/description"),
        .init(name: "pull_files", method: "GET", path: "pulls/{pr}/files"),
        .init(name: "pull_commits", method: "GET", path: "pulls/{pr}/commits"),
        .init(name: "pull_checks", method: "GET", path: "pulls/{pr}/checks"),
        .init(name: "pull_comments", method: "GET", path: "pulls/{pr}/comments"),
        .init(name: "pull_reviews", method: "GET", path: "pulls/{pr}/reviews"),
        .init(name: "pull_review_comments", method: "GET", path: "pulls/{pr}/review-comments"),
        .init(name: "findings", method: "GET", path: "pulls/{pr}/findings"),
        .init(name: "finding_decision", method: "POST", path: "pulls/{pr}/findings/decision"),
        .init(name: "merge_pull", method: "POST", path: "pulls/{pr}/merge"),
        .init(name: "serve_pull", method: "POST", path: "pulls/{prNumber}/serve"),
        .init(name: "commit", method: "GET", path: "commits/{sha}"),
        // Issues
        .init(name: "close_issue", method: "POST", path: "issues/{issue}/close"),   // `reason` completed or not_planned, and an optional `comment`
        // Sessions. The list has no project parameter: a `repo` argument cuts the answer down here instead.
        .init(name: "sessions", method: "GET", path: "sessions", filter: "repo", list: "sessions"),
        .init(name: "start_session", method: "POST", path: "sessions"),
        .init(name: "review", method: "POST", path: "sessions", set: "review"),
        .init(name: "qa", method: "POST", path: "sessions", set: "qa"),
        .init(name: "session", method: "GET", path: "sessions/{sessionId}"),
        .init(name: "rename", method: "PATCH", path: "sessions/{sessionId}"),
        .init(name: "delete", method: "DELETE", path: "sessions/{sessionId}"),
        .init(name: "message", method: "POST", path: "sessions/{sessionId}/messages"),
        .init(name: "drop_message", method: "DELETE", path: "sessions/{sessionId}/queue/{index}"),
        .init(name: "cancel", method: "POST", path: "sessions/{sessionId}/cancel"),
        .init(name: "close", method: "POST", path: "sessions/{sessionId}/close"),
        .init(name: "reopen", method: "POST", path: "sessions/{sessionId}/reopen"),
        .init(name: "serve", method: "POST", path: "sessions/{sessionId}/serve"),
        .init(name: "compact", method: "POST", path: "sessions/{sessionId}/compact"),
        .init(name: "clear", method: "POST", path: "sessions/{sessionId}/clear"),
        .init(name: "review_loop", method: "POST", path: "sessions/{sessionId}/review-loop"),
        .init(name: "qa_loop", method: "POST", path: "sessions/{sessionId}/qa-loop"),
        .init(name: "link_pr", method: "POST", path: "sessions/{sessionId}/link-pr"),
        .init(name: "complete_findings", method: "POST", path: "sessions/{sessionId}/findings/triage"),
        .init(name: "save_findings", method: "POST", path: "sessions/{sessionId}/findings/save"),
        .init(name: "reply_finding", method: "POST", path: "sessions/{sessionId}/findings/reply"),
        .init(name: "delete_finding", method: "POST", path: "sessions/{sessionId}/findings/delete"),
        // The Cloudflare Access service token the Run tab's browser sends to ▶ Run preview hosts; a manage token.
        .init(name: "preview_access", method: "GET", path: "preview/access"),
        // Composer. These two send raw bytes (upload, transcribe); the entries say whether the server has them.
        .init(name: "upload", method: "POST", path: "uploads"),
        .init(name: "transcribe", method: "POST", path: "transcribe"),
        // Settings, for an admin token: every project with all its settings, and the values a new one starts from.
        .init(name: "settings_projects", method: "GET", path: "settings/projects"),
        .init(name: "create_project", method: "POST", path: "settings/projects"),
        .init(name: "update_project", method: "PUT", path: "settings/projects/{id}"),
        .init(name: "delete_project", method: "DELETE", path: "settings/projects/{id}"),
        .init(name: "order_projects", method: "PUT", path: "settings/projects/order"),
        // The providers sessions start on: every row, its connection and quota, its login, and a probe of an endpoint.
        .init(name: "settings_providers", method: "GET", path: "settings/providers"),
        .init(name: "create_provider", method: "POST", path: "settings/providers"),
        .init(name: "update_provider", method: "PUT", path: "settings/providers/{id}"),
        .init(name: "delete_provider", method: "DELETE", path: "settings/providers/{id}"),
        .init(name: "test_provider", method: "POST", path: "settings/providers/test"),
        .init(name: "provider_status", method: "GET", path: "settings/providers/{id}/status"),
        .init(name: "provider_login", method: "POST", path: "settings/providers/{id}/login"),
        .init(name: "provider_login_start", method: "POST", path: "settings/providers/{id}/login/start"),
        .init(name: "provider_login_finish", method: "POST", path: "settings/providers/{id}/login/finish"),
        // The database pool: the servers sessions claim one at a time, and a probe of one as its form holds it.
        .init(name: "settings_db_servers", method: "GET", path: "settings/db-servers"),
        .init(name: "create_db_server", method: "POST", path: "settings/db-servers"),
        .init(name: "update_db_server", method: "PUT", path: "settings/db-servers/{id}"),
        .init(name: "delete_db_server", method: "DELETE", path: "settings/db-servers/{id}"),
        .init(name: "test_db_server", method: "POST", path: "settings/db-servers/test"),
        // The SSH servers agents may run commands on, each held to one project; also for an admin token.
        .init(name: "settings_ssh_servers", method: "GET", path: "settings/ssh/servers"),
        .init(name: "create_ssh_server", method: "POST", path: "settings/ssh/servers"),
        .init(name: "update_ssh_server", method: "PUT", path: "settings/ssh/servers/{id}"),
        .init(name: "delete_ssh_server", method: "DELETE", path: "settings/ssh/servers/{id}"),
        // The database login stored with one, opened, for a tunnel over it to its database.
        .init(name: "ssh_server_db_credentials", method: "GET", path: "settings/ssh/servers/{id}/db-credentials"),
        // The tokens issued and the projects one can be held to; a new token's secret is in the create answer alone.
        .init(name: "settings_devices", method: "GET", path: "settings/devices"),
        .init(name: "create_device", method: "POST", path: "settings/devices"),
        .init(name: "delete_device", method: "DELETE", path: "settings/devices/{id}"),
    ]
    private static let table: [String: APIRoute] = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
}

// MARK: - Transport

struct HTTPResponse: Sendable {
    var status: Int
    var contentType: String?
    var retryAfter: String?
    var body: Data
}

/// One round trip. Throws only when nothing was received, with the reason as the error's message.
protocol HTTPTransport: Sendable {
    func send(method: String, url: URL, headers: [String: String], body: Data?, timeout: TimeInterval) async throws -> HTTPResponse
}

/// URLSession with no cookies, no cache, no stored credentials and no redirects.
final class URLSessionTransport: NSObject, HTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCredentialStorage = nil
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.httpAdditionalHeaders = ["User-Agent": "Briareus-Mac/1.0"]
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func send(method: String, url: URL, headers: [String: String], body: Data?, timeout: TimeInterval) async throws -> HTTPResponse {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = body
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError(.network, message: "The server could not be reached.") }
            return HTTPResponse(status: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type"),
                                retryAfter: http.value(forHTTPHeaderField: "Retry-After"), body: data)
        } catch let error as URLError {
            if error.code == .cancelled { throw APIError(.cancelled) }
            throw APIError(.network, message: URLSessionTransport.text(error))
        }
    }

    static func text(_ error: URLError) -> String {
        switch error.code {
        case .timedOut: return "The request timed out."
        case .cannotConnectToHost: return "Could not connect to the server."
        case .cannotFindHost, .dnsLookupFailed: return "The server address could not be found."
        case .networkConnectionLost: return "The connection with the server was interrupted."
        case .notConnectedToInternet: return "This Mac is not connected to the internet."
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
             .secureConnectionFailed: return "The server’s certificate could not be verified."
        case .cancelled: return "The request was cancelled."
        default: return error.localizedDescription
        }
    }
}

// MARK: - Client

final class APIClient: @unchecked Sendable {
    static let requestTimeout: TimeInterval = 30
    static let maxRequestBytes = 1_048_576
    static let uploadLimit = 25 * 1024 * 1024

    let address: ServerAddress
    private let token: String
    var transport: HTTPTransport

    /// Fails with `.invalidToken` unless the token has the token shape.
    init(address: ServerAddress, token: String, transport: HTTPTransport = URLSessionTransport()) throws {
        guard apiTokenValid(token) else { throw APIError(.invalidToken) }
        self.address = address; self.token = token; self.transport = transport
    }

    private func send(method: String, url: String, contentType: String?, body: Data?, timeout: TimeInterval) async throws -> JSON {
        guard let u = URL(string: url) else { throw APIError(.invalidAddress) }
        var headers = ["Authorization": "Bearer \(token)", "Accept": "application/json"]
        if let contentType { headers["Content-Type"] = contentType }
        // No automatic application-level retries, including for POST reads: the screen owns read backoff.
        let r = try await transport.send(method: method, url: u, headers: headers, body: body, timeout: timeout)
        if r.status >= 300 && r.status < 400 { throw APIError(.redirected, status: r.status) }
        let type = r.contentType?.lowercased().split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) }
        let isJSON = type == "application/json"
        if r.status < 200 || r.status >= 300 {
            let payload = isJSON ? JSON.parse(r.body) : nil
            throw APIError(.http, status: r.status, message: payload?["error"].nonEmpty ?? APIError.statusText(r.status),
                           retryAfter: retryAfterSeconds(r.retryAfter))
        }
        guard isJSON, let json = JSON.parse(r.body) else { throw APIError(.nonJSON, status: r.status) }
        return json
    }

    private func request(_ path: String, method: String, body: JSON?, timeout: TimeInterval) async throws -> JSON {
        var data: Data?
        if let body {
            data = body.data
            if data!.count > APIClient.maxRequestBytes { throw APIError(.oversizedRequest) }
        }
        return try await send(method: method, url: address.baseURL + path, contentType: body != nil ? "application/json" : nil, body: data, timeout: timeout)
    }

    /// `GET /`: the token's own record and what the server can do.
    func discovery() async throws -> Discovery {
        let j = try await request("", method: "GET", body: nil, timeout: APIClient.requestTimeout)
        guard let d = Discovery(j) else { throw APIError(.nonJSON) }
        if d.version != 1 { throw APIError(.incompatibleVersion) }
        return d
    }
    /// `GET /openapi.json`, read into the routes the server has and who may call each.
    func catalog() async throws -> [Route] {
        let j = try await request("openapi.json", method: "GET", body: nil, timeout: APIClient.requestTimeout)
        guard let routes = Route.parse(j) else { throw APIError(.nonJSON) }
        return routes
    }

    /// The path and remaining arguments of a call, or a 400 before any network call.
    static func resolve(_ route: APIRoute, _ arguments: JSON) throws -> (path: String, rest: [String: JSON]) {
        var rest = arguments.object ?? [:]
        var path = ""
        var p = Substring(route.path)
        while let open = p.firstIndex(of: "{") {
            path += p[..<open]
            let close = p[open...].firstIndex(of: "}")!
            let arg = String(p[p.index(after: open)..<close])
            guard let value = urlValue(rest[arg] ?? .null, inPath: true) else {
                throw APIError(.http, status: 400, message: "Missing argument: \(arg)")
            }
            path += value
            rest.removeValue(forKey: arg)
            p = p[p.index(after: close)...]
        }
        path += p
        return (path, rest)
    }

    /// One call by name, on its route. `timeout` is for a call that answers only once its work is done; nil leaves the
    /// 30-second default. A name not in the table, or a missing path argument, is refused with a 400 before any network call.
    func call(_ name: String, _ arguments: JSON = [:], timeout: TimeInterval? = nil) async throws -> JSON {
        guard let route = APIRoute.named(name) else { throw APIError(.http, status: 400, message: "Unknown call") }
        var (path, rest) = try APIClient.resolve(route, arguments)
        var kept: String?
        if let filter = route.filter {
            kept = rest[filter]?.string
            rest.removeValue(forKey: filter)
        }
        let reads = route.method == "GET" || route.method == "DELETE"
        let t = timeout ?? APIClient.requestTimeout
        var result: JSON
        if reads {
            var sep = "?"
            for key in rest.keys.sorted() {
                // An array is a repeatable parameter: `project=a&project=b`.
                let arg = rest[key]!
                let values = arg.array ?? [arg]
                for v in values {
                    guard let value = APIClient.urlValue(v, inPath: false) else { continue }
                    path += "\(sep)\(APIClient.encode(key))=\(value)"
                    sep = "&"
                }
            }
            result = try await request(path, method: route.method, body: nil, timeout: t)
        } else {
            if let set = route.set { rest[set] = .bool(true) }
            result = try await request(path, method: route.method, body: .object(rest), timeout: t)
        }
        if let kept, let list = route.list, let filter = route.filter {
            result[list] = .array(result[list].items.filter { $0[filter].string == kept })
        }
        return result
    }

    /// The text of a recorded voice note, sent with the content type it was recorded in.
    func transcribe(_ audio: Data, contentType: String = "audio/mp4") async throws -> String {
        // The server allows the transcription two minutes.
        let j = try await send(method: "POST", url: address.baseURL + "transcribe", contentType: contentType, body: audio, timeout: 150)
        guard let text = j["text"].string else { throw APIError(.nonJSON) }
        return text
    }

    /// Stores a file to attach to a message, as the dashboard's composer does: the bytes are the body and the name rides in the
    /// query. The answer is the id a message takes in `attachments`.
    func upload(name: String, bytes: Data) async throws -> String {
        if bytes.count > APIClient.uploadLimit { throw APIError(.http, status: 413, message: "The file exceeds the server’s 25 MB limit for an attachment.") }
        let url = address.baseURL + "uploads?name=" + APIClient.encode(name.isEmpty ? "file" : name)
        // Always octet-stream, whatever the file is: the server reads the raw body.
        let j = try await send(method: "POST", url: url, contentType: "application/octet-stream", body: bytes, timeout: 120)
        guard let id = j["file"]["id"].nonEmpty else { throw APIError(.nonJSON) }
        return id
    }

    static func encode(_ s: String) -> String {
        var out = ""
        for b in s.utf8 {
            let c = Character(UnicodeScalar(b))
            if (b < 0x80 && (c.isLetter || c.isNumber)) || "-_.~".contains(c) { out.append(c) }
            else { out += String(format: "%%%02X", b) }
        }
        return out
    }
    /// A string or number as it goes in a URL, or nil for anything else (and for an empty string in a path).
    static func urlValue(_ v: JSON, inPath: Bool) -> String? {
        switch v {
        case .string(let s): return inPath && s.isEmpty ? nil : encode(s)
        case .number(let n):
            guard n.isFinite else { return nil }
            if n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
            return inPath ? nil : String(n)
        case .bool(let b): return inPath ? nil : (b ? "1" : "0")
        default: return nil
        }
    }
}
