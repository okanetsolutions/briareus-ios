// A new session, as the Mac's New session screen (screen_new_session.c) and its row of chips: what to build, said or
// dictated, with files; the project (when started from the projects list), the branch, provider, model and effort, and
// the review loop. Starting runs a paid agent, so the sheet says so; a start whose outcome is unknown is not repeated.
import Combine
import SwiftUI

@MainActor
final class NewConversationModel: ObservableObject {
    @Published private(set) var projects: [Project] = []
    @Published var repo: String?
    @Published private(set) var catalog: RuntimeCatalog?
    /// The pick; nil starts on the project's default.
    @Published var runtime: RuntimeChoice?
    @Published private(set) var branches: [String] = []
    @Published private(set) var defaultBranch: String?
    /// Nil: a new branch off the default.
    @Published var branch: String?
    @Published var reviewLoop = true
    @Published var prompt = ""
    @Published private(set) var busy = false
    @Published private(set) var uncertain = false
    @Published private(set) var error: String?

    let files = ComposerFiles(call: "start_session")
    let voice = PhoneVoiceNote()
    private var choicesTask: Task<Void, Never>?
    /// Whether a start can go depends on the files too.
    private var filesChanged: AnyCancellable?

    init(repo: String?) {
        var list = ProjectsModel.shared.projects
        if list.isEmpty, let repo { list = [Project(repo: repo)] }
        projects = list
        self.repo = repo ?? list.first?.repo
        filesChanged = files.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        voice.onText = { [weak self] text in
            guard let self else { return }
            prompt = appendDictation(prompt, text)
        }
    }

    var project: Project? { projects.first { $0.repo == repo } ?? repo.map { Project(repo: $0) } }
    /// What the session would start on: the pick, else the project's default.
    var effective: RuntimeChoice? { runtime ?? catalog?.defaultChoice }
    /// A catalog without a default needs a pick before anything can start.
    var needsRuntime: Bool { catalog != nil && effective == nil }
    /// A session starts on a prompt, on files, or on both; never while a file is still uploading.
    var canStart: Bool {
        !busy && !uncertain && project != nil && !needsRuntime && (!prompt.cTrimmed.isEmpty || files.count > 0) && !files.uploading
    }

    /// Reads what the picked project offers: its runtimes and branches, the saved answer first.
    func loadChoices() {
        choicesTask?.cancel()
        catalog = nil; runtime = nil; branches = []; defaultBranch = nil; branch = nil
        guard let p = project else { return }
        let store = Store.shared
        if store.supports("runtimes"), let saved = store.cache.value("runtimes:\(p.repo)") { adopt(RuntimeCatalog(saved)) }
        if store.supports("branches"), let saved = store.cache.value("branches:\(p.repo)") { adoptBranches(saved) }
        choicesTask = Task {
            async let runtimes: Void = readRuntimes(p.repo)
            async let branches: Void = readBranches(p.repo)
            _ = await (runtimes, branches)
        }
    }
    private func readRuntimes(_ repo: String) async {
        let store = Store.shared
        guard store.supports("runtimes"), let answer = try? await store.call("runtimes", ["repo": .string(repo)]),
              !Task.isCancelled, project?.repo == repo, let c = RuntimeCatalog(answer) else { return }
        adopt(c)
        store.cache.store(answer, "runtimes:\(repo)")
    }
    private func readBranches(_ repo: String) async {
        let store = Store.shared
        guard store.supports("branches"), let answer = try? await store.call("branches", ["repo": .string(repo)]),
              !Task.isCancelled, project?.repo == repo else { return }
        adoptBranches(answer)
        store.cache.store(answer, "branches:\(repo)")
    }
    private func adopt(_ c: RuntimeCatalog?) {
        guard let c else { return }
        catalog = c
        // Without a project default a start needs a provider.
        if c.defaultChoice == nil && runtime == nil { runtime = c.firstAvailable() }
    }
    private func adoptBranches(_ value: JSON) {
        branches = value["branches"].items.compactMap(\.string)
        defaultBranch = value["defaultBranch"].string
    }

    func disappeared() {
        voice.drop()
        choicesTask?.cancel(); choicesTask = nil
    }

    func start(started: @escaping (Session) -> Void) {
        guard canStart, let p = project, Store.shared.supports("start_session") else { return }
        var args: JSON = ["repo": .string(p.repo)]
        if !prompt.cTrimmed.isEmpty { args["prompt"] = .string(prompt) }
        if let ids = files.ids { args["attachments"] = ids }
        if let branch { args["branch"] = .string(branch) }
        if let runtime { args.merge(runtime.arguments) }
        busy = true; error = nil
        let loop = reviewLoop
        Task {
            do {
                let answer = try await Store.shared.call("start_session", args)
                busy = false
                guard let session = Session(answer["session"]) else { error = "The server returned an unexpected response."; uncertain = true; return }
                prompt = ""
                files.sent(args["attachments"].isNull ? nil : args["attachments"])
                // The loop the switch turned off, which the server arms by default.
                if !loop && Store.shared.supports("review_loop") && session.canReviewLoop {
                    Task { _ = try? await Store.shared.call("review_loop", ["sessionId": .string(session.id), "on": false]) }
                }
                let feed = Store.shared.feed(p.repo)
                Task { try? await feed.loadSessions(fresh: true) }
                started(session)
            } catch {
                busy = false
                if error.isCancellation { return }
                self.error = errorText(error)
                // A refusal started nothing; anything else may have.
                if !((error as? APIError)?.isRefusal ?? false) { uncertain = true }
            }
        }
    }
}

struct NewConversationSheet: View {
    let fixedRepo: String?
    let started: (Session) -> Void
    @StateObject private var model: NewConversationModel
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @FocusState private var promptFocused: Bool

    /// `repo` nil lets the project be picked, as from the projects list.
    init(repo: String?, started: @escaping (Session) -> Void) {
        fixedRepo = repo
        self.started = started
        _model = StateObject(wrappedValue: NewConversationModel(repo: repo))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    projectRow
                    composer
                    Label(model.catalog == nil ? "Starting a conversation runs a paid agent using this project\u{2019}s configured provider and model."
                          : "Starting a conversation runs a paid agent on the selected model.", systemImage: "sparkle")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let error = model.error { ErrorNotice(message: error) }
                    if model.uncertain {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("The request may have completed. Close this sheet and refresh the conversations before starting again.").font(.footnote)
                            Button("Return to conversations") { dismiss() }.buttonStyle(.bordered)
                        }
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.background)
            .navigationTitle("New conversation").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        model.start { session in dismiss(); started(session) }
                    } label: {
                        if model.busy { ProgressView() } else { Text("Start").bold() }
                    }
                    .disabled(!model.canStart)
                }
            }
        }
        .interactiveDismissDisabled(model.busy)
        .onAppear {
            promptFocused = true
            if model.catalog == nil { model.loadChoices() }
        }
        .onDisappear { model.disappeared() }
        .onChange(of: model.repo) { _, _ in model.loadChoices() }
        .onChange(of: store.active) { _, active in if !active { model.voice.stop() } }
    }

    // MARK: Pieces

    @ViewBuilder private var projectRow: some View {
        let title = model.project?.title ?? "Project"
        if fixedRepo == nil && model.projects.count > 1 {
            Menu {
                Picker("Project", selection: $model.repo) {
                    ForEach(model.projects, id: \.repo) { Text($0.title).tag(Optional($0.repo)) }
                }
            } label: {
                HStack(spacing: 10) {
                    Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                }
            }
            .disabled(model.busy)
            .accessibilityLabel("Project: \(title)")
        } else {
            HStack(spacing: 10) {
                Text(title).font(.subheadline.weight(.medium))
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            AttachmentChipRow(files: model.files, enabled: !model.busy)
            TextField("Describe what to build\u{2026}", text: $model.prompt, axis: .vertical)
                .lineLimit(6...16).focused($promptFocused).disabled(model.busy)
            HStack(spacing: 8) {
                if model.files.supported { AttachMenu(files: model.files, enabled: !model.busy) }
                Spacer(minLength: 0)
                if store.canTranscribe { VoiceNoteControls(voice: model.voice, enabled: !model.busy) }
            }
            if store.supports("branches") {
                Divider().overlay(Theme.border)
                NavigationLink {
                    ConversationBranchPicker(branches: model.branches, defaultBranch: model.defaultBranch, selection: $model.branch)
                } label: {
                    pickerRow(icon: "arrow.triangle.branch", text: model.branch ?? "New branch off \(model.defaultBranch ?? "main")",
                              placeholder: model.branch == nil, chevron: "chevron.right", mono: model.branch != nil)
                }
                .buttonStyle(.plain).disabled(model.busy)
                .accessibilityLabel("Branch: \(model.branch ?? "a new branch off the default")")
            }
            if let catalog = model.catalog, !catalog.providers.isEmpty { runtimeRows(catalog) }
            if store.supports("review_loop") {
                Divider().overlay(Theme.border)
                Toggle(isOn: $model.reviewLoop) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Review loop", systemImage: "repeat").font(.subheadline)
                        Text("Each push gets a paid review round, and its findings a fix session.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(model.busy)
            }
        }
        .padding(14)
        .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.border, lineWidth: 0.5))
    }

    @ViewBuilder private func runtimeRows(_ catalog: RuntimeCatalog) -> some View {
        let effective = model.effective
        Divider().overlay(Theme.border)
        Menu {
            if let standard = catalog.defaultChoice {
                Button { model.runtime = nil } label: {
                    Label("Project default (\(catalog.label(for: standard)))", systemImage: model.runtime == nil ? "checkmark" : "gearshape")
                }
            }
            ForEach(catalog.providers, id: \.id) { provider in
                if !provider.isAvailable {
                    Button("\(provider.label) (unavailable)") {}.disabled(true)
                } else if provider.models.isEmpty {
                    Button(provider.label) { model.runtime = catalog.choice(provider: provider.id) }
                } else {
                    Menu(provider.label) {
                        ForEach(provider.models, id: \.id) { m in
                            Button { model.runtime = catalog.choice(provider: provider.id, model: m.id) } label: {
                                if effective?.providerId == provider.id && effective?.model == m.id {
                                    Label(m.title, systemImage: "checkmark")
                                } else { Text(m.title) }
                            }
                        }
                    }
                }
            }
        } label: {
            pickerRow(icon: "cpu", text: effective.map { catalog.label(for: $0) } ?? "Choose a model",
                      note: model.runtime == nil && effective != nil ? "Default" : nil, placeholder: effective == nil)
        }
        .disabled(model.busy)
        .accessibilityLabel("Model: \(effective.map { catalog.label(for: $0) } ?? "none")")
        if let effective, !catalog.efforts(for: effective).isEmpty {
            Divider().overlay(Theme.border)
            Menu {
                ForEach(catalog.efforts(for: effective), id: \.self) { effort in
                    Button {
                        model.runtime = RuntimeChoice(providerId: effective.providerId, model: effective.model, effort: effort)
                    } label: {
                        if effective.effort == effort { Label(effort.capitalized, systemImage: "checkmark") } else { Text(effort.capitalized) }
                    }
                }
            } label: {
                pickerRow(icon: "gauge.with.dots.needle.50percent", text: "\((effective.effort ?? "default").capitalized) effort", placeholder: false)
            }
            .disabled(model.busy)
            .accessibilityLabel("Effort: \(effective.effort ?? "default")")
        }
    }

    private func pickerRow(icon: String, text: String, note: String? = nil, placeholder: Bool,
                           chevron: String = "chevron.up.chevron.down", mono: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.caption).foregroundStyle(.secondary).frame(width: 18)
            Text(text).font(mono ? .subheadline.monospaced() : .subheadline).foregroundStyle(placeholder ? .secondary : .primary).lineLimit(1)
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Image(systemName: chevron).font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

/// The branch to start on: a new one off the default, or one the project has, found by name.
struct ConversationBranchPicker: View {
    let branches: [String]
    let defaultBranch: String?
    @Binding var selection: String?
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var filtered: [String] {
        let list = branches.filter { $0 != defaultBranch }
        return search.isEmpty ? list : list.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            Section {
                row(nil, label: "New branch off \(defaultBranch ?? "main")")
                if let defaultBranch { row(defaultBranch, label: defaultBranch) }
            }
            Section {
                ForEach(filtered, id: \.self) { row($0, label: $0) }
                if branches.isEmpty { Text("No other branches.").foregroundStyle(.secondary) }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden).background(Theme.background)
        .navigationTitle("Branch").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .pinned, prompt: "Find a branch")
        .textInputAutocapitalization(.never).autocorrectionDisabled()
    }

    private func row(_ value: String?, label: String) -> some View {
        Button { selection = value; dismiss() } label: {
            HStack {
                Text(label).font(value == nil ? .subheadline : .subheadline.monospaced()).foregroundStyle(.primary).lineLimit(1)
                Spacer()
                if selection == value { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Theme.row)
    }
}
