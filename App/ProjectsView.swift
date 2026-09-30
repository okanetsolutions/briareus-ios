import SwiftUI

private struct ActivePolling: ViewModifier {
    @Environment(\.scenePhase) private var phase
    @State private var visible = false
    @State private var clock = PollClock()
    @State private var behind = false
    let interval: Double
    let enabled: Bool
    let action: () async throws -> Void
    let failed: (Error) -> Void
    func body(content: Content) -> some View {
        let watched = visible && phase.isInUse
        // A Mac window behind another app is still in view, but nobody is waiting on it.
        let pace = interval * (behind ? 3 : 1)
        content.onAppear { visible = true }.onDisappear { visible = false }
            .onBehindOtherApps { behind = $0 }
            // The interval is part of what the task is, so a conversation that goes idle slows its polling down.
            .task(id: watched && enabled ? pace : 0) {
                guard watched else { return }
                // A pause is a dialog or a write, and a write reads what it changed by itself. What is on screen
                // counts as read when the pause began, so ending it does not ask again at once.
                guard enabled else { if clock.last != nil { clock.last = Date() }; return }
                await poll(every: pace, clock: clock, action: action, failed: failed)
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
    @Environment(\.horizontalSizeClass) private var width
    var body: some View {
        // An iPad or a Mac window has room for the conversation beside the list; a phone, or a narrow window, does not.
        if width == .regular { SplitLayout() } else { NavigationStack { ProjectsList() } }
    }
}

struct ProjectsList: View {
    @EnvironmentObject private var store: AppStore
    @State private var projects: [Project] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var showingConnection = false
    @Environment(\.splitProject) private var chosen
    var body: some View {
        List {
            if !store.canManage {
                Label("Read-only access", systemImage: "eye").font(.subheadline).foregroundStyle(.secondary)
            }
            if let error { ErrorNotice(message: error) }
            ForEach(projects) { project in
                let label = VStack(alignment: .leading, spacing: 2) {
                    Text(project.title).font(.body.weight(.medium))
                    if project.title != project.repo { Text(project.repo).font(.caption).foregroundStyle(.secondary) }
                }.padding(.vertical, 4)
                if let chosen {
                    let selected = chosen.wrappedValue?.repo == project.repo
                    Button { chosen.wrappedValue = project } label: {
                        label.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Theme.row(selected: selected))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                } else {
                    NavigationLink(value: project) { label }.listRowBackground(Theme.row)
                }
            }
            if loaded && projects.isEmpty && error == nil {
                ContentUnavailableView("No projects", systemImage: "folder", description: Text("Grant this device access to a project in web Settings."))
                    .listRowBackground(Color.clear)
            }
            if !loaded { ProgressView("Loading projects…").frame(maxWidth: .infinity).listRowBackground(Color.clear) }
        }
        // Beside the conversation a list would otherwise take the flat sidebar style.
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle("Projects")
        .toolbar {
            Button { showingConnection = true } label: { Image(systemName: "network") }
                .buttonStyle(.automatic).accessibilityLabel("Connection")
        }
        .sheet(isPresented: $showingConnection) { SettingsView().sheetSize() }
        .navigationDestination(for: Project.self) { ProjectView(project: $0) }
        .refreshable { do { try await load() } catch { if let said = failure(error) { self.error = said } } }
        .foregroundPoll(every: 30, action: load) { error = $0.localizedDescription; loaded = true }
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
    @State private var search = ""
    @State private var showClosed = false
    @State private var creating = false
    /// What a phone pushes; beside the list it fills the other side instead.
    @State private var pushed: Pane?
    @State private var error: String?
    @Environment(\.splitPane) private var pane
    /// The project's conversations, which its board and its findings read too.
    private var feed: ProjectFeed { store.feed(project.repo) }
    private var sessions: [Session] { feed.sessions }
    private var loaded: Bool { feed.sessionsLoaded || error != nil }
    var filtered: [Session] {
        sessions.filter { (showClosed || $0.status != "closed") && (search.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(search)) }
    }
    var body: some View {
        #if os(macOS)
        // A Mac's toolbar would put these at the far end of the window, away from the list they act on.
        list.safeAreaInset(edge: .top, spacing: 0) { finder }
        #else
        // Beside a conversation the list's column is too narrow for a bar holding them and the project's name.
        if pane != nil { list.safeAreaInset(edge: .top, spacing: 0) { finder } }
        else {
            list.searchable(text: $search, prompt: "Find a conversation")
                // One item rather than three, which would leave the project's name little room.
                .toolbar { ToolbarItem(placement: .topBarTrailing) { HStack(spacing: 0) { actions } } }
        }
        #endif
    }
    private var list: some View {
        List {
            if let error { Section { ErrorNotice(message: error) }.listRowBackground(Theme.row) }
            let active = filtered.filter(\.isActive)
            if !active.isEmpty {
                Section("Active") { ForEach(active) { row($0) } }.listRowBackground(Theme.row)
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
            }.listRowBackground(Theme.row)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle(project.title).navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $creating) {
            NewConversationView(project: project) { open(.conversation($0)) }
                .sheetSize(width: 580, height: 440)
        }
        .navigationDestination(item: $pushed) { $0.screen }
        .refreshable { do { try await load(fresh: true) } catch { if let said = failure(error) { self.error = said } } }
        .foregroundPoll(every: ProjectFeed.sessionsEvery, enabled: !creating, action: { try await load() }) { error = $0.localizedDescription }
    }
    private var finder: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.callout).foregroundStyle(.secondary)
                TextField("Find a conversation", text: $search).autocorrectionDisabled()
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .accessibilityLabel("Clear the search")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Theme.border, lineWidth: 0.5))
            HStack(spacing: 2) { actions }
        }
        .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 8)
        .background(Theme.background)
    }
    /// The project's other screens and a new conversation, as icons above the list in either layout.
    @ViewBuilder private var actions: some View {
        if store.supports("pulls") {
            action("Pull requests", symbol: "arrow.triangle.pull", opens: .pulls(project))
        }
        let waiting = Session.holdingFindings(sessions).count
        if waiting > 0 && store.supports("complete_findings") {
            action("Findings", symbol: "flag", count: waiting, opens: .findings(project))
                .accessibilityLabel("Findings, \(waiting) waiting")
        }
        if store.supports("start_session") {
            Button { creating = true } label: { icon("square.and.pencil") }
                .help("New conversation").accessibilityLabel("New conversation")
        }
    }
    private func action(_ name: String, symbol: String, count: Int = 0, opens target: Pane) -> some View {
        let selected = pane?.wrappedValue?.id == target.id
        return Button { open(target) } label: { icon(symbol, count: count, selected: selected) }
            .help(name).accessibilityLabel(name).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func icon(_ symbol: String, count: Int = 0, selected: Bool = false) -> some View {
        Image(systemName: symbol)
            // The count sits inside the button's own bounds: a navigation bar cuts off what hangs outside them.
            .padding(.horizontal, count > 0 ? 8 : 0).padding(.vertical, count > 0 ? 6 : 0)
            .overlay(alignment: .topTrailing) {
                if count > 0 {
                    Text(String(count)).font(.caption2.weight(.bold).monospacedDigit()).foregroundStyle(.white)
                        .padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15).background(Theme.warning, in: Capsule())
                }
            }
            .font(.body.weight(.medium)).foregroundStyle(Theme.accent).frame(width: 34, height: 34)
            .background(selected ? Theme.accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
    }
    private func open(_ target: Pane) {
        if let pane { pane.wrappedValue = target } else { pushed = target }
    }
    private func row(_ session: Session) -> some View {
        PaneLink(pane: .conversation(session)) { ConversationView(initial: session) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                mark(session)
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.displayTitle).font(.body.weight(.medium)).lineLimit(2)
                        .foregroundStyle(session.status == "closed" ? .secondary : .primary)
                    Text([session.status.capitalized, session.model].compactMap { $0.flatMap { $0.isEmpty ? nil : $0 } }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }.padding(.vertical, 3)
        }
        .help(session.pullBadge ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityValue(session.pullBadge ?? "")
    }
    /// A pull request takes the dot's place, as Claude's list shows it; a conversation at work keeps its pulsing dot.
    @ViewBuilder private func mark(_ session: Session) -> some View {
        if let tone = session.pullTone, !session.isActive {
            Image(systemName: "arrow.triangle.pull").font(.caption.weight(.semibold)).foregroundStyle(pullColor(tone))
                .frame(width: 14).accessibilityHidden(true)
        } else {
            StatusDot(status: session.status).frame(width: 14).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        }
    }
    /// Purple once merged, grey when closed unmerged; while open, the checks' colour.
    private func pullColor(_ tone: String) -> Color {
        switch tone {
        case "merged": return .purple
        case "closed": return .secondary
        case "failing": return Theme.danger
        case "pending": return Theme.warning
        default: return Theme.success
        }
    }
    private func load(fresh: Bool = false) async throws {
        try await feed.loadSessions(fresh: fresh)
        try Task.checkCancellation()
        error = nil
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
                        if store.canTranscribe {
                            HStack { Spacer(); VoiceNoteButton(text: $prompt) }
                        }
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
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.buttonStyle(.automatic).disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await start() } } label: {
                        if busy { ProgressView() } else { Text("Start").bold() }
                    }.buttonStyle(.automatic).disabled(!canStart)
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
        .plainMenu()
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
            .plainMenu()
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
        .listRowBackground(Theme.row)
        .scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle("Branch").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .pinned, prompt: "Find or type a branch")
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
        .listRowBackground(Theme.row)
    }
}
