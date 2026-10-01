// A pull request's changed files as GitHub's Files changed tab (screen_files.c): the tree of paths on the left, the chosen
// file's diff beside it. The component is laid out inside the pull request screen, and the standalone screen wraps it for
// the conversation's menu.
import SwiftUI

/// The scroll view the files are laid out in, so the tree can stay in view beside a long diff.
let pullScrollSpace = "pullScroll"

@MainActor
final class PullFilesModel: ObservableObject {
    let repo: String
    let number: Int
    @Published private(set) var list = PullFileList()
    @Published private(set) var loading = false
    @Published private(set) var changed = false
    @Published private(set) var error: String?
    @Published var collapsed: Set<String> = []
    @Published var selectedPath: String?
    @Published var wrap = true
    private var confirmed = false
    private var retried = false
    private var task: Task<Void, Never>?
    private var treeCache: (count: Int, tree: FileTree)?
    private var diffCache: (path: String, patch: String?, lines: [DiffLine])?

    init(repo: String, number: Int) { self.repo = repo; self.number = number }

    private var key: String { "files:\(repo)#\(number)" }
    var started: Bool { confirmed || !list.pr.isNull }

    func load() {
        guard !loading, Store.shared.supports("pull_files") else { return }
        if !confirmed && list.pr.isNull, let saved = Store.shared.cache.value(key), let l = PullFileList(saved) { list = l }
        guard let args = (confirmed ? list : PullFileList()).arguments(repo: repo, number: number) else { return }
        loading = true
        task = Task { [weak self] in
            let r = await boardCall("pull_files", args)
            self?.done(r)
        }
    }
    private func done(_ r: Result<JSON, APIError>) {
        loading = false
        switch r {
        case .failure(let e):
            if e.kind == .cancelled { return }
            // A push or rebase invalidates the pages already read; never mix two revisions.
            if e.kind == .http && e.status == 409 && !retried {
                list = PullFileList(); changed = true; confirmed = true; retried = true
                load()
                return
            }
            error = e.description
        case .success(let v):
            guard let page = PullFilesPage(v) else { error = "The server returned an unexpected response."; return }
            error = nil
            retried = false
            if !confirmed {
                confirmed = true
                // The same revision has the same files; only a push or rebase makes them worth reading again.
                if list.confirm(page) { return }
                list = PullFileList()
            }
            list.append(page)
            // Only whole lists are saved, so a saved one never waits on a page.
            if list.nextPage == nil { Store.shared.cache.store(list.json, key) }
        }
    }
    func cancel() { task?.cancel(); task = nil; loading = false }
    func refresh() {
        cancel()
        list = PullFileList(); changed = false; confirmed = true
        load()
    }
    func retry() { load() }

    var tree: FileTree {
        if let c = treeCache, c.count == list.files.count { return c.tree }
        let t = FileTree(list.files)
        treeCache = (list.files.count, t)
        return t
    }
    /// The chosen file follows its path across revisions; the first file is chosen until then.
    var selected: Int? {
        if let p = selectedPath, let i = list.files.firstIndex(where: { $0.filename == p }) { return i }
        return list.files.isEmpty ? nil : 0
    }
    func lines(_ file: PullFile) -> [DiffLine] {
        if let c = diffCache, c.path == file.filename, c.patch == file.patch { return c.lines }
        let l = diffParse(file.patch)
        diffCache = (file.filename, file.patch, l)
        return l
    }
    func toggle(_ path: String) { if collapsed.contains(path) { collapsed.remove(path) } else { collapsed.insert(path) } }
}

/// The Files changed tab, `width` wide; `viewHeight` is the pane's, which the tree's own scrolling is held to.
struct PullFilesView: View {
    @ObservedObject var model: PullFilesModel
    var width: CGFloat
    var viewHeight: CGFloat
    @State private var frame: CGRect = .zero

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.changed {
                GlyphLabel(glyph: 0xE72C, text: "This pull request changed while reading. Showing its latest revision.", font: Theme.footnote, color: Theme.muted)
                    .padding(.horizontal, 4).padding(.bottom, 10)
            }
            if let e = model.error {
                Notice(message: e).padding(.horizontal, 4)
                Button("Try again") { model.retry() }.dashButton(.bordered).disabled(model.loading).padding(.horizontal, 4).padding(.top, 8).padding(.bottom, 12)
            }
            if model.list.pr.isNull {
                if model.error == nil { LoadingNote(text: "Loading changes…") }
            } else if model.list.files.isEmpty && model.list.nextPage == nil {
                Text("No files changed").font(Theme.callout).foregroundStyle(Theme.muted).padding(.horizontal, 8)
            } else {
                content
                if model.list.nextPage != nil && model.error == nil { LoadingNote(text: "Loading more files…").padding(.top, 8) }
                if model.list.truncated {
                    Text("GitHub lists only the first 3,000 files of this pull request.").font(Theme.caption).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4).padding(.top, 8)
                }
            }
        }
        // The next page is read as soon as the one before is in, while the tab is on show.
        .task(id: "\(model.list.files.count)-\(model.loading)-\(model.error == nil)-\(model.list.nextPage ?? 0)") {
            if model.started, model.list.nextPage != nil, model.error == nil, !model.loading { model.load() }
        }
    }

    @ViewBuilder private var content: some View {
        let tree = model.tree
        let rows = tree.rows(collapsed: model.collapsed)
        if width >= 720 {
            // Wide: the tree on the left, the diff on the right, as GitHub's `.pr-toolbar` layout. The tree stays in view
            // beside the diff and scrolls on its own, as GitHub's file tree does.
            let treeW = min(max(width * 28 / 100, 220), 320)
            let treeH = min(26 + CGFloat(rows.count) * 27, max(viewHeight - 24, 120))
            let stick = max(0, min(-frame.minY, frame.height - treeH))
            HStack(alignment: .top, spacing: 16) {
                ScrollView(.vertical) { treeList(tree, rows) }
                    .frame(width: treeW, height: treeH)
                    .offset(y: stick)
                diff.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: treeH, alignment: .top)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(pullScrollSpace)) } action: { frame = $0 }
        } else {
            treeList(tree, rows)
            Spacer().frame(height: 12)
            diff
        }
    }

    private func treeList(_ tree: FileTree, _ rows: [FileTree.Row]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(model.list.files.count) file\(model.list.files.count == 1 ? "" : "s")").font(Theme.captionSemibold).foregroundStyle(Theme.muted)
                .lineLimit(1).padding(.horizontal, 6).padding(.bottom, 5)
            ForEach(rows, id: \.node) { row in
                let node = tree.nodes[row.node]
                TreeRow(node: node, indent: row.indent, open: !model.collapsed.contains(node.path),
                        selected: node.file != nil && node.file == model.selected,
                        file: node.file.map { model.list.files[$0] }) {
                    if let f = node.file { model.selectedPath = model.list.files[f].filename } else { model.toggle(node.path) }
                }
            }
        }
    }

    @ViewBuilder private var diff: some View {
        if let index = model.selected, index < model.list.files.count {
            let file = model.list.files[index]
            DiffBox(file: file, lines: model.lines(file), wrap: model.wrap) { model.wrap.toggle() }
        }
    }
}

/// A row of the tree: a chevron and folder for a directory, the status mark for a file, then the name.
private struct TreeRow: View {
    var node: FileTree.Node
    var indent: Int
    var open: Bool
    var selected: Bool
    var file: PullFile?
    var action: () -> Void
    @State private var hovered = false

    private var mark: (String, Color) {
        switch file?.status {
        case "added": return (Glyph.symbol(0xE710), Theme.ok)
        case "removed": return (Glyph.symbol(0xE738), Theme.danger)
        case "renamed", "copied": return (Glyph.symbol(0xE72A), Theme.accent)
        default: return (Glyph.symbol(0xE70F), Theme.warn)
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Spacer().frame(width: 6 + CGFloat(indent) * 16)
                if node.file == nil {
                    Image(systemName: Glyph.symbol(open ? 0xE70D : 0xE76C)).font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.muted).frame(width: 14)
                    Spacer().frame(width: 2)
                    Image(systemName: Glyph.symbol(0xE8B7)).font(.system(size: 11)).foregroundStyle(Theme.accent).frame(width: 16)
                } else {
                    Spacer().frame(width: 16)
                    Image(systemName: mark.0).font(.system(size: 10, weight: .semibold)).foregroundStyle(mark.1).frame(width: 16)
                }
                Spacer().frame(width: 4)
                Text(node.name).font(selected ? Theme.footnoteSemibold : Theme.footnote).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
            }
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.accent.opacity(0.16) : hovered ? Theme.raise : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// The chosen file: `.file-header` with its path and diffstat, the wrap and GitHub buttons, then the patch's lines.
private struct DiffBox: View {
    var file: PullFile
    var lines: [DiffLine]
    var wrap: Bool
    var toggleWrap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            let buttons = file.patch != nil || safeWebURL(file.url)
            if buttons {
                HStack(spacing: 6) {
                    if file.patch != nil {
                        GlyphButton(glyph: Glyph.symbol(wrap ? 0xE8E4 : 0xE8E3), title: wrap ? "Scroll long lines" : "Wrap long lines", kind: .plain, action: toggleWrap)
                    }
                    if safeWebURL(file.url) {
                        GlyphButton(glyph: Glyph.symbol(0xE8A7), title: "Open on GitHub", kind: .plain) { openWebURL(file.url) }
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 8)
            }
            if file.patch == nil {
                GlyphLabel(glyph: 0xE8A5, text: "No diff available", font: Theme.subheadlineSemibold).padding(.horizontal, 12)
                Text("GitHub returns no patch for binary files and very large changes.").font(Theme.footnote).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
            }
            if !lines.isEmpty {
                if wrap {
                    LazyVStack(alignment: .leading, spacing: 0) { ForEach(lines, id: \.id) { DiffRow(line: $0, wrap: true) } }
                } else {
                    // Long lines scroll sideways: the rows grow to the widest line.
                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: 0) { ForEach(lines, id: \.id) { DiffRow(line: $0, wrap: false) } }
                    }
                }
                Spacer().frame(height: 6)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raise))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var head: some View {
        HStack(spacing: 0) {
            Image(systemName: Glyph.symbol(0xE8A5)).font(.system(size: 12)).foregroundStyle(Theme.muted).frame(width: 16).padding(.trailing, 6)
            VStack(alignment: .leading, spacing: 0) {
                Text(file.filename).font(Theme.monoSmall).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                if let from = file.previousFilename {
                    Text("renamed from \(from)").font(Theme.monoCaption2).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 12)
            Text("+\(file.additions ?? 0)").font(Theme.monoSmall).foregroundStyle(Theme.ok)
            Spacer().frame(width: 6)
            Text("\u{2212}\(file.deletions ?? 0)").font(Theme.monoSmall).foregroundStyle(Theme.danger)
        }
        .padding(.horizontal, 12).frame(height: 40)
        .background(UnevenRoundedRectangle(topLeadingRadius: 7, topTrailingRadius: 7).fill(Theme.accent.opacity(0.06)))
        .overlay(alignment: .bottom) { Rule() }
    }
}

/// One line of the patch: its number, its sign and its text on the added or removed tint; a hunk header on the accent's.
private struct DiffRow: View {
    var line: DiffLine
    var wrap: Bool

    private var text: String { line.text.replacingOccurrences(of: "\t", with: "        ") }

    var body: some View {
        if line.kind == .hunk || line.kind == .note {
            Text(text).font(Theme.monoCaption2).foregroundStyle(Theme.muted)
                .lineLimit(wrap ? nil : 1).fixedSize(horizontal: !wrap, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, line.kind == .hunk ? 6 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(line.kind == .hunk ? Theme.accent.opacity(0.08) : Color.clear)
        } else {
            let tint: Color = line.kind == .added ? Theme.ok : line.kind == .removed ? Theme.danger : Theme.raise
            let n = line.newLine != 0 ? line.newLine : line.oldLine
            HStack(alignment: .top, spacing: 0) {
                Text(n != 0 ? "\(n)" : "").font(Theme.monoCaption2).foregroundStyle(Theme.tertiary).frame(width: 40, alignment: .trailing)
                Spacer().frame(width: 8)
                Text(line.kind == .added ? "+" : line.kind == .removed ? "\u{2212}" : " ").font(Theme.monoSmall)
                    .foregroundStyle(line.kind == .context ? Theme.muted : tint).frame(width: 14, alignment: .leading)
                Text(text.isEmpty ? " " : text).font(Theme.monoSmall).foregroundStyle(Theme.ink)
                    .lineLimit(wrap ? nil : 1).fixedSize(horizontal: !wrap, vertical: true)
                    .textSelection(.enabled)
                    .padding(.trailing, 12)
                if !wrap { Spacer(minLength: 0) }
            }
            .padding(.vertical, 1.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(line.kind == .context ? Color.clear : tint.opacity(0.13))
        }
    }
}

/// The files on their own, for the conversation's menu (pull_files_screen_new).
struct PullFilesScreen: View {
    var repo: String
    var number: Int
    @ObservedObject private var model: PullFilesModel

    init(repo: String, number: Int) {
        self.repo = repo; self.number = number
        model = BoardModels.model("files:\(repo)#\(number)") { PullFilesModel(repo: repo, number: number) }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "#\(number)", subtitle: "Files changed")
            GeometryReader { geo in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Spacer().frame(height: 10)
                        PullFilesView(model: model, width: geo.size.width - 2 * Theme.paneMargin, viewHeight: geo.size.height)
                        Spacer().frame(height: 16)
                    }
                    .padding(.horizontal, Theme.paneMargin)
                }
                .coordinateSpace(name: pullScrollSpace)
            }
        }
        .onAppear { model.load() }
        .onDisappear { model.cancel(); BoardModels.release("files:\(repo)#\(number)") }
        .onReceive(NotificationCenter.default.publisher(for: .refreshScreen)) { _ in model.refresh() }
    }
}
