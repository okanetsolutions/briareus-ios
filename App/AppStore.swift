import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    /// One connection for the phone's windows and the car's screen.
    static let shared = AppStore()
    @Published private(set) var client: APIClient?
    @Published private(set) var device: Device?
    @Published private(set) var operations: [Operation] = []
    /// What the server last said about transcribing; nil from a server that predates voice notes.
    @Published private(set) var transcribes: Bool?
    /// The errands the server lists, which word a suggested one this app predates.
    @Published private(set) var errands: [JSONValue] = []
    @Published var connecting = false
    @Published var connectionError: String?
    @Published var server = UserDefaults.standard.string(forKey: "serverOrigin") ?? ""
    /// What screens showed last, read before the network answers. It belongs to one device token and goes with it.
    let cache = DiskCache(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Responses", isDirectory: true))

    /// What the screens of each project share, kept for as long as the connection is.
    private var feeds: [String: ProjectFeed] = [:]
    private var errandsRead: Date?
    private var errandsRestored = false

    var canManage: Bool { device?.canManage == true }
    /// The microphone shows for any device allowed to write the message a note becomes;
    /// pressed on a server that cannot transcribe, it says what is missing, as the dashboard's does.
    var canTranscribe: Bool { canManage }
    /// Asks the server again before refusing, so a server set up since launch needs no restart of the app.
    func voiceNotesOff() async -> String? {
        guard transcribes != true, let api = client else { return Discovery.voiceNotesOff(transcribes) }
        do {
            let discovery = try await api.discovery()
            guard client === api else { return nil }
            transcribes = discovery.transcribe
            await cache.store(Connection(device: discovery.device, operations: operations, transcribe: discovery.transcribe), for: "connection")
        } catch {
            if (error as? APIError)?.isUnauthorized == true { await invalidateCredentials(error); return nil }
            return "The server could not be asked about voice notes: \(error.localizedDescription)"
        }
        return Discovery.voiceNotesOff(transcribes)
    }
    func supports(_ name: String) -> Bool {
        operations.contains { $0.name == name && ($0.readOnly || canManage) }
    }
    func feed(_ repo: String) -> ProjectFeed {
        if let feed = feeds[repo] { return feed }
        let feed = ProjectFeed(repo: repo, store: self)
        feeds[repo] = feed
        return feed
    }
    /// The errands change with the server's settings, not with a project's work, so a board that polls
    /// asks for them once in a while rather than every time. What this device saved shows meanwhile.
    func loadErrands() async {
        if !errandsRestored {
            errandsRestored = true
            if let saved: JSONValue = await cache.value("actions"), errands.isEmpty { errands = saved["actions"].array }
        }
        guard canManage, supports("actions"), errandsRead.map({ abs(Date().timeIntervalSince($0)) > 600 }) ?? true else { return }
        let api = client, before = errandsRead
        errandsRead = Date()
        guard let served: JSONValue = try? await call("actions"), client === api else {
            if client === api { errandsRead = before }
            return
        }
        if errands != served["actions"].array { errands = served["actions"].array }
        await cache.store(served, for: "actions")
    }
    /// Leaves the server: nothing read from it outlives the token it was read with.
    private func disconnect() {
        client?.invalidate(); client = nil; device = nil; operations = []; transcribes = nil
        feeds = [:]; errands = []; errandsRead = nil; errandsRestored = false
    }
    func restore() async {
        guard client == nil, !server.isEmpty else { return }
        do {
            let address = try ServerAddress(server)
            guard let token = try Keychain.read(address.origin) else { return }
            await cache.prune(olderThan: 30 * 86_400)
            // A device that paired before opens on what it saved; the server confirms the token meanwhile.
            if let saved: Connection = await cache.value("connection"), client == nil, !connecting {
                let api = try APIClient(address: address, token: token)
                device = saved.device; operations = saved.operations; transcribes = saved.transcribe; client = api
                await verify(api, saved: saved)
            } else { await connect(server: server, token: token) }
        } catch { connectionError = error.localizedDescription }
    }
    private func verify(_ api: APIClient, saved: Connection) async {
        do {
            let discovery = try await api.discovery()
            let catalog = try await api.operations()
            guard client === api else { return }
            // Saved screens may hold projects this device can no longer read.
            if discovery.device.id != saved.device.id || Set(discovery.device.repos) != Set(saved.device.repos) { await cache.removeAll() }
            device = discovery.device; operations = catalog.operations; transcribes = discovery.transcribe
            await cache.store(Connection(device: discovery.device, operations: catalog.operations, transcribe: discovery.transcribe), for: "connection")
        } catch {
            guard client === api, let error = error as? APIError else { return }
            if error.isUnauthorized { await invalidateCredentials(error) }
            else if error == .incompatibleVersion {
                disconnect()
                connectionError = error.localizedDescription
            }
            // Anything else is a server out of reach: saved screens stay readable and report their own errors.
        }
    }
    func connect(server: String, token: String) async {
        guard !connecting else { return }
        connecting = true; connectionError = nil
        defer { connecting = false }
        do {
            let address = try ServerAddress(server)
            let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
            let api = try APIClient(address: address, token: token)
            let discovery = try await api.discovery()
            let catalog = try await api.operations()
            try Keychain.save(token, origin: address.origin)
            self.server = address.origin
            UserDefaults.standard.set(address.origin, forKey: "serverOrigin")
            let saved: Connection? = await cache.value("connection")
            if saved?.device.id != discovery.device.id { await cache.removeAll() }
            await cache.store(Connection(device: discovery.device, operations: catalog.operations, transcribe: discovery.transcribe), for: "connection")
            device = discovery.device; operations = catalog.operations; transcribes = discovery.transcribe; client = api
        } catch { connectionError = error.localizedDescription }
    }
    func call<T: Decodable>(_ name: String, _ args: [String: JSONValue] = [:], timeout: TimeInterval? = nil) async throws -> T {
        guard let api = client, supports(name) else {
            throw APIError.http(403, "This device cannot perform that action.", retryAfter: nil)
        }
        do { return try await api.operation(name, arguments: args, timeout: timeout) }
        catch {
            if (error as? APIError)?.isUnauthorized == true { await invalidateCredentials(error) }
            throw error
        }
    }
    func transcribe(_ audio: Data) async throws -> String {
        guard let api = client, canTranscribe else {
            throw APIError.http(403, "This device cannot transcribe voice notes.", retryAfter: nil)
        }
        do { return try await api.transcribe(audio) }
        catch {
            if (error as? APIError)?.isUnauthorized == true { await invalidateCredentials(error) }
            throw error
        }
    }
    private func invalidateCredentials(_ error: Error) async {
        disconnect()
        await cache.removeAll()
        // Keep the origin so a replacement token is easy to enter. A failed deletion is reported.
        do {
            try Keychain.remove(try ServerAddress(server).origin)
            connectionError = error.localizedDescription
        } catch { connectionError = error.localizedDescription }
    }
    func forget() async throws {
        try Keychain.remove(try ServerAddress(server).origin)
        disconnect(); connectionError = nil
        await cache.removeAll()
        UserDefaults.standard.removeObject(forKey: "serverOrigin")
        server = ""
    }
    func revoke() async throws {
        guard let client else { return }
        do { try await client.revoke() }
        catch { if (error as? APIError)?.isUnauthorized != true { throw error } }
        try await forget()
    }
}

/// What a failed read should say, or nil for one that was only abandoned: left behind by its screen, not refused.
func failure(_ error: Error) -> String? {
    if error is CancellationError || (error as? URLError)?.code == .cancelled { return nil }
    return error.localizedDescription
}

/// What a screen's polling remembers from one task to the next: when the server last answered it,
/// or when it last stopped asking.
final class PollClock {
    var last: Date?
}

// The task is canceled by SwiftUI when its screen disappears or the scene becomes inactive.
@MainActor
func poll(every seconds: Double, clock: PollClock, action: () async throws -> Void, failed: (Error) -> Void) async {
    // A task begun soon after the last answer waits out the rest of the interval: closing a dialog or a
    // glance at another app is no reason to ask again.
    if let last = clock.last {
        let wait = min(seconds, seconds - Date().timeIntervalSince(last))
        if wait > 0 { do { try await Task.sleep(for: .seconds(wait)) } catch { return } }
    }
    var failures = 0
    while !Task.isCancelled {
        var delay = seconds
        do { try await action(); failures = 0; clock.last = Date() }
        catch {
            if Task.isCancelled || error is CancellationError { return }
            failed(error); failures += 1
            if (error as? APIError)?.isUnauthorized == true { return }
            delay = max(min(60, pow(2, Double(min(failures, 6)))), (error as? APIError)?.retryDelay ?? 0)
        }
        do { try await Task.sleep(for: .seconds(delay)) } catch { return }
    }
}
