// An SSH server a project's agents may run commands on, as the web's form has it, across the whole pane with its fields
// two to a row. The SSH server tab: Label and Project, Host and Port, Username and Private key path, and the Permission
// mode beside "Available to sessions on this project". The Database tab, on a server that stores one: where the database
// listens as seen from the server, and the login for it, which the server keeps encrypted and opens only through
// GET …/db-credentials, read here when the tab is first shown. Saved through /settings/ssh/servers, which needs an Admin
// token.
import SwiftUI

@MainActor
final class SSHServerFormModel: ObservableObject {
    /// The open tab stays open from one server to the next, as the other settings forms' do.
    static var openTab: SSHServerTab = .server
    /// The box a clone opens on: its label.
    static var pendingFocus: SSHServerField?

    @Published var state: SSHServerFormState
    @Published var tab: SSHServerTab { didSet { Self.openTab = tab; if tab == .database { readLogin() } } }
    /// Reading the stored database login, and why the last read failed.
    @Published var readingLogin = false
    @Published var loginError: String?
    @Published var saving = false
    @Published var deleting = false
    @Published var error: String?
    @Published var scrollToken = 0
    let defaults: JSON?
    var focusFirst: SSHServerField?

    init(row: JSON?, defaults: JSON?) {
        let r: JSON = row?.isObject == true ? row! : defaults?.isObject == true ? defaults! : [:]
        // A new server starts on the first project, as the web's form does, and where its label is typed.
        let s = SSHServerFormState(row: r, firstRepo: SettingsModel.shared.projects.list.first?["repo"].nonEmpty,
                                   database: Store.shared.supports("ssh_server_db_credentials"))
        state = s
        self.defaults = defaults
        if s.id == 0 && row == nil { focusFirst = .label; Self.openTab = .server }
        if let f = Self.pendingFocus { focusFirst = f; Self.pendingFocus = nil; Self.openTab = f.tab }
        if !s.offersDatabase { Self.openTab = .server }
        tab = Self.openTab
        if tab == .database { readLogin() }
    }

    var busy: Bool { saving || deleting }
    func tabDot(_ t: SSHServerTab) -> Bool { state.dirty && state.tabChanged(t) }

    func binding(_ f: SSHServerField) -> Binding<String> {
        Binding(get: { self.state.text(f) }, set: { v in
            // The port boxes take digits only, five at most; the others up to 1024 characters, as their edits do.
            let value = f.def.kind == .number ? String(v.filter { $0.isASCII && $0.isNumber }.prefix(5)) : String(v.prefix(1024))
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
        let message = state.id != 0 ? "The changes to \(state.row["label"].nonEmpty ?? "this SSH server") have not been saved." : "The new SSH server has not been saved."
        let leave = confirmDiscard(message)
        if leave { state.dirty = false }
        return leave
    }
    private func showError(_ text: String) { error = text; scrollToken += 1 }

    /// The login stored on the server, opened, into its boxes; once, the first time the Database tab shows.
    func readLogin() {
        guard state.id != 0, state.offersDatabase, !state.loginKnown, !readingLogin,
              Store.shared.supports("ssh_server_db_credentials") else { return }
        let id = state.id
        loginError = nil
        readingLogin = true
        Task {
            defer { readingLogin = false }
            do {
                let r = try await Store.shared.call("ssh_server_db_credentials", ["id": .number(id)])
                guard state.id == id, !state.loginKnown else { return }
                guard r["credentials"].isObject else { loginError = unexpectedResponse; return }
                state.loginRead(r["credentials"])
            } catch {
                guard !error.isCancellation, state.id == id else { return }
                loginError = errorText(error)
            }
        }
    }

    /// The project picker, as a menu under the pointer. A project that is gone stays picked rather than being swapped for
    /// another; the server refuses it on save.
    func pickRepo() {
        let repos = SettingsModel.shared.projects.list.compactMap { $0["repo"].string }
        let now = state.repo
        var items = repos.map { PopupMenu.Item(title: $0, checked: $0 == now) }
        if !now.isEmpty && !repos.contains(now) { items.append(PopupMenu.Item(title: "\(now) (not a project)", checked: true, enabled: false)) }
        if repos.isEmpty && now.isEmpty { items.append(PopupMenu.Item(title: "No projects yet", enabled: false)) }
        guard let chosen = PopupMenu.choose(items), repos.indices.contains(chosen), repos[chosen] != now else { return }
        state.repo = repos[chosen]
        changed()
    }
    func pickMode() {
        let modes = ["ask", "allow"]
        guard let chosen = PopupMenu.choose(modes.map { PopupMenu.Item(title: SSHServerFormState.modeTitle($0), checked: $0 == state.mode) }),
              modes.indices.contains(chosen), modes[chosen] != state.mode else { return }
        state.mode = modes[chosen]
        changed()
    }

    func save() {
        let id = state.id
        guard !busy, Store.shared.supports(id != 0 ? "update_ssh_server" : "create_ssh_server") else { return }
        var body: JSON
        switch state.body() {
        case .failure(let p): tab = SSHServerTab(rawValue: p.tab) ?? .server; showError(p.message); return
        case .success(let b): body = b
        }
        if id != 0 { body["id"] = .number(id) }
        saving = true
        Task {
            defer { saving = false }
            do {
                let r = try await Store.shared.call(id != 0 ? "update_ssh_server" : "create_ssh_server", body)
                let row = r["server"]
                guard row.isObject else { showError(unexpectedResponse); return }
                // The server's word on what was saved: an empty label is now user@host:port, and a new server has an id.
                error = nil
                state.saved(row, sent: body)
                readLoginIfShown()
                post(.sshServersChanged)
                if id == 0 { Navigator.shared.show(.sshServerSettings(row: row, defaults: defaults)) }
            } catch {
                if !error.isCancellation { showError(errorText(error)) }
            }
        }
    }

    func delete() {
        guard state.id != 0, !busy else { return }
        let name = state.row["label"].nonEmpty ?? "this SSH server"
        guard Dialogs.confirm("Delete \(name)?", "Sessions lose access through the SSH tool and pending approvals are cancelled.",
                              continueLabel: "Delete", destructive: true) else { return }
        deleting = true
        Task {
            defer { deleting = false }
            do {
                _ = try await Store.shared.call("delete_ssh_server", ["id": .number(state.id)])
                state.dirty = false
                Navigator.shared.clear()
                post(.sshServersChanged)
            } catch {
                if !error.isCancellation { showError(errorText(error)) }
            }
        }
    }

    private func readLoginIfShown() { if tab == .database { readLogin() } }

    func clone() {
        let copy: JSON
        switch state.copy() {
        case .failure(let p): tab = SSHServerTab(rawValue: p.tab) ?? .server; showError(p.message); return
        case .success(let c): copy = c
        }
        // The copy carries what the form holds now, saved or not, its database login too, without the label that named
        // this one.
        state.dirty = false
        Self.pendingFocus = .label
        Navigator.shared.show(.sshServerSettings(row: copy, defaults: nil))
    }
}

struct SSHServerSettingsScreen: View {
    var row: JSON?
    var defaults: JSON?
    @StateObject private var model: SSHServerFormModel
    @FocusState private var focus: SSHServerField?
    @EnvironmentObject private var store: Store

    init(row: JSON?, defaults: JSON?) {
        self.row = row
        self.defaults = defaults
        _model = StateObject(wrappedValue: SSHServerFormModel(row: row, defaults: defaults))
    }

    private var state: SSHServerFormState { model.state }

    var body: some View {
        SettingsPage(header: header,
                     unavailable: settingsUnavailable("settings_ssh_servers", path: "settings/ssh/servers", what: "SSH servers", manage: "them"),
                     scrollToken: model.scrollToken) {
            // The Database tab only on a server that stores a database login with an SSH server.
            let tabs = state.offersDatabase ? SSHServerTab.allCases : [.server]
            SettingsTabs(tabs: tabs.map { t in
                SettingsTabs.Tab(id: t.rawValue, title: t.title, glyph: Glyph.symbol(t == .server ? 0xE968 : 0xE1D3), dot: model.tabDot(t))
            }, open: model.tab.rawValue) { t in
                focus = nil
                model.tab = SSHServerTab(rawValue: t) ?? .server
                model.scrollToken += 1
            }
            if let error = model.error { NoticeBox(message: error).padding(.bottom, 16) }
            switch model.tab {
            case .server: serverTab
            case .database: databaseTab
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

    // MARK: SSH server

    @ViewBuilder private var serverTab: some View {
        SettingsPair {
            field(.label)
        } right: {
            SettingsLabeledSelect(label: "Project", text: state.repo.isEmpty ? "Choose a project" : state.repo,
                                  hint: "Only this project's sessions see the server, through their SSH tool.") { model.pickRepo() }
        }
        SettingsPair { field(.host) } right: { field(.port) }
        SettingsPair { field(.username) } right: { field(.key) }
        SettingsPair {
            SettingsLabeledSelect(label: "Permission mode", text: SSHServerFormState.modeTitle(state.mode),
                                  hint: "Ask holds each command until it is approved. Don't ask anything sends every command immediately.") { model.pickMode() }
        } right: {
            // Level with the box beside it: below where its label sits, centred on its height.
            SettingsCheck(label: "Available to sessions on this project", on: state.enabled, height: 36) { model.toggle() }
                .padding(.top, SettingsFonts.footnoteLineHeight + 6).padding(.bottom, 14)
        }
        SettingsNote(text: "First verify the server's host key and add it to the Briareus account's known_hosts file. Unknown or changed host keys are refused. SSH configuration aliases and interactive commands are not supported.")
    }

    // MARK: Database

    /// Where the server's database listens and the login for it, for a client that tunnels to it over this server.
    @ViewBuilder private var databaseTab: some View {
        SettingsNote(text: "The database on this server, reached through an SSH tunnel over it. The login is stored encrypted on Briareus, never shown to agents, and read back only with an Admin token.")
        Color.clear.frame(height: 8)
        HStack(alignment: .top, spacing: 14) {
            field(.dbHost).frame(maxWidth: .infinity)
            field(.dbPort).frame(width: 140)
        }
        if model.readingLogin {
            SettingsNote(text: "Reading the stored login…")
        } else if let error = model.loginError {
            NoticeBox(message: "The stored login could not be read: \(error)").padding(.bottom, 16)
        }
        SettingsPair { field(.dbUsername, hint: loginHint(.dbUsername)) } right: { field(.dbPassword, hint: loginHint(.dbPassword)) }
    }

    /// What the login's help icons say once one is stored: how to replace it while it is not read, how to remove it once
    /// it is. Without one, the fields' own hints.
    private func loginHint(_ f: SSHServerField) -> String? {
        guard state.hasLogin else { return nil }
        if !state.loginKnown {
            return f == .dbUsername ? "A login is stored. Type a username to replace it; the stored password stays as it is."
                                    : "A password is stored. Type one to replace it; leave empty to keep it."
        }
        return f == .dbUsername ? "Empty it to remove the stored login, password and all." : nil
    }

    private var header: PaneHeader {
        let id = state.id
        var buttons: [HeaderButton] = []
        if store.supports("settings_ssh_servers") {
            buttons.append(HeaderButton(glyph: Glyph.symbol(0xE74E), label: model.saving ? "Saving…" : "Save", tip: "Save this SSH server (⌘S)",
                                        enabled: !model.busy && (state.dirty || id == 0) && store.supports(id != 0 ? "update_ssh_server" : "create_ssh_server"),
                                        prominent: true) { model.save() })
            if id != 0 {
                buttons.append(HeaderButton(glyph: Glyph.symbol(0xE8C8), tip: "Clone into a new SSH server",
                                            enabled: !model.busy && store.supports("create_ssh_server")) { model.clone() })
                buttons.append(HeaderButton(glyph: Glyph.symbol(0xE74D), tip: "Delete this SSH server",
                                            enabled: !model.busy && store.supports("delete_ssh_server"), destructive: true) { model.delete() })
            }
        }
        return id != 0
            ? PaneHeader(title: state.row["label"].nonEmpty ?? state.row["host"].nonEmpty ?? "SSH server", subtitle: SSHServerFormState.subtitle(state.row), buttons: buttons)
            : PaneHeader(title: "New SSH server", subtitle: "A server a project's agents may run commands on, with approval.", buttons: buttons)
    }

    private func field(_ f: SSHServerField, hint: String? = nil) -> some View {
        SettingsFieldBox(def: f.def, text: model.binding(f), hint: hint, focus: $focus, key: f) {
            let all = SSHServerField.on(f.tab)
            focus = all[((all.firstIndex(of: f) ?? 0) + 1) % all.count]
        }
    }
}
