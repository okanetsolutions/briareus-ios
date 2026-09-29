import SwiftUI

struct ConversationView: View {
    let initial: Session
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.splitPane) private var pane
    @State private var snapshot: Session?
    @State private var transcript = Transcript()
    @State private var loaded = false
    @State private var restored = false
    /// Set when a write to the saved transcript failed, so the next one rewrites it whole and leaves no gap.
    @State private var unsaved = false
    @State private var retimed = false
    @State private var message = ""
    @State private var busy = false
    @State private var loading = false
    @State private var error: String?
    @State private var writeError: String?
    @State private var uncertain = false
    @State private var pendingAction: String?
    @State private var renaming = false
    @State private var title = ""
    @State private var atBottom = true
    @State private var pull: PullRoute?
    @FocusState private var composerFocused: Bool
    var session: Session { snapshot ?? initial }
    private var cacheKey: String { "transcript:\(initial.id)" }
    private var canMessage: Bool { store.supports("message") && session.status != "closed" }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let error { ErrorNotice(message: error).padding(12).background(Theme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 12)) }
                    if let writeError { uncertainNotice(writeError) }
                    if transcript.events.isEmpty && error == nil {
                        VStack(spacing: 12) {
                            if loaded { Image(systemName: "text.bubble").font(.title).foregroundStyle(.tertiary) } else { ProgressView() }
                            Text(loaded ? "No messages yet" : "Waiting for the conversation…").font(.callout).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.top, 80)
                    }
                    ForEach(TranscriptRow.group(transcript.events.filter(\.visible))) { row in
                        switch row {
                        case .event(let event):
                            EventView(event: event, canAnswer: canMessage) { message = $0; composerFocused = true }
                        case .tools(let events):
                            VStack(alignment: .leading, spacing: 2) { ForEach(events) { ToolRow(event: $0) } }
                        }
                    }
                    ForEach(Array((session.queued ?? []).enumerated()), id: \.offset) { index, queued in
                        QueuedBubble(text: queued["text"].string ?? "Message", removable: store.supports("drop_message") && !busy && !uncertain) {
                            Task { await mutate("drop_message", extra: ["index": .number(Double(index))]) }
                        }
                    }
                    if let triage = session.heldTriage, store.supports("complete_findings") {
                        FindingsTriageCard(triage: triage, disabled: busy || uncertain) { verdicts, note in
                            var extra: [String: JSONValue] = [:]
                            if !verdicts.isEmpty { extra["verdicts"] = .array(verdicts) }
                            if !note.isEmpty { extra["note"] = .string(note) }
                            Task { await mutate("complete_findings", extra: extra) }
                        }
                    }
                    if session.isActive { WorkingIndicator(status: session.status) }
                    Color.clear.frame(height: 1).id("bottom")
                        .onAppear { atBottom = true }.onDisappear { atBottom = false }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .startAtBottom()
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.background)
            // Pulling down reads the whole transcript again, in case the saved one drifted from the server's.
            .refreshable { do { try await refresh(full: true) } catch { if let said = failure(error) { self.error = said } } }
            .onChange(of: transcript.events.count) { old, _ in
                // The first page can be thousands of events; jump without animating so the lazy stack lays out once.
                if old == 0 {
                    Task { @MainActor in
                        // Row heights are estimated until laid out, so one jump can land short of the end.
                        for _ in 0..<6 {
                            proxy.scrollTo("bottom", anchor: .bottom)
                            try? await Task.sleep(for: .milliseconds(120))
                            if atBottom { break }
                        }
                    }
                }
                else if atBottom { scrollToBottom(proxy) }
            }
            .onChange(of: session.isActive) { if atBottom { scrollToBottom(proxy) } }
            .overlay(alignment: .bottom) {
                if !atBottom && !transcript.events.isEmpty {
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
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        }
        .navigationTitle(session.displayTitle).navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        // A Mac's toolbar cuts a title short and names the project instead, so the conversation is named above its transcript.
        #if os(macOS)
        .safeAreaInset(edge: .top, spacing: 0) { heading }
        #endif
        .toolbar {
            #if !os(macOS)
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(session.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                    HStack(spacing: 5) {
                        StatusDot(status: session.status)
                        Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            #endif
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let number = session.pullNumber, let repo = session.repo {
                        if store.supports("pull_files") {
                            Button("View changes", systemImage: "doc.text.magnifyingglass") { pull = PullRoute(repo: repo, number: number, changes: true) }
                        }
                        if store.supports("pull") {
                            Button("Pull request #\(String(number))", systemImage: "arrow.triangle.pull") { pull = PullRoute(repo: repo, number: number, changes: false) }
                        }
                    }
                    if store.supports("review_loop") && session.canReviewLoop {
                        if session.reviewLoopOn { Button("Turn off review loop", systemImage: "repeat") { Task { await mutate("review_loop", extra: ["on": .bool(false)]) } } }
                        else { Button("Turn on review loop", systemImage: "repeat") { pendingAction = "review_loop" } }
                    }
                    if store.supports("rename") { Button("Rename", systemImage: "pencil") { title = session.displayTitle; renaming = true } }
                    if store.supports("cancel") && session.isActive { Button("Stop agent", systemImage: "stop.circle", role: .destructive) { pendingAction = "cancel" } }
                    if store.supports("close") && session.status != "closed" { Button("Close conversation", systemImage: "archivebox") { pendingAction = "close" } }
                    if store.supports("reopen") && session.status == "closed" { Button("Reopen", systemImage: "arrow.uturn.backward") { pendingAction = "reopen" } }
                    if store.supports("delete") { Button("Delete conversation", systemImage: "trash", role: .destructive) { pendingAction = "delete" } }
                } label: { Image(systemName: "ellipsis") }
                    .buttonStyle(.automatic)
                    .disabled(busy || uncertain).accessibilityLabel("Conversation actions")
            }
        }
        .navigationDestination(item: $pull) { route in
            if route.changes { PullFilesView(project: Project(repo: route.repo), number: route.number) }
            else { PullDetailView(project: Project(repo: route.repo), number: route.number) }
        }
        .foregroundPoll(every: session.isActive ? 2 : 7, enabled: !busy && !renaming && pendingAction == nil, action: { try await refresh() }) { error = $0.localizedDescription; loaded = true }
        .confirmationDialog(actionTitle, isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
                            titleVisibility: .visible, presenting: pendingAction) { action in
            Button("Confirm", role: action == "delete" || action == "cancel" ? .destructive : nil) {
                Task { await mutate(action, extra: action == "review_loop" ? ["on": .bool(true)] : [:]) }
            }
        }
        .alert("Rename conversation", isPresented: $renaming) {
            TextField("Title", text: $title)
            Button("Save") { Task { await mutate("rename", extra: ["title": .string(title)]) } }
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
    }
    private var heading: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(session.displayTitle).font(.headline).lineLimit(2).textSelection(.enabled)
            HStack(spacing: 6) {
                StatusDot(status: session.status)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 10)
        .background(Theme.background)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 0.5) }
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
    }
    private var subtitle: String {
        var parts = [session.status.capitalized]
        if let model = session.model, !model.isEmpty { parts.append(model) }
        if session.reviewLoopOn { parts.append("Review loop") }
        return parts.joined(separator: " · ")
    }
    private var actionTitle: String {
        switch pendingAction {
        case "delete": return "Permanently delete this conversation and its transcript?"
        case "cancel": return "Stop the running agent?"
        case "close": return "Close this conversation?"
        case "review_loop": return "Turn on the review loop? Each push gets a paid review round, and may start one now."
        default: return "Reopen this conversation?"
        }
    }
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }
    private func uncertainNotice(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ErrorNotice(message: message)
            Text("The action may have completed. Check the latest conversation before trying again.").font(.caption).foregroundStyle(.secondary)
            Button("Refresh and check outcome") {
                Task {
                    do { try await refresh(); uncertain = false; self.writeError = nil }
                    catch { self.error = error.localizedDescription }
                }
            }.buttonStyle(.bordered).controlSize(.small).disabled(loading || busy)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
    private var trimmedMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }
    @ViewBuilder private var composer: some View {
        VStack(spacing: 0) {
            if canMessage {
                VStack(alignment: .leading, spacing: 10) {
                    TextField(session.isActive ? "Send a follow-up…" : "Reply to your agent…", text: $message, axis: .vertical)
                        .lineLimit(1...8).focused($composerFocused).accessibilityIdentifier("messageInput")
                    HStack(spacing: 10) {
                        if let hint = composerHint {
                            Label(hint.text, systemImage: hint.icon).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if store.canTranscribe { VoiceNoteButton(text: $message) }
                        if session.isActive && store.supports("cancel") && trimmedMessage.isEmpty {
                            Button { pendingAction = "cancel" } label: {
                                Image(systemName: "stop.fill").font(.footnote).foregroundStyle(.primary)
                                    .frame(width: 32, height: 32).background(Theme.bubble, in: Circle())
                            }.disabled(busy || uncertain).accessibilityLabel("Stop agent")
                        } else {
                            let enabled = !busy && !uncertain && !trimmedMessage.isEmpty
                            Button {
                                Task { await mutate("message", extra: ["text": .string(message)]) }
                            } label: {
                                Group {
                                    if busy { ProgressView().tint(.white) } else { Image(systemName: "arrow.up").font(.subheadline.weight(.bold)) }
                                }
                                .foregroundStyle(.white).frame(width: 32, height: 32)
                                .background(enabled || busy ? Theme.accent : Color.secondary.opacity(0.35), in: Circle())
                            }.disabled(!enabled).accessibilityLabel("Send message")
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
                .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.border, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.06), radius: 10, y: 2)
                .onTapGesture { composerFocused = true }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: store.canManage ? "archivebox" : "eye").foregroundStyle(.secondary)
                    Text(store.canManage ? "This conversation is closed" : "Read-only access").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    if store.supports("reopen") && session.status == "closed" {
                        Button("Reopen") { pendingAction = "reopen" }.buttonStyle(.borderedProminent).controlSize(.small).disabled(busy || uncertain)
                    }
                }
                .padding(14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
        .background(Theme.background)
    }
    /// Where a message sent during a turn goes; one sent to an idle agent needs no word.
    private var composerHint: (text: String, icon: String)? {
        guard session.isActive else { return nil }
        return session.liveInput == true ? ("Sent into the running turn", "bolt.fill") : ("Queued for the next turn", "clock")
    }
    private func refresh(full: Bool = false) async throws {
        // A poll already reading must not swallow a pull to refresh, which waits its turn.
        while full && loading { try await Task.sleep(for: .milliseconds(100)) }
        guard !loading else { return }
        loading = true; defer { loading = false }
        if !restored {
            // Saved events show at once and move the cursor, so only what happened since is downloaded.
            let saved: [Event] = await store.cache.lines(cacheKey)
            if !restored { restored = true; transcript.append(saved) }
        }
        // A transcript saved before messages showed their time has none; it is read again once to get them.
        var full = full
        if !retimed && !transcript.events.isEmpty && transcript.events.allSatisfy({ $0.t == nil }) { full = true }
        retimed = true
        let since = full ? 0 : transcript.cursor
        let result: SessionResult = try await store.call("session", ["sessionId": .string(initial.id), "since": .number(Double(since))])
        try Task.checkCancellation()
        let events = result.events ?? []
        if full { transcript = Transcript() }
        snapshot = result.session; transcript.append(events); error = nil; loaded = true
        if full || unsaved { unsaved = !(await store.cache.replace(transcript.events, in: cacheKey)) }
        else if !events.isEmpty { unsaved = !(await store.cache.append(events, to: cacheKey)) }
    }
    private func mutate(_ name: String, extra: [String: JSONValue] = [:]) async {
        guard !busy && !uncertain else { return }
        busy = true; writeError = nil
        defer { busy = false }
        do {
            let _: JSONValue = try await store.call(name, ["sessionId": .string(initial.id)].merging(extra) { _, new in new })
            if name == "message", message == extra["text"]?.string { message = ""; atBottom = true }
            if name == "delete" {
                await store.cache.remove(cacheKey)
                // Beside the list there is nothing to go back to: the right-hand side empties instead.
                if pane?.wrappedValue?.id == Pane.conversation(initial).id { pane?.wrappedValue = nil } else { dismiss() }
                return
            }
        } catch {
            writeError = error.localizedDescription; uncertain = true; return
        }
        do { try await refresh() } catch { self.error = error.localizedDescription }
    }
}

/// Consecutive tool activity collapses into one tight cluster, like a terminal log.
enum TranscriptRow: Identifiable {
    case event(Event), tools([Event])
    static let toolKinds: Set<String> = ["tool", "tool_error", "cmd", "git"]
    var id: Int {
        switch self {
        case .event(let event): return event.seq
        case .tools(let events): return events.first?.seq ?? 0
        }
    }
    static func group(_ events: [Event]) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        for event in events {
            if toolKinds.contains(event.kind) {
                if case .tools(let existing)? = rows.last { rows[rows.count - 1] = .tools(existing + [event]) }
                else { rows.append(.tools([event])) }
            } else { rows.append(.event(event)) }
        }
        return rows
    }
}

struct EventView: View {
    let event: Event
    let canAnswer: Bool
    let answer: (String) -> Void
    var body: some View {
        switch event.kind {
        case "user":
            HStack {
                Spacer(minLength: 48)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(event.text ?? "").textSelection(.enabled)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Theme.bubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    ForEach(Array((event.attachments ?? []).enumerated()), id: \.offset) { _, attachment in
                        Label(attachment["name"].string ?? "Attachment", systemImage: "paperclip")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Theme.surface, in: Capsule())
                    }
                    EventTime(date: event.time)
                }
            }
            .accessibilityElement(children: .combine).accessibilityLabel("You: \(event.text ?? "")")
        case "text":
            VStack(alignment: .leading, spacing: 6) {
                MarkdownText(event.text ?? "")
                EventTime(date: event.time)
            }
        case "ask":
            AskCard(event: event, canAnswer: canAnswer, answer: answer)
        case "result":
            TurnFooter(event: event)
        default:
            if let text = event.text {
                if event.kind == "stderr" || event.kind == "claude" {
                    Text(text).font(.caption.monospaced())
                        .foregroundStyle(event.kind == "stderr" ? Theme.danger : Color.secondary)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    // Dashboard notices (review loops, interruptions).
                    Label { Text(.init(text)).textSelection(.enabled) } icon: { Image(systemName: "info.circle") }
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

struct ToolRow: View {
    let event: Event
    @State private var expanded = false
    private var isError: Bool { event.kind == "tool_error" }
    private var details: String? { event.detail.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } }
    private var summary: String {
        details?.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }
    private var title: String {
        if let name = event.name, !name.isEmpty { return name }
        switch event.kind {
        case "cmd": return "Command"
        case "git": return "Git"
        case "tool_error": return "Tool error"
        default: return "Tool"
        }
    }
    private var icon: String {
        if isError { return "exclamationmark.triangle.fill" }
        switch event.kind {
        case "cmd": return "terminal"
        case "git": return "arrow.triangle.branch"
        default: break
        }
        switch (event.name ?? "").lowercased() {
        case let n where n.contains("bash") || n.contains("shell") || n.contains("exec"): return "terminal"
        case let n where n.contains("read") || n.contains("view"): return "doc.text"
        case let n where n.contains("edit") || n.contains("write") || n.contains("patch"): return "pencil"
        case let n where n.contains("grep") || n.contains("glob") || n.contains("search") || n.contains("find"): return "magnifyingglass"
        case let n where n.contains("web") || n.contains("fetch"): return "globe"
        case let n where n.contains("todo") || n.contains("plan"): return "checklist"
        case let n where n.contains("task") || n.contains("agent"): return "person.2"
        default: return "wrench.and.screwdriver"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if details != nil { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon).font(.caption2.weight(.semibold))
                        .foregroundStyle(isError ? Theme.danger : .secondary)
                        .frame(width: 22, height: 22)
                        .background((isError ? Theme.danger : Color.secondary).opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(isError ? Theme.danger : .primary)
                    Text(summary).font(.footnote.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    if details != nil {
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                }
                .padding(.vertical, 5).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title): \(summary)").accessibilityHint(details == nil ? "" : expanded ? "Collapse details" : "Show details")
            if expanded, let details {
                ScrollView {
                    Text(details).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                .frame(maxHeight: 280).fixedSize(horizontal: false, vertical: true)
                .background(Theme.code, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.border, lineWidth: 0.5))
                .padding(.leading, 30)
            }
        }
    }
}

struct AskCard: View {
    let event: Event
    let canAnswer: Bool
    let answer: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Your input is needed", systemImage: "questionmark.bubble.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
            MarkdownText(event.question ?? event.text ?? "")
            if canAnswer {
                let options = (event.options ?? []).compactMap { $0["label"].string }
                if !options.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(options, id: \.self) { label in
                            Button { answer(label) } label: {
                                HStack {
                                    Text(label).multilineTextAlignment(.leading)
                                    Spacer(minLength: 8)
                                    Image(systemName: "arrow.turn.down.left").font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border, lineWidth: 0.5))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                Text("Choose an answer to put it in the composer, or write your own.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.accent.opacity(0.4), lineWidth: 1))
    }
}

/// When a message was logged: the time alone for today's, with its day for an older one.
struct EventTime: View {
    let date: Date?
    static func text(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
    var body: some View {
        if let date { Text(Self.text(date)).font(.caption2).foregroundStyle(.tertiary) }
    }
}

struct TurnFooter: View {
    let event: Event
    var body: some View {
        let failed = event.isError == true
        HStack(spacing: 6) {
            Image(systemName: failed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(failed ? Theme.danger : Theme.success)
            Text(failed ? "Turn failed" : "Turn complete")
            if let ms = event.durationMs { Text("·"); Text(Duration.milliseconds(ms).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))) }
            if let time = event.time { Text("·"); Text(EventTime.text(time)) }
        }
        .font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct QueuedBubble: View {
    let text: String
    let removable: Bool
    let remove: () -> Void
    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 4) {
                Text(text).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                HStack(spacing: 8) {
                    Label("Queued", systemImage: "clock").font(.caption2).foregroundStyle(.secondary)
                    if removable {
                        Button("Remove", role: .destructive, action: remove).font(.caption2.weight(.semibold))
                    }
                }
            }
        }
    }
}

/// Claude-style spinner: a cycling asterisk glyph and a rotating verb while the agent works.
struct WorkingIndicator: View {
    let status: String
    private static let glyphs = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]
    private static let verbs = ["Working", "Thinking", "Reasoning", "Tinkering", "Crafting", "Pondering"]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.periodic(from: .now, by: reduceMotion ? 3 : 0.12)) { context in
            let tick = Int(context.date.timeIntervalSinceReferenceDate / 0.12)
            HStack(spacing: 8) {
                Text(reduceMotion ? "✻" : Self.glyphs[tick % Self.glyphs.count])
                    .font(.body.weight(.semibold)).foregroundStyle(Theme.accent).frame(width: 16)
                Text(label(tick: tick) + "…").font(.subheadline).foregroundStyle(Theme.accent)
            }
        }
        .accessibilityElement().accessibilityLabel(status == "running" ? "Agent is working" : "Agent is \(status)")
    }
    private func label(tick: Int) -> String {
        switch status {
        case "queued": return "Queued"
        case "preparing", "starting": return "Starting up"
        default: return Self.verbs[(tick / 25) % Self.verbs.count]
        }
    }
}

private extension View {
    /// Opens on the latest message; short transcripts still read from the top where the system allows it.
    @ViewBuilder func startAtBottom() -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            defaultScrollAnchor(.bottom, for: .initialOffset).defaultScrollAnchor(.bottom, for: .sizeChanges)
                .defaultScrollAnchor(.top, for: .alignment)
        } else { defaultScrollAnchor(.bottom) }
    }
}

struct PullRoute: Hashable {
    let repo: String
    let number: Int
    let changes: Bool
}
