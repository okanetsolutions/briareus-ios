// One provider's settings, as the Mac's provider form on a phone: Provider, Models and, once saved, Status on a
// segmented control over the form, saved through /settings/providers. A provider is one login or endpoint of one CLI;
// its login happens in the browser and its connection and quota are read from the server.
import SwiftUI

@MainActor
private final class ProviderFormModel: ObservableObject {
    /// The open tab stays open from one provider to the next.
    static var openTab: ProviderTab = .provider
    /// After a device login is started, the status is read again this long after it, then after each next wait.
    static let loginWaits: [TimeInterval] = [10, 30, 60, 120]

    @Published var state: ProviderFormState
    @Published var tab: ProviderTab { didSet { Self.openTab = tab } }
    /// GET /settings/providers/{id}/status's `status`.
    @Published var status: JSON = .null
    @Published var statusError: String?
    @Published var statusLoading = false
    /// The read under way was asked with `fresh`.
    @Published var statusFresh = false
    @Published var testResult: String?
    @Published var testFailed = false
    @Published var testing = false
    /// codex's code to type on its confirm page.
    @Published var deviceCode: String?
    /// A claude login waits for the code its authorization page shows.
    @Published var codeWanted = false
    @Published var loginCode = ""
    @Published var loggingIn = false
    @Published var saving = false
    @Published var deleting = false
    @Published var error: String?
    @Published var scrollToken = 0
    /// A word after a login: its title and message.
    @Published var notice: (title: String, message: String)?
    /// Set to move the focus from the model (the login code box once a claude login opened the browser).
    @Published var focusRequest: ProviderField?
    let defaults: JSON?
    var focusFirst: ProviderField?
    private var statusTask: Task<Void, Never>?
    private var loginTimer: Task<Void, Never>?

    init(row: JSON?, defaults: JSON?) {
        // A saved row, a clone's values without an id, or a new provider from the server's defaults.
        let r: JSON = row?.isObject == true ? row! : defaults?.isObject == true ? defaults! : [:]
        let s = ProviderFormState(row: r)
        state = s
        self.defaults = defaults
        if s.id == 0 { focusFirst = .label; Self.openTab = .provider }
        tab = Self.openTab
    }
    deinit { loginTimer?.cancel(); statusTask?.cancel() }

    var busy: Bool { saving || deleting }
    /// Status is a saved provider's alone.
    var openTab: ProviderTab { tab == .status && state.id == 0 ? .provider : tab }

    func binding(_ f: ProviderField) -> Binding<String> {
        if f == .loginCode { return Binding(get: { self.loginCode }, set: { self.loginCode = $0 }) }
        return Binding(get: { self.state.text(f) }, set: { v in
            guard v != self.state.text(f) else { return }
            self.state.texts[f] = v
            self.changed()
        })
    }
    var activeBinding: Binding<Bool> {
        Binding(get: { self.state.active }, set: { v in guard v != self.state.active else { return }; self.state.active = v; self.changed() })
    }
    var binaryBinding: Binding<String> {
        Binding(get: { self.state.binary }, set: { v in
            guard v != self.state.binary else { return }
            self.state.binary = v
            // Another CLI's login flow and probe verdict say nothing about this one.
            self.testResult = nil; self.deviceCode = nil; self.codeWanted = false
            self.changed()
        })
    }
    /// The Mode: an API token rather than the CLI's own login. Switching to Login drops the endpoint and its token when
    /// saved; switching back brings back what the boxes hold.
    var tokenBinding: Binding<Bool> {
        Binding(get: { self.state.token }, set: { v in
            guard v != self.state.token else { return }
            self.state.token = v
            self.testResult = nil
            self.changed()
        })
    }

    private func changed() { if !state.dirty { state.dirty = true } }
    var discardMessage: String {
        state.id != 0 ? "The changes to \(state.row["label"].nonEmpty ?? "this provider") have not been saved." : "The new provider has not been saved."
    }
    func tabDot(_ t: ProviderTab) -> Bool { state.dirty && state.tabChanged(t) }
    private func showError(_ text: String?) {
        guard let text else { return }
        error = text; scrollToken += 1
    }

    // MARK: Status, login and Test

    func loadStatus(fresh: Bool) {
        guard state.id != 0, Store.shared.supports("provider_status") else { return }
        statusTask?.cancel()
        var args: JSON = ["id": JSON(state.id)]
        if fresh { args["fresh"] = 1 }
        statusFresh = fresh
        statusLoading = true
        statusTask = Task { [weak self] in
            do {
                let r = try await Store.shared.call("provider_status", args)
                guard let self, !Task.isCancelled else { return }
                self.statusLoading = false
                self.status = r["status"]
                self.statusError = nil
                // A login that landed shows in the list's own login tag.
                if self.status["auth"]["loggedIn"].is(true) && self.deviceCode != nil {
                    self.deviceCode = nil
                    Task { try? await SettingsLists.shared.loadProviders() }
                }
            } catch {
                guard let self, !error.isCancellation else { return }
                self.statusLoading = false
                self.statusError = errorText(error)
            }
        }
    }

    func logIn(open: @escaping (URL) -> Void) {
        guard state.canLogIn, !loggingIn else { return }
        let claude = state.binary == "claude"
        let op = claude ? "provider_login_start" : "provider_login"
        guard Store.shared.supports(op) else { return }
        deviceCode = nil; codeWanted = false
        loggingIn = true
        Task {
            defer { loggingIn = false }
            do {
                let r = try await Store.shared.call(op, ["id": JSON(state.id)])
                error = nil
                let url = r["url"].nonEmpty.flatMap(URL.init(string:))
                if claude {
                    // claude.ai shows a code once approved; it comes back here to finish.
                    if let url { open(url); codeWanted = true; focusRequest = .loginCode }
                } else if url == nil {
                    notice = ("Already logged in", "This entry is already logged in.")
                    loadStatus(fresh: false)
                } else if let url {
                    // Device auth prints the URL and waits, so the app opens it; the status is read again a few times to
                    // catch the login.
                    open(url)
                    deviceCode = r["deviceCode"].nonEmpty
                    startLoginTimer()
                }
            } catch {
                showError(failure(error))
            }
        }
    }
    private func startLoginTimer() {
        loginTimer?.cancel()
        loginTimer = Task { [weak self] in
            var previous: TimeInterval = 0
            for (i, wait) in Self.loginWaits.enumerated() {
                try? await Task.sleep(nanoseconds: UInt64((wait - previous) * 1_000_000_000))
                previous = wait
                guard let self, !Task.isCancelled else { return }
                self.loadStatus(fresh: false)
                if i + 1 >= Self.loginWaits.count || self.deviceCode == nil { return }
            }
        }
    }

    func finishLogin() {
        guard codeWanted, !loggingIn, Store.shared.supports("provider_login_finish") else { return }
        let code = loginCode.cTrimmed
        guard !code.isEmpty else { showError("Paste the code from the browser first."); return }
        loggingIn = true
        Task {
            defer { loggingIn = false }
            do {
                let r = try await Store.shared.call("provider_login_finish", ["id": JSON(state.id), "code": .string(code)])
                let row = r["provider"]
                guard row.isObject else { showError(settingsUnexpectedResponse); return }
                error = nil
                codeWanted = false
                loginCode = ""
                // The saved row now carries its login; the form keeps any change not saved yet.
                state.row["hasLogin"] = true
                if let dir = row["loginDir"].string { state.row["loginDir"] = .string(dir) }
                loadStatus(fresh: false)
                Task { try? await SettingsLists.shared.loadProviders() }
                notice = ("Logged in", "\(row["label"].nonEmpty ?? "The provider") is logged in.")
            } catch {
                showError(failure(error))
            }
        }
    }

    func test() {
        guard !testing, Store.shared.supports("test_provider") else { return }
        var args: JSON = ["binary": .string(state.binary), "baseUrl": .string(state.fieldNow(.baseUrl)), "apiKey": .string(state.text(.apiKey)),
                          "defaultModel": .string(state.fieldNow(.defaultModel)),
                          "models": JSON(SettingsText.list(from: state.fieldNow(.models)))]
        // The saved row's id lets the server probe as the model it resolves for it.
        if state.id != 0 { args["id"] = JSON(state.id) }
        testResult = "Testing…"; testFailed = false
        testing = true
        Task {
            defer { testing = false }
            do {
                let r = try await Store.shared.call("test_provider", args)
                testFailed = false
                // The endpoint's own model list goes into the Models box, unsaved, so a bad list is one discard away.
                let result = ProviderStatusText.testResult(r, modelsNow: state.fieldNow(.models))
                if let models = result.models, models != state.text(.models) { state.texts[.models] = models; changed() }
                testResult = result.text
            } catch {
                guard let text = failure(error) else { testResult = nil; return }
                testFailed = true
                testResult = text
            }
        }
    }

    // MARK: Saving, cloning, deleting

    func save(done: @escaping () -> Void) {
        guard !busy, Store.shared.supports(state.id != 0 ? "update_provider" : "create_provider") else { return }
        var body: JSON
        switch state.body() {
        case .failure(let p):
            tab = ProviderTab(rawValue: p.tab) ?? .provider
            showError(p.message)
            return
        case .success(let b): body = b
        }
        let id = state.id
        if id != 0 { body["id"] = JSON(id) }
        saving = true
        Task {
            defer { saving = false }
            do {
                let r = try await Store.shared.call(id != 0 ? "update_provider" : "create_provider", body)
                let row = r["provider"]
                guard row.isObject else { showError(settingsUnexpectedResponse); return }
                error = nil
                state.row = row
                state.fill()
                Task { try? await SettingsLists.shared.loadProviders() }
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
                try await Store.shared.call("delete_provider", ["id": JSON(state.id)])
                state.dirty = false
                Task { try? await SettingsLists.shared.loadProviders() }
                done()
            } catch {
                showError(failure(error))
            }
        }
    }

    /// What a clone starts from: what the form holds now, saved or not, without its label, which is typed first.
    func cloneRow() -> JSON? {
        guard case .success(var copy) = state.body(validate: false) else { return nil }
        copy["label"] = ""
        Self.openTab = .provider
        return copy
    }
}

struct ProviderSettingsScreen: View {
    let row: JSON?
    let defaults: JSON?
    @StateObject private var model: ProviderFormModel
    @FocusState private var focus: ProviderField?
    @EnvironmentObject private var store: Store
    @Environment(\.navigate) private var navigate
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var confirmDelete = false
    @State private var copied = false

    init(row: JSON?, defaults: JSON?) {
        self.row = row
        self.defaults = defaults
        _model = StateObject(wrappedValue: ProviderFormModel(row: row, defaults: defaults))
    }

    private var state: ProviderFormState { model.state }

    var body: some View {
        if store.supports("settings_providers") {
            form
        } else {
            SettingsUnavailableView(text: "Provider settings need an Admin token on a server that offers them (GET /settings/providers).")
                .navigationTitle("Provider")
        }
    }

    private var form: some View {
        let id = state.id
        return ScrollViewReader { proxy in
            Form {
                Section {
                    Picker("Section", selection: Binding(get: { model.openTab }, set: { focus = nil; model.tab = $0 })) {
                        ForEach(ProviderTab.allCases.filter { $0 != .status || id != 0 }, id: \.self) { t in
                            Text(settingsTabTitle(t.title, changed: model.tabDot(t))).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                } footer: {
                    if id == 0 { Text("A provider is a login or endpoint sessions can be started on.") }
                    else { Text("Runs the \(ProviderFormState.rowBinary(state.row)) CLI.") }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                SettingsErrorSection(error: model.error)
                switch model.openTab {
                case .provider: providerTab
                case .models: modelsTab
                case .status: statusTab
                }
            }
            .onChange(of: model.scrollToken) { _, _ in withAnimation { proxy.scrollTo(settingsErrorID, anchor: .top) } }
        }
        .refreshable { model.loadStatus(fresh: false) }
        .modifier(SettingsFormChrome(
            title: id != 0 ? state.row["label"].nonEmpty ?? "Provider" : "New provider",
            dirty: state.dirty, discardMessage: model.discardMessage, saveTitle: "Save",
            canSave: !model.busy && (state.dirty || id == 0) && store.supports(id != 0 ? "update_provider" : "create_provider"),
            saving: model.saving, onSave: { focus = nil; model.save { dismiss() } },
            cloneTitle: "Clone into a new provider",
            onClone: id != 0 && store.supports("create_provider") ? { if let copy = model.cloneRow() { navigate(.providerSettings(row: copy, defaults: nil)) } } : nil,
            deleteTitle: "Delete provider",
            onDelete: id != 0 && store.supports("delete_provider") ? { confirmDelete = true } : nil))
        .confirmationDialog("Delete \(state.row["label"].nonEmpty ?? "this provider")?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { model.delete { dismiss() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sessions already run on it keep their history, but no new one can be started on it.")
        }
        .alert(model.notice?.title ?? "", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.notice?.message ?? "")
        }
        .onAppear {
            if id != 0 && !model.status.isObject && !model.statusLoading { model.loadStatus(fresh: false) }
            if let f = model.focusFirst {
                model.focusFirst = nil
                DispatchQueue.main.async { focus = f }
            }
        }
        .onChange(of: model.focusRequest) { _, f in
            guard let f else { return }
            model.focusRequest = nil
            DispatchQueue.main.async { focus = f }
        }
    }

    // MARK: Provider

    @ViewBuilder private var providerTab: some View {
        Section {
            Toggle("Active: new sessions may start on this provider", isOn: model.activeBinding).tint(Theme.accent)
            field(.label)
            Picker("Binary", selection: model.binaryBinding) {
                ForEach(ProviderFormState.binaries, id: \.id) { b in Text(b.title).tag(b.id) }
                if !ProviderFormState.binaries.contains(where: { $0.id == state.binary }) {
                    Text(ProviderFormState.binaryTitle(state.binary)).tag(state.binary)
                }
            }
        }
        .listRowBackground(Theme.row)
        connection
    }

    /// Under the label and binary: the mode, then the login, or the endpoint with its token and Test.
    @ViewBuilder private var connection: some View {
        Section {
            if ProviderFormState.modeOffered(state.binary) {
                Picker("Mode", selection: model.tokenBinding) {
                    Text("Login").tag(false)
                    Text("API token").tag(true)
                }
            }
            if state.usesToken {
                field(.baseUrl, hint: ProviderFormState.baseURLHint(state.binary))
                field(.apiKey, hint: ProviderFormState.apiKeyHint(state.binary))
            }
        } header: {
            Text("Connection")
        } footer: {
            if state.binary == "grok" {
                Text(inlineMarkdown("grok signs in with its own login; it takes no API token."))
            } else if state.binary == "opencode" {
                Text(inlineMarkdown("opencode authenticates with an API key per service and has no login of its own."))
            } else if !state.usesToken && state.id == 0 {
                Text("Save the provider first: its login is registered against the saved entry, so there is nothing to log in until one exists.")
            }
        }
        .listRowBackground(Theme.row)
        if state.usesToken {
            Section {
                Button(action: model.test) {
                    HStack(spacing: 8) {
                        if model.testing { ProgressView() }
                        Text(model.testing ? "Testing…" : "Test")
                    }
                }
                .disabled(model.testing || !store.supports("test_provider"))
                if let result = model.testResult, !model.testing { SettingsVerdict(text: result, ok: !model.testFailed) }
            } footer: {
                Text("Test probes the endpoint and token as the form holds them, no save needed, and puts the endpoint's models in the Models tab.")
            }
            .listRowBackground(Theme.row)
        } else if state.id != 0 {
            login
        }
    }

    @ViewBuilder private var login: some View {
        let supported = store.supports(state.binary == "claude" ? "provider_login_start" : "provider_login")
        Section {
            headline
            Button {
                model.logIn { openURL($0) }
            } label: {
                HStack(spacing: 8) {
                    if model.loggingIn { ProgressView() }
                    Text(model.loggingIn ? "Logging in…" : "Log in")
                }
            }
            .disabled(!supported || model.loggingIn)
            if let code = model.deviceCode {
                // codex's confirm page asks for the code its hidden CLI printed.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Enter this code on the page that opened; the login is picked up automatically.").font(.subheadline)
                    HStack {
                        Text(code).font(.system(.title3, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                        Spacer()
                        Button {
                            Pasteboard.copy(code); copied = true
                            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                        } label: {
                            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.vertical, 2)
            }
            if model.codeWanted && state.canLogIn {
                field(.loginCode) { model.finishLogin() }
                Button("Finish") { focus = nil; model.finishLogin() }
                    .fontWeight(.semibold)
                    .disabled(model.loggingIn || !store.supports("provider_login_finish"))
            }
        } header: {
            Text("Login")
        } footer: {
            if model.codeWanted && state.canLogIn {
                Text("Approve in the browser, then paste the code it shows here.")
            } else {
                Text(state.binary == "claude"
                     ? "The login happens in the browser: approve on claude.ai, then paste the code it shows back here."
                     : "The login happens in the browser: the server runs the CLI's device login and picks it up once approved.")
            }
        }
        .listRowBackground(Theme.row)
    }

    /// The connection at a glance: a dot and a sentence.
    @ViewBuilder private var headline: some View {
        if let h = ProviderStatusText.headline(model.status) {
            HStack(spacing: 10) {
                Circle().fill(h.dot == "failed" ? Theme.danger : h.dot == "idle" ? Theme.success : Color.secondary)
                    .frame(width: 8, height: 8).accessibilityHidden(true)
                Text(h.text).font(.subheadline.weight(.medium)).textSelection(.enabled)
            }
        } else if let error = model.statusError {
            ErrorNotice(message: error)
        } else {
            HStack(spacing: 10) { ProgressView(); Text("Checking the connection…").foregroundStyle(.secondary) }
        }
    }

    // MARK: Models

    @ViewBuilder private var modelsTab: some View {
        Section {
            field(.models, hint: "One model per line; empty offers the CLI's own list.")
            field(.efforts, hint: "One effort per line; empty offers the CLI's own.")
        }
        .listRowBackground(Theme.row)
        Section { field(.defaultModel); field(.defaultEffort) } header: { Text("Defaults") }.listRowBackground(Theme.row)
    }

    // MARK: Status

    /// Who the provider is logged in as, its plan, where its CLI lives, and the quota windows its plan meters.
    @ViewBuilder private var statusTab: some View {
        Section {
            headline
            if model.status.isObject {
                ForEach(Array(ProviderStatusText.rows(model.status).enumerated()), id: \.offset) { _, r in
                    SettingsValueRow(label: r.label, value: r.value, mono: r.mono)
                }
            }
        }
        .listRowBackground(Theme.row)
        if model.status.isObject {
            // Which windows a plan meters is the provider's call, so the bars wear the labels that came with them.
            let windows = model.status["usage"]["windows"].items
            Section("Usage") {
                ForEach(Array(windows.enumerated()), id: \.offset) { _, win in
                    ProviderQuotaBar(window: ProviderStatusText.window(win))
                }
                if windows.isEmpty {
                    Text(model.status["usage"]["error"].nonEmpty ?? "Usage unavailable: this account’s meter could not be read or is not supported.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .listRowBackground(Theme.row)
        }
        Section {
            Button {
                model.loadStatus(fresh: true)
            } label: {
                HStack(spacing: 8) {
                    if model.statusLoading && model.statusFresh { ProgressView() }
                    Text(model.statusLoading && model.statusFresh ? "Checking usage…" : "Check usage")
                }
            }
            .disabled(model.statusLoading || !store.supports("provider_status"))
        } footer: {
            Text("Check usage reads the account and its quota again rather than the server's last answer.")
        }
        .listRowBackground(Theme.row)
    }

    // MARK: Fields

    private func field(_ f: ProviderField, hint: String? = nil, onSubmit: (() -> Void)? = nil) -> some View {
        SettingsTextRow(def: f.def, text: model.binding(f), hint: hint, rich: true, focus: $focus, key: f, onSubmit: onSubmit)
    }
}

/// A quota window: its label and how much is used, over a bar filled green, amber past 70% and red past 90%.
private struct ProviderQuotaBar: View {
    var window: (label: String, right: String, pct: Double)
    var body: some View {
        let pct = min(max(window.pct, 0), 100)
        let color = pct >= 90 ? Theme.danger : pct >= 70 ? Theme.warning : Theme.success
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label).font(.subheadline)
                Spacer(minLength: 8)
                Text(window.right).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
            ProgressView(value: pct, total: 100).tint(color)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
