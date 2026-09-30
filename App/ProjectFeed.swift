import SwiftUI

/// What every screen of a project reads: its conversations and its board. Each is asked for once, however many
/// screens show it, and a screen opening on a project another one shows starts on what that one read.
@MainActor @Observable
final class ProjectFeed {
    /// How often a screen showing the conversations or the board asks for them again. The board costs the
    /// server a question to GitHub each time, so it is left longer than the server keeps its own answer.
    static let sessionsEvery = 7.0, boardEvery = 60.0

    let repo: String
    private(set) var sessions: [Session] = []
    /// True once the conversations were read, from what was saved or from the server.
    private(set) var sessionsLoaded = false
    /// The board as the server sent it, which is what is saved and what names the stacks.
    private(set) var board: JSONValue = .null
    private(set) var pulls: [PullSummary] = []
    private(set) var issues: [IssueSummary] = []
    private(set) var boardLoaded = false

    private struct Reading {
        var at: Date?
        var task: Task<Void, Error>?
    }
    private unowned let store: AppStore
    @ObservationIgnored private var readingSessions = Reading()
    @ObservationIgnored private var readingBoard = Reading()

    init(repo: String, store: AppStore) {
        self.repo = repo; self.store = store
    }

    /// `fresh` asks the server whatever was read a moment ago, as after a write or a pull to refresh.
    func loadSessions(fresh: Bool = false) async throws {
        let key = "sessions:\(repo)"
        if !sessionsLoaded, let saved: [Session] = await store.cache.value(key), !sessionsLoaded { sessions = saved; sessionsLoaded = true }
        try await read(\.readingSessions, every: Self.sessionsEvery, fresh: fresh) { [self] in
            let result: SessionList = try await store.call("sessions", ["repo": .string(repo)])
            let gone = Set(sessions.map(\.id)).subtracting(result.sessions.map(\.id))
            sessions = result.sessions; sessionsLoaded = true
            await store.cache.store(result.sessions, for: key)
            for id in gone { await store.cache.remove("transcript:\(id)") }
        }
    }

    /// Shows the board this device saved, until the server answers.
    func restoreBoard() async {
        if !boardLoaded, let saved: JSONValue = await store.cache.value("pulls:\(repo)"), !boardLoaded { show(saved) }
    }
    /// `fresh` also has the server ask GitHub again instead of answering from its own short cache.
    func loadBoard(fresh: Bool = false) async throws {
        await restoreBoard()
        try await read(\.readingBoard, every: Self.boardEvery, fresh: fresh) { [self] in
            var result: JSONValue
            do { result = try await store.call("pulls", ["repo": .string(repo)].merging(fresh ? ["fresh": .string("1")] : [:]) { $1 }) }
            catch APIError.http(400, _, _) where fresh {
                // A server from before `fresh` refuses the argument it does not know.
                result = try await store.call("pulls", ["repo": .string(repo)])
            }
            show(result)
            await store.cache.store(result, for: "pulls:\(repo)")
        }
    }
    private func show(_ result: JSONValue) {
        board = result
        pulls = result["pulls"].array.compactMap(PullSummary.init)
        issues = result["issues"].array.compactMap(IssueSummary.init)
        boardLoaded = true
    }

    /// One request at a time. A poll finding an answer young enough asks nothing, and one finding a request on
    /// its way waits for that answer. A fresh read lets such a request land first and then asks again, so what
    /// is shown last is what the server said last. The request belongs to the feed: a screen that leaves
    /// while it is out does not take it along, since another may be waiting on it.
    private func read(_ reading: ReferenceWritableKeyPath<ProjectFeed, Reading>, every interval: Double, fresh: Bool,
                      _ request: @escaping @MainActor () async throws -> Void) async throws {
        if let asked = self[keyPath: reading].task {
            if !fresh { return try await asked.value }
            _ = try? await asked.value
        } else if !fresh, let at = self[keyPath: reading].at, abs(Date().timeIntervalSince(at)) < interval - 1 { return }
        let asking = Task { try await request() }
        self[keyPath: reading].task = asking
        defer { if self[keyPath: reading].task == asking { self[keyPath: reading].task = nil } }
        try await asking.value
        self[keyPath: reading].at = Date()
    }
}
