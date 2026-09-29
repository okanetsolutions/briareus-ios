import SwiftUI

/// The review results waiting for a decision in a project, apart from the conversations they came
/// from, as the dashboard keeps them. They are read off the project's conversations.
struct FindingsView: View {
    let project: Project
    @EnvironmentObject private var store: AppStore
    @State private var sessions: [Session] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var sending: String?
    /// Conversations whose last send failed without saying whether it was recorded.
    @State private var uncertain: [String: String] = [:]
    private var held: [Session] { Session.holdingFindings(sessions) }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if let error { ErrorNotice(message: error).padding(12).background(Theme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 12)) }
                ForEach(held) { session in
                    VStack(alignment: .leading, spacing: 10) {
                        PaneLink(pane: .conversation(session)) { ConversationView(initial: session) } label: {
                            HStack(spacing: 8) {
                                StatusDot(status: session.status)
                                Text(session.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(2)
                                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain).accessibilityHint("Opens the conversation")
                        if let said = uncertain[session.id] { unsure(said, session: session) }
                        if let triage = session.heldTriage {
                            FindingsTriageCard(triage: triage, disabled: sending != nil || uncertain[session.id] != nil) { verdicts, note in
                                Task { await complete(session, verdicts: verdicts, note: note) }
                            }
                        }
                    }
                }
                if loaded && held.isEmpty && error == nil {
                    ContentUnavailableView("No findings waiting", systemImage: "flag",
                                           description: Text("Review results that need a decision appear here."))
                        .frame(maxWidth: .infinity).padding(.top, 60)
                }
                if !loaded { ProgressView("Loading findings…").frame(maxWidth: .infinity).padding(.top, 60) }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .background(Theme.background)
        .navigationTitle("Findings").navigationBarTitleDisplayMode(.inline)
        .refreshable { do { try await load() } catch { if let said = failure(error) { self.error = said } } }
        .foregroundPoll(every: 7, enabled: sending == nil, action: load) { error = $0.localizedDescription; loaded = true }
    }
    private func unsure(_ message: String, session: Session) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ErrorNotice(message: message)
            Text("The triage may have been recorded. Check before sending it again.").font(.caption).foregroundStyle(.secondary)
            Button("Refresh and check outcome") {
                Task {
                    do { try await load(); uncertain[session.id] = nil }
                    catch { self.error = error.localizedDescription }
                }
            }.buttonStyle(.bordered).controlSize(.small).disabled(sending != nil)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
    private func load() async throws {
        let key = "sessions:\(project.repo)"
        if !loaded, let saved: [Session] = await store.cache.value(key), !loaded { sessions = saved; loaded = true }
        let result: SessionList = try await store.call("sessions", ["repo": .string(project.repo)])
        try Task.checkCancellation()
        sessions = result.sessions; loaded = true; error = nil
        await store.cache.store(result.sessions, for: key)
    }
    private func complete(_ session: Session, verdicts: [JSONValue], note: String) async {
        guard sending == nil, uncertain[session.id] == nil else { return }
        sending = session.id
        defer { sending = nil }
        var args: [String: JSONValue] = ["sessionId": .string(session.id)]
        if !verdicts.isEmpty { args["verdicts"] = .array(verdicts) }
        if !note.isEmpty { args["note"] = .string(note) }
        do {
            let _: JSONValue = try await store.call("complete_findings", args)
        } catch {
            // A write is never sent twice by itself: what happened is checked first.
            uncertain[session.id] = error.localizedDescription; return
        }
        do { try await load() } catch { self.error = error.localizedDescription }
    }
}
