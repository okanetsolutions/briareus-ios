// A project's conversations in the sidebar, as screen_projects.c's SessionsScreen holds them: the list (saved first, then
// the server's), ☑ Select's picks, and the bulk ⏻ Close or 🗑 Delete that works through them one at a time.
import Foundation

@MainActor
final class SidebarSessions: ObservableObject {
    let project: Project

    @Published private(set) var sessions: [Session] = []
    @Published private(set) var loaded = false
    @Published private(set) var error: String?
    @Published var selectMode = false
    @Published private(set) var picked: Set<String> = []
    /// A bulk close or delete is under way, and which.
    @Published private(set) var bulkRunning = false
    @Published private(set) var bulkDelete = false
    @Published private(set) var bulkError: String?

    private var generation = 0

    init(project: Project) {
        self.project = project
    }

    private var key: String { "sessions:\(project.repo)" }

    private func show(_ value: JSON, fromServer: Bool) {
        guard let items = Session.parseList(value) else { return }
        if fromServer {
            // Transcripts of conversations that are gone go with them.
            let kept = Set(items.map(\.id))
            for s in sessions where !kept.contains(s.id) { Store.shared.cache.remove("transcript:\(s.id)") }
        }
        sessions = items
        loaded = true
    }

    /// sessions_load: the saved list at once the first time, then the server's. Nil on success, else the error.
    @discardableResult
    func load() async -> APIError? {
        if !loaded, let saved = Store.shared.cache.value(key) { show(saved, fromServer: false) }
        generation += 1
        let mine = generation
        do {
            let answer = try await Store.shared.call("sessions", ["repo": .string(project.repo)])
            guard mine == generation else { return nil }
            show(answer, fromServer: true)
            error = nil
            Store.shared.cache.store(Session.json(sessions), key)
            ProjectsModel.shared.recount()
            return nil
        } catch {
            guard mine == generation, !error.isCancellation else { return nil }
            self.error = errorText(error)
            loaded = true
            return error as? APIError
        }
    }

    /// The conversation leaves the list on screen at once (sessions_forget).
    func drop(_ id: String) { sessions.removeAll { $0.id == id } }

    // MARK: Select

    func isPicked(_ id: String) -> Bool { picked.contains(id) }
    func togglePick(_ id: String) { if picked.contains(id) { picked.remove(id) } else { picked.insert(id) } }
    func toggleSelectMode() { selectMode.toggle(); if !selectMode { picked = [] } }
    func leaveSelectMode() { selectMode = false; picked = [] }
    func selectAll() { picked = Set(sessions.map(\.id)) }

    /// Open = still holding a workspace and a database, the only kind Close has anything to release.
    private static func isOpen(_ s: Session) -> Bool { ["queued", "preparing", "running", "idle"].contains(s.status) }

    /// bulk_start: asks first, then closes or deletes the picked conversations (or, with `all`, every one) one at a time.
    func bulk(delete del: Bool, all: Bool) {
        guard !bulkRunning else { return }
        let ids = sessions.filter { (all || picked.contains($0.id)) && (del || Self.isOpen($0)) }.map(\.id)
        let n = ids.count
        guard n > 0 else { return }
        let title = del ? "Delete \(n) conversation\(n == 1 ? "" : "s") and their logs?" : "Close \(n) session\(n == 1 ? "" : "s")?"
        let message = del ? "This cannot be undone." : "Each one releases its workspace and database; the conversation stays readable."
        guard Dialogs.confirm(title, message, continueLabel: del ? "Delete" : "Close", destructive: del) else { return }
        bulkError = nil
        bulkRunning = true
        bulkDelete = del
        let repo = project.repo
        Task {
            for id in ids {
                do {
                    _ = try await Store.shared.call(del ? "delete" : "close", ["sessionId": .string(id)])
                    if del { ProjectsModel.shared.forget(repo: repo, id: id) }
                } catch {
                    bulkError = errorText(error)
                }
            }
            bulkRunning = false
            picked = []
            await load()
        }
    }
}
