// The pull request screen as GitHub lays one out: the title with its state and the sentence under it, the tabnav, then the
// open tab beside GitHub's sidebar when the pane is wide (screen_pulls.c pull_layout).
import SwiftUI

struct PullScreen: View {
    var repo: String
    var number: Int
    var stack: JSON?
    var summary: JSON?
    @ObservedObject private var model: PullModel
    @ObservedObject private var store = Store.shared

    init(repo: String, number: Int, stack: JSON?, summary: JSON?) {
        self.repo = repo; self.number = number; self.stack = stack; self.summary = summary
        model = BoardModels.model("pull:\(repo)#\(number)") {
            PullModel(repo: repo, number: number, stack: stack.flatMap { StackPosition(restoring: $0) }, summary: summary.flatMap { PullSummary($0) })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geo in
                let w = geo.size.width - 2 * Theme.paneMargin
                if model.tab == .run {
                    VStack(alignment: .leading, spacing: 0) {
                        top(w)
                        RunArea(model: model).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(.bottom, 12)
                    }
                    .padding(.horizontal, Theme.paneMargin)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            top(w)
                            columns(w, viewHeight: geo.size.height)
                            Spacer().frame(height: 16)
                        }
                        .padding(.horizontal, Theme.paneMargin)
                    }
                    .coordinateSpace(name: pullScrollSpace)
                }
            }
        }
        .task {
            await poll(every: 30) {
                if model.busy || model.merging || model.deciding != nil || model.dialogOpen { return nil }
                return await model.load()
            }
        }
        // The setup's log while a Run is being prepared, every second and a half.
        .task(id: model.runBusy) {
            while model.runBusy && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if Task.isCancelled { return }
                await model.runLogTick()
            }
        }
        .onAppear { model.appeared() }
        .onDisappear { model.disappeared(); BoardModels.release(model.id) }
        .onReceive(NotificationCenter.default.publisher(for: .refreshScreen)) { _ in model.refresh() }
    }

    private var header: some View {
        var sub = "\(repo) #\(number)"
        var buttons: [HeaderButton] = []
        if model.tab == .run, model.runURL != nil {
            sub += " · \(model.pageURL ?? "")"
            buttons.append(HeaderButton(glyph: Glyph.symbol(0xE72C), tip: "Reload the page", enabled: model.browser?.ready ?? false) { model.browser?.reload() })
            buttons.append(HeaderButton(glyph: Glyph.symbol(0xE8A7), tip: "Open in your browser") { openWebURL(model.pageURL) })
        }
        return PaneHeader(title: "Pull request", subtitle: sub, buttons: buttons)
    }

    /// The notices, the title block and the tabs.
    @ViewBuilder private func top(_ w: CGFloat) -> some View {
        Spacer().frame(height: 14)
        if let e = model.error { Notice(message: e).padding(.horizontal, 4).padding(.bottom, 10) }
        if let e = model.writeError {
            Notice(message: e).padding(.horizontal, 4)
            if model.uncertain {
                Text("The request may have completed. Refresh (F5) and look for its conversation in the Sessions tab before starting another agent.")
                    .font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4).padding(.top, 4)
            }
            Spacer().frame(height: 10)
        }
        PullHeader(model: model, width: w - 8).padding(.horizontal, 4)
        Spacer().frame(height: 12)
        PullTabs(model: model).padding(.horizontal, 4)
        Spacer().frame(height: 18)
    }

    @ViewBuilder private func columns(_ w: CGFloat, viewHeight: CGFloat) -> some View {
        if model.tab == .files && !model.pr.isNull {
            // The files take the whole width: GitHub's Files changed tab has no sidebar.
            PullFilesView(model: model.files, width: w, viewHeight: viewHeight)
        } else if w >= 880 {
            // Wide: the conversation on the left, GitHub's sidebar on the right.
            let side = min(max(w * 26 / 100, 240), 320)
            HStack(alignment: .top, spacing: 28) {
                PullMain(model: model).frame(maxWidth: .infinity, alignment: .topLeading)
                PullSidebar(model: model).frame(width: side).padding(.top, -14)
            }
        } else {
            PullMain(model: model)
            Spacer().frame(height: 6)
            PullSidebar(model: model).padding(.horizontal, 4)
        }
    }
}

// MARK: - Title block

/// `gh-header`: the title with its muted number and the buttons beside it, then the state and `author wants to merge N
/// commits into base from head`.
private struct PullHeader: View {
    @ObservedObject var model: PullModel
    var width: CGFloat

    var body: some View {
        let row = model.boardRow
        VStack(alignment: .leading, spacing: 0) {
            // Beside the title when there is room, above it when there is not.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    title.frame(minWidth: 320, alignment: .leading)
                    toolbar.padding(.top, 3).fixedSize()
                }
                VStack(alignment: .leading, spacing: 12) {
                    toolbar
                    title
                }
            }
            Spacer().frame(height: 10)
            HStack(alignment: .top, spacing: 0) {
                StatePill(text: stateText(row), color: stateColor)
                if let stack = model.stack {
                    StackPill(label: stack.label(model.number), open: model.stackOpen) { model.stackOpen.toggle() }.padding(.leading, 8)
                }
                WordFlow(runs: sentence(row), lineHeight: 26).padding(.leading, 10)
            }
            if let stack = model.stack, model.stackOpen {
                StackOverview(model: model, stack: stack).padding(.top, 10)
            }
            if let e = model.mergeError { Notice(message: e).padding(.top, 8) }
        }
    }

    private var title: some View {
        let t = model.pr["title"].string ?? model.boardRow?.title ?? "Pull request"
        return (Text(t + " ").foregroundStyle(Theme.ink) + Text("#\(model.number)").foregroundStyle(Theme.muted))
            .font(Theme.title).lineSpacing(6).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button("⟳ Refresh") { model.refresh() }.dashButton(.bordered).disabled(model.readingPull)
            if model.canMerge {
                Button(model.merging ? "Merging…" : "Merge") { model.merge() }.dashButton(.prominent).disabled(model.merging || model.busy)
            }
            if safeWebURL(model.pr["url"].string) {
                Button("Open in GitHub ↗") { openWebURL(model.pr["url"].string) }.dashButton(.bordered)
            }
        }
    }

    private var draft: Bool { model.pr["draft"].is(true) || (model.pr.isNull && (model.boardRow?.draft ?? false)) }
    private func stateText(_ row: PullSummary?) -> String {
        if draft && model.isOpen { return "draft" }
        return model.pr["state"].string ?? (row != nil ? "open" : "loading")
    }
    private var stateColor: Color {
        let state = model.pr["state"].string
        return state == "merged" ? Theme.accent : state == "closed" ? Theme.danger : draft ? Theme.muted : Theme.ok
    }
    private func sentence(_ row: PullSummary?) -> [FlowRun] {
        var runs: [FlowRun] = []
        let state = model.pr["state"].string
        var head = model.pr["headRef"].string, base = model.pr["baseRef"].string
        if head == nil, let r = row, !r.branch.isEmpty { head = r.branch }
        if base == nil, let r = row, !r.baseBranch.isEmpty { base = r.baseBranch }
        let author = model.author
        let commits = model.commitCount
        if let author { runs.append(FlowRun(text: author + " ", font: Theme.footnoteSemibold, color: Theme.ink)) }
        if head != nil || base != nil || commits > 0 {
            let done = state == "merged"
            var verb = done ? (author != nil ? "merged " : "Merged ") : author != nil ? "wants to merge " : "Wants to merge "
            if commits > 0 { verb += "\(commits) commit\(commits == 1 ? "" : "s") " }
            if base != nil || head != nil { verb += "into " }
            runs.append(FlowRun(text: verb, font: Theme.footnote, color: Theme.muted))
            if base != nil || head != nil { runs.append(FlowRun(text: base ?? "main", font: Theme.monoCaption2, color: Theme.accent, chip: true)) }
            if let head {
                runs.append(FlowRun(text: "from ", font: Theme.footnote, color: Theme.muted))
                runs.append(FlowRun(text: head, font: Theme.monoCaption2, color: Theme.accent, chip: true))
            }
        }
        if let row, row.mergeable == "conflicting" {
            runs.append(FlowRun(text: "· ⚠ conflicts with \(base ?? "its base") ", font: Theme.footnote, color: Theme.warn))
        }
        if let at = row?.updatedAt { runs.append(FlowRun(text: "· updated \(formatRelative(at))", font: Theme.footnote, color: Theme.muted)) }
        return runs
    }
}

/// GitHub's stack button beside the state: the stack glyph and `2/3` in a bordered pill, pressed while the overview is open.
private struct StackPill: View {
    var label: String
    var open: Bool
    var action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: Glyph.symbol(0xE81E)).font(.system(size: 11)).foregroundStyle(Theme.accent).frame(width: 16)
                Text(label).font(Theme.footnoteSemibold).foregroundStyle(Theme.ink)
            }
            .padding(.horizontal, 10).frame(height: 26)
            .background(Capsule().fill(open ? Theme.accent.opacity(0.18) : hovered ? Theme.raise : Theme.canvas))
            .overlay(Capsule().strokeBorder(open ? Theme.accent : Theme.line, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// GitHub's stack popover, laid out under the title: the stack top first, this pull request marked, and the base branch at
/// the bottom.
private struct StackOverview: View {
    @ObservedObject var model: PullModel
    var stack: StackPosition
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Stack · \(stack.label(model.number))").font(Theme.footnoteSemibold).foregroundStyle(Theme.ink).lineLimit(1).padding(.horizontal, 4)
            BoardRule().padding(.vertical, 6)
            ForEach(stack.topFirst, id: \.self) { i in
                let item = stack.chain[i]
                StackRow(item: item, current: item.number == model.number) {
                    Navigator.shared.push(.pull(repo: model.repo, number: item.number, stack: stack.json, summary: nil))
                }
            }
            if stack.chain.isEmpty {
                Text("The board did not list the stack's pull requests.").font(Theme.caption).foregroundStyle(Theme.muted).padding(.horizontal, 4)
            }
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    Rectangle().fill(Theme.line).frame(width: 1, height: 10)
                    Circle().strokeBorder(Theme.muted, lineWidth: 1).frame(width: 9, height: 9)
                    Spacer(minLength: 0)
                }
                .frame(width: 18).padding(.leading, 10)
                Spacer().frame(width: 8)
                if let base = stack.base { Chip(name: base, color: Theme.accent) }
                else { Text("base branch not on the board").font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1) }
                Spacer(minLength: 0)
            }
            .frame(height: 30)
            Text(stack.partial ? "Only part of this stack is on the board; it may be longer. Merge from the bottom up." : "Merge from the bottom up.")
                .font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4).padding(.top, 4)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: 520, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.raise))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line, lineWidth: 1))
    }
}

/// One pull request of the overview: the pull request glyph, its title, and `#number · branch` under it.
private struct StackRow: View {
    var item: StackItem
    var current: Bool
    var action: () -> Void
    @State private var hovered = false
    var body: some View {
        let sub = "#\(item.number)" + (item.branch.map { " · \($0)" } ?? "") + (item.draft ? " · draft" : "")
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 0) {
                Image(systemName: Glyph.symbol(0xE81E)).font(.system(size: 11)).foregroundStyle(current ? Theme.ink : Theme.accent).frame(width: 18, height: 22)
                // The rail of the stack: a thin line under the glyph joining the rows.
                Rectangle().fill(Theme.line).frame(width: 1).frame(maxHeight: .infinity)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title).font(Theme.footnoteSemibold).foregroundStyle(!current && hovered ? Theme.accent : Theme.ink)
                    .lineLimit(1).truncationMode(.tail).frame(height: 20).padding(.top, 2)
                Text(sub).font(Theme.monoCaption2).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail).frame(maxHeight: .infinity)
            }
            Spacer(minLength: 8)
        }
        .padding(.leading, 10)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 6).fill(current ? Theme.accent.opacity(0.10) : hovered ? Theme.canvas : .clear))
        .overlay(alignment: .leading) {
            if current { RoundedRectangle(cornerRadius: 1).fill(Theme.accent).frame(width: 3).padding(.vertical, 6) }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !current { action() } }
        .onHover { hovered = $0 && !current }
    }
}

// MARK: - Tabs

/// `tabnav`: Sessions, PR Body, Conversation, Files changed, Commits, Checks and Findings with their counts, the Run tab,
/// and the diffstat at the right.
private struct PullTabs: View {
    @ObservedObject var model: PullModel
    @ObservedObject private var store = Store.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                FlowLayout(spacing: 0, lineSpacing: 0) {
                    if !model.runs.isEmpty { tab(0xE8F2, "Sessions", "\(model.runs.count)", .sessions) }
                    tab(0xE7C3, "PR Body", nil, .body)
                    if store.supports(ConvFeed.comments.operation) {
                        tab(0xE8BD, "Conversation", model.convCountShown.map(String.init), .conversation)
                    }
                    let files = model.pr["changedFiles"].number.map { String(Int($0)) }
                    // The files are a tab here, or GitHub's page when the server cannot list them.
                    if store.supports("pull_files") { tab(0xE8A5, "Files changed", files, .files) }
                    else if let url = model.pr["url"].string, safeWebURL(url) {
                        TabNavItem(glyph: Glyph.symbol(0xE8A5), title: "Files changed", count: files, active: false) { openWebURL(url + "/files") }
                    }
                    if model.pr["commitList"].count > 0 { tab(0xE8EE, "Commits", "\(model.commitCount)", .commits) }
                    if !model.pr.isNull { tab(0xE9D5, "Checks", "\(model.pr["checks"]["runs"].count)", .checks) }
                    if store.supports("findings") { tab(0xE7C1, "Findings", "\(model.findings.count)", .findings) }
                    if store.supports("serve_pull") || model.runURL != nil { runTab }
                }
                if let add = model.pr["additions"].number, let del = model.pr["deletions"].number {
                    DiffStat(additions: Int(add), deletions: Int(del)).frame(height: 40)
                }
            }
            BoardRule().padding(.horizontal, -4)
        }
    }

    private func tab(_ glyph: UInt32, _ title: String, _ count: String?, _ t: PullTab) -> some View {
        TabNavItem(glyph: Glyph.symbol(glyph), title: title, count: count, active: model.tab == t) { model.select(t) }
    }

    /// With run profiles, the tab names the one chosen and, once open, picks another. Inside the open tab, at its left end,
    /// a trash button deletes the run's session, and the workspace serving it with it.
    @ViewBuilder private var runTab: some View {
        let on = model.tab == .run
        let title = model.profiles.isEmpty ? "Run" : "Run · \(model.shownProfile ?? "") ▾"
        HStack(spacing: 0) {
            if on, let target = model.runTarget, store.supports("delete") {
                TrashButton(deleting: model.deletingRun == target, enabled: model.deletingRun == nil) { model.deleteServed() }
                    .padding(.leading, 4)
                    .frame(height: 40)
                    .overlay(alignment: .bottom) { RoundedRectangle(cornerRadius: 1).fill(Theme.accent).frame(height: 2).padding(.leading, 4) }
            }
            if on && !model.profiles.isEmpty {
                RunTabLabel(title: title) { model.pickProfile() }
            } else {
                TabNavItem(glyph: Glyph.symbol(0xE768), title: title, active: on) { model.select(.run) }
            }
        }
    }
}

/// The open Run tab with profiles: a tab that opens the profile menu.
private struct RunTabLabel: View {
    var title: String
    var action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: Glyph.symbol(0xE768)).font(.system(size: 12)).foregroundStyle(Theme.ink)
                Text(title).font(Theme.footnoteSemibold).foregroundStyle(Theme.ink)
            }
            .padding(.horizontal, 12).frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? Theme.raise : .clear).padding(.vertical, 5).padding(.horizontal, 2))
            .overlay(alignment: .bottom) { RoundedRectangle(cornerRadius: 1).fill(Theme.accent).frame(height: 2).padding(.horizontal, 4) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// `+N −N` and five squares split by the share of lines added and deleted.
private struct DiffStat: View {
    var additions: Int
    var deletions: Int
    var body: some View {
        let blocks = diffstatBlocks(additions: additions, deletions: deletions)
        HStack(spacing: 0) {
            Text("+\(additions)").font(Theme.captionSemibold).foregroundStyle(Theme.ok)
            Spacer().frame(width: 4)
            Text("\u{2212}\(deletions)").font(Theme.captionSemibold).foregroundStyle(Theme.danger)
            Spacer().frame(width: 6)
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2).fill(i < blocks.green ? Theme.ok : i < blocks.green + blocks.red ? Theme.danger : Theme.line)
                        .frame(width: 8, height: 8)
                }
            }
        }
    }
}

/// The trash button at the right of a session row: muted, red with a tint under the pointer, an ellipsis while deleting.
struct TrashButton: View {
    var deleting: Bool
    var enabled: Bool
    var action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            Group {
                if deleting { Text("…").font(Theme.caption).foregroundStyle(Theme.muted) }
                else { Image(systemName: Glyph.symbol(0xE74D)).font(.system(size: 12)).foregroundStyle(hovered && enabled ? Theme.danger : enabled ? Theme.muted : Theme.lineStrong) }
            }
            .frame(width: 28, height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovered && enabled ? Theme.danger.opacity(0.14) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovered = $0 }
        .help("Delete")
    }
}

// MARK: - Main column

/// The main column: what the selected tab holds.
private struct PullMain: View {
    @ObservedObject var model: PullModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.pr.isNull {
                if model.tab == .sessions { RunsList(model: model) }
                else if model.error == nil { LoadingNote() }
            } else {
                switch model.tab {
                case .conversation: ConversationTab(model: model)
                case .commits: CommitsTab(model: model)
                case .checks: ChecksTab(model: model)
                case .findings: FindingsTab(model: model)
                case .sessions: RunsList(model: model)
                default: Description(model: model)
                }
            }
        }
    }
}

/// A timeline comment's box: the header strip, then the contents 16px in.
private struct CommentBox<Content: View>: View {
    var head: CommentHead
    var url: String? = nil
    var bottom: CGFloat = 14
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let url, safeWebURL(url) { head.contentShape(Rectangle()).onTapGesture { openWebURL(url) }.handCursor() } else { head }
            }
            .padding(1)
            // A review that only carries its verdict ends with its header.
            if bottom > 0 {
                VStack(alignment: .leading, spacing: 0) { content }
                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, bottom)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raise))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, lineWidth: 1))
    }
}

/// The opening comment: the pull request's description as GitHub shows it.
private struct Description: View {
    @ObservedObject var model: PullModel
    @ObservedObject private var store = Store.shared
    var body: some View {
        let body = model.pr["body"].string ?? model.descriptionBody
        let loading = body == nil && !model.bodyRead && store.supports("pull_description")
        if body != nil || loading {
            let author = model.author
            let when: String = {
                let did = author != nil ? "commented" : "Description"
                if let at = model.boardRow?.updatedAt { return "\(did) · updated \(formatRelative(at))" }
                return did
            }()
            CommentBox(head: CommentHead(author: author, when: when), bottom: 16) {
                if let body {
                    let t = visibleMarkdown(body)
                    if t.isEmpty { Text("No description provided.").font(Theme.callout.italic()).foregroundStyle(Theme.muted) }
                    else { MarkdownView(source: t, size: .callout) }
                } else {
                    Text("Loading the description…").font(Theme.callout).foregroundStyle(Theme.muted)
                }
            }
        }
    }
}

// MARK: Conversation

/// GitHub's timeline of conversation comments, reviews and the line comments they carry.
private struct ConversationTab: View {
    @ObservedObject var model: PullModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let e = model.conv.compactMap(\.error).first { Notice(message: e).padding(.bottom, 12) }
            if !model.convRead {
                LoadingNote(text: "Loading the conversation…")
            } else {
                let comments = model.convComments, reviews = model.convReviews, lines = model.convLines
                let entries = convTimeline(comments: comments, reviews: reviews, lines: lines)
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, e in entry(e, comments, reviews, lines) }
                }
                if entries.isEmpty { Text("No comments yet").font(Theme.callout).foregroundStyle(Theme.muted) }
            }
        }
    }

    private func head(_ v: JSON, _ did: String, _ field: String, glyph: String? = nil, color: Color = Theme.muted) -> CommentHead {
        let at = convTime(v, field)
        let when = at != 0 ? "\(did) · \(formatRelative(Date(timeIntervalSince1970: TimeInterval(at))))" : did
        return CommentHead(author: v["author"].string ?? "Someone", when: when, glyph: glyph, glyphColor: color)
    }

    @ViewBuilder private func entry(_ e: ConvEntry, _ comments: JSON, _ reviews: JSON, _ lines: JSON) -> some View {
        switch e.feed {
        case .comments:
            let v = comments[e.index]
            CommentBox(head: head(v, "commented", "createdAt"), url: v["url"].string) {
                let t = visibleMarkdown(v["body"].string ?? "")
                if t.isEmpty { Text("No description provided.").font(Theme.callout.italic()).foregroundStyle(Theme.muted) }
                else { MarkdownView(source: t, size: .callout) }
            }
        case .reviews:
            let v = reviews[e.index]
            let verdict = ReviewVerdict(v)
            let g: (UInt32, Color) = verdict == .approved ? (0xE73E, Theme.ok) : verdict == .changesRequested ? (0xE7BA, Theme.danger)
                : verdict == .dismissed ? (0xE711, Theme.muted) : (0xE8BD, Theme.muted)
            let t = visibleMarkdown(v["body"].string ?? "")
            let threads = convReviewThreads(reviews: reviews, lines: lines, review: e.index)
            let any = !t.isEmpty || !threads.isEmpty
            CommentBox(head: head(v, verdict?.words ?? "reviewed", "submittedAt", glyph: Glyph.symbol(g.0), color: g.1), url: v["url"].string, bottom: any ? 14 : 0) {
                if any {
                    VStack(alignment: .leading, spacing: 10) {
                        if !t.isEmpty { MarkdownView(source: t, size: .callout) }
                        ForEach(threads, id: \.self) { ThreadBox(lines: lines, root: $0) }
                    }
                }
            }
        case .reviewComments:
            let v = lines[e.index]
            CommentBox(head: head(v, "commented on a line", "createdAt"), url: v["url"].string) {
                ThreadBox(lines: lines, root: e.index)
            }
        }
    }
}

/// A line comment thread: the file and line, then each comment in it with its author and time.
private struct ThreadBox: View {
    var lines: JSON
    var root: Int
    var body: some View {
        let first = lines[root]
        let path = first["path"].string ?? ""
        let line = first["line"].number ?? first["originalLine"].number
        VStack(alignment: .leading, spacing: 0) {
            Text(line.map { "\(path):\(Int($0))" } ?? path).font(Theme.monoSmall).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .onTapGesture { if safeWebURL(first["url"].string) { openWebURL(first["url"].string) } }
            BoardRule()
            ForEach(convThread(lines: lines, root: root), id: \.self) { i in
                let cm = lines[i]
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(cm["author"].string ?? "Someone").font(Theme.footnoteSemibold).foregroundStyle(Theme.ink).lineLimit(1)
                        let at = convTime(cm, "createdAt")
                        if at != 0 { Text(formatRelative(Date(timeIntervalSince1970: TimeInterval(at)))).font(Theme.footnote).foregroundStyle(Theme.muted).lineLimit(1) }
                    }
                    .frame(height: 20)
                    let t = visibleMarkdown(cm["body"].string ?? "")
                    if !t.isEmpty { MarkdownView(source: t, size: .callout) }
                }
                .padding(.horizontal, 12).padding(.top, 10)
            }
            Spacer().frame(height: 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.canvas))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line, lineWidth: 1))
    }
}

// MARK: Checks, commits, findings

/// A column box: 12px in, the rows split by rules.
private struct ColumnBox<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { BoardBox(padding: 12, radius: 8) { content } }
}
private struct RowGap: View {
    var body: some View { BoardRule().padding(.vertical, 6) }
}

private struct ChecksTab: View {
    @ObservedObject var model: PullModel
    var body: some View {
        let checks = model.pr["checks"]
        ColumnBox {
            CheckCounts(passed: checks["passed"].int32 ?? 0, pending: checks["pending"].int32 ?? 0, failed: checks["failed"].int32 ?? 0)
            ForEach(Array(checks["runs"].items.enumerated()), id: \.offset) { _, check in
                RowGap()
                let result = check["conclusion"].string ?? check["status"].string ?? "Pending"
                let g = checkGlyph(result)
                let url = check["url"].string
                HStack(spacing: 4) {
                    Image(systemName: g.symbol).font(.system(size: 12)).foregroundStyle(g.color).frame(width: 18)
                    Text(check["name"].string ?? "Check").font(Theme.callout).foregroundStyle(safeWebURL(url) ? Theme.accent : Theme.ink).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(result.replacingOccurrences(of: "_", with: " ").asciiCapitalized).font(Theme.callout).foregroundStyle(Theme.muted).lineLimit(1)
                }
                .frame(height: 22)
                .contentShape(Rectangle())
                .onTapGesture { if safeWebURL(url) { openWebURL(url) } }
            }
            if checks["runs"].count == 0 {
                RowGap()
                Text("No checks reported").font(Theme.callout).foregroundStyle(Theme.muted)
            }
        }
    }
}

private struct CommitsTab: View {
    @ObservedObject var model: PullModel
    var body: some View {
        let commits = model.pr["commitList"].items
        ColumnBox {
            ForEach(Array(commits.enumerated()), id: \.offset) { i, cm in
                if i > 0 { RowGap() }
                let sha = cm["sha"].string ?? ""
                let url = cm["url"].string
                HStack(alignment: .top, spacing: 12) {
                    GlyphLabel(glyph: 0xE8EE, text: cm["message"].string ?? "", color: Theme.ink)
                        .onTapGesture { if safeWebURL(url) { openWebURL(url) } }
                    Spacer(minLength: 0)
                    Text(String(sha.prefix(7))).font(Theme.monoSmall).foregroundStyle(Theme.muted).textSelection(.enabled)
                }
            }
            if commits.isEmpty { Text("No commits reported").font(Theme.callout).foregroundStyle(Theme.muted) }
        }
    }
}

private struct FindingsTab: View {
    @ObservedObject var model: PullModel
    @ObservedObject private var store = Store.shared
    private static let decisionIDs = ["", "fix", "optional", "dismissed"]
    private static let decisionTitles = ["Undecided", "Fix", "Optional", "Dismiss"]

    var body: some View {
        let findings = model.findings.items
        ColumnBox {
            if let e = model.findingsError { Notice(message: e).padding(.bottom, 6) }
            ForEach(Array(findings.enumerated()), id: \.offset) { i, f in
                if i > 0 { RowGap() }
                finding(i, f)
            }
            if findings.isEmpty && model.findingsError == nil { Text("No findings reported").font(Theme.callout).foregroundStyle(Theme.muted) }
            if store.supports("finding_decision") && !findings.isEmpty {
                Text("Decisions are saved on the dashboard and mirrored to the pull request’s checklist on GitHub.")
                    .font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }
            if model.solveFindingsOffered {
                let fixes = findingsToFix(model.findings)
                Button(model.busy ? "Starting…" : fixes > 0 ? "Solve findings · \(fixes) to fix" : "Solve findings") { model.solveFindings() }
                    .dashButton(.prominent).disabled(model.busy || model.uncertain || model.deciding != nil).padding(.top, 12)
                Text(fixes > 0 ? "Starts a paid session that addresses the findings marked Fix, pushes the fixes and has them reviewed again."
                               : "Starts a paid session that addresses the open findings, pushes the fixes and has them reviewed again. Mark what to fix first to narrow it down.")
                    .font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            }
        }
    }

    @ViewBuilder private func finding(_ i: Int, _ f: JSON) -> some View {
        let open = model.openFindings.contains(i)
        let fixed = f["fixed"].is(true)
        let decision = f["decision"].string
        GlyphLabel(glyph: open ? 0xE70D : 0xE76C, text: f["title"].string ?? "Finding")
            .contentShape(Rectangle()).onTapGesture { model.toggleFinding(i) }.handCursor()
        let meta: String = {
            var parts: [String] = []
            if let s = f["severity"].string { parts.append(s) }
            if fixed { parts.append("Fixed") }
            else if let d = decision { parts.append(Self.decisionIDs.firstIndex(of: d).flatMap { $0 > 0 ? Self.decisionTitles[$0] : nil } ?? d) }
            var m = parts.joined(separator: " · ")
            if let key = f["key"].string, model.deciding == key { m += " · saving…" }
            return m
        }()
        if !meta.isEmpty {
            Text(meta).font(Theme.caption).foregroundStyle(fixed ? Theme.ok : decision == "fix" ? Theme.warn : Theme.muted).lineLimit(1)
                .padding(.leading, 22).padding(.top, 2)
        }
        if open {
            VStack(alignment: .leading, spacing: 4) {
                if let file = f["file"].string {
                    Text(f["line"].number.map { "\(file):\(Int($0))" } ?? file).font(Theme.monoSmall).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                if safeWebURL(f["url"].string) {
                    Button("Open finding on GitHub") { openWebURL(f["url"].string) }.buttonStyle(.plain).font(Theme.caption).foregroundStyle(Theme.accent).handCursor()
                }
                if store.supports("finding_decision"), let key = f["key"].string, !fixed {
                    let selected = decision.flatMap { Self.decisionIDs.firstIndex(of: $0) } ?? 0
                    Segments(titles: Self.decisionTitles, selected: selected) { k in model.decide(key, k == 0 ? nil : Self.decisionIDs[k]) }
                        .disabled(model.deciding != nil).padding(.top, 4)
                }
            }
            .padding(.leading, 22).padding(.top, 4)
        }
    }
}

// MARK: Sessions

/// The conversations already run on this pull request, each with a trash button.
private struct RunsList: View {
    @ObservedObject var model: PullModel
    @ObservedObject private var store = Store.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let e = model.runError { Notice(message: e).padding(.bottom, 2) }
            if model.runs.isEmpty {
                Text("No conversations on this pull request").font(Theme.callout).foregroundStyle(Theme.muted)
            }
            let deletable = store.supports("delete")
            ForEach(model.runs, id: \.id) { run in
                SessionRow(session: run, background: Theme.raise, trailing: deletable ? 36 : 0) { model.openRun(run) }
                    .overlay(alignment: .trailing) {
                        if deletable {
                            TrashButton(deleting: model.deletingRun == run.id, enabled: model.deletingRun == nil) { model.deleteRun(run) }
                                .padding(.trailing, 10)
                        }
                    }
            }
        }
    }
}

// MARK: - Sidebar

/// The sidebar: only what the server reports; GitHub's projects and notifications are not part of it.
private struct PullSidebar: View {
    @ObservedObject var model: PullModel
    var body: some View {
        let row = model.boardRow
        var items: [AnyView] = []
        if !model.actions.isEmpty { items.append(AnyView(actions(row))) }
        if !model.pr.isNull { items.append(AnyView(checks)); items.append(AnyView(reviewers(row))) }
        if let row {
            items.append(AnyView(section("Assignees") {
                if row.assignees.isEmpty { Text("No one").font(Theme.caption).foregroundStyle(Theme.muted) }
                ForEach(row.assignees, id: \.self) { Text($0).font(Theme.footnoteSemibold).foregroundStyle(Theme.ink).lineLimit(1) }
            }))
            items.append(AnyView(section("Labels") {
                if row.labels.isEmpty { Text("None yet").font(Theme.caption).foregroundStyle(Theme.muted) }
                else { LabelChips(labels: row.labels, background: Theme.canvas) }
            }))
            if let milestone = row.raw["milestone"].string {
                items.append(AnyView(section("Milestone") { Text(milestone).font(Theme.footnote).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true) }))
            }
        }
        let issues = (row?.issues.isEmpty == false) ? row!.issues : BoardLink.parseList(model.pr["issues"])
        if !issues.isEmpty { items.append(AnyView(development(issues))) }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                if i > 0 { Spacer().frame(height: 14); BoardRule() }
                Spacer().frame(height: 14)
                item
            }
        }
    }

    /// `.discussion-sidebar-item`: a small heading over its contents.
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(Theme.captionSemibold).foregroundStyle(Theme.muted).lineLimit(1).padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 4) { content() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The errands as the sidebar's first item: one full-width button per action, the one the state asks for filled.
    private func actions(_ row: PullSummary?) -> some View {
        section(model.busy ? "Actions · starting…" : "Actions") {
            VStack(spacing: 6) {
                ForEach(model.actions, id: \.id) { a in
                    let kind: ButtonKind = row?.recommended == a.id ? .prominent : a.id == "delete-self-comments" ? .destructive : .bordered
                    Button("\(actionIcon(a.id)) \(a.label)") { model.act(a) }
                        .dashButton(kind, stretch: true).disabled(model.busy || model.uncertain).help(a.hint)
                }
            }
            Text("Uses the provider and model configured for this project. These actions run paid agents and may write to GitHub.")
                .font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
        }
    }

    /// The checks as counts only; the row opens the Checks tab for the individual runs.
    private var checks: some View {
        let checks = model.pr["checks"]
        return section("Checks") {
            if checks["runs"].count == 0 { Text("No checks reported").font(Theme.caption).foregroundStyle(Theme.muted) }
            else {
                CheckCounts(passed: checks["passed"].int32 ?? 0, pending: checks["pending"].int32 ?? 0, failed: checks["failed"].int32 ?? 0)
                    .contentShape(Rectangle())
                    .onTapGesture { if model.tab != .checks { model.select(.checks) } }
                    .handCursor(model.tab != .checks)
            }
        }
    }

    private func reviewer(_ user: String, badge: BadgeSpec?, state: String?) -> some View {
        HStack(spacing: 8) {
            Text(user).font(Theme.footnoteSemibold).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            if let badge { Badge(glyph: badge.glyph, text: badge.text, color: badge.color, background: Theme.canvas) }
            else if let state { Text(state).font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1) }
        }
        .frame(minHeight: 22)
    }
    private func reviewers(_ row: PullSummary?) -> some View {
        let reviews = model.pr["reviews"].items
        let requested = (row?.reviewers ?? []).filter { r in
            r.state == "requested" && !reviews.contains { foldEqual($0["user"].string, r.user) }
        }
        return section("Reviewers") {
            ForEach(Array(reviews.enumerated()), id: \.offset) { _, review in
                let user = review["user"].string ?? "Reviewer"
                let st = ReviewStatus(decision: nil, reviews: .array([review]))
                if st != .none {
                    let g = reviewGlyph(st)
                    reviewer(user, badge: BadgeSpec(glyph: g.symbol, text: st.text, color: g.color), state: nil)
                } else {
                    reviewer(user, badge: nil, state: review["state"].string)
                }
            }
            ForEach(requested, id: \.user) { r in
                reviewer(r.user, badge: BadgeSpec(glyph: Glyph.symbol(0xE823), text: "Review requested", color: Theme.muted), state: nil)
            }
            if reviews.isEmpty && requested.isEmpty { Text("No reviews").font(Theme.caption).foregroundStyle(Theme.muted) }
        }
    }

    private func development(_ issues: [BoardLink]) -> some View {
        section("Development") {
            Text("Successfully merging this pull request may close these issues.").font(Theme.caption).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true).padding(.bottom, 2)
            ForEach(Array(issues.enumerated()), id: \.offset) { _, link in
                LinkedRow(link: link, repo: model.repo, action: safeWebURL(link.url) ? { openWebURL(link.url) } : nil)
            }
        }
    }
}

// MARK: - Run

/// The Run tab: the browser's area, down to the bottom of the pane, under a line saying what a restart is doing, with what
/// is happening written in it until the page is up.
private struct RunArea: View {
    @ObservedObject var model: PullModel

    var body: some View {
        let browser = model.browser
        let page = model.runURL != nil && !model.runBusy && browser != nil && browser?.error == nil
        VStack(alignment: .leading, spacing: 0) {
            if let e = model.runError { Notice(message: e).padding(.horizontal, 4).padding(.bottom, 10) }
            if page, let e = model.serveError {
                Text(e).font(Theme.footnote).foregroundStyle(Theme.danger).lineLimit(1).truncationMode(.tail).padding(.horizontal, 4).padding(.bottom, 10)
            }
            ZStack(alignment: .topLeading) {
                if let browser, page {
                    BrowserView(browser: browser).opacity(browser.ready ? 1 : 0)
                }
                if !(page && browser?.ready == true) { status }
            }
            .frame(maxWidth: .infinity, minHeight: 320, maxHeight: .infinity, alignment: .topLeading)
        }
        .task(id: "\(model.runURL ?? "")|\(model.runBusy)|\(browser == nil)|\(model.tab == .run)") { model.ensureBrowser() }
    }

    private func statusText(_ error: String?) -> String? {
        if let error { return error }
        if model.runBusy && model.runURL != nil { return model.runAsked.map { "Restarting with profile \($0)…" } ?? "Serving it again…" }
        if model.runURL != nil { return "Starting the browser…" }
        if model.runBusy && model.runSession != nil { return "Serving it…" }
        // Once the setup's console has lines it says what is happening; until then, a line saying what is coming.
        if model.log.lines.isEmpty { return "Preparing a workspace for this pull request and serving it with the project’s run commands. This can take a few minutes…" }
        return nil
    }

    @ViewBuilder private var status: some View {
        let browser = model.browser
        let error: String? = model.runBusy ? nil : model.runURL == nil ? model.serveError : browser?.error
        let text = statusText(error)
        VStack(alignment: .leading, spacing: 0) {
            if let text {
                Text(text).font(Theme.body).foregroundStyle(error != nil ? Theme.danger : Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            if model.runURL == nil && model.serveError != nil && !model.runBusy {
                Button("▶ Try again") { model.runStart() }.dashButton(.bordered).padding(.top, 10)
            } else if error != nil && model.runURL != nil {
                Button("Open in your browser instead ↗") { openWebURL(model.pageURL) }.buttonStyle(.plain).font(Theme.body).foregroundStyle(Theme.accent).padding(.top, 8)
            }
            // The setup as it happens, its latest lines filling what is left of the area, as a terminal does.
            if !model.log.lines.isEmpty && (model.runBusy || model.runURL == nil) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.log.lines.enumerated()), id: \.offset) { _, l in
                            Text(l.text).font(Theme.monoSmall).foregroundStyle(l.isError ? Theme.danger : Theme.muted)
                                .lineLimit(1).truncationMode(.tail).frame(height: 17, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.sunken))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line, lineWidth: 1))
                .padding(.top, 12)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
