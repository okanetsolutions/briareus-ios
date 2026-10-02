// One server of the database pool, as the Windows client's database server form, its fields on tabs along the top as the
// project form lays out its own: Server (where it is, how sessions sign in to it, and Test connection) and Pool. Saved
// through /settings/db-servers, which needs an Admin token as the project routes do.
import SwiftUI

@MainActor
final class DBServerFormModel: ObservableObject {
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
    func toggle() { state.enabled.toggle(); changed() }

    private func changed() {
        if !state.dirty { state.dirty = true }
        guardLeaving { [weak self] in self?.canLeave() ?? true }
    }
    func canLeave() -> Bool {
        guard state.dirty else { return true }
        let message = state.id != 0 ? "The changes to \(state.row["label"].nonEmpty ?? "this server") have not been saved." : "The new database server has not been saved."
        let leave = confirmDiscard(message)
        if leave { state.dirty = false }
        return leave
    }
    func tabDot(_ t: DBServerTab) -> Bool { state.dirty && state.tabChanged(t) }
    private func showError(_ text: String) { error = text; scrollToken += 1 }

    func save() {
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
                guard row.isObject else { showError(unexpectedResponse); return }
                // The server's word on what was saved: an empty label became host:port, and a new server now has an id.
                error = nil
                state.row = row
                state.fill()
                post(.settingsDBServersChanged, ["openFirst": false])
                if id == 0 { Navigator.shared.show(.dbServerSettings(row: row, defaults: defaults)) }
            } catch {
                if !error.isCancellation { showError(errorText(error)) }
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
                if error.isCancellation { return }
                testOK = false
                testText = errorText(error)
            }
        }
    }

    func delete() {
        guard state.id != 0, !busy else { return }
        let name = state.row["label"].nonEmpty ?? "this server"
        guard Dialogs.confirm("Remove \(name) from the pool?", "Sessions can no longer claim it. Nothing on the server itself is touched.",
                              continueLabel: "Remove", destructive: true) else { return }
        deleting = true
        Task {
            defer { deleting = false }
            do {
                _ = try await Store.shared.call("delete_db_server", ["id": JSON(state.id)])
                state.dirty = false
                Navigator.shared.clear()
                post(.settingsDBServersChanged, ["openFirst": true])
            } catch {
                if !error.isCancellation { showError(errorText(error)) }
            }
        }
    }

    func clone() {
        var copy: JSON
        switch state.body() {
        case .failure(let p): tab = .server; showError(p.message); return
        case .success(let b): copy = b
        }
        // host:port is unique in the pool, so the copy starts without a port; an empty label becomes host:port on save.
        copy["label"] = ""
        copy["port"] = .null
        state.dirty = false
        Self.openTab = .server
        Self.pendingFocus = .port
        Navigator.shared.show(.dbServerSettings(row: copy, defaults: nil))
    }
}

struct DBServerSettingsScreen: View {
    var row: JSON?
    var defaults: JSON?
    @StateObject private var model: DBServerFormModel
    @ObservedObject private var settings = SettingsModel.shared
    @FocusState private var focus: DBServerField?
    @EnvironmentObject private var store: Store

    init(row: JSON?, defaults: JSON?) {
        self.row = row
        self.defaults = defaults
        _model = StateObject(wrappedValue: DBServerFormModel(row: row, defaults: defaults))
    }

    private var state: DBServerFormState { model.state }

    var body: some View {
        SettingsPage(header: header,
                     unavailable: store.supports("settings_db_servers") ? nil
                        : "The database pool needs an Admin token on a server that offers it (GET /settings/db-servers).",
                     scrollToken: model.scrollToken) {
            SettingsTabs(tabs: DBServerTab.allCases.map { t in
                SettingsTabs.Tab(id: t.rawValue, title: t.title, glyph: Glyph.symbol(t == .server ? 0xE1D3 : 0xE716), dot: model.tabDot(t))
            }, open: model.tab.rawValue) { t in
                focus = nil
                model.tab = DBServerTab(rawValue: t) ?? .server
                model.scrollToken += 1
            }
            if let error = model.error { NoticeBox(message: error).padding(.bottom, 16) }
            switch model.tab {
            case .server: serverTab
            case .pool: poolTab
            }
        }
        .onAppear {
            if let f = model.focusFirst {
                model.focusFirst = nil
                DispatchQueue.main.async { focus = f }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveScreen)) { _ in model.save() }
    }

    private var header: PaneHeader {
        let id = state.id
        let address = DBServerFormState.address(state.row)
        var buttons: [HeaderButton] = []
        if store.supports("settings_db_servers") {
            buttons.append(HeaderButton(glyph: Glyph.symbol(0xE74E), label: model.saving ? "Saving…" : "Save", tip: "Save this server (⌘S)",
                                        enabled: !model.busy && (state.dirty || id == 0) && store.supports(id != 0 ? "update_db_server" : "create_db_server"),
                                        prominent: true) { model.save() })
            if id != 0 {
                buttons.append(HeaderButton(glyph: Glyph.symbol(0xE8C8), tip: "Clone into a new server",
                                            enabled: !model.busy && store.supports("create_db_server")) { model.clone() })
                buttons.append(HeaderButton(glyph: Glyph.symbol(0xE74D), tip: "Remove this server from the pool",
                                            enabled: !model.busy && store.supports("delete_db_server"), destructive: true) { model.delete() })
            }
        }
        return id != 0
            ? PaneHeader(title: state.row["label"].nonEmpty ?? address, subtitle: "\(address) · a session claims this server for itself while it runs", buttons: buttons)
            : PaneHeader(title: "New database server", subtitle: "A server sessions claim one at a time, each for a database of its own.", buttons: buttons)
    }

    // MARK: Server

    @ViewBuilder private var serverTab: some View {
        if state.has("enabled") {
            SettingsCheck(label: "In the pool: sessions may claim this server", on: state.enabled) { model.toggle() }.padding(.bottom, 10)
        }
        field(.label)
        HStack(alignment: .top, spacing: 14) {
            // The port's 140px stay its own even on a server whose rows carry none, as the C client's field_pair keeps them.
            field(.host).frame(maxWidth: .infinity)
            Group {
                if state.has(DBServerField.port.key) { field(.port) } else { Color.clear.frame(height: 0) }
            }
            .frame(width: 140)
        }
        SettingsNote(text: "Host and port are unique in the pool. A label left empty is host:port.")
        Color.clear.frame(height: 8)
        SettingsPair { field(.username) } right: { field(.password) }
        SettingsNote(text: "The user sessions connect as. It needs the rights to create the databases its projects name.")
        if store.supports("test_db_server") { testRow.padding(.bottom, 14) }
    }

    /// Test connection and what it last said beside it: one line when it fits, wrapped under the button when it does not.
    @ViewBuilder private var testRow: some View {
        let button = Button(model.testing ? "Connecting…" : "Test connection") { model.test() }.dashButton().disabled(model.testing)
        if let text = model.testText {
            let color = model.testOK ? Theme.ok : Theme.danger
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    button
                    Text(text).font(Theme.caption).foregroundStyle(color).lineLimit(1).fixedSize()
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 8) {
                    button
                    Text(text).font(Theme.caption).foregroundStyle(color).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
        } else {
            button
        }
    }

    // MARK: Pool

    /// The pool as a whole: how many sessions it lets open at once, and the projects that claim from it.
    @ViewBuilder private var poolTab: some View {
        SettingsNote(text: "One session holds a server at a time, so the pool is the session cap: as many sessions may be open at once as there are entries in it. The session's project decides which database name is used on it (created if missing); its setup commands are where migrations and seeding happen, on every session.")
        Text(DBServerFormState.poolText(capacity: settings.poolCapacity, total: settings.servers.list.count))
            .font(Theme.footnote).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 18)
        Text("Projects that claim a server").font(Theme.footnoteSemibold).foregroundStyle(Theme.ink).lineLimit(1).padding(.bottom, 8)
        let claiming = settings.projects.list.filter { $0["dbPoolEnabled"].is(true) }
        ForEach(Array(claiming.enumerated()), id: \.offset) { _, p in
            let name = p["label"].nonEmpty ?? p["repo"].nonEmpty ?? "Project"
            HStack(spacing: 8) {
                Image(systemName: Glyph.symbol(0xE8B7)).font(.system(size: 12)).foregroundStyle(Theme.ink)
                Text(p["dbPoolDatabase"].nonEmpty.map { "\(name) · database \($0)" } ?? name).font(Theme.footnote).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.tail)
            }
            .padding(.bottom, 4)
        }
        if claiming.isEmpty {
            SettingsNote(text: "None yet. A project claims a server once “Give each session a database server of its own” is ticked on its Database tab.")
        }
    }

    @ViewBuilder private func field(_ f: DBServerField) -> some View {
        if state.has(f.key) {
            SettingsFieldBox(def: f.def, text: model.binding(f), focus: $focus, key: f) { focus = next(after: f) }
        }
    }
    private func next(after f: DBServerField) -> DBServerField? {
        let order = DBServerField.allCases.filter { state.has($0.key) }
        guard let i = order.firstIndex(of: f) else { return f }
        return order[(i + 1) % order.count]
    }
}
