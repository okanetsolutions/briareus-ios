// Gives the board what it shows of a project's SSH and SFTP sessions: their counts, the header of the tab on show, and its ⟳.
import Combine
import Foundation

@MainActor
enum RemoteBoardHooks {
    private static var watching: AnyCancellable?

    static func install() {
        RemoteSessions.sshCount = { RemoteRegistry.sshCount(repo: $0) }
        RemoteSessions.sftpCount = { RemoteRegistry.sftpCount(repo: $0) }
        RemoteSessions.sshHeader = { repo in
            let h = ProjectSSHTab.header(repo: repo)
            return RemoteTabHeader(subtitle: h.subtitle, status: h.status, buttons: h.buttons)
        }
        RemoteSessions.sftpHeader = { repo in
            let h = ProjectSFTPTab.header(repo: repo)
            return RemoteTabHeader(subtitle: h.subtitle, status: h.status, buttons: h.buttons)
        }
        RemoteSessions.sshRefresh = { _ in post(.sshServersChanged) }
        RemoteSessions.sftpRefresh = { _ in post(.sshServersChanged) }
        // Sessions opening, closing or changing state redraw the board's counts and header.
        watching = SSHSessions.shared.objectWillChange.merge(with: SFTPSessions.shared.objectWillChange)
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { _ in post(.remoteSessionsChanged) }
    }
}
