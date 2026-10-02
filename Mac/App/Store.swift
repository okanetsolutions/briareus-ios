// The connection: one token, the server's route catalog, the saved-response cache, and requests answered on the main actor.
import AppKit
import Foundation

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var client: APIClient?
    @Published private(set) var device: Device?
    /// What the server lists in its OpenAPI document.
    @Published private(set) var routes: [Route] = []
    /// nil from a server that predates voice notes.
    @Published private(set) var transcribes: Bool?
    @Published private(set) var connecting = false
    @Published var connectionError: String?
    /// The origin shown in the pairing field.
    @Published private(set) var server: String
    /// The app is in the foreground and not minimized; polling pauses otherwise.
    @Published var active = true

    let cache: DiskCache
    private static let originKey = "serverOrigin"

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        cache = DiskCache(directory: base.appendingPathComponent("Okanet/Briareus/Responses", isDirectory: true))
        server = UserDefaults.standard.string(forKey: Store.originKey) ?? ""
    }

    var connected: Bool { client != nil }
    var canManage: Bool { device?.canManage ?? false }
    var isAdmin: Bool { device?.isAdmin ?? false }
    /// The microphone shows for any device allowed to write the message a note becomes.
    var canTranscribe: Bool { canManage }

    /// Whether the server has the route a call is made on and this token may call it.
    func supports(_ call: String) -> Bool {
        guard let route = APIRoute.named(call), let device else { return false }
        return Route.allow(routes, method: route.method, path: route.path, permission: device.permission)
    }
    /// Files can go with a message (`message`, or `start_session` for a session's first prompt): the server takes uploads
    /// and that call, and this token may write.
    func supportsAttachments(on call: String = "message") -> Bool { canManage && supports("upload") && supports(call) }

    // MARK: Pairing

    private func adopt(_ connection: Connection) {
        device = connection.device; routes = connection.routes; transcribes = connection.transcribe
    }
    private func dropClient() { client = nil; device = nil; routes = []; transcribes = nil }
    private func saveConnection(_ connection: Connection) { cache.store(connection.json, "connection") }

    private static func pair(_ client: APIClient) async throws -> Connection {
        let discovery = try await client.discovery()
        let routes = try await client.catalog()
        return Connection(device: discovery.device, routes: routes, transcribe: discovery.transcribe)
    }

    func connect(server input: String, token: String) {
        guard !connecting else { return }
        connectionError = nil
        guard let address = ServerAddress(input) else { connectionError = APIError(.invalidAddress).description; return }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let newClient: APIClient
        do { newClient = try APIClient(address: address, token: token) } catch let e as APIError { connectionError = e.description; return } catch { return }
        connecting = true
        Task {
            defer { connecting = false }
            do {
                let connection = try await Store.pair(newClient)
                do { try Keychain.save(token, origin: address.origin) } catch { connectionError = error.localizedDescription; return }
                server = address.origin
                UserDefaults.standard.set(address.origin, forKey: Store.originKey)
                let previous = cache.value("connection").flatMap(Connection.init)
                if previous?.device.id != connection.device.id { cache.removeAll() }
                saveConnection(connection)
                dropClient()
                adopt(connection)
                client = newClient
                connectionError = nil
            } catch let e as APIError {
                connectionError = e.description
            } catch { connectionError = error.localizedDescription }
        }
    }

    /// A device that paired before opens on what it saved; the server confirms the token meanwhile.
    func restore() {
        guard client == nil, !server.isEmpty, let address = ServerAddress(server) else { return }
        let token: String
        do {
            guard let t = try Keychain.read(address.origin) else { return }
            token = t
        } catch { connectionError = Keychain.failureText; return }
        cache.prune(olderThan: 30 * 86400)
        guard let saved = cache.value("connection").flatMap(Connection.init) else { connect(server: server, token: token); return }
        let restored: APIClient
        do { restored = try APIClient(address: address, token: token) } catch let e as APIError { connectionError = e.description; return } catch { return }
        adopt(saved)
        client = restored
        Task {
            do {
                let connection = try await Store.pair(restored)
                guard client === restored else { return }
                // Saved screens may hold projects this device can no longer read.
                if connection.device.id != saved.device.id || !connection.device.sameRepos(saved.device) { cache.removeAll() }
                adopt(connection)
                saveConnection(connection)
            } catch let e as APIError {
                guard client === restored else { return }
                if e.unauthorized { invalidateCredentials(e) }
                else if e.kind == .incompatibleVersion { dropClient(); connectionError = e.description }
                // Anything else is a server out of reach: saved screens stay readable and report their own errors.
            } catch {}
        }
    }

    /// Handles a 401 from any request: the token was revoked or expired.
    func invalidateCredentials(_ error: APIError) {
        dropClient()
        cache.removeAll()
        // Keep the origin so a replacement token is easy to enter. A failed deletion is reported.
        var removed = true
        if let address = ServerAddress(server) { removed = Keychain.remove(address.origin) }
        connectionError = removed ? error.description : Keychain.failureText
    }

    /// Removes local credentials and saved conversations only.
    func forget() {
        if let address = ServerAddress(server) { Keychain.remove(address.origin) }
        dropClient()
        connectionError = nil
        cache.removeAll()
        UserDefaults.standard.removeObject(forKey: Store.originKey)
        server = ""
    }

    /// Asks the server again before refusing voice notes: nil when they work, else what is missing.
    func voiceNotesOff() async -> String? {
        guard transcribes != true, let client else { return Discovery.voiceNotesOff(transcribes) }
        do {
            let d = try await client.discovery()
            guard self.client === client else { return nil }
            transcribes = d.transcribe
            if let device { saveConnection(Connection(device: device, routes: routes, transcribe: d.transcribe)) }
            return Discovery.voiceNotesOff(d.transcribe)
        } catch let e as APIError {
            if e.unauthorized { invalidateCredentials(e); return nil }
            return "The server could not be asked about voice notes: \(e.description)"
        } catch { return nil }
    }

    // MARK: Requests

    private func finish<T>(_ client: APIClient, _ work: () async throws -> T) async throws -> T {
        do {
            let value = try await work()
            try Task.checkCancellation()
            return value
        } catch let e as APIError {
            if e.unauthorized && self.client === client { invalidateCredentials(e) }
            throw e
        } catch is CancellationError {
            throw APIError(.cancelled)
        }
    }

    /// Makes a call; a token that cannot make it gets a 403 without a network call.
    func call(_ operation: String, _ arguments: JSON = [:], timeout: TimeInterval? = nil) async throws -> JSON {
        guard let client, supports(operation) else { throw APIError.refused("This token cannot perform that action.") }
        return try await finish(client) { try await client.call(operation, arguments, timeout: timeout) }
    }
    func transcribe(_ audio: Data, contentType: String = "audio/mp4") async throws -> String {
        guard let client, canTranscribe else { throw APIError.refused("This token cannot transcribe voice notes.") }
        return try await finish(client) { try await client.transcribe(audio, contentType: contentType) }
    }
    /// Stores a file on the server for the next message; the answer is the id to send.
    func upload(name: String, bytes: Data) async throws -> String {
        guard let client, canManage, supports("upload") else { throw APIError.refused("This server does not take files with a message.") }
        return try await finish(client) { try await client.upload(name: name, bytes: bytes) }
    }
}

/// The user-facing text of a failed request.
func errorText(_ error: Error) -> String {
    (error as? APIError)?.description ?? error.localizedDescription
}
extension Error {
    var isCancellation: Bool { (self as? APIError)?.kind == .cancelled || self is CancellationError }
}

// MARK: - Polling

/// The delay before the next poll after `failures` consecutive failures: exponential up to a minute, or the server's Retry-After.
func pollDelay(base: TimeInterval, failures: Int, retryAfter: Double?) -> TimeInterval {
    guard failures > 0 else { return base }
    var seconds = min(pow(2, Double(min(failures, 6))), 60)
    if let retryAfter, retryAfter > seconds { seconds = retryAfter }
    return seconds
}

/// One-shot polling with the dashboard's backoff, for a `.task`: runs `read` now and again after each delay until the task
/// is cancelled. `read` answers the error of a failed read, or nil. Polling pauses while the app is in the background.
@MainActor
func poll(every base: TimeInterval, immediately: Bool = true, _ read: @MainActor () async -> APIError?) async {
    var failures = 0
    var delay: TimeInterval = immediately ? 0 : base
    while !Task.isCancelled {
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        if Task.isCancelled { return }
        while !Store.shared.active && !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000_000) }
        if Task.isCancelled { return }
        let error = await read()
        if let error, error.kind != .cancelled { failures += 1 } else { failures = 0 }
        delay = pollDelay(base: base, failures: failures, retryAfter: error?.retryAfter)
    }
}
