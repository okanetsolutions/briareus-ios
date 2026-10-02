// What the board shows of a project's SSH and SFTP sessions without owning them: Mac/App/Remote sets these hooks, as
// LiveSessions is set for the quit confirmation. The defaults say nothing is open.
import SwiftUI

/// What the SSH or SFTP sessions tab puts in the board's header while it is on show (project_ssh_header and
/// project_sftp_header): the subtitle and status dot of the session shown, and its buttons. The board adds ⟳ after them.
struct RemoteTabHeader {
    var subtitle: String?
    var status: String?
    var buttons: [HeaderButton] = []
}

@MainActor
enum RemoteSessions {
    /// The SSH sessions open on a project's servers (project_ssh_session_count), for the tab's "❯ SSH sessions N".
    static var sshCount: (_ repo: String) -> Int = { _ in 0 }
    /// The SFTP sessions open on them (project_sftp_session_count), for "⇵ SFTP sessions N".
    static var sftpCount: (_ repo: String) -> Int = { _ in 0 }
    /// The header while the tab is on show; nil leaves the board's own subtitle.
    static var sshHeader: (_ repo: String) -> RemoteTabHeader? = { _ in nil }
    static var sftpHeader: (_ repo: String) -> RemoteTabHeader? = { _ in nil }
    /// ⟳ and F5 on the tab: read the servers (and the folder on show) again.
    static var sshRefresh: (_ repo: String) -> Void = { _ in }
    static var sftpRefresh: (_ repo: String) -> Void = { _ in }
}

extension Notification.Name {
    /// A session opened or closed, or the one on show changed: the board redraws its tab counts and header.
    static let remoteSessionsChanged = Notification.Name("BriareusRemoteSessionsChanged")
}
