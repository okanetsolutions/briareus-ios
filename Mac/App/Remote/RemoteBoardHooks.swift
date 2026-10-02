// Gives the board what it shows of a project's SSH and SFTP sessions: their counts, the header of the tab on show, and its ⟳.
import Combine
import Foundation

@MainActor
enum RemoteBoardHooks {
    private static var watching: AnyCancellable?
    private static var serversWatch: NSObjectProtocol?

    static func install() {
        RemoteSessions.sshCount = { RemoteRegistry.sshCount(repo: $0) }
        RemoteSessions.sftpCount = { RemoteRegistry.sftpCount(repo: $0) }
        // project_ssh_header and project_sftp_header: nothing (the board's own subtitle) until a session is on show.
        RemoteSessions.sshHeader = { repo in
            let h = ProjectSSHTab.header(repo: repo)
            return RemoteTabHeader(subtitle: h.subtitle, status: h.status, buttons: h.buttons)
        }
        RemoteSessions.sftpHeader = { repo in
            let h = ProjectSFTPTab.header(repo: repo)
            return RemoteTabHeader(subtitle: h.subtitle, status: h.status, buttons: h.buttons)
        }
        // ⟳ and F5 on the tab (project_ssh_refresh, project_sftp_refresh): this project's servers read again, and on the SFTP
        // tab the folder on show too. Nothing else is told: Settings and the other projects' tabs keep what they have.
        RemoteSessions.sshRefresh = { repo in RemoteServers.of(.ssh, repo: repo).refresh() }
        RemoteSessions.sftpRefresh = { repo in ProjectSFTPTab.refresh(repo: repo, servers: RemoteServers.of(.sftp, repo: repo)) }
        // The servers changed in Settings (servers_ssh_changed): every tab that has read them reads them again.
        serversWatch = NotificationCenter.default.addObserver(forName: .sshServersChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { RemoteServers.serversChanged() }
        }
        // Sessions opening, closing, connecting, ending, or the one on show changing its title or selected path, redraw the
        // board's counts and header. objectWillChange comes before the change: the post waits for it to be made.
        watching = SSHSessions.shared.objectWillChange.merge(with: SFTPSessions.shared.objectWillChange)
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { _ in post(.remoteSessionsChanged) }
    }
}
