// What one screen tells the others, as the Windows client's cross-screen calls (sessions_forget, settings_*_changed,
// servers_ssh_changed, projects_recount_findings).
import Foundation

extension Notification.Name {
    /// A conversation was deleted: `userInfo["id"]` and `userInfo["repo"]`. The sidebar drops it and asks the server again.
    static let sessionForgotten = Notification.Name("BriareusSessionForgotten")
    /// A session changed (renamed, stopped, started): the sidebar reads its project again. `userInfo["repo"]` when known.
    static let sessionsChanged = Notification.Name("BriareusSessionsChanged")
    /// The Findings screen read the conversations again: the sidebar's ⚑ counts once more.
    static let findingsRecount = Notification.Name("BriareusFindingsRecount")
    /// The settings sidebar reads the projects again; `userInfo["select"]` is an id to highlight.
    static let settingsProjectsChanged = Notification.Name("BriareusSettingsProjectsChanged")
    /// The settings sidebar reads the providers again; `userInfo["openFirst"]` opens the first one left (after a delete).
    static let settingsProvidersChanged = Notification.Name("BriareusSettingsProvidersChanged")
    /// The settings sidebar reads the database pool again; `userInfo["openFirst"]` as for providers.
    static let settingsDBServersChanged = Notification.Name("BriareusSettingsDBServersChanged")
    /// The SSH servers changed: the settings sidebar and the SSH and SFTP sessions tabs read them again.
    static let sshServersChanged = Notification.Name("BriareusSSHServersChanged")
    /// The project list changed (a project saved, cloned, deleted or reordered): the sidebar reads it again.
    static let projectsChanged = Notification.Name("BriareusProjectsChanged")
    /// Runs a session operation (`compact`, `clear`, `rename` with compaction settings) through its open conversation, which
    /// shows its progress and errors and reads the session again afterwards: `userInfo["id"]`, `["operation"]`, `["extra"]` (JSON).
    static let conversationSessionOperation = Notification.Name("BriareusConversationSessionOperation")
}

func post(_ name: Notification.Name, _ info: [String: Any] = [:]) {
    NotificationCenter.default.post(name: name, object: nil, userInfo: info)
}
