// A project's SFTP sessions tab, beside its SSH sessions (the Windows client's project_sftp.c): the SSH servers registered
// for the project in Settings down the left, and its open SFTP sessions as tabs over the server's file tree on the right.
// A click on a server opens an SFTP session to it (or returns to the open one); the tree opens at the folder the server
// starts in, its folders open with a click, and files go up (⇧ Upload, or dropped from the Finder onto a folder) and down
// (⇩ Download, or a double click). Sessions run this Mac's OpenSSH sftp client (SFTPSession), so its keys, agent and
// ~/.ssh/config apply.
//
// The board screen places this view in its tab body; it scrolls by itself. The header's state and buttons are drawn on a
// line at the top of the tab (`showsHeader`), and are also given by `ProjectSFTPTab.header(repo:)`.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ProjectSFTPTab: View {
    var repo: String
    var showsHeader = true
    @StateObject private var servers = RemoteServers()
    @ObservedObject private var sessions = SFTPSessions.shared
    @ObservedObject private var store = Store.shared
    @State private var lastClick: (path: String, at: Date)?

    static let rowHeight: CGFloat = 28
    static let indent: CGFloat = 18

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
        .onAppear { servers.load(repo) }
        .onReceive(NotificationCenter.default.publisher(for: .sshServersChanged)) { _ in servers.serversChanged() }
        .onReceive(NotificationCenter.default.publisher(for: .refreshScreen)) { _ in Self.refresh(repo: repo, servers: servers) }
    }

    private var content: some View {
        GeometryReader { geo in
            let lw = min(ProjectSSHTab.listWidth, geo.size.width / 3)
            VStack(alignment: .leading, spacing: 0) {
                if showsHeader {
                    RemoteHeaderLine(header: Self.header(repo: repo, refresh: { Self.refresh(repo: repo, servers: servers) }))
                        .padding(.bottom, 10)
                }
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        RemoteServerList(servers: servers, glyph: 0xE8B7,
                                         sessions: { sessions.count(for: $0.key("sftp")) },
                                         live: { sessions.live($0.key("sftp")) },
                                         open: connect)
                            .frame(width: lw)
                        Spacer().frame(width: 18)
                        right
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .padding(.bottom, 14)
                    .frame(minHeight: max(geo.size.height - (showsHeader ? 42 : 0), 240), alignment: .top)
                    // A rule between the list and the sessions.
                    .background(alignment: .topLeading) {
                        Rectangle().fill(Theme.line).frame(width: 1).padding(.leading, lw + 8).padding(.bottom, 14)
                    }
                }
            }
        }
    }

    @ViewBuilder private var right: some View {
        if let s = sessions.shown(group: repo) {
            VStack(alignment: .leading, spacing: 0) {
                FlowLayout(spacing: 4, lineSpacing: 4) {
                    ForEach(sessions.sessions.filter { $0.group == repo }) { t in
                        RemoteSessionTab(label: t.label, active: t === s, live: t.state != .closed,
                                         select: { sessions.setActive(t) }, close: { Self.close(t) })
                    }
                }
                .padding(.bottom, 10)
                session(s)
            }
        } else {
            EmptyNote(title: "No open sessions",
                      detail: "Click a server on the left to browse its files here, and upload and download them. It connects from this Mac straight to the server with your own OpenSSH client, so your keys, ssh-agent and ~/.ssh/config apply; passwords are asked for in a window.")
                .padding(.top, 40)
        }
    }

    @ViewBuilder private func session(_ s: SFTPSession) -> some View {
        let state = s.state
        if state == .connecting {
            VStack(spacing: 8) {
                LoadingNote(text: "Connecting to \(s.display)\u{2026}")
                Text("A password or an unknown host key is asked for in a window of its own.")
                    .font(Theme.caption).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .padding(.top, 30)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                StatusLine(session: s).padding(.bottom, 4)
                if let root = s.core.root {
                    if state == .closed {
                        Text("The session is closed; Reconnect opens it again.").font(Theme.caption).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true).padding(.bottom, 6)
                    }
                    Columns()
                    Rectangle().fill(Theme.line).frame(height: 1).padding(.bottom, 2)
                    tree(s, root)
                    Spacer().frame(height: 10)
                } else {
                    let log = s.core.connectLog
                    Notice(message: "Could not connect to \(s.display).\(log.map { "\n\($0)" } ?? "")")
                    Button("Connect again") { Self.reconnect(s) }.dashButton(.bordered).padding(.top, 8)
                }
            }
            // Files dropped anywhere else go to the selected folder.
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                guard s.state == .ready else { return false }
                Self.dropped(providers, on: s, folder: Self.targetFolder(s))
                return true
            }
        }
    }

    // MARK: - The tree

    private enum Line: Identifiable {
        case node(SFTPNode, depth: Int)
        case note(id: String, text: String, inset: Int, kind: Int)   // 0 loading, 1 error, 2 empty
        var id: String {
            switch self {
            case .node(let n, _): return "n:" + n.path
            case .note(let id, _, _, _): return id
            }
        }
    }

    /// Whether a node opens like a folder: a folder, or a link not yet listed or listed with entries.
    private static func isFolder(_ n: SFTPNode) -> Bool { n.dir || (n.link && (!n.loaded || !n.kids.isEmpty)) }
    /// Whether a node takes uploads and downloads as a folder.
    private static func holds(_ n: SFTPNode) -> Bool { n.dir || (n.link && !n.kids.isEmpty) }

    /// A folder's open entries under it, depth first.
    private func lines(_ n: SFTPNode, _ depth: Int, into out: inout [Line]) {
        out.append(.node(n, depth: depth))
        guard Self.isFolder(n), n.expanded else { return }
        if n.loading && n.kids.isEmpty { out.append(.note(id: "l:" + n.path, text: "Loading\u{2026}", inset: depth + 1, kind: 0)) }
        if let e = n.error { out.append(.note(id: "e:" + n.path, text: e, inset: depth + 1, kind: 1)) }
        else if n.loaded && !n.loading && n.kids.isEmpty { out.append(.note(id: "x:" + n.path, text: "Empty folder", inset: depth + 1, kind: 2)) }
        for k in n.kids { lines(k, depth + 1, into: &out) }
    }

    private func tree(_ s: SFTPSession, _ root: SFTPNode) -> some View {
        var all: [Line] = []
        lines(root, 0, into: &all)
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(all) { line in
                switch line {
                case .node(let n, let depth):
                    TreeRow(name: n.name, size: Self.isFolder(n) ? nil : SFTP.formatSize(n.size), when: n.when, link: n.link,
                            expanded: n.expanded, depth: depth, folder: Self.isFolder(n), selected: s.core.selected == n.path,
                            home: n.path == s.core.home,
                            click: { click(s, n.path) },
                            twisty: { s.core.toggle(n.path) })
                        .contextMenu { menu(s, n) }
                        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                            guard s.state == .ready else { return false }
                            // Onto a folder's row: into it; onto a file's: beside it.
                            Self.dropped(providers, on: s, folder: Self.holds(n) ? n.path : (SFTP.parent(n.path) ?? Self.targetFolder(s)))
                            return true
                        }
                case .note(_, let text, let inset, let kind):
                    Text(text).font(Theme.caption)
                        .foregroundStyle(kind == 1 ? Theme.danger : kind == 2 ? Theme.tertiary : Theme.muted)
                        .lineLimit(kind == 1 ? nil : 1).fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, CGFloat(inset) * Self.indent + 28)
                        .padding(.bottom, 4)
                }
            }
        }
    }

    private func click(_ s: SFTPSession, _ path: String) {
        guard let n = s.core.node(path) else { return }
        let folder = Self.isFolder(n)
        // A second click on the same row soon after is a double click: it opens a file by downloading it.
        let now = Date()
        let twice = lastClick.map { $0.path == path && now.timeIntervalSince($0.at) <= NSEvent.doubleClickInterval } ?? false
        lastClick = twice ? nil : (path, now)
        if twice {
            if !folder && s.state == .ready { Self.download(s, path) }
            return
        }
        s.core.select(path)
        if folder { s.core.toggle(path) }
    }

    @ViewBuilder private func menu(_ s: SFTPSession, _ n: SFTPNode) -> some View {
        let path = n.path, ready = s.state == .ready, folder = Self.holds(n), root = path == "/"
        if !root {
            Button(folder ? "Download folder\u{2026}" : "Download\u{2026}") { act(s, path) { Self.download(s, path) } }.disabled(!ready)
        }
        if folder {
            Button("Upload files here\u{2026}") { act(s, path) { Self.uploadFiles(s, into: path) } }.disabled(!ready)
            Button("Upload a folder here\u{2026}") { act(s, path) { Self.uploadFolder(s, into: path) } }.disabled(!ready)
            Button("New folder\u{2026}") { act(s, path) { Self.makeFolder(s, in: path) } }.disabled(!ready)
            Button("Refresh") { act(s, path) { s.core.list(path) } }.disabled(!ready)
        }
        Divider()
        Button("Copy path") { Clipboard.copy(path) }
        if !root {
            Button("Rename\u{2026}") { act(s, path) { Self.rename(s, path) } }.disabled(!ready)
            Button("Delete") { act(s, path) { Self.delete(s, path) } }.disabled(!ready)
        }
    }

    /// A menu choice: the row is selected, and the choice runs only while the session and the row are still there.
    private func act(_ s: SFTPSession, _ path: String, _ run: () -> Void) {
        guard sessions.sessions.contains(where: { $0 === s }), s.core.node(path) != nil else { return }
        s.core.select(path)
        run()
    }

    // MARK: - Connecting

    private func connect(_ row: RemoteServer) {
        if let open = sessions.find(row.key("sftp")) { sessions.setActive(open); return }
        if let error = sessions.open(row.target("sftp", group: repo)) {
            Dialogs.alert("Could not connect to \(row.name)", error)
        }
    }

    @MainActor static func close(_ s: SFTPSession) {
        if s.state != .closed && s.core.busy.what != nil
            && !Dialogs.confirm("Disconnect from \(s.label)?", "A transfer is still running; disconnecting stops it, and the transfers waiting behind it are dropped.",
                                continueLabel: "Disconnect", destructive: true) { return }
        SFTPSessions.shared.close(s)
    }

    @MainActor static func reconnect(_ s: SFTPSession) {
        if let error = s.reconnect() { Dialogs.alert("Could not reconnect", error) }
    }

    /// ⟳: the servers, and the folder on show, read again.
    @MainActor static func refresh(repo: String, servers: RemoteServers) {
        servers.refresh()
        guard let s = SFTPSessions.shared.shown(group: repo), s.state == .ready else { return }
        let sel = s.core.selected
        let dir: String? = s.core.node(sel).flatMap { $0.dir || $0.link ? $0.path : nil } ?? SFTP.parent(sel)
        if let dir { s.core.list(dir) }
    }

    // MARK: - Files

    /// The folder new files go to: the selected folder, the selected file's folder, else the folder the server started in.
    @MainActor static func targetFolder(_ s: SFTPSession) -> String {
        let sel = s.core.selected
        if let n = s.core.node(sel), holds(n) { return n.path }
        if let sel, let parent = SFTP.parent(sel) { return parent }
        return s.core.home ?? "/"
    }

    /// Queues local files and folders for upload into `folder`, after asking before replacing what is there.
    @MainActor static func upload(_ s: SFTPSession, _ paths: [String], into folder: String) {
        guard !paths.isEmpty else { return }
        let kids = Set(s.core.node(folder)?.kids.map(\.name) ?? [])
        let clashes = paths.map { ($0 as NSString).lastPathComponent }.filter { kids.contains($0) }
        if let first = clashes.first {
            let one = clashes.count == 1
            let title = one ? "Replace \(first)?" : "Replace \(clashes.count) items?"
            let message = "\(one ? first : "Some of them") already \(one ? "exists" : "exist") in \(folder). Uploading replaces \(one ? "it" : "them")."
            if !Dialogs.confirm(title, message, continueLabel: "Replace", destructive: true) { return }
        }
        for p in paths {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir) else { continue }
            s.core.upload(p, into: folder, folder: isDir.boolValue)
        }
    }

    @MainActor static func dropped(_ providers: [NSItemProvider], on s: SFTPSession, folder: String) {
        var urls: [URL] = []
        let group = DispatchGroup()
        let lock = NSLock()
        for p in providers where p.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated {
                NSApp.activate(ignoringOtherApps: true)
                guard SFTPSessions.shared.sessions.contains(where: { $0 === s }), s.state == .ready else { return }
                upload(s, urls.map(\.path), into: folder)
            }
        }
    }

    @MainActor static func uploadFiles(_ s: SFTPSession, into folder: String) {
        let panel = NSOpenPanel()
        panel.title = "Upload to \(folder)"
        panel.message = "Upload to \(folder)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        guard panel.runModal() == .OK else { return }
        upload(s, panel.urls.map(\.path), into: folder)
    }

    @MainActor static func uploadFolder(_ s: SFTPSession, into folder: String) {
        guard let local = pickFolder("Upload a folder to \(folder)", prompt: "Upload") else { return }
        upload(s, [local], into: folder)
    }

    /// A local folder from the folder picker.
    @MainActor static func pickFolder(_ title: String, prompt: String) -> String? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    @MainActor static func download(_ s: SFTPSession, _ path: String) {
        guard let n = s.core.node(path), path != "/" else { return }
        if holds(n) {
            guard let into = pickFolder("Download \(n.name) into", prompt: "Download") else { return }
            let local = (into as NSString).appendingPathComponent(n.name)
            if !FileManager.default.fileExists(atPath: local)
                || Dialogs.confirm("Merge folders?", "A folder with this name is already there; the download adds to it and replaces files with the same names.",
                                   continueLabel: "Download", destructive: true) {
                s.core.download(path, to: local, folder: true)
            }
        } else {
            let panel = NSSavePanel()
            panel.title = "Download"
            // The Mac does not allow every name a server does: the default name drops what it refuses.
            panel.nameFieldStringValue = String(n.name.map { $0 == "/" || $0 == ":" || ($0.asciiValue.map { $0 < 32 } ?? false) ? "_" : $0 })
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            panel.canCreateDirectories = true
            if panel.runModal() == .OK, let url = panel.url { s.core.download(path, to: url.path, folder: false) }
        }
    }

    @MainActor static func makeFolder(_ s: SFTPSession, in folder: String) {
        guard let name = Dialogs.text("New folder", label: "Name of the new folder in \(folder)", okLabel: "Create")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
        if name.contains("/") { Dialogs.alert("New folder", "A folder name cannot hold a slash."); return }
        s.core.mkdir(SFTP.join(folder, name))
    }

    @MainActor static func rename(_ s: SFTPSession, _ path: String) {
        guard path != "/" else { return }
        let current = SFTP.basename(path)
        guard let name = Dialogs.text("Rename", label: "New name", okLabel: "Rename", current: current)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name != current else { return }
        if name.contains("/") { Dialogs.alert("Rename", "A name cannot hold a slash."); return }
        s.core.rename(path, to: SFTP.join(SFTP.parent(path), name))
    }

    @MainActor static func delete(_ s: SFTPSession, _ path: String) {
        guard let n = s.core.node(path), path != "/" else { return }
        if Dialogs.confirm("Delete \(n.name)?", n.dir ? "The folder is deleted on the server. Only an empty folder can be deleted." : "The file is deleted on the server; this cannot be undone.",
                           continueLabel: "Delete", destructive: true) {
            s.core.remove(path, folder: n.dir)
        }
    }

    // MARK: - The header

    /// The session on show: "SFTP user@host:port · connected · <selected path>", its dot, ⇧ Upload, ⇩ Download, New folder,
    /// Home, Reconnect (while it is closed), Close, and ⟳ (which reads the servers and the folder on show again).
    @MainActor static func header(repo: String, refresh: (() -> Void)? = nil) -> RemoteHeader {
        var buttons: [HeaderButton] = []
        var subtitle: String?, status: String?
        if let s = SFTPSessions.shared.shown(group: repo) {
            let state = s.state, ready = state == .ready
            let word = ready ? "connected" : state == .connecting ? "connecting" : "closed"
            let where_ = s.core.selected
            subtitle = "SFTP \(s.display) \u{00B7} \(word)\(where_.map { " \u{00B7} \($0)" } ?? "")"
            status = state == .closed ? "closed" : "idle"
            let sel = s.core.node(s.core.selected)
            buttons.append(HeaderButton(glyph: Glyph.symbol(0xE898), label: "Upload", tip: "Upload files into the selected folder", enabled: ready, prominent: true) {
                if s.state == .ready { uploadFiles(s, into: targetFolder(s)) }
            })
            buttons.append(HeaderButton(glyph: Glyph.symbol(0xE896), label: "Download", tip: "Download the selected file or folder",
                                        enabled: ready && sel != nil && sel?.path != "/") {
                if s.state == .ready, let p = s.core.selected { download(s, p) }
            })
            buttons.append(HeaderButton(glyph: Glyph.symbol(0xE8F4), tip: "New folder in the selected folder", enabled: ready) {
                if s.state == .ready { makeFolder(s, in: targetFolder(s)) }
            })
            buttons.append(HeaderButton(glyph: Glyph.symbol(0xE80F), tip: "Go to the folder the server starts in", enabled: ready && s.core.home != nil) {
                s.core.revealPath(s.core.home)
            })
            if state == .closed {
                buttons.append(HeaderButton(glyph: Glyph.symbol(0xE72C), label: "Reconnect", tip: "Connect this session again") { reconnect(s) })
            }
            buttons.append(HeaderButton(glyph: Glyph.symbol(0xE711), tip: "Close this session") { close(s) })
        }
        if let refresh {
            buttons.append(HeaderButton(glyph: Glyph.symbol(0xE72C), tip: "Read the servers and the folder on show again", action: refresh))
        }
        return RemoteHeader(subtitle: subtitle, status: status, buttons: buttons)
    }
}

// MARK: - Rows

/// The tree's column headings.
private struct Columns: View {
    var body: some View {
        HStack(spacing: 0) {
            Text("Name").padding(.leading, 6)
            Spacer(minLength: 12)
            Text("Size").frame(width: 80, alignment: .trailing)
            Spacer().frame(width: 12)
            Text("Modified").frame(width: 120, alignment: .trailing)
        }
        .font(Theme.caption2).foregroundStyle(Theme.tertiary).lineLimit(1)
        .padding(.trailing, 8)
        .frame(height: 22)
    }
}

/// A row of the tree: its twisty, its icon, its name, and a file's size and date.
private struct TreeRow: View {
    var name: String
    var size: String?
    var when: String?
    var link: Bool
    var expanded: Bool
    var depth: Int
    var folder: Bool
    var selected: Bool
    var home: Bool
    var click: () -> Void
    var twisty: () -> Void
    @State private var hovered = false

    var body: some View {
        let glyph: UInt32 = folder ? (home ? 0xE80F : expanded ? 0xE838 : 0xE8B7) : link ? 0xE71B : 0xE8A5
        HStack(spacing: 0) {
            Spacer().frame(width: 6 + CGFloat(depth) * ProjectSFTPTab.indent)
            Group {
                if folder {
                    // The twisty opens and closes without selecting.
                    Image(systemName: Glyph.symbol(expanded ? 0xE70D : 0xE76C)).font(.system(size: 10))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 22, height: ProjectSFTPTab.rowHeight)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: twisty)
                        .padding(.horizontal, -3)
                } else {
                    Color.clear.frame(width: 16)
                }
            }
            .frame(width: 16)
            Image(systemName: Glyph.symbol(glyph)).font(.system(size: 12))
                .foregroundStyle(folder ? Theme.accent : Theme.muted)
                .frame(width: 20)
                .padding(.leading, 2)
            Text(name).font(selected ? Theme.footnoteSemibold : Theme.footnote).foregroundStyle(Theme.ink)
                .lineLimit(1).truncationMode(.tail)
                .padding(.leading, 6)
            Spacer(minLength: 12)
            Text(size ?? "").font(Theme.caption).foregroundStyle(Theme.muted)
                .lineLimit(1).frame(width: 80, alignment: .trailing)
            Spacer().frame(width: 12)
            Text(when ?? "").font(Theme.caption).foregroundStyle(Theme.muted)
                .lineLimit(1).frame(width: 120, alignment: .trailing)
        }
        .padding(.trailing, 8)
        .frame(height: ProjectSFTPTab.rowHeight)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 5).fill(Theme.raise)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line, lineWidth: 1))
            } else if hovered {
                RoundedRectangle(cornerRadius: 5).fill(Theme.raise.opacity(0.5))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: click)
        .onHover { hovered = $0 }
    }
}

/// One line over the tree, always there so the rows do not move: what runs now, how the last transfer or change went
/// (with "Show in Finder" after a download), else how to move files.
private struct StatusLine: View {
    private var text: String
    private var glyph: UInt32?
    private var color: Color = Theme.tertiary
    private var download: String?
    @State private var linkHovered = false

    @MainActor init(session: SFTPSession) {
        let core = session.core!
        let busy = core.busy
        if let what = busy.what {
            text = busy.queued > 0 ? "\(what) \u{00B7} \(busy.queued) more waiting" : what
            glyph = 0xE895; color = Theme.accent
        } else if let status = core.status {
            // Several complaints share the line.
            text = status.replacingOccurrences(of: "\n", with: " \u{00B7} ")
            glyph = core.statusFailed ? 0xE783 : 0xE73E
            color = core.statusFailed ? Theme.danger : Theme.muted
            if !core.statusFailed && status.hasPrefix("Downloaded ") { download = core.lastDownload }
        } else {
            text = session.state == .ready
                ? "Drop files or folders from the Finder onto a folder to upload them there; double-click a file to download it; right-click for more."
                : "Not connected."
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            if let glyph {
                Image(systemName: Glyph.symbol(glyph)).font(.system(size: 12)).foregroundStyle(color).frame(width: 18)
            }
            Text(text).font(Theme.caption).foregroundStyle(color).lineLimit(1).truncationMode(.tail)
                .padding(.leading, 6)
            Spacer(minLength: 16)
            if let local = download {
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: local)]) } label: {
                    Text("Show in Finder").font(Theme.captionSemibold).foregroundStyle(linkHovered ? Theme.ink : Theme.accent)
                }
                .buttonStyle(.plain)
                .onHover { linkHovered = $0 }
                .padding(.trailing, 4)
            }
        }
        .frame(height: 24)
    }
}
