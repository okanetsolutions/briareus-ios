// What the SSH and SFTP sessions tabs share (project_ssh.c and project_sftp.c draw them alike): the project's SSH servers
// read from Settings, the server rows down the left, the session tabs, and the header line with the session's state and
// its buttons.
import AppKit
import SwiftUI

/// The counts and the header the board screen shows for the two tabs.
@MainActor
enum RemoteRegistry {
    /// Whether the tabs are offered: the servers are read from Settings, which needs an Admin token.
    static var offered: Bool { Store.shared.supports("settings_ssh_servers") }
    /// The project's open SSH sessions, for "❯ SSH sessions N".
    static func sshCount(repo: String) -> Int { SSHSessions.shared.count(group: repo) }
    /// The project's open SFTP sessions, for "⇵ SFTP sessions N".
    static func sftpCount(repo: String) -> Int { SFTPSessions.shared.count(group: repo) }
}

/// The text shown when the token may not read the servers.
let remoteNeedsAdmin = "The SSH servers are read from Settings, which needs an Admin token. Create one on the web dashboard under Settings \u{2192} Devices and clients and connect with it."

/// One registered SSH server, as Settings has it.
struct RemoteServer: Identifiable {
    var row: JSON
    var id: String { idKey }
    private var idKey: String {
        if let n = row["id"].number, n.isFinite { return String(format: "%.0f", n) }
        return row["host"].string ?? ""
    }
    /// What names the server in a session's key: "ssh:<id>" or "sftp:<id>", else the host.
    func key(_ prefix: String) -> String { "\(prefix):\(idKey)" }
    /// The name a server goes by: its label, else user@host.
    var name: String {
        if let label = row["label"].nonEmpty { return label }
        let user = row["username"].string ?? "", host = row["host"].string ?? ""
        return !user.isEmpty ? "\(user)@\(host)" : (host.isEmpty ? "SSH server" : host)
    }
    var user: String { row["username"].string ?? "" }
    var host: String { row["host"].string ?? "" }
    var port: Int { let p = row["port"].int ?? 22; return p > 0 ? p : 22 }
    var enabled: Bool { !row["enabled"].is(false) }
    /// user@host:port
    var display: String { "\(user)@\(host):\(port)" }
    func target(_ prefix: String, group: String) -> TermTarget {
        TermTarget(key: key(prefix), group: group, label: name, user: user, host: host, port: port)
    }
}

/// The project's SSH servers, read from Settings and filtered to the project.
@MainActor
final class RemoteServers: ObservableObject {
    @Published private(set) var rows: [RemoteServer] = []
    @Published private(set) var loaded = false
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?
    private var repo = ""

    func load(_ repo: String) {
        self.repo = repo
        if loaded || task != nil { return }
        guard RemoteRegistry.offered else { loaded = true; return }
        task = Task { [weak self] in
            do {
                let answer = try await Store.shared.call("settings_ssh_servers")
                guard let self, !Task.isCancelled else { return }
                self.error = nil
                self.rows = answer["servers"].items.filter { $0["repo"].string == self.repo }.map { RemoteServer(row: $0) }
                self.loaded = true
                self.task = nil
            } catch {
                guard let self, !error.isCancellation else { return }
                self.error = errorText(error)
                self.loaded = true
                self.task = nil
            }
        }
    }
    func refresh() {
        task?.cancel(); task = nil
        loaded = false
        load(repo)
    }
    /// The servers changed in Settings: a tab that has read them reads them again.
    func serversChanged() { if loaded || task != nil { refresh() } }
}

/// A server down the left: its glyph, its name, user@host:port, and how many sessions are open to it (with a dot, green
/// while one is connected).
struct RemoteServerRow: View {
    var glyph: UInt32
    var server: RemoteServer
    var sessions: Int
    var live: Bool
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Image(systemName: Glyph.symbol(glyph)).font(.system(size: 12))
                    .foregroundStyle(live ? Theme.accent : Theme.muted)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(server.name).font(Theme.subheadline).foregroundStyle(server.enabled ? Theme.ink : Theme.muted)
                        .lineLimit(1).truncationMode(.tail).frame(height: 20, alignment: .leading)
                    Text(server.display).font(Theme.caption2).foregroundStyle(Theme.muted)
                        .lineLimit(1).truncationMode(.tail).frame(height: 16, alignment: .leading)
                }
                .padding(.leading, 6)
                Spacer(minLength: 8)
                if sessions > 0 {
                    StatusDot(status: live ? "idle" : "closed")
                    Text("\(sessions)").font(Theme.caption).foregroundStyle(Theme.muted).padding(.leading, 5)
                }
            }
            .padding(.leading, 6).padding(.trailing, 8)
            .frame(height: 46)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? Theme.raise : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// The servers down the left, each with its name, user@host:port and its open sessions.
struct RemoteServerList: View {
    @ObservedObject var servers: RemoteServers
    var glyph: UInt32
    var sessions: (RemoteServer) -> Int
    var live: (RemoteServer) -> Bool
    var open: (RemoteServer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = servers.error { Notice(message: error).padding(.bottom, 8) }
            if !servers.loaded {
                LoadingNote(text: "Loading servers\u{2026}")
            } else {
                ForEach(servers.rows) { row in
                    RemoteServerRow(glyph: glyph, server: row, sessions: sessions(row), live: live(row)) { open(row) }
                }
                if servers.rows.isEmpty && servers.error == nil {
                    Text("No SSH servers for this project. Register one under \u{2699} Settings.")
                        .font(Theme.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 6)
                }
            }
        }
    }
}

/// A session's tab: a dot (green while connected), its label, and × to close it; the one on show is raised and
/// underlined in the accent.
struct RemoteSessionTab: View {
    static let height: CGFloat = 30
    static let closeWidth: CGFloat = 22
    var label: String
    var active: Bool
    var live: Bool
    var select: () -> Void
    var close: () -> Void
    @State private var hovered = false
    @State private var closeHovered = false

    private var width: CGFloat {
        let w = (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width
        return min(max(ceil(w) + 10 + 12 + Self.closeWidth + 6, 110), 240)
    }

    var body: some View {
        let soft = Theme.raise.opacity(0.5)
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6).fill(active ? Theme.raise : hovered ? soft : .clear)
            RoundedRectangle(cornerRadius: 6).strokeBorder(active ? Theme.line : hovered ? soft : .clear, lineWidth: 1)
            if active {
                Rectangle().fill(Theme.accent).frame(height: 2).padding(.horizontal, 8)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            HStack(spacing: 0) {
                StatusDot(status: live ? "idle" : "closed").padding(.leading, 9.5)
                Text(label).font(active ? Theme.captionSemibold : Theme.caption)
                    .foregroundStyle(active ? Theme.ink : Theme.muted)
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.leading, 5.5)
                Spacer(minLength: 0)
            }
            .padding(.trailing, Self.closeWidth)
        }
        .frame(width: width, height: Self.height)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovered = $0 }
        .overlay(alignment: .trailing) {
            Button(action: close) {
                Image(systemName: Glyph.symbol(0xE711)).font(.system(size: 10))
                    .foregroundStyle(closeHovered ? Theme.ink : Theme.muted)
                    .frame(width: 20, height: 18)
                    .background(RoundedRectangle(cornerRadius: 4).fill(closeHovered ? Theme.line : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { closeHovered = $0 }
            .help("Close this session")
            .padding(.trailing, 4)
        }
    }
}

/// What the board's header says while one of the tabs is open: the session on show, its state and its buttons.
struct RemoteHeader {
    var subtitle: String?
    var status: String?
    var buttons: [HeaderButton]
}

/// The header's line inside the tab: the session's state with its dot, and the buttons (as the pane header draws them).
struct RemoteHeaderLine: View {
    var header: RemoteHeader

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(labels: true)
            row(labels: false)
        }
        .frame(minHeight: 32)
    }

    private func row(labels: Bool) -> some View {
        HStack(spacing: 8) {
            if let subtitle = header.subtitle {
                HStack(spacing: 6) {
                    if let status = header.status { StatusDot(status: status) }
                    Text(subtitle).font(Theme.footnote).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
                }
                .layoutPriority(1)
            }
            Spacer(minLength: 8)
            ForEach(header.buttons) { b in
                Group {
                    if let label = b.label, labels {
                        Button(action: b.action) {
                            HStack(spacing: 5) {
                                Image(systemName: b.glyph).font(.system(size: 11))
                                Text(label)
                            }
                        }
                        .dashButton(b.prominent ? .prominent : b.destructive ? .destructive : .bordered)
                    } else {
                        Button(action: b.action) { Image(systemName: b.glyph) }
                            .buttonStyle(IconButtonStyle(destructive: b.destructive, prominent: b.prominent))
                    }
                }
                .disabled(!b.enabled)
                .help(b.tip ?? b.label ?? "")
            }
        }
    }
}
