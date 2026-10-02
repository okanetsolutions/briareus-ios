// What the screens of a project share: its conversations and its board, each asked for once however many screens show
// them; and the projects themselves, with the ⚑ count of review rounds waiting across them.
import Combine
import SwiftUI

@MainActor
final class ProjectFeed: ObservableObject {
    /// How often a screen showing the conversations or the board asks for them again. The board costs the server a
    /// question to GitHub each time, so it is left longer than the server keeps its own answer.
    static let sessionsEvery = 7.0, boardEvery = 60.0

    let repo: String
    @Published private(set) var sessions: [Session] = []
    /// True once the conversations were read, from what was saved or from the server.
    @Published private(set) var sessionsLoaded = false
    /// The board as the server sent it (`pulls` and `issues`), which is what is saved and what names the stacks.
    @Published private(set) var board: JSON = .null
    @Published private(set) var boardLoaded = false

    private struct Reading {
        var at: Date?
        var task: Task<Void, Error>?
    }
    private var readingSessions = Reading()
    private var readingBoard = Reading()

    init(repo: String) {
        self.repo = repo
        if let saved = Store.shared.cache.value("sessions:\(repo)").flatMap(Session.parseList) { sessions = saved; sessionsLoaded = true }
        if let saved = Store.shared.cache.value("pulls:\(repo)") { board = saved; boardLoaded = true }
    }

    /// `fresh` asks the server whatever was read a moment ago, as after a write or a pull to refresh.
    func loadSessions(fresh: Bool = false) async throws {
        try await read(\.readingSessions, every: Self.sessionsEvery, fresh: fresh) { [self] in
            let answer = try await Store.shared.call("sessions", ["repo": .string(repo)])
            guard let list = Session.parseList(listOf(answer, "sessions")) else { throw APIError(.nonJSON) }
            adopt(list)
        }
    }
    /// What another screen read of the project's conversations, such as the projects list's read of every one.
    func adopt(_ list: [Session]) {
        let gone = Set(sessions.map(\.id)).subtracting(list.map(\.id))
        if list != sessions { sessions = list }
        sessionsLoaded = true
        Store.shared.cache.store(Session.json(list), "sessions:\(repo)")
        for id in gone { Store.shared.cache.remove("transcript:\(id)") }
        ProjectsModel.shared.recount()
    }
    /// A deleted conversation leaves the list at once, before the server is asked again.
    func drop(_ id: String) {
        adopt(sessions.filter { $0.id != id })
    }

    /// `fresh` also has the server ask GitHub again instead of answering from its own short cache.
    func loadBoard(fresh: Bool = false) async throws {
        try await read(\.readingBoard, every: Self.boardEvery, fresh: fresh) { [self] in
            var answer: JSON
            do { answer = try await Store.shared.call("pulls", fresh ? ["repo": .string(repo), "fresh": "1"] : ["repo": .string(repo)]) }
            catch let e as APIError where fresh && e.kind == .http && e.status == 400 {
                // A server from before `fresh` refuses the argument it does not know.
                answer = try await Store.shared.call("pulls", ["repo": .string(repo)])
            }
            if answer != board { board = answer }
            boardLoaded = true
            Store.shared.cache.store(answer, "pulls:\(repo)")
        }
    }

    /// One request at a time. A poll finding an answer young enough asks nothing, and one finding a request on its way
    /// waits for that answer. A fresh read lets such a request land first and then asks again, so what is shown last is
    /// what the server said last. The request belongs to the feed: a screen that leaves while it is out does not take it
    /// along, since another may be waiting on it.
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

/// The projects this device can read, and the ⚑ count of review rounds waiting across them, for the tab bar's badge and
/// every screen that picks a project.
@MainActor
final class ProjectsModel: ObservableObject {
    static let shared = ProjectsModel()

    @Published private(set) var projects: [Project] = []
    /// What `projects` answered, whole: the run profiles and other per-project fields ride along.
    @Published private(set) var raw: JSON = .null
    /// Review rounds waiting for a decision across the projects.
    @Published private(set) var findingsWaiting = 0
    /// The list has been read, from the saved copy or the server.
    @Published private(set) var loaded = false
    /// Why the last read of the projects failed.
    @Published private(set) var error: String?

    private var generation = 0
    private var signOut: AnyCancellable?

    private init() {
        if let saved = Store.shared.cache.value("projects") { adopt(saved) }
        // Signing out (or a revoked token) empties the cache; what was read goes with it.
        signOut = Store.shared.$client.map { $0 != nil }.removeDuplicates().dropFirst().sink { connected in
            guard !connected else { return }
            MainActor.assumeIsolated { ProjectsModel.shared.reset() }
        }
    }

    private func adopt(_ answer: JSON) {
        guard let list = Project.parseList(answer) else { return }
        raw = answer
        if list != projects { projects = list }
        loaded = true
        recount()
    }
    private func reset() {
        generation += 1
        projects = []; raw = .null; findingsWaiting = 0; loaded = false; error = nil
    }

    func project(_ repo: String?) -> Project? { projects.first { $0.repo == repo } }

    /// The ⚑ count from what is saved of each project's conversations.
    func recount() {
        var waiting = 0
        for p in projects {
            guard let list = Store.shared.cache.value("sessions:\(p.repo)").flatMap(Session.parseList) else { continue }
            waiting += list.filter { $0.heldRound != nil }.count
        }
        if waiting != findingsWaiting { findingsWaiting = waiting }
    }

    /// `projects`, then every project's conversations in one call (for the counts), each project's handed to its feed.
    func load() async throws {
        generation += 1
        let mine = generation
        let answer: JSON
        do { answer = try await Store.shared.call("projects") }
        catch {
            guard mine == generation, !error.isCancellation else { throw error }
            self.error = errorText(error); loaded = true
            throw error
        }
        guard mine == generation else { return }
        adopt(answer)
        error = nil
        Store.shared.cache.store(answer, "projects")
        guard Store.shared.supports("sessions") else { return }
        let all = try await Store.shared.call("sessions")
        guard mine == generation, let items = Session.parseList(listOf(all, "sessions")) else { return }
        for p in projects { Store.shared.feed(p.repo).adopt(items.filter { $0.repo == p.repo }) }
        recount()
    }
}
