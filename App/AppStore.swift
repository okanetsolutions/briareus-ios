import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var client: APIClient?
    @Published private(set) var device: Device?
    @Published private(set) var operations: [Operation] = []
    @Published private(set) var transcribes = false
    @Published var connecting = false
    @Published var connectionError: String?
    @Published var server = UserDefaults.standard.string(forKey: "serverOrigin") ?? ""
    /// What screens showed last, read before the network answers. It belongs to one device token and goes with it.
    let cache = DiskCache(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Responses", isDirectory: true))

    var canManage: Bool { device?.canManage == true }
    /// Voice notes need a server that transcribes and a device allowed to write the message they become.
    var canTranscribe: Bool { transcribes && canManage }
    func supports(_ name: String) -> Bool {
        operations.contains { $0.name == name && ($0.readOnly || canManage) }
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
                device = saved.device; operations = saved.operations; transcribes = saved.transcribe == true; client = api
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
            device = discovery.device; operations = catalog.operations; transcribes = discovery.transcribe == true
            await cache.store(Connection(device: discovery.device, operations: catalog.operations, transcribe: discovery.transcribe), for: "connection")
        } catch {
            guard client === api, let error = error as? APIError else { return }
            if error.isUnauthorized { await invalidateCredentials(error) }
            else if error == .incompatibleVersion {
                client?.invalidate(); client = nil; device = nil; operations = []; transcribes = false
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
            device = discovery.device; operations = catalog.operations; transcribes = discovery.transcribe == true; client = api
        } catch { connectionError = error.localizedDescription }
    }
    func call<T: Decodable>(_ name: String, _ args: [String: JSONValue] = [:]) async throws -> T {
        guard let api = client, supports(name) else {
            throw APIError.http(403, "This device cannot perform that action.", retryAfter: nil)
        }
        do { return try await api.operation(name, arguments: args) }
        catch {
            if (error as? APIError)?.isUnauthorized == true { await invalidateCredentials(error) }
            throw error
        }
    }
    func transcribe(_ audio: Data, language: String) async throws -> String {
        guard let api = client, canTranscribe else {
            throw APIError.http(403, "This device cannot transcribe voice notes.", retryAfter: nil)
        }
        do { return try await api.transcribe(audio, language: language) }
        catch {
            if (error as? APIError)?.isUnauthorized == true { await invalidateCredentials(error) }
            throw error
        }
    }
    private func invalidateCredentials(_ error: Error) async {
        client?.invalidate(); client = nil; device = nil; operations = []; transcribes = false
        await cache.removeAll()
        // Keep the origin so a replacement token is easy to enter. A failed deletion is reported.
        do {
            try Keychain.remove(try ServerAddress(server).origin)
            connectionError = error.localizedDescription
        } catch { connectionError = error.localizedDescription }
    }
    func forget() async throws {
        try Keychain.remove(try ServerAddress(server).origin)
        client?.invalidate(); client = nil; device = nil; operations = []; transcribes = false; connectionError = nil
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

// The task is canceled by SwiftUI when its screen disappears or the scene becomes inactive.
@MainActor
func poll(every seconds: Double, action: () async throws -> Void, failed: (Error) -> Void) async {
    var failures = 0
    while !Task.isCancelled {
        var delay = seconds
        do { try await action(); failures = 0 }
        catch {
            if Task.isCancelled || error is CancellationError { return }
            failed(error); failures += 1
            if (error as? APIError)?.isUnauthorized == true { return }
            delay = max(min(60, pow(2, Double(min(failures, 6)))), (error as? APIError)?.retryDelay ?? 0)
        }
        do { try await Task.sleep(for: .seconds(delay)) } catch { return }
    }
}
