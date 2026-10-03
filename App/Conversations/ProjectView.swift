// A project's conversations, as the Mac sidebar's second screen (SidebarSessions, SidebarRows): found by their title, the
// closed ones on request, those at work first; each row marked by its pull request where it has one. Above them the
// project's board, its findings waiting and a new conversation; a swipe closes, reopens, renames or deletes one, and
// Select closes or deletes several, as ☑ Select does.
import SwiftUI

struct ProjectView: View {
    let repo: String
    @EnvironmentObject private var store: Store
    @ObservedObject private var feed: ProjectFeed
    @ObservedObject private var projects = ProjectsModel.shared
    @Environment(\.navigate) private var navigate
    @State private var search = ""
    @State private var showClosed = false
    @State private var composing = false
    @State private var error: String?
    @State private var actionError: String?
    @State private var editMode: EditMode = .inactive
    @State private var picked: Set<String> = []
    /// The bulk action waiting for its confirmation: true for Delete, false for Close.
    @State private var bulkAsked: Bool?
    @State private var bulkRunning = false
    /// A row's action waiting for its confirmation.
    @State private var asked: RowAction?
    @State private var renaming: Session?
    @State private var newTitle = ""
    /// Rows with an action under way.
    @State private var working: Set<String> = []

    private struct RowAction: Identifiable {
        var session: Session
        var action: String
        var id: String { "\(session.id):\(action)" }
    }

    init(repo: String) {
        self.repo = repo
        _feed = ObservedObject(wrappedValue: Store.shared.feed(repo))
    }

    private var title: String { projects.project(repo)?.title ?? repo }
    private var editing: Bool { editMode.isEditing }
    private var shown: [Session] { conversationsShown(feed.sessions, search: search, showClosed: showClosed) }
    private var canSelect: Bool { store.canManage && (store.supports("close") || store.supports("delete")) && !feed.sessions.isEmpty }
    private var waiting: Int { feed.sessions.filter { $0.heldRound != nil }.count }

    var body: some View {
        dialogs(chrome(List(selection: editing ? $picked : nil) { sections }))
            .onChange(of: feed.sessions.map(\.id)) { _, ids in picked.formIntersection(ids) }
            .refreshable { _ = await load(fresh: true) }
            .task { await poll(every: ProjectFeed.sessionsEvery) { await load() } }
    }

    @ViewBuilder private var sections: some View {
        if let message = actionError ?? error {
            Section { ErrorNotice(message: message) }.listRowBackground(Theme.row)
        }
        let list = shown
        let active = list.filter(\.isActive)
        if !active.isEmpty {
            Section("Active") { ForEach(active, id: \.id) { row($0) } }.listRowBackground(Theme.row)
        }
        Section {
            ForEach(list.filter { !$0.isActive }, id: \.id) { row($0) }
            if feed.sessionsLoaded && list.isEmpty {
                Text(search.isEmpty ? (feed.sessions.isEmpty ? "No conversations here yet." : "No open conversations.") : "No matching conversations.")
                    .foregroundStyle(.secondary)
            }
            if !feed.sessionsLoaded && error == nil { ProgressView().frame(maxWidth: .infinity) }
        } header: {
            HStack {
                Text(active.isEmpty ? "Conversations" : "Recent")
                Spacer()
                Toggle("Show closed", isOn: $showClosed).toggleStyle(.button).buttonStyle(.borderless).controlSize(.mini)
                    .font(.caption.weight(.medium)).textCase(nil)
            }
        }
        .listRowBackground(Theme.row)
    }

    /// The list's styling, search and toolbar, apart from `dialogs` so each part type-checks quickly.
    private func chrome(_ list: some View) -> some View {
        list
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden).background(Theme.background)
            .environment(\.editMode, $editMode)
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Find a conversation")
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom, spacing: 0) { if editing { bulkBar } }
    }

    /// The new conversation sheet, the confirmations and the rename alert.
    private func dialogs(_ view: some View) -> some View {
        view
            .sheet(isPresented: $composing) {
                NewConversationSheet(repo: repo) { started in navigate(.conversation(id: started.id, session: started.raw)) }
            }
            .alert(asked.flatMap { conversationActionQuestion($0.action) } ?? "",
                   isPresented: Binding(get: { asked != nil }, set: { if !$0 { asked = nil } }), presenting: asked) { a in
                Button(a.action == "delete" ? "Delete" : a.action == "close" ? "Close" : "Confirm", role: a.action == "delete" ? .destructive : nil) {
                    perform(a.action, on: a.session)
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert(bulkAsked.map { question($0).title } ?? "",
                   isPresented: Binding(get: { bulkAsked != nil }, set: { if !$0 { bulkAsked = nil } }), presenting: bulkAsked) { delete in
                Button(delete ? "Delete" : "Close", role: delete ? .destructive : nil) { runBulk(delete: delete) }
                Button("Cancel", role: .cancel) {}
            } message: { delete in Text(question(delete).message) }
            .alert("Rename conversation", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Title", text: $newTitle)
                Button("Save") {
                    if let s = renaming, !newTitle.cTrimmed.isEmpty { perform("rename", on: s, extra: ["title": .string(newTitle)]) }
                }
                Button("Cancel", role: .cancel) {}
            }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if editing {
                Button("Done") { leaveSelect() }.bold()
            } else {
                if store.supports("pulls") {
                    Button { navigate(.board(repo: repo)) } label: { Image(systemName: "arrow.triangle.pull") }
                        .accessibilityLabel("Pull requests and issues")
                }
                if waiting > 0 {
                    Button { navigate(.findings(repo: repo)) } label: { FindingsCountIcon(count: waiting) }
                        .accessibilityLabel("Findings, \(waiting) waiting")
                }
                if store.supports("start_session") {
                    Button { composing = true } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("New conversation")
                }
                if canSelect {
                    Button { withAnimation { editMode = .active } } label: { Image(systemName: "checkmark.circle") }
                        .accessibilityLabel("Select conversations")
                }
            }
        }
    }

    /// While selecting: Select All, and Close and Delete for the picked conversations.
    private var bulkBar: some View {
        let closable = bulkConversationTargets(feed.sessions, picked: picked, delete: false).count
        let all = Set(shown.map(\.id))
        return HStack(spacing: 16) {
            Button(picked.isSuperset(of: all) && !all.isEmpty ? "Deselect All" : "Select All") {
                if picked.isSuperset(of: all) { picked.subtract(all) } else { picked.formUnion(all) }
            }
            .disabled(bulkRunning || all.isEmpty)
            Spacer(minLength: 0)
            if bulkRunning { ProgressView() }
            if store.supports("close") {
                Button("Close\(closable > 0 ? " (\(closable))" : "")") { bulkAsked = false }.disabled(bulkRunning || closable == 0)
            }
            if store.supports("delete") {
                Button("Delete\(picked.isEmpty ? "" : " (\(picked.count))")", role: .destructive) { bulkAsked = true }
                    .disabled(bulkRunning || picked.isEmpty)
            }
        }
        .font(.body.weight(.medium))
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 0.5) }
    }

    // MARK: Rows

    @ViewBuilder private func row(_ s: Session) -> some View {
        if editing {
            ConversationRowLabel(session: s).tag(s.id)
        } else {
            DestinationLink(destination: .conversation(id: s.id, session: s.raw)) {
                ConversationRowLabel(session: s, working: working.contains(s.id))
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if store.supports("delete") {
                    Button("Delete", systemImage: "trash", role: .destructive) { asked = RowAction(session: s, action: "delete") }
                }
                if s.status == "closed" {
                    if store.supports("reopen") {
                        Button("Reopen", systemImage: "arrow.uturn.backward") { asked = RowAction(session: s, action: "reopen") }.tint(Theme.success)
                    }
                } else if store.supports("close") {
                    Button("Close", systemImage: "archivebox") { asked = RowAction(session: s, action: "close") }.tint(Theme.warning)
                }
            }
            .swipeActions(edge: .leading) {
                if store.supports("rename") {
                    Button("Rename", systemImage: "pencil") { startRename(s) }.tint(Theme.accent)
                }
            }
            .contextMenu { menu(s) }
        }
    }

    @ViewBuilder private func menu(_ s: Session) -> some View {
        if store.supports("rename") { Button("Rename", systemImage: "pencil") { startRename(s) } }
        if s.status == "closed" {
            if store.supports("reopen") { Button("Reopen", systemImage: "arrow.uturn.backward") { asked = RowAction(session: s, action: "reopen") } }
        } else if store.supports("close") {
            Button("Close", systemImage: "archivebox") { asked = RowAction(session: s, action: "close") }
        }
        Button("Copy Session ID", systemImage: "doc.on.doc") { Pasteboard.copy(s.id) }
        if store.supports("delete") {
            Button("Delete", systemImage: "trash", role: .destructive) { asked = RowAction(session: s, action: "delete") }
        }
    }

    private func startRename(_ s: Session) {
        newTitle = s.displayTitle
        renaming = s
    }

    private func question(_ delete: Bool) -> (title: String, message: String) {
        bulkConversationQuestion(count: bulkConversationTargets(feed.sessions, picked: picked, delete: delete).count, delete: delete)
    }

    // MARK: Reading and writing

    private func load(fresh: Bool = false) async -> APIError? {
        let failed = await reading { try await feed.loadSessions(fresh: fresh) }
        if let failed { if let said = failure(failed) { error = said } } else { error = nil }
        return failed
    }

    private func perform(_ action: String, on s: Session, extra: JSON = [:]) {
        guard !working.contains(s.id) else { return }
        working.insert(s.id); actionError = nil
        var args: JSON = ["sessionId": .string(s.id)]
        args.merge(extra)
        Task {
            do {
                try await store.call(action, args)
                if action == "delete" { feed.drop(s.id) }
            } catch {
                if let said = failure(error) { actionError = said }
            }
            working.remove(s.id)
            _ = await load(fresh: true)
        }
    }

    private func runBulk(delete: Bool) {
        let ids = bulkConversationTargets(feed.sessions, picked: picked, delete: delete)
        guard !ids.isEmpty, !bulkRunning else { return }
        bulkRunning = true; actionError = nil
        Task {
            // One at a time, as the Mac's ☑ Select works through them; a refusal leaves the rest to go on.
            for id in ids {
                do {
                    try await store.call(delete ? "delete" : "close", ["sessionId": .string(id)])
                    if delete { feed.drop(id) }
                } catch {
                    if let said = failure(error) { actionError = said }
                }
            }
            bulkRunning = false
            leaveSelect()
            _ = await load(fresh: true)
        }
    }

    private func leaveSelect() {
        withAnimation { editMode = .inactive }
        picked = []
    }
}

/// The ⚑ with how many review rounds wait, the count inside the button's bounds: a navigation bar cuts off what hangs
/// outside them.
private struct FindingsCountIcon: View {
    let count: Int
    var body: some View {
        Image(systemName: "flag")
            .padding(.horizontal, 8).padding(.vertical, 6)
            .overlay(alignment: .topTrailing) {
                Text(String(count)).font(.caption2.weight(.bold).monospacedDigit()).foregroundStyle(.white)
                    .padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15).background(Theme.warning, in: Capsule())
            }
    }
}

/// A conversation in a list: its mark, its title, and a line of provider, branch, state and age; a ⚑ while a review
/// round waits on it.
struct ConversationRowLabel: View {
    let session: Session
    var working = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            ConversationMark(session: session).frame(width: 16)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.displayTitle).font(.body.weight(.medium)).lineLimit(2)
                    .foregroundStyle(session.status == "closed" ? .secondary : .primary)
                Text(session.conversationRowDetail()).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if working { ProgressView().controlSize(.small) }
            if session.heldRound != nil {
                Image(systemName: "flag.fill").font(.caption).foregroundStyle(Theme.warning).accessibilityLabel("Findings waiting")
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityValue(session.pullBadge ?? "")
    }
}

/// A pull request takes the status dot's place, coloured by its state and checks, as Claude's list shows it; a
/// conversation at work keeps its pulsing dot.
struct ConversationMark: View {
    let session: Session
    var body: some View {
        if let tone = session.pullTone, !session.isActive {
            Image(systemName: "arrow.triangle.pull").font(.caption.weight(.semibold)).foregroundStyle(Self.color(tone))
                .accessibilityHidden(true)
        } else {
            StatusDot(status: session.conversationState == "waiting" ? "queued" : session.status)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        }
    }
    /// Purple once merged, grey when closed unmerged or a draft; while open, the checks' colour.
    static func color(_ tone: String) -> Color {
        switch tone {
        case "merged": return .purple
        case "closed", "draft": return .secondary
        case "failing": return Theme.danger
        case "pending": return Theme.warning
        default: return Theme.success
        }
    }
}
