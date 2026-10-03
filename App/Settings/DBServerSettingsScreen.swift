// One server of the database pool, as the Mac's database server form on a phone: Server (where it is, how sessions
// sign in to it, and Test connection) and Pool on a segmented control. Saved through /settings/db-servers, which needs
// an Admin token as the project routes do.
import SwiftUI

@MainActor
private final class DBServerFormModel: ObservableObject {
    /// The open tab stays open from one server to the next, as the project form's does.
    static var openTab: DBServerTab = .server
    /// The box a clone opens on: its port, since host:port is unique in the pool.
    static var pendingFocus: DBServerField?

    @Published var state: DBServerFormState
    @Published var tab: DBServerTab { didSet { Self.openTab = tab } }
    @Published var saving = false
    @Published var deleting = false
    @Published var testing = false
    /// What the last Test connection said, green when the server answered.
    @Published var testText: String?
    @Published var testOK = false
    @Published var error: String?
    @Published var scrollToken = 0
    let defaults: JSON?
    var focusFirst: DBServerField?

    init(row: JSON?, defaults: JSON?) {
        let r: JSON = row?.isObject == true ? row! : defaults?.isObject == true ? defaults! : [:]
        let s = DBServerFormState(row: r)
        state = s
        self.defaults = defaults
        // A new server starts where its host is typed.
        if s.id == 0 { focusFirst = .host; Self.openTab = .server }
        if let f = Self.pendingFocus { focusFirst = f; Self.pendingFocus = nil }
        tab = Self.openTab
    }

    var busy: Bool { saving || deleting }

    func binding(_ f: DBServerField) -> Binding<String> {
        Binding(get: { self.state.text(f) }, set: { v in
            // The port box takes digits only, five at most, as its edit does.
            let value = f == .port ? String(v.filter { $0.isASCII && $0.isNumber }.prefix(5)) : v
            guard value != self.state.text(f) else { return }
            self.state.texts[f] = value
            self.changed()
        })
    }
    var enabledBinding: Binding<Bool> {
        Binding(get: { self.state.enabled }, set: { v in guard v != self.state.enabled else { return }; self.state.enabled = v; self.changed() })
    }

    private func changed() { if !state.dirty { state.dirty = true } }
    var discardMessage: String {
        state.id != 0 ? "The changes to \(state.row["label"].nonEmpty ?? "this server") have not been saved." : "The new database server has not been saved."
    }
    func tabDot(_ t: DBServerTab) -> Bool { state.dirty && state.tabChanged(t) }
    private func showError(_ text: String?) {
        guard let text else { return }
        error = text; scrollToken += 1
    }

    func save(done: @escaping () -> Void) {
        guard !busy, Store.shared.supports(state.id != 0 ? "update_db_server" : "create_db_server") else { return }
        var body: JSON
        switch state.body() {
        // Only the port can be refused here, and it is on the Server tab.
        case .failure(let p): tab = .server; showError(p.message); return
        case .success(let b): body = b
        }
        let id = state.id
        if id != 0 { body["id"] = JSON(id) }
        saving = true
        Task {
            defer { saving = false }
            do {
                let r = try await Store.shared.call(id != 0 ? "update_db_server" : "create_db_server", body)
                let row = r["server"]
                guard row.isObject else { showError(settingsUnexpectedResponse); return }
                error = nil
                state.row = row
                state.fill()
                Task { try? await SettingsLists.shared.loadServers() }
                done()
            } catch {
                showError(failure(error))
            }
        }
    }

    /// Does this host answer with these credentials, and is a session on it right now? Probed on the form's values, so a
    /// new server can be checked before it is saved.
    func test() {
        guard !testing, Store.shared.supports("test_db_server") else { return }
        let body: JSON
        switch state.body() {
        case .failure(let p): testText = p.message; testOK = false; return
        case .success(let b): body = b
        }
        var args: JSON = [:]
        for k in ["host", "port", "username", "password"] where body.object?[k] != nil { args[k] = body[k] }
        if state.id != 0 { args["id"] = JSON(state.id) }
        testText = nil
        testing = true
        Task {
            defer { testing = false }
            do {
                let r = try await Store.shared.call("test_db_server", args)
                testOK = true
                testText = DBServerFormState.testText(r)
            } catch {
                guard let text = failure(error) else { return }
                testOK = false
                testText = text
            }
        }
    }

    func delete(done: @escaping () -> Void) {
        guard state.id != 0, !busy else { return }
        deleting = true
        Task {
            defer { deleting = false }
            do {
                try await Store.shared.call("delete_db_server", ["id": JSON(state.id)])
                state.dirty = false
                Task { try? await SettingsLists.shared.loadServers() }
                done()
            } catch {
                showError(failure(error))
            }
        }
    }

    /// What a clone starts from: host:port is unique in the pool, so the copy starts without a port; an empty label
    /// becomes host:port on save.
    func cloneRow() -> JSON? {
        switch state.body() {
        case .failure(let p): tab = .server; showError(p.message); return nil
        case .success(var copy):
            copy["label"] = ""
            copy["port"] = .null
            Self.openTab = .server
            Self.pendingFocus = .port
            return copy
        }
    }
}

struct DBServerSettingsScreen: View {
    let row: JSON?
    let defaults: JSON?
    @StateObject private var model: DBServerFormModel
    @ObservedObject private var lists = SettingsLists.shared
    @FocusState private var focus: DBServerField?
    @EnvironmentObject private var store: Store
    @Environment(\.navigate) private var navigate
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    init(row: JSON?, defaults: JSON?) {
        self.row = row
        self.defaults = defaults
        _model = StateObject(wrappedValue: DBServerFormModel(row: row, defaults: defaults))
    }

    private var state: DBServerFormState { model.state }

    var body: some View {
        if store.supports("settings_db_servers") {
            form
        } else {
            SettingsUnavailableView(text: "The database pool needs an Admin token on a server that offers it (GET /settings/db-servers).")
                .navigationTitle("Database server")
        }
    }

    private var form: some View {
        let id = state.id
        let address = DBServerFormState.address(state.row)
        return ScrollViewReader { proxy in
            Form {
                Section {
                    Picker("Section", selection: Binding(get: { model.tab }, set: { focus = nil; model.tab = $0 })) {
                        ForEach(DBServerTab.allCases, id: \.self) { t in Text(settingsTabTitle(t.title, changed: model.tabDot(t))).tag(t) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                } footer: {
                    Text(id != 0 ? "\(address) · a session claims this server for itself while it runs"
                                 : "A server sessions claim one at a time, each for a database of its own.")
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                SettingsErrorSection(error: model.error)
                switch model.tab {
                case .server: serverTab
                case .pool: poolTab
                }
            }
            .onChange(of: model.scrollToken) { _, _ in withAnimation { proxy.scrollTo(settingsErrorID, anchor: .top) } }
        }
        .modifier(SettingsFormChrome(
            title: id != 0 ? state.row["label"].nonEmpty ?? address : "New database server",
            dirty: state.dirty, discardMessage: model.discardMessage, saveTitle: "Save",
            canSave: !model.busy && (state.dirty || id == 0) && store.supports(id != 0 ? "update_db_server" : "create_db_server"),
            saving: model.saving, onSave: { focus = nil; model.save { dismiss() } },
            cloneTitle: "Clone into a new server",
            onClone: id != 0 && store.supports("create_db_server") ? { if let copy = model.cloneRow() { navigate(.dbServerSettings(row: copy, defaults: nil)) } } : nil,
            deleteTitle: "Remove from the pool",
            onDelete: id != 0 && store.supports("delete_db_server") ? { confirmDelete = true } : nil))
        .alert("Remove \(state.row["label"].nonEmpty ?? "this server") from the pool?", isPresented: $confirmDelete) {
            Button("Remove", role: .destructive) { model.delete { dismiss() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sessions can no longer claim it. Nothing on the server itself is touched.")
        }
        .onAppear {
            if let f = model.focusFirst {
                model.focusFirst = nil
                DispatchQueue.main.async { focus = f }
            }
        }
    }

    // MARK: Server

    @ViewBuilder private var serverTab: some View {
        Section {
            if state.has("enabled") {
                Toggle("In the pool: sessions may claim this server", isOn: model.enabledBinding).tint(Theme.accent)
            }
            field(.label)
            field(.host)
            field(.port)
        } footer: {
            Text("Host and port are unique in the pool. A label left empty is host:port.")
        }
        .listRowBackground(Theme.row)
        Section {
            field(.username)
            field(.password)
        } header: {
            Text("Login")
        } footer: {
            Text("The user sessions connect as. It needs the rights to create the databases its projects name.")
        }
        .listRowBackground(Theme.row)
        if store.supports("test_db_server") {
            Section {
                Button(action: model.test) {
                    HStack(spacing: 8) {
                        if model.testing { ProgressView() }
                        Text(model.testing ? "Connecting…" : "Test connection")
                    }
                }
                .disabled(model.testing)
                if let text = model.testText, !model.testing { SettingsVerdict(text: text, ok: model.testOK) }
            }
            .listRowBackground(Theme.row)
        }
    }

    // MARK: Pool

    /// The pool as a whole: how many sessions it lets open at once, and the projects that claim from it.
    @ViewBuilder private var poolTab: some View {
        Section {
            Text(DBServerFormState.poolText(capacity: lists.poolCapacity, total: lists.servers.list.count))
        } footer: {
            Text("One session holds a server at a time, so the pool is the session cap: as many sessions may be open at once as there are entries in it. The session's project decides which database name is used on it (created if missing); its setup commands are where migrations and seeding happen, on every session.")
        }
        .listRowBackground(Theme.row)
        let claiming = lists.projects.list.filter { $0["dbPoolEnabled"].is(true) }
        Section {
            ForEach(Array(claiming.enumerated()), id: \.offset) { _, p in
                let name = p["label"].nonEmpty ?? p["repo"].nonEmpty ?? "Project"
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name)
                        if let db = p["dbPoolDatabase"].nonEmpty {
                            Text("database \(db)").font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Projects that claim a server")
        } footer: {
            if claiming.isEmpty {
                Text("None yet. A project claims a server once “Give each session a database server of its own” is ticked on its Database tab.")
            }
        }
        .listRowBackground(Theme.row)
    }

    @ViewBuilder private func field(_ f: DBServerField) -> some View {
        if state.has(f.key) {
            SettingsTextRow(def: f.def, text: model.binding(f), focus: $focus, key: f)
        }
    }
}
