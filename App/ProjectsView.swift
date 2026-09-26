import SwiftUI

private struct ActivePolling: ViewModifier {
    @Environment(\.scenePhase) private var phase
    @State private var visible = false
    let interval: Double
    let enabled: Bool
    let action: () async throws -> Void
    let failed: (Error) -> Void
    func body(content: Content) -> some View {
        content.onAppear { visible = true }.onDisappear { visible = false }
            .task(id: visible && phase == .active && enabled) {
                guard visible && phase == .active && enabled else { return }
                await poll(every: interval, action: action, failed: failed)
            }
    }
}
extension View {
    func foregroundPoll(every interval: Double, enabled: Bool = true,
                        action: @escaping () async throws -> Void, failed: @escaping (Error) -> Void) -> some View {
        modifier(ActivePolling(interval: interval, enabled: enabled, action: action, failed: failed))
    }
}

struct ProjectsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var projects: [Project] = []
    @State private var loaded = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                if !store.canManage {
                    Label("Read-only access", systemImage: "eye").foregroundStyle(.secondary)
                }
                if let error { ErrorNotice(message: error) }
                ForEach(projects) { project in
                    NavigationLink(value: project) {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(project.title).font(.headline)
                                if project.title != project.repo { Text(project.repo).font(.caption).foregroundStyle(.secondary) }
                            }.padding(.vertical, 6)
                        } icon: { Image(systemName: "folder.fill").foregroundStyle(.indigo) }
                    }
                }
                if loaded && projects.isEmpty && error == nil {
                    ContentUnavailableView("No projects", systemImage: "folder", description: Text("Grant this device access to a project in web Settings."))
                }
                if !loaded { ProgressView("Loading projects…") }
            }
            .navigationTitle("Projects")
            .navigationDestination(for: Project.self) { ProjectView(project: $0) }
            .refreshable { do { try await load() } catch { self.error = error.localizedDescription } }
            .foregroundPoll(every: 30, action: load) { error = $0.localizedDescription; loaded = true }
        }
    }
    private func load() async throws {
        let result: ProjectList = try await store.call("projects")
        try Task.checkCancellation()
        projects = result.projects; loaded = true; error = nil
    }
}

struct ProjectView: View {
    let project: Project
    @EnvironmentObject private var store: AppStore
    @State private var sessions: [Session] = []
    @State private var search = ""
    @State private var showClosed = false
    @State private var creating = false
    @State private var created: Session?
    @State private var error: String?
    @State private var loaded = false
    var filtered: [Session] {
        sessions.filter { (showClosed || $0.status != "closed") && (search.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(search)) }
    }
    var body: some View {
        List {
            Section {
                if store.supports("pulls") {
                    NavigationLink { PullsView(project: project) } label: { Label("Pull requests", systemImage: "arrow.triangle.pull") }
                }
                if store.supports("usage") {
                    NavigationLink { UsageView(project: project) } label: { Label("Usage", systemImage: "chart.bar") }
                }
            }
            Section("Conversations") {
                Toggle("Show closed", isOn: $showClosed)
                if let error { ErrorNotice(message: error) }
                ForEach(filtered) { session in
                    NavigationLink { ConversationView(initial: session) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(session.displayTitle).font(.headline).lineLimit(2)
                            HStack { StatusLabel(status: session.status); Spacer(); Text(session.model ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }.padding(.vertical, 4)
                    }
                }
                if loaded && filtered.isEmpty { Text("No conversations here yet.").foregroundStyle(.secondary) }
                if !loaded { ProgressView() }
            }
        }
        .navigationTitle(project.title).navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Find a conversation")
        .toolbar {
            if store.supports("start_session") {
                Button { creating = true } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("New conversation")
            }
        }
        .sheet(isPresented: $creating) {
            NewConversationView(project: project) { session in created = session }
        }
        .navigationDestination(item: $created) { ConversationView(initial: $0) }
        .refreshable { do { try await load() } catch { self.error = error.localizedDescription } }
        .foregroundPoll(every: 7, enabled: !creating, action: load) { error = $0.localizedDescription; loaded = true }
    }
    private func load() async throws {
        let result: SessionList = try await store.call("sessions", ["repo": .string(project.repo)])
        try Task.checkCancellation()
        sessions = result.sessions; loaded = true; error = nil
    }
}

struct NewConversationView: View {
    let project: Project
    let started: (Session) -> Void
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var branch = ""
    @State private var busy = false
    @State private var uncertain = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Task for \(project.title)") {
                    TextField("What would you like to work on?", text: $prompt, axis: .vertical).lineLimit(5...15)
                    TextField("Branch (optional)", text: $branch).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    Text("Starting a conversation runs a paid agent using this project’s configured provider and model.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error { Section { ErrorNotice(message: error) } }
                if uncertain {
                    Section {
                        Text("The request may have completed. Close this sheet and refresh the conversations before starting again.")
                        Button("Return to conversations") { dismiss() }
                    }
                }
            }.navigationTitle("New conversation").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(busy ? "Starting…" : "Start") { Task { await start() } }
                            .disabled(busy || uncertain || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.interactiveDismissDisabled(busy)
        }
    }
    private func start() async {
        busy = true; error = nil
        defer { busy = false }
        var args: [String: JSONValue] = ["repo": .string(project.repo), "prompt": .string(prompt)]
        let branch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        if !branch.isEmpty { args["branch"] = .string(branch) }
        do {
            let result: SessionResult = try await store.call("start_session", args)
            dismiss(); started(result.session)
        } catch { self.error = error.localizedDescription; uncertain = true }
    }
}
