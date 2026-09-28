import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ServerAddress: Equatable, Sendable {
    public let baseURL: URL
    public let origin: String
    public init(_ input: String) throws {
        guard var c = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme?.lowercased() == "https", let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.port == nil || (1...65535).contains(c.port!),
              ["", "/", "/api/mobile/v1", "/api/mobile/v1/"].contains(c.path)
        else { throw APIError.invalidAddress }
        c.scheme = "https"; c.host = host.lowercased(); c.path = ""
        if c.port == 443 { c.port = nil }
        guard let originURL = c.url else { throw APIError.invalidAddress }
        origin = originURL.absoluteString
        c.path = "/api/mobile/v1/"
        guard let url = c.url else { throw APIError.invalidAddress }
        baseURL = url
    }
}

public enum APIError: Error, LocalizedError, Equatable {
    case invalidAddress, invalidToken, redirected, nonJSON, incompatibleVersion, oversizedRequest
    case http(Int, String, retryAfter: TimeInterval?)
    public var errorDescription: String? {
        switch self {
        case .invalidAddress: return "Enter an HTTPS server address, optionally ending in /api/mobile/v1, without credentials or query parameters."
        case .invalidToken: return "Paste the complete device token from Settings → Mobile devices."
        case .redirected: return "The server redirected this request. Check the Cloudflare Access exception for /api/mobile/v1 and /api/mobile/v1/*."
        case .nonJSON: return "The server returned an unexpected response. Check that the mobile API is deployed and reachable through Cloudflare Access."
        case .incompatibleVersion: return "This server uses an unsupported mobile API version."
        case .oversizedRequest: return "This message exceeds the server’s 1 MiB request limit. Shorten it before sending."
        case .http(401, _, _): return "This device token has expired or was revoked. Reconnect with a new token."
        case .http(403, let message, _): return "Access denied: \(message)"
        case .http(429, _, _): return "The server is rate limiting requests. Updates will resume after a delay."
        case .http(let status, let message, _): return "\(message) (HTTP \(status))"
        }
    }
    public var isUnauthorized: Bool { if case .http(401, _, _) = self { return true }; return false }
    public var retryDelay: TimeInterval? { if case .http(_, _, let delay) = self { return delay }; return nil }
}

public final class RejectRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public final class APIClient: @unchecked Sendable {
    public let address: ServerAddress
    private let token: String
    private let session: URLSession
    public init(address: ServerAddress, token: String, configuration: URLSessionConfiguration = .ephemeral) throws {
        guard token.range(of:  #"\Abrm_[A-Za-z0-9_-]{43}\z"#, options: .regularExpression) != nil else {
            throw APIError.invalidToken
        }
        self.address = address; self.token = token
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        // Long enough for a voice note's transcription; every other request still gives up after 30 idle seconds.
        configuration.timeoutIntervalForResource = 180
        session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    public func invalidate() { session.invalidateAndCancel() }
    public func discovery() async throws -> Discovery {
        let result: Discovery = try await request(path: "", method: "GET", body: nil)
        guard result.version == 1 else { throw APIError.incompatibleVersion }
        return result
    }
    public func operations() async throws -> OperationList {
        try await request(path: "operations", method: "GET", body: nil)
    }
    public func revoke() async throws {
        let _: JSONValue = try await request(path: "token", method: "DELETE", body: nil)
    }
    public func operation<T: Decodable>(_ name: String, arguments: [String: JSONValue] = [:]) async throws -> T {
        guard name.range(of:  #"\A[a-z][a-z0-9_]*\z"#, options: .regularExpression) != nil else {
            throw APIError.http(400, "Invalid operation", retryAfter: nil)
        }
        return try await request(path: "operations/\(name)", method: "POST", body: .object(arguments))
    }
    /// The text of a recorded voice note. `language` is the spoken one as a BCP 47 tag; empty lets the server detect it.
    public func transcribe(_ audio: Data, type: String = "audio/mp4", language: String = "") async throws -> String {
        var components = URLComponents(url: address.baseURL.appendingPathComponent("transcribe"), resolvingAgainstBaseURL: false)
        if !language.isEmpty { components?.queryItems = [URLQueryItem(name: "lang", value: language)] }
        guard let url = components?.url else { throw APIError.invalidAddress }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = audio
        request.setValue(type, forHTTPHeaderField: "Content-Type")
        // The server allows the transcription two minutes.
        request.timeoutInterval = 150
        let result: JSONValue = try await send(request)
        guard let text = result["text"].string else { throw APIError.nonJSON }
        return text
    }
    private func request<T: Decodable>(path: String, method: String, body: JSONValue?) async throws -> T {
        let url = path.isEmpty ? address.baseURL : address.baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            let data = try JSONEncoder().encode(body)
            guard data.count <= 1_048_576 else { throw APIError.oversizedRequest }
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await send(request)
    }
    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // No automatic application-level retries, including for POST reads: the view owns read backoff.
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.nonJSON }
        if (300..<400).contains(http.statusCode) { throw APIError.redirected }
        let json = http.mimeType?.lowercased() == "application/json"
        if !(200..<300).contains(http.statusCode) {
            let payload = json ? (try? JSONDecoder().decode(JSONValue.self, from: data)) : nil
            let message = payload?["error"].string ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw APIError.http(http.statusCode, message, retryAfter: Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After")))
        }
        guard json else { throw APIError.nonJSON }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw APIError.nonJSON }
    }
    public static func retryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = Double(value), seconds.isFinite { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }
}
