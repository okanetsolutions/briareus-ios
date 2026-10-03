// One conversation, as the Mac's ConversationScreen (screen_conversation.c): the transcript, read a little at a time
// after the saved part, opening on its end; the composer under it; the session's actions in the toolbar's menu. The
// Mac's session panel opens as a sheet from the title or the strip over the transcript, and a review round held for a
// decision shows as a banner over the composer that opens its card.
import SwiftUI

struct ConversationScreen: View {
    let sessionID: String
    let initial: JSON?
    @StateObject private var model: ConversationScreenModel
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.navigate) private var navigate
    @FocusState private var composerFocused: Bool
    /// An action waiting for its confirmation.
    @State private var asked: String?
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var showingDetails = false
    @State private var showingTriage = false
    @State private var atBottom = true

    init(sessionID: String, initial: JSON?) {
        self.sessionID = sessionID
        self.initial = initial
        _model = StateObject(wrappedValue: ConversationScreenModel(id: sessionID, initial: initial))
    }

    private var session: Session { model.session }

    var body: some View {
        Group {
            if model.deleted {
                ContentUnavailableView("Conversation deleted", systemImage: "trash",
                                       description: Text("The conversation and its transcript are gone."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.background)
            } else {
                content
            }
        }
        .navigationTitle(session.displayTitle).navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) { heading }
            ToolbarItem(placement: .topBarTrailing) { actions }
        }
        .task { await model.run() }
        .onDisappear { model.hidden() }
        .onChange(of: model.deleted) { _, deleted in if deleted { dismiss() } }
        .onChange(of: store.active) { _, active in
            // Recording cannot go on in the background: what was said until then is transcribed, as if stopped.
            if !active && model.voice.state == .recording { model.voice.stop() }
        }
        .onChange(of: asked != nil || renaming) { _, open in model.paused = open }
        .confirmationDialog(asked.flatMap(conversationActionQuestion) ?? "",
                            isPresented: Binding(get: { asked != nil }, set: { if !$0 { asked = nil } }),
                            titleVisibility: .visible, presenting: asked) { action in
            Button(confirmLabel(action), role: action == "delete" || action == "cancel" ? .destructive : nil) {
                model.mutate(action)
            }
        }
        .alert("Rename conversation", isPresented: $renaming) {
            TextField("Title", text: $newTitle)
            Button("Save") { if !newTitle.cTrimmed.isEmpty { model.mutate("rename", ["title": .string(newTitle)]) } }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingDetails) {
            SessionDetailsSheet(model: model) { navigate($0) }
        }
        .sheet(isPresented: $showingTriage) { triageSheet }
    }

    // MARK: Transcript

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ConversationTranscript(blocks: model.blocks, session: session, expanded: model.expanded, loaded: model.loaded,
                                           error: model.error, writeError: model.writeError, uncertain: model.uncertain,
                                           blocked: !model.can, canMessage: model.canMessage,
                                           answer: { model.draft.text = $0; composerFocused = true },
                                           toggle: { model.toggle($0) },
                                           dropQueued: { model.mutate("drop_message", ["index": JSON($0)]) },
                                           refreshOutcome: { model.refreshOutcome() })
                        .equatable()
                    Color.clear.frame(height: 1).id("bottom")
                        .onAppear { atBottom = true }.onDisappear { atBottom = false }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(maxWidth: 820).frame(maxWidth: .infinity)
            }
            .conversationStartsAtBottom()
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.background)
            // Pulling down reads the whole transcript again, in case the saved one drifted from the server's.
            .refreshable { await model.refresh(full: true) }
            .onChange(of: model.transcript.events.count) { old, _ in
                if old == 0 {
                    // The first page can be thousands of events, and row heights are estimated until laid out, so one
                    // jump can land short of the end.
                    Task { @MainActor in
                        for _ in 0..<6 {
                            proxy.scrollTo("bottom", anchor: .bottom)
                            try? await Task.sleep(for: .milliseconds(120))
                            if atBottom { break }
                        }
                    }
                } else if atBottom { scrollToBottom(proxy) }
            }
            .onChange(of: session.isActive) { _, _ in if atBottom { scrollToBottom(proxy) } }
            .onChange(of: session.queued.count) { _, _ in if atBottom { scrollToBottom(proxy) } }
            .onChange(of: model.scrollToEnd) { _, _ in scrollToBottom(proxy) }
            .overlay(alignment: .bottom) {
                if !atBottom && !model.blocks.isEmpty {
                    Button { scrollToBottom(proxy) } label: {
                        Image(systemName: "arrow.down").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            .frame(width: 36, height: 36)
                            .background(Theme.elevated, in: Circle())
                            .overlay(Circle().stroke(Theme.border, lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    }
                    .accessibilityLabel("Latest message")
                    .padding(.bottom, 10).transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.snappy, value: atBottom)
            .safeAreaInset(edge: .top, spacing: 0) { strip }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    triageBanner
                    ConversationComposer(model: model, draft: model.draft, files: model.files, focused: $composerFocused,
                                         stop: { asked = "cancel" }, reopen: { asked = "reopen" })
                }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    // MARK: Header

    /// The title with the state and runtime under it; a tap opens the details.
    private var heading: some View {
        Button { showingDetails = true } label: {
            VStack(spacing: 1) {
                Text(session.displayTitle).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                HStack(spacing: 5) {
                    StatusDot(status: session.status)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: 260)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows the session's details")
    }
    private var subtitle: String {
        var parts = [session.conversationState.capitalized]
        if let model = session.model { parts.append(model) }
        if session.reviewLoopOn { parts.append("Review loop") }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// The panel's gist over the transcript: the pull request, the context in use and the cost; a tap opens the details.
    @ViewBuilder private var strip: some View {
        if let text = conversationStripText(session) {
            Button { showingDetails = true } label: {
                HStack(spacing: 8) {
                    if session.pullTone != nil { ConversationMark(session: session) }
                    else { Image(systemName: "gauge.with.dots.needle.33percent").font(.caption).foregroundStyle(.secondary) }
                    Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16).padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Theme.background)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 0.5) }
            .accessibilityLabel("Details: \(text)")
        }
    }

    // MARK: Review round

    @ViewBuilder private var triageBanner: some View {
        if let triage = session.heldTriage, store.supports("complete_findings") {
            let count = triage["findings"].count
            Button { showingTriage = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "flag.fill").foregroundStyle(Theme.warning)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(triageTitle(triage)).font(.subheadline.weight(.medium)).lineLimit(1)
                        Text("\(count) finding\(count == 1 ? "" : "s") waiting for a verdict").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Text("Review").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                }
                .padding(12)
                .background(Theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.top, 6)
            .background(Theme.background)
        }
    }

    private var triageSheet: some View {
        NavigationStack {
            ScrollView {
                TriageCard(session: session) {
                    showingTriage = false
                    model.triageDone()
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle(session.heldTriage.map(triageTitle) ?? "Review findings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingTriage = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Actions

    private var actions: some View {
        let s = session
        let can = model.can
        let closed = s.status == "closed"
        return Menu {
            Section {
                Button("Details", systemImage: "info.circle") { showingDetails = true }
                if let number = s.pullNumber, let repo = s.repo {
                    if store.supports("pull") {
                        Button("Pull Request #\(String(number))", systemImage: "arrow.triangle.pull") {
                            navigate(.pull(repo: repo, number: number, stack: nil, summary: nil))
                        }
                    }
                    if store.supports("pull_files") {
                        Button("View Changes", systemImage: "doc.text.magnifyingglass") { navigate(.pullFiles(repo: repo, number: number)) }
                    }
                }
            }
            Section {
                if store.supports("rename") {
                    Button("Rename", systemImage: "pencil") { newTitle = s.displayTitle; renaming = true }.disabled(!can)
                }
                if store.supports("review_loop") && s.canReviewLoop {
                    Button(s.reviewLoopOn ? "Turn Off Review Loop" : "Turn On Review Loop", systemImage: "repeat") {
                        model.mutate("review_loop", ["on": .bool(!s.reviewLoopOn)])
                    }.disabled(!can)
                }
                if sessionOffersCompact(s.raw) && store.supports("compact") && store.canManage {
                    let compacting = s.raw["compacting"].is(true)
                    Button(compacting ? "Compacting\u{2026}" : "Compact", systemImage: "arrow.down.right.and.arrow.up.left") { asked = "compact" }
                        .disabled(!can || compacting)
                }
                if sessionOffersClear(s.raw) && store.supports("clear") && store.canManage {
                    Button("Clear Transcript", systemImage: "eraser") { asked = "clear" }.disabled(!can)
                }
            }
            Section {
                if let url = s.raw["prStatus"]["url"].nonEmpty {
                    Button("Copy Pull Request Link", systemImage: "link") { Pasteboard.copy(url) }
                }
            }
            Section {
                if store.supports("cancel") && s.isActive {
                    Button("Stop Agent", systemImage: "stop.circle", role: .destructive) { asked = "cancel" }.disabled(!can)
                }
                if closed {
                    if store.supports("reopen") { Button("Reopen", systemImage: "arrow.uturn.backward") { asked = "reopen" }.disabled(!can) }
                } else if store.supports("close") {
                    Button("Close Conversation", systemImage: "archivebox") { asked = "close" }.disabled(!can)
                }
                if store.supports("delete") {
                    Button("Delete Conversation", systemImage: "trash", role: .destructive) { asked = "delete" }.disabled(!can)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Conversation actions")
    }

    private func confirmLabel(_ action: String) -> String {
        switch action {
        case "delete": return "Delete"
        case "cancel": return "Stop"
        case "close": return "Close"
        case "reopen": return "Reopen"
        case "compact": return "Compact"
        case "clear": return "Clear"
        default: return "Confirm"
        }
    }
}

private extension View {
    /// Opens on the latest message; short transcripts still read from the top where the system allows it.
    @ViewBuilder func conversationStartsAtBottom() -> some View {
        if #available(iOS 18.0, *) {
            defaultScrollAnchor(.bottom, for: .initialOffset).defaultScrollAnchor(.bottom, for: .sizeChanges)
                .defaultScrollAnchor(.top, for: .alignment)
        } else { defaultScrollAnchor(.bottom) }
    }
}
