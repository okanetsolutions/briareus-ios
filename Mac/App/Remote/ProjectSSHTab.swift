// A project's SSH sessions tab, beside its pull requests and issues (the Windows client's project_ssh.c): the SSH servers
// registered for the project in Settings down the left, and its open sessions as tabs over a terminal on the right. A
// click on a server opens an SSH session to it (or returns to the open one). Sessions run this Mac's OpenSSH client
// (TerminalSession) straight to the server, so its keys, agent and ~/.ssh/config apply, and they stay open while other
// screens are shown.
//
// The board screen places this view in its tab body (not inside a scroll view: the terminal fills the height left). The
// header's state and buttons are drawn on a line at the top of the tab (`showsHeader`), and are also given by
// `ProjectSSHTab.header(repo:)` for a board header that shows them itself.
import SwiftUI

struct ProjectSSHTab: View {
    var repo: String
    var showsHeader = true
    @ObservedObject private var servers: RemoteServers
    @ObservedObject private var sessions = SSHSessions.shared
    @ObservedObject private var store = Store.shared

    static let listWidth: CGFloat = 260

    init(repo: String, showsHeader: Bool = true) {
        self.repo = repo
        self.showsHeader = showsHeader
        servers = RemoteServers.of(.ssh, repo: repo)
    }

    var body: some View {
        Group {
            if !RemoteRegistry.offered {
                Text(remoteNeedsAdmin).font(Theme.footnote).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                content
            }
        }
        .onAppear { servers.revisit() }
        // F5 and ⌘R: the board hosting the tab passes them on itself (RemoteSessions.sshRefresh).
        .onReceive(NotificationCenter.default.publisher(for: .refreshScreen)) { _ in if showsHeader { servers.refresh() } }
    }

    private var content: some View {
        GeometryReader { geo in
            let lw = min(Self.listWidth, geo.size.width / 3)
            let shown = sessions.shown(group: repo)
            VStack(alignment: .leading, spacing: 0) {
                if showsHeader {
                    RemoteHeaderLine(header: Self.header(repo: repo, refresh: { servers.refresh() }))
                        .padding(.bottom, 10)
                }
                HStack(alignment: .top, spacing: 0) {
                    ScrollView {
                        RemoteServerList(servers: servers, glyph: 0xE7F4,
                                         sessions: { sessions.count(for: $0.key("ssh")) },
                                         live: { sessions.live($0.key("ssh")) },
                                         open: connect)
                    }
                    .frame(width: lw)
                    // A rule between the list and the sessions.
                    Rectangle().fill(Theme.line).frame(width: 1).padding(.leading, 8).padding(.trailing, 9)
                    VStack(alignment: .leading, spacing: 0) {
                        if let shown {
                            FlowLayout(spacing: 4, lineSpacing: 4) {
                                ForEach(sessions.sessions.filter { $0.group == repo }) { t in
                                    RemoteSessionTab(label: t.label, active: t === shown, live: t.running,
                                                     select: { sessions.setActive(t) }, close: { Self.close(t) })
                                }
                            }
                            .padding(.bottom, 8)
                            TerminalHost(session: shown)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .frame(minHeight: 200)
                        } else {
                            EmptyNote(title: "No open sessions",
                                      detail: "Click a server on the left to open an SSH session here. It connects from this Mac straight to the server with your own OpenSSH client, so your keys, ssh-agent and ~/.ssh/config apply, and password prompts appear in the terminal.")
                                .padding(.top, 40)
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(minHeight: 240)
            }
            .padding(.bottom, 14)
        }
    }

    // MARK: - Connecting

    private func connect(_ row: RemoteServer) {
        if let open = sessions.find(row.key("ssh")) { sessions.setActive(open); return }
        if let error = sessions.open(row.target("ssh", group: repo)) {
            Dialogs.alert("Could not connect to \(row.name)", error)
        }
    }

    @MainActor static func close(_ t: TerminalSession) {
        if t.running && !Dialogs.confirm("Disconnect from \(t.label)?", "The session ends and anything running in it on the server is stopped with it.",
                                         continueLabel: "Disconnect", destructive: true) { return }
        SSHSessions.shared.close(t)
    }

    // MARK: - The header

    /// The session on show: "SSH user@host:port · connected · <title>", its dot, Reconnect (while it is closed), Close, and
    /// ⟳ (which reads the project's SSH servers again).
    @MainActor static func header(repo: String, refresh: (() -> Void)? = nil) -> RemoteHeader {
        var buttons: [HeaderButton] = []
        var subtitle: String?, status: String?
        if let t = SSHSessions.shared.shown(group: repo) {
            let title = t.title ?? ""
            subtitle = "SSH \(t.display) \u{00B7} \(t.running ? "connected" : "closed")\(title.isEmpty ? "" : " \u{00B7} \(title)")"
            status = t.running ? "idle" : "closed"
            buttons.append(HeaderButton(glyph: Glyph.symbol(0xE72C), label: "Reconnect", tip: "Connect this session again", enabled: !t.running) {
                if let error = t.reconnect() { Dialogs.alert("Could not reconnect", error) }
            })
            buttons.append(HeaderButton(glyph: Glyph.symbol(0xE711), tip: "Close this session") { close(t) })
        }
        if let refresh {
            buttons.append(HeaderButton(glyph: Glyph.symbol(0xE72C), tip: "Read the project's SSH servers again", action: refresh))
        }
        return RemoteHeader(subtitle: subtitle, status: status, buttons: buttons)
    }
}
