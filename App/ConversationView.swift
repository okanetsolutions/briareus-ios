import SwiftUI

struct ConversationView: View {
    let initial: Session
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: Session?
    @State private var transcript = Transcript()
    @State private var message = ""
    @State private var busy = false
    @State private var loading = false
    @State private var error: String?
    @State private var writeError: String?
    @State private var uncertain = false
    @State private var pendingAction: String?
    @State private var renaming = false
    @State private var title = ""
    var session: Session { snapshot ?? initial }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    HStack {
                        StatusLabel(status: session.status)
                        Spacer()
                        if let cost = session.usage?["costUsd"].double {
                            Text(cost, format: .currency(code: "USD").precision(.fractionLength(2...4))).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let error { ErrorNotice(message: error) }
                    if let writeError {
                        ErrorNotice(message: writeError)
                        Text("The action may have completed. Check the latest conversation before trying again.").font(.caption)
                        Button("Refresh and check outcome") {
                            Task {
                                do { try await refresh(); uncertain = false; self.writeError = nil }
                                catch { self.error = error.localizedDescription }
                            }
                        }.disabled(loading || busy)
                    }
                    if transcript.events.isEmpty && error == nil { Text("Waiting for the conversation…").foregroundStyle(.secondary) }
                    ForEach(transcript.events.filter(\.visible)) { event in
                        EventView(event: event, canAnswer: store.supports("message") && session.status != "closed") { message = $0 }
                    }
                    ForEach(Array((session.queued ?? []).enumerated()), id: \.offset) { index, queued in
                        HStack {
                            Label(queued["text"].string ?? "Message", systemImage: "clock").font(.callout)
                            Spacer()
                            if store.supports("drop_message") {
                                Button("Remove", role: .destructive) {
                                    Task { await mutate("drop_message", extra: ["index": .number(Double(index))]) }
                                }.disabled(busy || uncertain)
                            }
                        }.padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding()
            }
            .refreshable { do { try await refresh() } catch { self.error = error.localizedDescription } }
            .safeAreaInset(edge: .bottom) { composer }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } } label: { Image(systemName: "arrow.down.to.line") }
                        .accessibilityLabel("Latest message")
                    Menu {
                        if store.supports("rename") { Button("Rename", systemImage: "pencil") { title = session.displayTitle; renaming = true } }
                        if store.supports("cancel") && session.isActive { Button("Stop agent", systemImage: "stop.circle", role: .destructive) { pendingAction = "cancel" } }
                        if store.supports("close") && session.status != "closed" { Button("Close conversation", systemImage: "archivebox") { pendingAction = "close" } }
                        if store.supports("reopen") && session.status == "closed" { Button("Reopen", systemImage: "arrow.uturn.backward") { pendingAction = "reopen" } }
                        if store.supports("delete") { Button("Delete conversation", systemImage: "trash", role: .destructive) { pendingAction = "delete" } }
                    } label: { Image(systemName: "ellipsis.circle") }.disabled(busy || uncertain)
                }
            }
        }
        .navigationTitle(session.displayTitle).navigationBarTitleDisplayMode(.inline)
        .foregroundPoll(every: session.isActive ? 2 : 7, enabled: !busy && !renaming && pendingAction == nil, action: refresh) { error = $0.localizedDescription }
        .confirmationDialog(actionTitle, isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }), titleVisibility: .visible) {
            Button("Confirm", role: pendingAction == "delete" || pendingAction == "cancel" ? .destructive : nil) {
                if let action = pendingAction { Task { await mutate(action) } }
            }
        }
        .alert("Rename conversation", isPresented: $renaming) {
            TextField("Title", text: $title)
            Button("Save") { Task { await mutate("rename", extra: ["title": .string(title)]) } }
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
    }
    private var actionTitle: String {
        switch pendingAction {
        case "delete": return "Permanently delete this conversation and its transcript?"
        case "cancel": return "Stop the running agent?"
        case "close": return "Close this conversation?"
        default: return "Reopen this conversation?"
        }
    }
    @ViewBuilder private var composer: some View {
        VStack(spacing: 8) {
            if store.supports("message") && session.status != "closed" {
                HStack(alignment: .bottom) {
                    TextField(session.isActive ? "Send a follow-up…" : "Message your agent…", text: $message, axis: .vertical)
                        .lineLimit(1...6).textFieldStyle(.roundedBorder).accessibilityIdentifier("messageInput")
                    Button {
                        Task { await mutate("message", extra: ["text": .string(message)]) }
                    } label: { Image(systemName: busy ? "hourglass" : "arrow.up.circle.fill").font(.title) }
                        .disabled(busy || uncertain || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("Send message")
                }
                Text(session.isActive ? (session.liveInput == true ? "Sent into the running turn" : "Queued for the next turn") : "Sending starts a paid agent turn")
                    .font(.caption2).foregroundStyle(.secondary)
            } else { Text(store.canManage ? "This conversation is closed" : "Read-only access").font(.caption).foregroundStyle(.secondary) }
        }.padding().background(.bar)
    }
    private func refresh() async throws {
        guard !loading else { return }
        loading = true; defer { loading = false }
        let result: SessionResult = try await store.call("session", ["sessionId": .string(initial.id), "since": .number(Double(transcript.cursor))])
        try Task.checkCancellation()
        snapshot = result.session; transcript.append(result.events ?? []); error = nil
    }
    private func mutate(_ name: String, extra: [String: JSONValue] = [:]) async {
        guard !busy && !uncertain else { return }
        busy = true; writeError = nil
        defer { busy = false }
        do {
            let _: JSONValue = try await store.call(name, ["sessionId": .string(initial.id)].merging(extra) { _, new in new })
            if name == "message", message == extra["text"]?.string { message = "" }
            if name == "delete" { dismiss(); return }
        } catch {
            writeError = error.localizedDescription; uncertain = true; return
        }
        do { try await refresh() } catch { self.error = error.localizedDescription }
    }
}

struct EventView: View {
    let event: Event
    let canAnswer: Bool
    let answer: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch event.kind {
            case "user":
                Label("You", systemImage: "person.fill").font(.caption.bold()).foregroundStyle(.secondary)
                Text(event.text ?? "").textSelection(.enabled)
                ForEach(Array((event.attachments ?? []).enumerated()), id: \.offset) { _, attachment in
                    Label(attachment["name"].string ?? "Attachment", systemImage: "paperclip").font(.caption)
                }
            case "text":
                Text(.init(event.text ?? "")).textSelection(.enabled)
            case "ask":
                Label("Your input is needed", systemImage: "questionmark.bubble").font(.caption.bold()).foregroundStyle(.indigo)
                Text(event.question ?? event.text ?? "").textSelection(.enabled)
                if canAnswer {
                    ForEach(Array((event.options ?? []).enumerated()), id: \.offset) { _, option in
                        if let label = option["label"].string { Button(label) { answer(label) }.buttonStyle(.bordered) }
                    }
                    Text("Choose an answer to put it in the composer, or write your own.").font(.caption).foregroundStyle(.secondary)
                }
            case "tool", "tool_error", "cmd", "git", "setup":
                DisclosureGroup(event.name ?? event.kind.capitalized) {
                    Text(event.text ?? "No additional details").font(.caption.monospaced()).textSelection(.enabled)
                }.foregroundStyle(event.kind == "tool_error" ? Color.red : Color.secondary)
            case "result":
                HStack {
                    Label(event.isError == true ? "Turn failed" : "Turn complete", systemImage: event.isError == true ? "exclamationmark.circle" : "checkmark.circle")
                    Spacer()
                    if let cost = event.costUsd { Text(cost, format: .currency(code: "USD").precision(.fractionLength(4))) }
                }.font(.caption).foregroundStyle(.secondary)
            default:
                if let text = event.text { Text(text).font(.callout).foregroundStyle(event.kind == "stderr" ? Color.red : Color.secondary).textSelection(.enabled) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(event.kind == "user" || event.kind == "ask" ? 14 : 0)
        .background(event.kind == "user" || event.kind == "ask" ? Color.indigo.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 14))
    }
}
