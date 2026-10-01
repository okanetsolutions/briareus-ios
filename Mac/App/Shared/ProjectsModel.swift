// The projects the sidebar lists, for the screens that pick one (projects_list), and the ⚑ count of review rounds waiting.
// The sidebar owns the reading; other screens only read what it holds.
import Foundation

@MainActor
final class ProjectsModel: ObservableObject {
    static let shared = ProjectsModel()

    @Published var projects: [Project] = []
    /// What `projects` answered, whole: the run profiles and other per-project fields ride along.
    @Published var raw: JSON = .null
    /// Review rounds waiting for a decision across the projects, the ⚑ badge.
    @Published var findingsWaiting = 0

    private init() {
        if let saved = Store.shared.cache.value("projects") { adopt(saved) }
    }

    func adopt(_ answer: JSON) {
        raw = answer
        projects = Project.parseList(answer) ?? []
    }

    /// Reads the list again; nil on success, else the error.
    @discardableResult
    func load() async -> APIError? {
        do {
            let answer = try await Store.shared.call("projects")
            adopt(answer)
            Store.shared.cache.store(answer, "projects")
            return nil
        } catch let e as APIError { return e } catch { return nil }
    }

    func project(_ repo: String?) -> Project? { projects.first { $0.repo == repo } }
}
