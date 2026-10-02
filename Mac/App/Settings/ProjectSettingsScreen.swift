// A project's settings across the whole pane, the Windows client's sections as tabs along the top (Project with its setup,
// Database, Code review, Orchestrator, Checkout .env, Run), saved through /settings/projects. A dot marks a tab with
// unsaved changes; the provider, model and effort pickers serve the code review, each errand step and the workers.
import SwiftUI

@MainActor
final class ProjectFormModel: ObservableObject {
    /// The open tab stays open from one project to the next, so comparing a setting across projects is one click each.
    static var openTab: ProjectTab = .project

    @Published var state: ProjectFormState
    @Published var tab: ProjectTab { didSet { Self.openTab = tab } }
    @Published var catalog: RuntimeCatalog?
    @Published var saving = false
    @Published var deleting = false
    @Published var error: String?
    @Published var scrollToken = 0
    let defaults: JSON?
    /// The field to focus once the form is up.
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
    func toggle(_ f: ProjectField) { state.bools[f] = !state.bool(f); changed() }

    private func changed() {
        if !state.dirty { state.dirty = true }
        guardLeaving { [weak self] in self?.canLeave() ?? true }
    }
    func canLeave() -> Bool {
        guard state.dirty else { return true }
        let message = state.id != 0 ? "The changes to \(state.row["label"].nonEmpty ?? "this project") have not been saved." : "The new project has not been saved."
        let leave = confirmDiscard(message)
        if leave { state.dirty = false }
        return leave
    }
    func tabDot(_ t: ProjectTab) -> Bool { state.dirty && state.tabChanged(t) }

    private func show(_ problem: FormProblem) {
        error = problem.message
        if let t = ProjectTab(rawValue: problem.tab) { tab = t }
        scrollToken += 1
    }
    private func showError(_ text: String) { error = text; scrollToken += 1 }

    // MARK: Runtimes

    /// The providers the pickers offer. The list is the server's for any project; it is asked with this one, or another.
    func loadRuntimes() {
        guard catalog == nil, runtimesTask == nil, Store.shared.supports("runtimes") else { return }
        var repo = state.row["repo"].nonEmpty
        if state.id == 0 || repo == nil {
            repo = ProjectsModel.shared.projects.first?.repo ?? SettingsModel.shared.projects.list.first?["repo"].nonEmpty
        }
        guard let repo else { return }
        runtimesTask = Task { [weak self] in
            let r = try? await Store.shared.call("runtimes", ["repo": .string(repo)])
            guard let self else { return }
            // A failed read is asked again the next time the form comes up, as the C client's cleared request is.
            self.runtimesTask = nil
            if let r, let c = RuntimeCatalog(r) { self.catalog = c }
        }
    }

    func pick(_ r: ProjectRuntime, part: Int) {
        var p = state.pick(r)
        let pr = catalog.flatMap { $0.provider(p.providerId) }
        if part == 0 {
            var items = [PopupMenu.Item(title: r.none, checked: p.providerId == 0)]
            let providers = catalog?.providers ?? []
            if !providers.isEmpty || (p.providerId != 0 && pr == nil) { items.append(.separatorItem) }
            for o in providers {
                items.append(PopupMenu.Item(title: o.isAvailable ? o.label : "\(o.label) (unavailable)", checked: o.id == p.providerId,
                                            enabled: o.isAvailable || o.id == p.providerId))
            }
            // A configured provider the list no longer carries stays picked rather than collapsing to the first choice.
            if p.providerId != 0 && pr == nil { items.append(PopupMenu.Item(title: "Provider #\(p.providerId) (unavailable)", checked: true, enabled: false)) }
            guard let chosen = PopupMenu.choose(items) else { return }
            if chosen == 0 {
                if p.providerId != 0 { state.picks[r] = RuntimePick(); changed() }
                return
            }
            let index = chosen - 2
            guard providers.indices.contains(index), providers[index].id != p.providerId else { return }
            // A new provider starts on its default model and that model's default effort.
            if let c = catalog?.choice(provider: providers[index].id) {
                state.picks[r] = RuntimePick(providerId: c.providerId, model: c.model, effort: c.effort)
                changed()
            }
        } else if part == 1 {
            let models = pr?.models ?? []
            var items = models.map { PopupMenu.Item(title: $0.title, checked: $0.id == p.model) }
            if models.isEmpty { items = [PopupMenu.Item(title: catalog != nil ? "No models listed" : "Loading the providers…", enabled: false)] }
            guard let chosen = PopupMenu.choose(items), models.indices.contains(chosen), models[chosen].id != p.model else { return }
            // The effort carries over when the new model offers it, else that model's default.
            let model = models[chosen]
            let efforts = model.efforts ?? []
            let effort = efforts.contains(p.effort ?? "\u{0}") ? p.effort : model.defaultEffort ?? efforts.first ?? ""
            p.model = model.id
            p.effort = effort
            state.picks[r] = p
            changed()
        } else {
            let efforts = catalog?.efforts(for: RuntimeChoice(providerId: p.providerId, model: p.model, effort: p.effort)) ?? []
            var items = efforts.map { PopupMenu.Item(title: $0, checked: $0 == p.effort) }
            if efforts.isEmpty { items = [PopupMenu.Item(title: catalog != nil ? "This model takes no effort" : "Loading the providers…", enabled: false)] }
            guard let chosen = PopupMenu.choose(items), efforts.indices.contains(chosen), efforts[chosen] != p.effort else { return }
            p.effort = efforts[chosen]
            state.picks[r] = p
            changed()
        }
    }

    // MARK: Saving, cloning, deleting

    func save() {
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
                guard row.isObject else { showError(unexpectedResponse); return }
                // The server's word on what was saved: it may have tidied a value, and a new project now has an id.
                error = nil
                state.row = row
                state.fill()
                post(.settingsProjectsChanged, ["select": row["id"].int32 ?? 0])
                post(.projectsChanged)
                if id == 0 { Navigator.shared.show(.projectSettings(row: row, defaults: defaults)) }
            } catch {
                if !error.isCancellation { showError(errorText(error)) }
            }
        }
    }

    func delete() {
        guard state.id != 0, !busy else { return }
        let name = state.row["repo"].nonEmpty ?? "this project"
        guard Dialogs.confirm("Delete \(name)?", "Sessions already started against it keep their history, but no new one can be.",
                              continueLabel: "Delete", destructive: true) else { return }
        deleting = true
        Task {
            defer { deleting = false }
            do {
                _ = try await Store.shared.call("delete_project", ["id": JSON(state.id)])
                // The list says the project is gone, and the sidebar opens the first one left in its place.
                state.dirty = false
                Navigator.shared.clear()
                post(.settingsProjectsChanged)
                post(.projectsChanged)
            } catch {
                if !error.isCancellation { showError(errorText(error)) }
            }
        }
    }

    func clone() {
        var copy: JSON
        switch state.body() {
        case .failure(let p): show(p); return
        case .success(let b): copy = b
        }
        // The copy carries what the form holds now, saved or not; the repository is unique, so it starts without one.
        copy["repo"] = ""
        state.dirty = false
        Self.openTab = .project
        Navigator.shared.show(.projectSettings(row: copy, defaults: nil))
    }
}

struct ProjectSettingsScreen: View {
    var row: JSON?
    var defaults: JSON?
    @StateObject private var model: ProjectFormModel
    @FocusState private var focus: ProjectField?
    @EnvironmentObject private var store: Store

    init(row: JSON?, defaults: JSON?) {
        self.row = row
        self.defaults = defaults
        _model = StateObject(wrappedValue: ProjectFormModel(row: row, defaults: defaults))
    }

    private var state: ProjectFormState { model.state }

    var body: some View {
        SettingsPage(header: header,
                     unavailable: settingsUnavailable("settings_projects", path: "settings/projects", what: "Project settings", manage: "projects"),
                     scrollToken: model.scrollToken) {
            SettingsTabs(tabs: ProjectTab.allCases.map { t in
                SettingsTabs.Tab(id: t.rawValue, title: t.title, glyph: Self.glyph(t), dot: model.tabDot(t))
            }, open: model.tab.rawValue) { t in
                // The focus leaves with the boxes of the tab that closes.
                focus = nil
                model.tab = ProjectTab(rawValue: t) ?? .project
                model.scrollToken += 1
            }
            if let error = model.error { NoticeBox(message: error).padding(.bottom, 16) }
            tabContent
        }
        .onAppear {
            // Asked once the screen is up.
            model.loadRuntimes()
            if let f = model.focusFirst {
                model.focusFirst = nil
                DispatchQueue.main.async { focus = f }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveScreen)) { _ in model.save() }
    }

    static func glyph(_ t: ProjectTab) -> String {
        switch t {
        case .project: return Glyph.symbol(0xE8B7)
        case .database: return Glyph.symbol(0xE1D3)
        case .review: return Glyph.symbol(0xE721)
        case .orchestrator: return Glyph.symbol(0xE716)
        case .env: return Glyph.symbol(0xE8D7)
        case .run: return Glyph.symbol(0xE768)
        }
    }

    private var header: PaneHeader {
        let label = state.row["label"].nonEmpty, repo = state.row["repo"].nonEmpty
        let id = state.id
        var buttons: [HeaderButton] = []
        if store.supports("settings_projects") {
            buttons.append(HeaderButton(glyph: Glyph.symbol(0xE74E), label: model.saving ? "Saving…" : "Save", tip: "Save this project (⌘S)",
                                        enabled: !model.busy && (state.dirty || id == 0) && store.supports(id != 0 ? "update_project" : "create_project"),
                                        prominent: true) { model.save() })
            if id != 0 {
                buttons.append(HeaderButton(glyph: Glyph.symbol(0xE8C8), tip: "Clone into a new project",
                                            enabled: !model.busy && store.supports("create_project")) { model.clone() })
                buttons.append(HeaderButton(glyph: Glyph.symbol(0xE74D), tip: "Delete this project",
                                            enabled: !model.busy && store.supports("delete_project"), destructive: true) { model.delete() })
            }
        }
        return id != 0
            ? PaneHeader(title: label ?? repo ?? "Project", subtitle: repo ?? "", buttons: buttons)
            : PaneHeader(title: "New project", subtitle: "A project is a repository a session can be started against.", buttons: buttons)
    }

    // MARK: Tabs

    @ViewBuilder private var tabContent: some View {
        switch model.tab {
        case .project:
            SettingsPair { field(.repo) } right: { field(.label) }
            field(.localDir)
            field(.setup)
            field(.php)
            SettingsNote(text: "This project's own prompt wording is kept on the server; saving here keeps it as it is.")
        case .database:
            field(.dbName)
            field(.dbExt)
            check(.dbPool)
            field(.dbRestore)
        case .review:
            HStack(alignment: .top, spacing: 14) {
                field(.reviewAuthor).frame(maxWidth: .infinity)
                Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
            }
            runtimeRow(.review)
            field(.publish)
            // Each step runs as a turn of its own, on the code review's runtime unless it names one; a step switched off has none.
            check(.testSheet)
            if state.bool(.testSheet) { runtimeRow(.testSheet).padding(.leading, 23) }
            check(.testRun)
            if state.bool(.testRun) { runtimeRow(.testRun).padding(.leading, 23) }
            Color.clear.frame(height: 4)
            field(.qaNotes)
            field(.sheetSteps)
            field(.feedbackSteps)
        case .orchestrator:
            runtimeRow(.worker)
            field(.budget)
            SettingsNote(text: "The orchestrator's standing instructions for this project live on the server, in its “Orchestrator instructions” template.")
            check(.isSelf)
            SettingsNote(text: "Tick it on the repository whose code is running right now, and on no other. An orchestrator on any project that finds a flaw in the tooling running it (a briefing, a worker tool, a loop) can then send a fix worker here, review loop armed, and merge its pull request once the loop approves and the checks are green. The running server keeps its code until you redeploy.")
        case .env:
            field(.env)
        case .run:
            field(.run)
            field(.profiles)
        }
    }

    @ViewBuilder private func field(_ f: ProjectField) -> some View {
        if state.offered(f) {
            SettingsFieldBox(def: f.def, text: model.binding(f), enabled: state.enabled(f), focus: $focus, key: f) { focus = next(after: f) }
        }
    }

    @ViewBuilder private func check(_ f: ProjectField) -> some View {
        if state.offered(f) {
            SettingsCheck(label: f.def.label, on: state.bool(f)) { model.toggle(f) }.padding(.bottom, 10)
        }
    }

    /// Provider, model and effort side by side, as the Windows client's `.runtime-row`.
    @ViewBuilder private func runtimeRow(_ r: ProjectRuntime) -> some View {
        if state.offered(r) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(0..<3, id: \.self) { part in
                    let enabled = part == 0 || state.pick(r).providerId != 0
                    VStack(alignment: .leading, spacing: 6) {
                        Text(part == 0 ? r.providerLabel : part == 1 ? "Model" : "Effort").font(Theme.footnote)
                            .foregroundStyle(enabled ? Theme.ink : Theme.muted).lineLimit(1)
                        SettingsSelect(text: state.pickText(r, part: part, catalog: model.catalog), enabled: enabled) { model.pick(r, part: part) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.bottom, 14)
        }
    }

    /// The next box laid out on the open tab and enabled, for Return in a one-line box.
    private func next(after f: ProjectField) -> ProjectField? {
        let order = ProjectField.allCases.filter { $0.tab == model.tab && $0.def.isEdit && state.offered($0) && state.enabled($0) }
        guard let i = order.firstIndex(of: f), !order.isEmpty else { return f }
        return order[(i + 1) % order.count]
    }
}
