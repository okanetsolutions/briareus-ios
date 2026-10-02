// One provider's settings, as the dashboard's provider form laid out as the project form is: tabs along the top (Provider,
// Models and, once saved, Status), saved through /settings/providers. A provider is one login or endpoint of one CLI; its
// login happens in the browser and its connection and quota are read from the server.
import SwiftUI

@MainActor
final class ProviderFormModel: ObservableObject {
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
    let defaults: JSON?
    var focusFirst: ProviderField?
    /// Set to move the focus from the model (the login code box once a claude login opened the browser).
    @Published var focusRequest: ProviderField?
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
    func toggleActive() { state.active.toggle(); changed() }

    private func changed() {
        if !state.dirty { state.dirty = true }
        guardLeaving { [weak self] in self?.canLeave() ?? true }
    }
    func canLeave() -> Bool {
        guard state.dirty else { return true }
        let message = state.id != 0 ? "The changes to \(state.row["label"].nonEmpty ?? "this provider") have not been saved." : "The new provider has not been saved."
        let leave = confirmDiscard(message)
        if leave { state.dirty = false }
        return leave
    }
    func tabDot(_ t: ProviderTab) -> Bool { state.dirty && state.tabChanged(t) }
    private func showError(_ text: String) { error = text; scrollToken += 1 }

    // MARK: Pickers

    func pickBinary() {
        let items = ProviderFormState.binaries.map { PopupMenu.Item(title: $0.title, checked: $0.id == state.binary) }
        guard let chosen = PopupMenu.choose(items), ProviderFormState.binaries[chosen].id != state.binary else { return }
        state.binary = ProviderFormState.binaries[chosen].id
        // Another CLI's login flow and probe verdict say nothing about this one.
        testResult = nil; deviceCode = nil; codeWanted = false
        changed()
    }
    func pickMode() {
        guard let chosen = PopupMenu.choose([PopupMenu.Item(title: "Login", checked: !state.token), PopupMenu.Item(title: "API token", checked: state.token)]),
              (chosen == 1) != state.token else { return }
        // Switching to Login drops the endpoint and its token when saved; switching back brings back what the boxes hold.
        state.token = chosen == 1
        testResult = nil
        changed()
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
                // A login that landed shows in the sidebar's own login tag.
                if self.status["auth"]["loggedIn"].is(true) && self.deviceCode != nil {
                    self.deviceCode = nil
                    post(.settingsProvidersChanged, ["openFirst": false])
                }
            } catch {
                guard let self, !error.isCancellation else { return }
                self.statusLoading = false
                self.statusError = errorText(error)
            }
        }
    }

    func logIn() {
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
                let url = r["url"].nonEmpty
                if claude {
                    // claude.ai shows a code once approved; it comes back here to finish.
                    if let url { openWebURL(url); codeWanted = true; focusRequest = .loginCode }
                } else if url == nil {
                    Dialogs.alert("Already logged in", "This entry is already logged in.")
                    loadStatus(fresh: false)
                } else {
                    // Device auth prints the URL and waits, so the app opens it; the status is read again a few times to
                    // catch the login.
                    openWebURL(url)
                    deviceCode = r["deviceCode"].nonEmpty
                    startLoginTimer()
                }
            } catch {
                if !error.isCancellation { showError(errorText(error)) }
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
        guard !code.isEmpty else { error = "Paste the code from the browser first."; return }
        loggingIn = true
        Task {
            defer { loggingIn = false }
            do {
                let r = try await Store.shared.call("provider_login_finish", ["id": JSON(state.id), "code": .string(code)])
                let row = r["provider"]
                guard row.isObject else { showError(unexpectedResponse); return }
                error = nil
                codeWanted = false
                loginCode = ""
                // The saved row now carries its login; the form keeps any change not saved yet.
                state.row["hasLogin"] = true
                if let dir = row["loginDir"].string { state.row["loginDir"] = .string(dir) }
                loadStatus(fresh: false)
                post(.settingsProvidersChanged, ["openFirst": false])
                Dialogs.alert("Logged in", "\(row["label"].nonEmpty ?? "The provider") is logged in.")
            } catch {
                if !error.isCancellation { showError(errorText(error)) }
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
                if error.isCancellation { return }
                testFailed = true
                testResult = errorText(error)
            }
        }
    }

    // MARK: Saving, cloning, deleting

    func save() {
        guard !busy, Store.shared.supports(state.id != 0 ? "update_provider" : "create_provider") else { return }
        var body: JSON
        switch state.body() {
        case .failure(let p):
            error = p.message
            tab = ProviderTab(rawValue: p.tab) ?? .provider
            scrollToken += 1
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
                guard row.isObject else { showError(unexpectedResponse); return }
                error = nil
                state.row = row
                state.fill()
                post(.settingsProvidersChanged, ["openFirst": false])
                // A new provider's connection can be read now that it exists (its own screen reads it as it opens).
                if id == 0 { Navigator.shared.show(.providerSettings(row: row, defaults: defaults)) }
                else if !status.isObject { loadStatus(fresh: false) }
            } catch {
                if !error.isCancellation { showError(errorText(error)) }
            }
        }
    }

    func delete() {
        guard state.id != 0, !busy else { return }
        let name = state.row["label"].nonEmpty ?? "this provider"
        guard Dialogs.confirm("Delete \(name)?", "Sessions already run on it keep their history, but no new one can be started on it.",
                              continueLabel: "Delete", destructive: true) else { return }
        deleting = true
        Task {
            defer { deleting = false }
            do {
                _ = try await Store.shared.call("delete_provider", ["id": JSON(state.id)])
                state.dirty = false
                Navigator.shared.clear()
                post(.settingsProvidersChanged, ["openFirst": true])
            } catch {
                if !error.isCancellation { showError(errorText(error)) }
            }
        }
    }

    func clone() {
        // The copy carries what the form holds now, saved or not, without its label, which is typed first.
        guard case .success(var copy) = state.body(validate: false) else { return }
        copy["label"] = ""
        state.dirty = false
        Self.openTab = .provider
        Navigator.shared.show(.providerSettings(row: copy, defaults: nil))
    }
}

struct ProviderSettingsScreen: View {
    var row: JSON?
    var defaults: JSON?
    @StateObject private var model: ProviderFormModel
    @FocusState private var focus: ProviderField?
    @EnvironmentObject private var store: Store

    init(row: JSON?, defaults: JSON?) {
        self.row = row
        self.defaults = defaults
        _model = StateObject(wrappedValue: ProviderFormModel(row: row, defaults: defaults))
    }

    private var state: ProviderFormState { model.state }

    var body: some View {
        SettingsPage(header: header,
                     unavailable: store.supports("settings_providers") ? nil
                        : "Provider settings need an Admin token on a server that offers them (GET /settings/providers).",
                     scrollToken: model.scrollToken) {
            SettingsTabs(tabs: ProviderTab.allCases.filter { $0 != .status || state.id != 0 }.map { t in
                SettingsTabs.Tab(id: t.rawValue, title: t.title, glyph: Self.glyph(t), dot: model.tabDot(t))
            }, open: model.openTab.rawValue) { t in
                focus = nil
                model.tab = ProviderTab(rawValue: t) ?? .provider
                model.scrollToken += 1
            }
            if let error = model.error { NoticeBox(message: error).padding(.bottom, 16) }
            switch model.openTab {
            case .provider: providerTab
            case .models: modelsTab
            case .status: statusTab
            }
        }
        .onAppear {
            if state.id != 0 && !model.status.isObject && !model.statusLoading { model.loadStatus(fresh: false) }
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
        .onReceive(NotificationCenter.default.publisher(for: .saveScreen)) { _ in model.save() }
        .onReceive(NotificationCenter.default.publisher(for: .refreshScreen)) { _ in model.loadStatus(fresh: false) }
    }

    static func glyph(_ t: ProviderTab) -> String {
        switch t {
        case .provider: return Glyph.symbol(0xE713)
        case .models: return Glyph.symbol(0xE8FD)
        case .status: return Glyph.symbol(0xE9D9)
        }
    }

    private var header: PaneHeader {
        let id = state.id
        var buttons: [HeaderButton] = []
        if store.supports("settings_providers") {
            buttons.append(HeaderButton(glyph: Glyph.symbol(0xE74E), label: model.saving ? "Saving…" : "Save", tip: "Save this provider (⌘S)",
                                        enabled: !model.busy && (state.dirty || id == 0) && store.supports(id != 0 ? "update_provider" : "create_provider"),
                                        prominent: true) { model.save() })
            if id != 0 {
                buttons.append(HeaderButton(glyph: Glyph.symbol(0xE8C8), tip: "Clone into a new provider",
                                            enabled: !model.busy && store.supports("create_provider")) { model.clone() })
                buttons.append(HeaderButton(glyph: Glyph.symbol(0xE74D), tip: "Delete this provider",
                                            enabled: !model.busy && store.supports("delete_provider"), destructive: true) { model.delete() })
            }
        }
        return id != 0
            ? PaneHeader(title: state.row["label"].nonEmpty ?? "Provider", subtitle: "runs the \(ProviderFormState.rowBinary(state.row)) CLI", buttons: buttons)
            : PaneHeader(title: "New provider", subtitle: "A provider is a login or endpoint sessions can be started on.", buttons: buttons)
    }

    // MARK: Provider

    @ViewBuilder private var providerTab: some View {
        SettingsCheck(label: "Active: new sessions may start on this provider", on: state.active) { model.toggleActive() }
            .padding(.bottom, 12)
        SettingsPair {
            field(.label)
        } right: {
            SettingsLabeledSelect(label: "Binary", text: ProviderFormState.binaryTitle(state.binary)) { model.pickBinary() }
        }
        connection
    }

    /// Under the label and binary: the mode, then the login, or the endpoint with its token and Test.
    @ViewBuilder private var connection: some View {
        if ProviderFormState.modeOffered(state.binary) {
            HStack(alignment: .top, spacing: 14) {
                SettingsLabeledSelect(label: "Mode", text: state.token ? "API token" : "Login") { model.pickMode() }
                Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
            }
        } else if state.binary == "grok" {
            SettingsNote(text: "grok signs in with its own login; it takes no API token.", rich: true, after: 12)
        } else {
            SettingsNote(text: "opencode authenticates with an API key per service and has no login of its own.", rich: true, after: 12)
        }
        if !state.usesToken {
            if state.id == 0 {
                SettingsNote(text: "Save the provider first: its login is registered against the saved entry, so there is nothing to log in until one exists.", rich: true, after: 12)
            } else {
                login
            }
        } else {
            field(.baseUrl, hint: ProviderFormState.baseURLHint(state.binary))
            field(.apiKey, hint: ProviderFormState.apiKeyHint(state.binary))
            Button(model.testing ? "Testing…" : "Test") { model.test() }.dashButton()
                .disabled(model.testing || !store.supports("test_provider"))
                .padding(.bottom, 8)
            if let result = model.testResult, !model.testing {
                Text(result).font(Theme.footnote).foregroundStyle(model.testFailed ? Theme.danger : Theme.ok)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).padding(.bottom, 8)
            }
            SettingsNote(text: "Test probes the endpoint and token as the form holds them, no save needed, and puts the endpoint's models in the Models tab.", rich: true, after: 12)
        }
    }

    @ViewBuilder private var login: some View {
        headline.padding(.bottom, 12)
        let supported = store.supports(state.binary == "claude" ? "provider_login_start" : "provider_login")
        Button(model.loggingIn ? "Logging in…" : "Log in") { model.logIn() }.dashButton()
            .disabled(!supported || model.loggingIn)
            .padding(.bottom, 10)
        if let code = model.deviceCode {
            // codex's confirm page asks for the code its hidden CLI printed.
            Text("Enter this code on the page that opened; the login is picked up automatically.").font(Theme.footnote).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true).padding(.bottom, 6)
            HStack(spacing: 14) {
                Text(code).font(Theme.mono).foregroundStyle(Theme.ink).textSelection(.enabled)
                Button("Copy") { Clipboard.copy(code) }.dashButton(.plain)
            }
            .padding(.bottom, 12)
        }
        if model.codeWanted && state.canLogIn {
            SettingsNote(text: "Approve in the browser, then paste the code it shows here.", rich: true, after: 12)
            field(.loginCode) { model.finishLogin() }
            Button("Finish") { model.finishLogin() }.dashButton(.prominent)
                .disabled(model.loggingIn || !store.supports("provider_login_finish"))
                .padding(.bottom, 12)
        } else {
            SettingsNote(text: state.binary == "claude"
                         ? "The login happens in the browser: approve on claude.ai, then paste the code it shows back here."
                         : "The login happens in the browser: the server runs the CLI's device login and picks it up once approved.",
                         rich: true, after: 12)
        }
    }

    /// The connection at a glance, as the dashboard's status headline: a dot and a sentence.
    @ViewBuilder private var headline: some View {
        if let h = ProviderStatusText.headline(model.status) {
            HStack(spacing: 9) {
                StatusDot(status: h.dot)
                Text(h.text).font(Theme.subheadline).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
            }
            .frame(height: 24)
        } else {
            Text(model.statusError ?? "Checking the connection…").font(Theme.footnote)
                .foregroundStyle(model.statusError != nil ? Theme.danger : Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Models

    @ViewBuilder private var modelsTab: some View {
        SettingsPair {
            field(.models, hint: "One model per line; empty offers the CLI's own list.")
        } right: {
            field(.efforts, hint: "One effort per line; empty offers the CLI's own.")
        }
        SettingsPair { field(.defaultModel) } right: { field(.defaultEffort) }
    }

    // MARK: Status

    /// Who the provider is logged in as, its plan, where its CLI lives, and the quota windows its plan meters.
    @ViewBuilder private var statusTab: some View {
        headline.padding(.bottom, 12)
        if model.status.isObject {
            ForEach(Array(ProviderStatusText.rows(model.status).enumerated()), id: \.offset) { _, r in
                SettingsStatusRow(label: r.label, value: r.value, mono: r.mono)
            }
            // Which windows a plan meters is the provider's call, so the bars wear the labels that came with them.
            let windows = model.status["usage"]["windows"].items
            ForEach(Array(windows.enumerated()), id: \.offset) { _, win in
                QuotaBar(window: ProviderStatusText.window(win)).padding(.top, 8)
            }
            if windows.isEmpty {
                Text(model.status["usage"]["error"].nonEmpty ?? "Usage unavailable: this account’s meter could not be read or is not supported.")
                    .font(Theme.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }
            Color.clear.frame(height: 16)
        }
        Button(model.statusLoading && model.statusFresh ? "Checking usage…" : "Check usage") { model.loadStatus(fresh: true) }.dashButton()
            .disabled(model.statusLoading || !store.supports("provider_status"))
            .padding(.bottom, 8)
        SettingsNote(text: "Check usage reads the account and its quota again rather than the server's last answer.", rich: true, after: 12)
    }

    // MARK: Fields

    @ViewBuilder private func field(_ f: ProviderField, hint: String? = nil, onSubmit: (() -> Void)? = nil) -> some View {
        SettingsFieldBox(def: f.def, text: model.binding(f), hint: hint, rich: true, focus: $focus, key: f) {
            if let onSubmit { onSubmit() } else { focus = next(after: f) }
        }
    }

    private func shown(_ f: ProviderField) -> Bool {
        switch f {
        case .baseUrl, .apiKey: return state.usesToken
        case .loginCode: return model.codeWanted && state.canLogIn
        default: return true
        }
    }
    /// The next box laid out on the open tab, for Return in a one-line box.
    private func next(after f: ProviderField) -> ProviderField? {
        let order = ProviderField.allCases.filter { $0.tab == model.openTab && shown($0) }
        guard let i = order.firstIndex(of: f) else { return f }
        return order[(i + 1) % order.count]
    }
}

/// A quota window: its label and how much is used on the right, over a 5px track filled green, amber past 70% and red past 90%.
private struct QuotaBar: View {
    var window: (label: String, right: String, pct: Double)
    var body: some View {
        let pct = min(max(window.pct, 0), 100)
        let color = pct >= 90 ? Theme.danger : pct >= 70 ? Theme.warn : Theme.ok
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.label).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                Text(window.right).lineLimit(1)
            }
            .font(Theme.caption).foregroundStyle(Theme.muted)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Theme.sunken)
                    if pct > 0 { RoundedRectangle(cornerRadius: 3).fill(color).frame(width: geo.size.width * pct / 100) }
                }
            }
            .frame(height: 5)
        }
    }
}
