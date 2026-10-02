// A project's settings, as the Mac's project form on a phone: its sections (Project with its setup, Database, Code
// review, Orchestrator, Checkout .env, Run) on a strip of tabs over one form, a dot on any holding unsaved changes; saved
// through /settings/projects. The provider, model and effort pickers serve the code review, each errand step and the
// orchestrator's workers.
import SwiftUI

@MainActor
private final class ProjectFormModel: ObservableObject {
    /// The open tab stays open from one project to the next, so comparing a setting across projects is a tap each.
    static var openTab: ProjectTab = .project

    @Published var state: ProjectFormState
    @Published var tab: ProjectTab { didSet { Self.openTab = tab } }
    @Published var catalog: RuntimeCatalog?
    @Published var saving = false
    @Published var deleting = false
    @Published var error: String?
    @Published var scrollToken = 0
    let defaults: JSON?
    var focusFirst: ProjectField?
    private var runtimesTask: Task<Void, Never>?

    init(row: JSON?, defaults: JSON?) {
        // A saved row, a clone's values without an id, or a new project from the server's defaults.
        let r: JSON = row?.isObject == true ? row! : defaults?.isObject == true ? defaults! : [:]
        let s = ProjectFormState(row: r)
        state = s
        self.defaults = defaults
        // A new project starts where its repository is typed.
        if s.id == 0 { focusFirst = .repo; Self.openTab = .project }
        tab = Self.openTab
    }

    var busy: Bool { saving || deleting }

    func binding(_ f: ProjectField) -> Binding<String> {
        Binding(get: { self.state.text(f) }, set: { v in
            guard v != self.state.text(f) else { return }
            self.state.texts[f] = v
            self.changed()
        })
    }
    func toggle(_ f: ProjectField) -> Binding<Bool> {
        Binding(get: { self.state.bool(f) }, set: { v in
            guard v != self.state.bool(f) else { return }
            self.state.bools[f] = v
            self.changed()
        })
    }
    private func changed() { if !state.dirty { state.dirty = true } }

    var discardMessage: String {
        state.id != 0 ? "The changes to \(state.row["label"].nonEmpty ?? "this project") have not been saved." : "The new project has not been saved."
    }
    func tabDot(_ t: ProjectTab) -> Bool { state.dirty && state.tabChanged(t) }

    private func show(_ problem: FormProblem) {
        error = problem.message
        if let t = ProjectTab(rawValue: problem.tab) { tab = t }
        scrollToken += 1
    }
    private func showError(_ text: String?) {
        guard let text else { return }
        error = text; scrollToken += 1
    }

    // MARK: Runtimes

    /// The providers the pickers offer. The list is the server's for any project; it is asked with this one, or another.
    func loadRuntimes() {
        guard catalog == nil, runtimesTask == nil, Store.shared.supports("runtimes") else { return }
        var repo = state.row["repo"].nonEmpty
        if state.id == 0 || repo == nil {
            repo = ProjectsModel.shared.projects.first?.repo ?? SettingsLists.shared.projects.list.first?["repo"].nonEmpty
        }
        guard let repo else { return }
        runtimesTask = Task { [weak self] in
            let r = try? await Store.shared.call("runtimes", ["repo": .string(repo)])
            guard let self else { return }
            // A failed read is asked again the next time the form comes up.
            self.runtimesTask = nil
            if let r, let c = RuntimeCatalog(r) { self.catalog = c }
        }
    }

    func providerBinding(_ r: ProjectRuntime) -> Binding<Int> {
        Binding(get: { self.state.pick(r).providerId }, set: { id in
            guard id != self.state.pick(r).providerId else { return }
            if id == 0 { self.state.picks[r] = RuntimePick(); self.changed(); return }
            // A new provider starts on its default model and that model's default effort.
            guard let c = self.catalog?.choice(provider: id) else { return }
            self.state.picks[r] = RuntimePick(providerId: c.providerId, model: c.model, effort: c.effort)
            self.changed()
        })
    }
    func modelBinding(_ r: ProjectRuntime) -> Binding<String> {
        Binding(get: { self.state.pick(r).model ?? "" }, set: { id in
            var p = self.state.pick(r)
            guard id != (p.model ?? ""), let model = self.catalog?.provider(p.providerId)?.models.first(where: { $0.id == id }) else { return }
            // The effort carries over when the new model offers it, else that model's default.
            let efforts = model.efforts ?? []
            p.effort = efforts.contains(p.effort ?? "\u{0}") ? p.effort : model.defaultEffort ?? efforts.first ?? ""
            p.model = model.id
            self.state.picks[r] = p
            self.changed()
        })
    }
    func effortBinding(_ r: ProjectRuntime) -> Binding<String> {
        Binding(get: { self.state.pick(r).effort ?? "" }, set: { effort in
            var p = self.state.pick(r)
            guard effort != (p.effort ?? "") else { return }
            p.effort = effort
            self.state.picks[r] = p
            self.changed()
        })
    }

    // MARK: Saving, cloning, deleting

    func save(done: @escaping () -> Void) {
        guard !busy, Store.shared.supports(state.id != 0 ? "update_project" : "create_project") else { return }
        var body: JSON
        switch state.body() {
        case .failure(let p): show(p); return    // the tab holding the field at fault comes up with the reason above it
        case .success(let b): body = b
        }
        let id = state.id
        if id != 0 { body["id"] = JSON(id) }
        saving = true
        Task {
            defer { saving = false }
            do {
                let r = try await Store.shared.call(id != 0 ? "update_project" : "create_project", body)
                let row = r["project"]
                guard row.isObject else { showError(settingsUnexpectedResponse); return }
                error = nil
                state.row = row
                state.fill()
                Self.refreshLists()
                done()
            } catch {
                showError(failure(error))
            }
        }
    }

    func delete(done: @escaping () -> Void) {
        guard state.id != 0, !busy else { return }
        deleting = true
        Task {
            defer { deleting = false }
            do {
                try await Store.shared.call("delete_project", ["id": JSON(state.id)])
                state.dirty = false
                Self.refreshLists()
                done()
            } catch {
                showError(failure(error))
            }
        }
    }

    /// What a clone starts from: what the form holds now, saved or not; the repository is unique, so without one.
    func cloneRow() -> JSON? {
        switch state.body() {
        case .failure(let p): show(p); return nil
        case .success(var copy):
            copy["repo"] = ""
            Self.openTab = .project
            return copy
        }
    }

    /// The settings list and the app's own projects list both show what changed.
    static func refreshLists() {
        Task {
            try? await SettingsLists.shared.loadProjects()
            try? await ProjectsModel.shared.load()
        }
    }
}

struct ProjectSettingsScreen: View {
    let row: JSON?
    let defaults: JSON?
    @StateObject private var model: ProjectFormModel
    @FocusState private var focus: ProjectField?
    @EnvironmentObject private var store: Store
    @Environment(\.navigate) private var navigate
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    init(row: JSON?, defaults: JSON?) {
        self.row = row
        self.defaults = defaults
        _model = StateObject(wrappedValue: ProjectFormModel(row: row, defaults: defaults))
    }

    private var state: ProjectFormState { model.state }

    var body: some View {
        if let why = settingsUnavailableReason("settings_projects", path: "settings/projects", what: "Project settings", manage: "projects") {
            SettingsUnavailableView(text: why).navigationTitle("Project")
        } else {
            form
        }
    }

    private var title: String {
        state.id != 0 ? state.row["label"].nonEmpty ?? state.row["repo"].nonEmpty ?? "Project" : "New project"
    }

    private var form: some View {
        let id = state.id
        return ScrollViewReader { proxy in
            Form {
                SettingsErrorSection(error: model.error)
                if id == 0 && model.tab == .project {
                    Section { EmptyView() } footer: { Text("A project is a repository a session can be started against.") }
                }
                tabContent
            }
            .safeAreaInset(edge: .top, spacing: 0) { tabStrip }
            .onChange(of: model.scrollToken) { _, _ in
                withAnimation { proxy.scrollTo(settingsErrorID, anchor: .top) }
            }
        }
        .modifier(SettingsFormChrome(
            title: title, dirty: model.state.dirty, discardMessage: model.discardMessage,
            saveTitle: "Save",
            canSave: !model.busy && (state.dirty || id == 0) && store.supports(id != 0 ? "update_project" : "create_project"),
            saving: model.saving, onSave: { focus = nil; model.save { dismiss() } },
            cloneTitle: "Clone into a new project",
            onClone: id != 0 && store.supports("create_project") ? { if let copy = model.cloneRow() { navigate(.projectSettings(row: copy, defaults: nil)) } } : nil,
            deleteTitle: "Delete project",
            onDelete: id != 0 && store.supports("delete_project") ? { confirmDelete = true } : nil))
        .confirmationDialog("Delete \(state.row["repo"].nonEmpty ?? "this project")?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { model.delete { dismiss() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sessions already started against it keep their history, but no new one can be.")
        }
        .onAppear {
            model.loadRuntimes()
            if let f = model.focusFirst {
                model.focusFirst = nil
                DispatchQueue.main.async { focus = f }
            }
        }
    }

    /// The tabs as a strip of chips under the bar: six do not fit a segmented control on a phone.
    private var tabStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ProjectTab.allCases, id: \.self) { t in
                        let on = model.tab == t
                        Button {
                            focus = nil
                            model.tab = t
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: Self.symbol(t)).font(.caption)
                                Text(t.title).font(.subheadline.weight(on ? .semibold : .regular))
                                if model.tabDot(t) { Circle().fill(Theme.accent).frame(width: 6, height: 6) }
                            }
                            .padding(.horizontal, 12).frame(minHeight: 34)
                            .foregroundStyle(on ? Color.white : .primary)
                            .background(on ? Theme.accent : Theme.surface, in: Capsule())
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .id(t)
                        .accessibilityAddTraits(on ? .isSelected : [])
                        .accessibilityValue(model.tabDot(t) ? "Unsaved changes" : "")
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            .onChange(of: model.tab) { _, t in withAnimation { proxy.scrollTo(t, anchor: .center) } }
            .onAppear { proxy.scrollTo(model.tab, anchor: .center) }
        }
        .background(Theme.background)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 0.5) }
    }

    static func symbol(_ t: ProjectTab) -> String {
        switch t {
        case .project: return "folder"
        case .database: return "cylinder.split.1x2"
        case .review: return "magnifyingglass"
        case .orchestrator: return "point.3.connected.trianglepath.dotted"
        case .env: return "doc.text"
        case .run: return "play"
        }
    }

    // MARK: Tabs

    @ViewBuilder private var tabContent: some View {
        switch model.tab {
        case .project:
            Section { field(.repo); field(.label); field(.localDir) }.listRowBackground(Theme.row)
            Section { field(.setup); field(.php) } header: { Text("Setup") } footer: {
                Text("This project's own prompt wording is kept on the server; saving here keeps it as it is.")
            }
            .listRowBackground(Theme.row)
        case .database:
            Section { field(.dbName); field(.dbExt) }.listRowBackground(Theme.row)
            Section { check(.dbPool); field(.dbRestore) } header: { Text("Database pool") }.listRowBackground(Theme.row)
        case .review:
            Section { field(.reviewAuthor) }.listRowBackground(Theme.row)
            if state.offered(.review) {
                Section { runtime(.review) } header: { Text("Runtime") }.listRowBackground(Theme.row)
            }
            Section { field(.publish) }.listRowBackground(Theme.row)
            // Each step runs as a turn of its own, on the code review's runtime unless it names one; a step switched off has none.
            Section {
                check(.testSheet)
                if state.bool(.testSheet) { runtime(.testSheet) }
            } header: { Text("Test sheet") }
            .listRowBackground(Theme.row)
            Section {
                check(.testRun)
                if state.bool(.testRun) { runtime(.testRun) }
            } header: { Text("Test run") }
            .listRowBackground(Theme.row)
            Section { field(.qaNotes); field(.sheetSteps); field(.feedbackSteps) } header: { Text("Prompts") }.listRowBackground(Theme.row)
        case .orchestrator:
            Section {
                runtime(.worker)
                field(.budget)
            } footer: {
                Text("The orchestrator's standing instructions for this project live on the server, in its “Orchestrator instructions” template.")
            }
            .listRowBackground(Theme.row)
            Section { check(.isSelf) } footer: {
                Text("Tick it on the repository whose code is running right now, and on no other. An orchestrator on any project that finds a flaw in the tooling running it (a briefing, a worker tool, a loop) can then send a fix worker here, review loop armed, and merge its pull request once the loop approves and the checks are green. The running server keeps its code until you redeploy.")
            }
            .listRowBackground(Theme.row)
        case .env:
            Section { field(.env) }.listRowBackground(Theme.row)
        case .run:
            Section { field(.run); field(.profiles) }.listRowBackground(Theme.row)
        }
    }

    @ViewBuilder private func field(_ f: ProjectField) -> some View {
        if state.offered(f) {
            SettingsTextRow(def: f.def, text: model.binding(f), enabled: state.enabled(f), focus: $focus, key: f)
        }
    }

    @ViewBuilder private func check(_ f: ProjectField) -> some View {
        if state.offered(f) {
            Toggle(isOn: model.toggle(f)) { Text(f.def.label) }.tint(Theme.accent)
        }
    }

    /// Provider, model and effort, one picker each; the model and effort follow the provider.
    @ViewBuilder private func runtime(_ r: ProjectRuntime) -> some View {
        if state.offered(r) {
            let p = state.pick(r)
            let catalog = model.catalog
            let current = catalog?.provider(p.providerId)
            Picker(r.providerLabel, selection: model.providerBinding(r)) {
                Text(r.none).tag(0)
                ForEach(catalog?.providers ?? [], id: \.id) { o in
                    // An unavailable provider is listed but only stays picked; a provider the list no longer carries
                    // stays picked rather than collapsing to the first choice.
                    if o.isAvailable || o.id == p.providerId {
                        Text(o.isAvailable ? o.label : "\(o.label) (unavailable)").tag(o.id)
                    }
                }
                if p.providerId != 0 && current == nil {
                    Text(state.pickText(r, part: 0, catalog: catalog)).tag(p.providerId)
                }
            }
            if p.providerId != 0 {
                let models = current?.models ?? []
                if models.isEmpty {
                    LabeledContent("Model", value: catalog == nil ? "Loading the providers…" : state.pickText(r, part: 1, catalog: catalog))
                } else {
                    Picker("Model", selection: model.modelBinding(r)) {
                        ForEach(models, id: \.id) { m in Text(m.title).tag(m.id) }
                        if !models.contains(where: { $0.id == (p.model ?? "") }) { Text(p.model.flatMap { $0.isEmpty ? nil : $0 } ?? "—").tag(p.model ?? "") }
                    }
                }
                let efforts = catalog?.efforts(for: RuntimeChoice(providerId: p.providerId, model: p.model, effort: p.effort)) ?? []
                if efforts.isEmpty {
                    LabeledContent("Effort", value: catalog == nil ? "Loading the providers…" : (p.effort ?? "").isEmpty ? "This model takes no effort" : p.effort!)
                } else {
                    Picker("Effort", selection: model.effortBinding(r)) {
                        ForEach(efforts, id: \.self) { Text($0).tag($0) }
                        if !efforts.contains(p.effort ?? "") { Text((p.effort ?? "").isEmpty ? "—" : p.effort!).tag(p.effort ?? "") }
                    }
                }
            }
        }
    }
}
