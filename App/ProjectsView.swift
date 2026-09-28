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
    @State private var showingConnection = false
    var body: some View {
        NavigationStack {
            List {
                if !store.canManage {
                    Label("Read-only access", systemImage: "eye").font(.subheadline).foregroundStyle(.secondary)
                }
                if let error { ErrorNotice(message: error) }
                ForEach(projects) { project in
                    NavigationLink(value: project) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.title).font(.body.weight(.medium))
                            if project.title != project.repo { Text(project.repo).font(.caption).foregroundStyle(.secondary) }
                        }.padding(.vertical, 4)
                    }
                    .listRowBackground(Theme.elevated)
                }
                if loaded && projects.isEmpty && error == nil {
                    ContentUnavailableView("No projects", systemImage: "folder", description: Text("Grant this device access to a project in web Settings."))
                        .listRowBackground(Color.clear)
                }
                if !loaded { ProgressView("Loading projects…").frame(maxWidth: .infinity).listRowBackground(Color.clear) }
            }
            .scrollContentBackground(.hidden).background(Theme.background)
            .navigationTitle("Projects")
            .toolbar {
                Button { showingConnection = true } label: { Image(systemName: "network") }
                    .accessibilityLabel("Connection")
            }
            .sheet(isPresented: $showingConnection) { SettingsView() }
            .navigationDestination(for: Project.self) { ProjectView(project: $0) }
            .refreshable { do { try await load() } catch { self.error = error.localizedDescription } }
            .foregroundPoll(every: 30, action: load) { error = $0.localizedDescription; loaded = true }
        }
    }
    private func load() async throws {
        if !loaded, let saved: [Project] = await store.cache.value("projects"), !loaded { projects = saved; loaded = true }
        let result: ProjectList = try await store.call("projects")
        try Task.checkCancellation()
        projects = result.projects; loaded = true; error = nil
        await store.cache.store(result.projects, for: "projects")
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
            if store.supports("pulls") {
                Section {
                    NavigationLink { PullsView(project: project) } label: { Label("Pull requests", systemImage: "arrow.triangle.pull") }
                }.listRowBackground(Theme.elevated)
            }
            if let error { Section { ErrorNotice(message: error) }.listRowBackground(Theme.elevated) }
            let active = filtered.filter(\.isActive)
            if !active.isEmpty {
                Section("Active") { ForEach(active) { row($0) } }.listRowBackground(Theme.elevated)
            }
            Section {
                ForEach(filtered.filter { !$0.isActive }) { row($0) }
                if loaded && filtered.isEmpty {
                    Text(search.isEmpty ? "No conversations here yet." : "No matching conversations.").foregroundStyle(.secondary)
                }
                if !loaded { ProgressView().frame(maxWidth: .infinity) }
            } header: {
                HStack {
                    Text(active.isEmpty ? "Conversations" : "Recent")
                    Spacer()
                    Toggle("Show closed", isOn: $showClosed).toggleStyle(.button).buttonStyle(.borderless).controlSize(.mini)
                        .font(.caption.weight(.medium)).textCase(nil)
                }
            }.listRowBackground(Theme.elevated)
        }
        .scrollContentBackground(.hidden).background(Theme.background)
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
    private func row(_ session: Session) -> some View {
        NavigationLink { ConversationView(initial: session) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                StatusDot(status: session.status).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.displayTitle).font(.body.weight(.medium)).lineLimit(2)
                        .foregroundStyle(session.status == "closed" ? .secondary : .primary)
                    Text([session.status.capitalized, session.model].compactMap { $0.flatMap { $0.isEmpty ? nil : $0 } }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }.padding(.vertical, 3)
        }
        .accessibilityElement(children: .combine)
    }
    private func load() async throws {
        let key = "sessions:\(project.repo)"
        if !loaded, let saved: [Session] = await store.cache.value(key), !loaded { sessions = saved; loaded = true }
        let result: SessionList = try await store.call("sessions", ["repo": .string(project.repo)])
        try Task.checkCancellation()
        let gone = Set(sessions.map(\.id)).subtracting(result.sessions.map(\.id))
        sessions = result.sessions; loaded = true; error = nil
        await store.cache.store(result.sessions, for: key)
        for id in gone { await store.cache.remove("transcript:\(id)") }
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
    @State private var catalog: RuntimeCatalog?
    /// nil starts on the project's configured runtime.
    @State private var runtime: RuntimeChoice?
    @FocusState private var promptFocused: Bool
    private var effective: RuntimeChoice? { runtime ?? catalog?.default }
    private var needsRuntime: Bool { catalog != nil && effective == nil }
    private var canStart: Bool {
        !busy && !uncertain && !needsRuntime && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        Monogram(text: project.title, size: 28)
                        Text(project.title).font(.subheadline.weight(.medium))
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("What would you like to work on?", text: $prompt, axis: .vertical)
                            .lineLimit(6...16).focused($promptFocused)
                        Divider().overlay(Theme.border)
                        if store.supports("branches") {
                            NavigationLink { BranchPicker(project: project, selection: $branch) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "arrow.triangle.branch").font(.caption).foregroundStyle(.secondary)
                                    Text(branch.isEmpty ? "Default branch" : branch).font(.subheadline.monospaced())
                                        .foregroundStyle(branch.isEmpty ? .secondary : .primary).lineLimit(1)
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("Branch: \(branch.isEmpty ? "default" : branch)")
                        } else {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.triangle.branch").font(.caption).foregroundStyle(.secondary)
                                TextField("Branch (optional)", text: $branch).font(.subheadline.monospaced())
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                            }
                        }
                        if let catalog, !catalog.providers.isEmpty { runtimeRows(catalog) }
                    }
                    .padding(14)
                    .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.border, lineWidth: 0.5))
                    Label(catalog == nil ? "Starting a conversation runs a paid agent using this project’s configured provider and model."
                          : "Starting a conversation runs a paid agent on the selected model.", systemImage: "sparkle")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let error { ErrorNotice(message: error) }
                    if uncertain {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("The request may have completed. Close this sheet and refresh the conversations before starting again.").font(.footnote)
                            Button("Return to conversations") { dismiss() }.buttonStyle(.bordered)
                        }
                    }
                }.padding(16)
            }
            .background(Theme.background)
            .navigationTitle("New conversation").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await start() } } label: {
                        if busy { ProgressView() } else { Text("Start").bold() }
                    }.disabled(!canStart)
                }
            }
            .interactiveDismissDisabled(busy)
            .onAppear { promptFocused = true }
            .task {
                guard store.supports("runtimes") else { return }
                // Without the catalog the server still starts on the project's configured runtime.
                let key = "runtimes:\(project.repo)"
                if let saved: RuntimeCatalog = await store.cache.value(key), catalog == nil { show(saved) }
                guard let result: RuntimeCatalog = try? await store.call("runtimes", ["repo": .string(project.repo)]) else { return }
                show(result)
                await store.cache.store(result, for: key)
            }
        }
    }
    private func show(_ result: RuntimeCatalog) {
        catalog = result
        if result.default == nil && runtime == nil { runtime = result.firstAvailable }
    }
    @ViewBuilder private func runtimeRows(_ catalog: RuntimeCatalog) -> some View {
        Divider().overlay(Theme.border)
        Menu {
            if let standard = catalog.default {
                Button { runtime = nil } label: {
                    Label("Project default (\(catalog.label(for: standard)))", systemImage: runtime == nil ? "checkmark" : "gearshape")
                }
            }
            ForEach(catalog.providers) { provider in
                if !provider.isAvailable {
                    Button("\(provider.label) (unavailable)") {}.disabled(true)
                } else if provider.models.isEmpty {
                    Button(provider.label) { runtime = catalog.choice(provider: provider.id) }
                } else {
                    Menu(provider.label) {
                        ForEach(provider.models) { model in
                            Button { runtime = catalog.choice(provider: provider.id, model: model.id) } label: {
                                if effective?.providerId == provider.id && effective?.model == model.id {
                                    Label(model.title, systemImage: "checkmark")
                                } else { Text(model.title) }
                            }
                        }
                    }
                }
            }
        } label: {
            pickerRow(icon: "cpu", text: effective.map { catalog.label(for: $0) } ?? "Choose a model",
                      note: runtime == nil && effective != nil ? "Default" : nil, placeholder: effective == nil)
        }
        .accessibilityLabel("Model: \(effective.map { catalog.label(for: $0) } ?? "none")")
        if let effective, !catalog.efforts(for: effective).isEmpty {
            Divider().overlay(Theme.border)
            Menu {
                ForEach(catalog.efforts(for: effective), id: \.self) { effort in
                    Button {
                        runtime = RuntimeChoice(providerId: effective.providerId, model: effective.model, effort: effort)
                    } label: {
                        if effective.effort == effort { Label(effort.capitalized, systemImage: "checkmark") } else { Text(effort.capitalized) }
                    }
                }
            } label: {
                pickerRow(icon: "gauge.with.dots.needle.50percent", text: "\((effective.effort ?? "default").capitalized) effort",
                          note: nil, placeholder: false)
            }
            .accessibilityLabel("Effort: \(effective.effort ?? "default")")
        }
    }
    private func pickerRow(icon: String, text: String, note: String?, placeholder: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.caption).foregroundStyle(.secondary)
            Text(text).font(.subheadline).foregroundStyle(placeholder ? .secondary : .primary).lineLimit(1)
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
        }.contentShape(Rectangle())
    }
    private func start() async {
        busy = true; error = nil
        defer { busy = false }
        var args: [String: JSONValue] = ["repo": .string(project.repo), "prompt": .string(prompt)]
        let branch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        if !branch.isEmpty { args["branch"] = .string(branch) }
        if let runtime { args.merge(runtime.arguments) { _, new in new } }
        do {
            let result: SessionResult = try await store.call("start_session", args)
            dismiss(); started(result.session)
        } catch { self.error = error.localizedDescription; uncertain = true }
    }
}

struct BranchPicker: View {
    let project: Project
    @Binding var selection: String
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var branches: [String] = []
    @State private var defaultBranch: String?
    @State private var search = ""
    @State private var loaded = false
    @State private var error: String?
    private var filtered: [String] {
        search.isEmpty ? branches : branches.filter { $0.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        List {
            if let error { ErrorNotice(message: error) }
            Section {
                row(nil, label: defaultBranch.map { "\($0) (default)" } ?? "Default branch")
            }
            Section {
                ForEach(filtered.filter { $0 != defaultBranch }, id: \.self) { row($0, label: $0) }
                let typed = search.trimmingCharacters(in: .whitespacesAndNewlines)
                if !typed.isEmpty && !branches.contains(typed) {
                    Button { selection = typed; dismiss() } label: {
                        Label("Use “\(typed)”", systemImage: "plus")
                    }
                }
                if !loaded { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .listRowBackground(Theme.elevated)
        .scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle("Branch").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find or type a branch")
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .task {
            let key = "branches:\(project.repo)"
            if let saved: JSONValue = await store.cache.value(key) { show(saved) }
            do {
                let result: JSONValue = try await store.call("branches", ["repo": .string(project.repo)])
                show(result)
                await store.cache.store(result, for: key)
            } catch { self.error = error.localizedDescription }
            loaded = true
        }
    }
    private func show(_ result: JSONValue) {
        branches = result["branches"].array.compactMap(\.string)
        defaultBranch = result["defaultBranch"].string
        loaded = true
    }
    private func row(_ value: String?, label: String) -> some View {
        Button { selection = value ?? ""; dismiss() } label: {
            HStack {
                Text(label).font(.subheadline.monospaced()).foregroundStyle(.primary).lineLimit(1)
                Spacer()
                if selection == (value ?? "") { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Theme.elevated)
    }
}
