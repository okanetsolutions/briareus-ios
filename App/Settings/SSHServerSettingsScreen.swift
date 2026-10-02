// An SSH server a project's agents may run commands on, as the Mac's form on a phone. The Server tab: label, project,
// host and port, username and private key path, the permission mode and whether sessions may use it. The Database tab,
// on a server that stores one: where the database listens as seen from the server, and the login for it, which the
// server keeps encrypted and opens only through GET …/db-credentials, read here when the tab first shows; a save sends
// only the half of the login that changed. Saved through /settings/ssh/servers, which needs an Admin token.
import SwiftUI

@MainActor
private final class SSHServerFormModel: ObservableObject {
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
        let s = SSHServerFormState(row: r, firstRepo: SettingsLists.shared.projects.list.first?["repo"].nonEmpty,
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
    var enabledBinding: Binding<Bool> {
        Binding(get: { self.state.enabled }, set: { v in guard v != self.state.enabled else { return }; self.state.enabled = v; self.changed() })
    }
    var repoBinding: Binding<String> {
        Binding(get: { self.state.repo }, set: { v in guard v != self.state.repo else { return }; self.state.repo = v; self.changed() })
    }
    var modeBinding: Binding<String> {
        Binding(get: { self.state.mode }, set: { v in guard v != self.state.mode else { return }; self.state.mode = v; self.changed() })
    }

    private func changed() { if !state.dirty { state.dirty = true } }
    var discardMessage: String {
        state.id != 0 ? "The changes to \(state.row["label"].nonEmpty ?? "this SSH server") have not been saved." : "The new SSH server has not been saved."
    }
    private func showError(_ text: String?) {
        guard let text else { return }
        error = text; scrollToken += 1
    }

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
                guard r["credentials"].isObject else { loginError = settingsUnexpectedResponse; return }
                state.loginRead(r["credentials"])
            } catch {
                guard state.id == id, let text = failure(error) else { return }
                loginError = text
            }
        }
    }

    func save(done: @escaping () -> Void) {
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
                guard row.isObject else { showError(settingsUnexpectedResponse); return }
                // The server's word on what was saved: an empty label is now user@host:port, and a new server has an id.
                error = nil
                state.saved(row, sent: body)
                Task { try? await SettingsLists.shared.loadSSH() }
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
                try await Store.shared.call("delete_ssh_server", ["id": .number(state.id)])
                state.dirty = false
                Task { try? await SettingsLists.shared.loadSSH() }
                done()
            } catch {
                showError(failure(error))
            }
        }
    }

    /// What a clone starts from: what the form holds now, saved or not, its database login too, without the label that
    /// named this one.
    func cloneRow() -> JSON? {
        switch state.copy() {
        case .failure(let p): tab = SSHServerTab(rawValue: p.tab) ?? .server; showError(p.message); return nil
        case .success(let copy):
            Self.pendingFocus = .label
            return copy
        }
    }
}

struct SSHServerSettingsScreen: View {
    let row: JSON?
    let defaults: JSON?
    @StateObject private var model: SSHServerFormModel
    @ObservedObject private var lists = SettingsLists.shared
    @FocusState private var focus: SSHServerField?
    @EnvironmentObject private var store: Store
    @Environment(\.navigate) private var navigate
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    init(row: JSON?, defaults: JSON?) {
        self.row = row
        self.defaults = defaults
        _model = StateObject(wrappedValue: SSHServerFormModel(row: row, defaults: defaults))
    }

    private var state: SSHServerFormState { model.state }

    var body: some View {
        if let why = settingsUnavailableReason("settings_ssh_servers", path: "settings/ssh/servers", what: "SSH servers", manage: "them") {
            SettingsUnavailableView(text: why).navigationTitle("SSH server")
        } else {
            form
        }
    }

    private var form: some View {
        let id = state.id
        return ScrollViewReader { proxy in
            Form {
                // The Database tab only on a server that stores a database login with an SSH server.
                if state.offersDatabase {
                    Section {
                        Picker("Section", selection: Binding(get: { model.tab }, set: { focus = nil; model.tab = $0 })) {
                            ForEach(SSHServerTab.allCases, id: \.self) { t in Text(settingsTabTitle(t.title, changed: model.tabDot(t))).tag(t) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    } footer: { subtitle }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } else {
                    Section { EmptyView() } footer: { subtitle }
                }
                SettingsErrorSection(error: model.error)
                switch state.offersDatabase ? model.tab : .server {
                case .server: serverTab
                case .database: databaseTab
                }
            }
            .onChange(of: model.scrollToken) { _, _ in withAnimation { proxy.scrollTo(settingsErrorID, anchor: .top) } }
        }
        .modifier(SettingsFormChrome(
            title: id != 0 ? state.row["label"].nonEmpty ?? state.row["host"].nonEmpty ?? "SSH server" : "New SSH server",
            dirty: state.dirty, discardMessage: model.discardMessage, saveTitle: "Save",
            canSave: !model.busy && (state.dirty || id == 0) && store.supports(id != 0 ? "update_ssh_server" : "create_ssh_server"),
            saving: model.saving, onSave: { focus = nil; model.save { dismiss() } },
            cloneTitle: "Clone into a new SSH server",
            onClone: id != 0 && store.supports("create_ssh_server") ? { if let copy = model.cloneRow() { navigate(.sshServerSettings(row: copy, defaults: nil)) } } : nil,
            deleteTitle: "Delete SSH server",
            onDelete: id != 0 && store.supports("delete_ssh_server") ? { confirmDelete = true } : nil))
        .confirmationDialog("Delete \(state.row["label"].nonEmpty ?? "this SSH server")?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { model.delete { dismiss() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sessions lose access through the SSH tool and pending approvals are cancelled.")
        }
        .onAppear {
            if let f = model.focusFirst {
                model.focusFirst = nil
                DispatchQueue.main.async { focus = f }
            }
        }
    }

    private var subtitle: Text {
        Text(state.id != 0 ? SSHServerFormState.subtitle(state.row) : "A server a project's agents may run commands on, with approval.")
    }

    // MARK: SSH server

    @ViewBuilder private var serverTab: some View {
        let repos = lists.projects.list.compactMap { $0["repo"].string }
        Section {
            field(.label)
            // A project that is gone stays picked rather than being swapped for another; the server refuses it on save.
            Picker(selection: model.repoBinding) {
                if state.repo.isEmpty { Text("Choose a project").tag("") }
                ForEach(repos, id: \.self) { Text($0).tag($0) }
                if !state.repo.isEmpty && !repos.contains(state.repo) { Text("\(state.repo) (not a project)").tag(state.repo) }
            } label: {
                SettingsLabel(label: "Project", hint: "Only this project's sessions see the server, through their SSH tool.")
            }
        }
        .listRowBackground(Theme.row)
        Section {
            field(.host)
            field(.port)
            field(.username)
            field(.key)
        } header: {
            Text("Connection")
        }
        .listRowBackground(Theme.row)
        Section {
            Picker(selection: model.modeBinding) {
                ForEach(["ask", "allow"], id: \.self) { Text(SSHServerFormState.modeTitle($0)).tag($0) }
            } label: {
                SettingsLabel(label: "Permission mode",
                              hint: "Ask shows the exact command in the dashboard for approval. Don't ask anything sends every command immediately.")
            }
            Toggle("Available to sessions on this project", isOn: model.enabledBinding).tint(Theme.accent)
        } footer: {
            Text("First verify the server's host key and add it to the Briareus account's known_hosts file. Unknown or changed host keys are refused. SSH configuration aliases and interactive commands are not supported.")
        }
        .listRowBackground(Theme.row)
    }

    // MARK: Database

    /// Where the server's database listens and the login for it, for a client that tunnels to it over this server.
    @ViewBuilder private var databaseTab: some View {
        Section {
            field(.dbHost)
            field(.dbPort)
        } footer: {
            Text("The database on this server, reached through an SSH tunnel over it. The login is stored encrypted on Briareus, never shown to agents, and read back only with an Admin token.")
        }
        .listRowBackground(Theme.row)
        Section {
            if model.readingLogin {
                HStack(spacing: 10) { ProgressView(); Text("Reading the stored login…").foregroundStyle(.secondary) }
            } else if let error = model.loginError {
                ErrorNotice(message: "The stored login could not be read: \(error)")
            }
            field(.dbUsername, hint: loginHint(.dbUsername))
            field(.dbPassword, hint: loginHint(.dbPassword))
        } header: {
            Text("Login")
        }
        .listRowBackground(Theme.row)
    }

    /// What the login's info buttons say once one is stored: how to replace it while it is not read, how to remove it
    /// once it is. Without one, the fields' own hints.
    private func loginHint(_ f: SSHServerField) -> String? {
        guard state.hasLogin else { return nil }
        if !state.loginKnown {
            return f == .dbUsername ? "A login is stored. Type a username to replace it; the stored password stays as it is."
                                    : "A password is stored. Type one to replace it; leave empty to keep it."
        }
        return f == .dbUsername ? "Empty it to remove the stored login, password and all." : nil
    }

    private func field(_ f: SSHServerField, hint: String? = nil) -> some View {
        SettingsTextRow(def: f.def, text: model.binding(f), hint: hint, focus: $focus, key: f)
    }
}
