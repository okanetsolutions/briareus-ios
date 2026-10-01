// The projects the sidebar lists, for the screens that pick one (projects_list), and the ⚑ count of review rounds waiting.
// The sidebar owns the reading; other screens only read what it holds. It is screen_projects.c's ProjectsScreen state
// (projects_load, projects_count, projects_recount_findings) and sessions_forget, kept here because the sidebar's views
// come and go (Settings takes the sidebar's place) while the Windows client's screens stay on their pane's stack.
import Combine
import Foundation

@MainActor
final class ProjectsModel: ObservableObject {
    static let shared = ProjectsModel()

    @Published var projects: [Project] = []
    /// What `projects` answered, whole: the run profiles and other per-project fields ride along.
    @Published var raw: JSON = .null
    /// Review rounds waiting for a decision across the projects, the ⚑ badge.
    @Published var findingsWaiting = 0
    /// Per project (by repo): how many conversations, and whether one is working.
    @Published private(set) var counts: [String: Int] = [:]
    @Published private(set) var busy: [String: Bool] = [:]
    /// The list has been read, from the saved copy or the server.
    @Published private(set) var loaded = false
    /// Why the last read of the projects failed.
    @Published private(set) var error: String?
    /// The project screen pushed inside the sidebar (sessions_screen_new), nil on the projects list.
    @Published var openProject: SidebarSessions?

    private var generation = 0
    private var observers: [NSObjectProtocol] = []
    private var signOut: AnyCancellable?

    private init() {
        if let saved = Store.shared.cache.value("projects") { adopt(saved); recount() }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .sessionForgotten, object: nil, queue: .main) { note in
            let repo = note.userInfo?["repo"] as? String, id = note.userInfo?["id"] as? String
            MainActor.assumeIsolated { ProjectsModel.shared.forget(repo: repo, id: id) }
        })
        observers.append(center.addObserver(forName: .findingsRecount, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ProjectsModel.shared.recount() }
        })
        observers.append(center.addObserver(forName: .projectsChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { _ = Task { await ProjectsModel.shared.load() } }
        })
        observers.append(center.addObserver(forName: .sessionsChanged, object: nil, queue: .main) { note in
            let repo = note.userInfo?["repo"] as? String
            MainActor.assumeIsolated {
                let model = ProjectsModel.shared
                if let open = model.openProject, repo == nil || repo == open.project.repo { Task { await open.load() } }
                model.recount()
            }
        })
        // Signing out (or a revoked token) empties the cache; what was read goes with it.
        signOut = Store.shared.$client.map { $0 != nil }.removeDuplicates().dropFirst().sink { connected in
            guard !connected else { return }
            MainActor.assumeIsolated { ProjectsModel.shared.reset() }
        }
    }

    func adopt(_ answer: JSON) {
        guard let list = Project.parseList(answer) else { return }
        raw = answer
        projects = list
        loaded = true
    }

    private func reset() {
        generation += 1
        projects = []; raw = .null; findingsWaiting = 0; counts = [:]; busy = [:]
        loaded = false; error = nil; openProject = nil
    }

    /// projects_count: what the saved lists say about each project's conversations, and the ⚑ count across them.
    func recount() {
        var counts: [String: Int] = [:], busy: [String: Bool] = [:]
        var waiting = 0
        for p in projects {
            guard let list = Store.shared.cache.value("sessions:\(p.repo)"), let sessions = Session.parseList(list) else { continue }
            counts[p.repo] = sessions.count
            busy[p.repo] = sessions.contains { $0.isActive }
            waiting += sessions.filter { $0.heldRound != nil }.count
        }
        if counts != self.counts { self.counts = counts }
        if busy != self.busy { self.busy = busy }
        if waiting != findingsWaiting { findingsWaiting = waiting }
    }

    /// projects_load: the saved list at once the first time, then `projects` and every project's conversations (for the
    /// counts and the dots), each project's rows saved under its own key. Nil on success, else the error.
    @discardableResult
    func load() async -> APIError? {
        if !loaded, let saved = Store.shared.cache.value("projects") { adopt(saved); recount() }
        generation += 1
        let mine = generation
        let answer: JSON
        do {
            answer = try await Store.shared.call("projects")
        } catch {
            guard mine == generation, !error.isCancellation else { return nil }
            self.error = errorText(error)
            loaded = true
            return error as? APIError
        }
        guard mine == generation else { return nil }
        adopt(answer)
        error = nil
        Store.shared.cache.store(answer, "projects")
        recount()
        guard Store.shared.supports("sessions") else { return nil }
        do {
            let all = try await Store.shared.call("sessions")
            guard mine == generation else { return nil }
            if let items = Session.parseList(all) {
                for p in projects {
                    Store.shared.cache.store(Session.json(items.filter { $0.repo == p.repo }), "sessions:\(p.repo)")
                }
            }
            recount()
            return nil
        } catch {
            guard mine == generation, !error.isCancellation else { return nil }
            recount()
            return error as? APIError
        }
    }

    /// sessions_forget: a deleted conversation leaves the saved list, its transcript, and the list on screen right away, which
    /// then asks the server again in case the list changed in other ways too.
    func forget(repo: String?, id: String?) {
        guard let repo, !repo.isEmpty, let id, !id.isEmpty else { return }
        let key = "sessions:\(repo)"
        if let saved = Store.shared.cache.value(key), let items = Session.parseList(saved) {
            Store.shared.cache.store(Session.json(items.filter { $0.id != id }), key)
        }
        Store.shared.cache.remove("transcript:\(id)")
        recount()
        guard let open = openProject, open.project.repo == repo else { return }
        open.drop(id)
        Task { await open.load() }
    }

    func project(_ repo: String?) -> Project? { projects.first { $0.repo == repo } }
}
