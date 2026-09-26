import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var client: APIClient?
    @Published private(set) var device: Device?
    @Published private(set) var operations: [Operation] = []
    @Published var connecting = false
    @Published var connectionError: String?
    @Published var server = UserDefaults.standard.string(forKey: "serverOrigin") ?? ""

    var canManage: Bool { device?.canManage == true }
    func supports(_ name: String) -> Bool {
        operations.contains { $0.name == name && ($0.readOnly || canManage) }
    }
    func restore() async {
        guard client == nil, !server.isEmpty else { return }
        do {
            let address = try ServerAddress(server)
            if let token = try Keychain.read(address.origin) { await connect(server: server, token: token) }
        } catch { connectionError = error.localizedDescription }
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
            device = discovery.device; operations = catalog.operations; client = api
        } catch { connectionError = error.localizedDescription }
    }
    func call<T: Decodable>(_ name: String, _ args: [String: JSONValue] = [:]) async throws -> T {
        guard let api = client, supports(name) else {
            throw APIError.http(403, "This device cannot perform that action.", retryAfter: nil)
        }
        do { return try await api.operation(name, arguments: args) }
        catch {
            if (error as? APIError)?.isUnauthorized == true { invalidateCredentials(error) }
            throw error
        }
    }
    private func invalidateCredentials(_ error: Error) {
        client?.invalidate(); client = nil; device = nil; operations = []
        // Keep the origin so a replacement token is easy to enter. A failed deletion is reported.
        do {
            try Keychain.remove(try ServerAddress(server).origin)
            connectionError = error.localizedDescription
        } catch { connectionError = error.localizedDescription }
    }
    func forget() throws {
        try Keychain.remove(try ServerAddress(server).origin)
        client?.invalidate(); client = nil; device = nil; operations = []; connectionError = nil
        UserDefaults.standard.removeObject(forKey: "serverOrigin")
        server = ""
    }
    func revoke() async throws {
        guard let client else { return }
        do { try await client.revoke() }
        catch { if (error as? APIError)?.isUnauthorized != true { throw error } }
        try forget()
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
