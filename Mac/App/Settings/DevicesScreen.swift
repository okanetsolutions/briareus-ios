// Settings → Devices and clients: the tokens issued for the client API, as the web dashboard's page lists them, with a
// new one issued here (its secret shown once) and any of them revoked. It reads /settings/devices, so it needs an Admin
// token like the rest of Settings. (The Windows client names this entry in its README but leaves it to the web dashboard;
// the Mac does it in place, on the same routes.)
import SwiftUI

struct DevicesScreen: View {
    @EnvironmentObject private var store: Store
    @State private var devices: [JSON] = []
    @State private var projects: [JSON] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var revoking: String?
    // The new token's form.
    @State private var composing = false
    @State private var label = ""
    @State private var permission = "manage"
    @State private var days = "90"
    @State private var repos: Set<String> = []
    @State private var creating = false
    @State private var issued: (label: String, token: String)?
    @FocusState private var focus: Field?
    private enum Field: Hashable { case label, days }

    private static let permissions: [(id: String, title: String)] = [("read", "Read-only"), ("manage", "Manage"), ("admin", "Admin")]
    private static func permissionTitle(_ p: String?) -> String { permissions.first { $0.id == p }?.title ?? (p ?? "") }

    var body: some View {
        SettingsPage(header: header,
                     unavailable: settingsUnavailable("settings_devices", path: "settings/devices", what: "Devices and clients", manage: "tokens"),
                     scrollToken: 0) {
            Color.clear.frame(height: 10)
            if let error { NoticeBox(message: error).padding(.bottom, 16) }
            if let issued { issuedCard(issued).padding(.bottom, 16) }
            if composing { newTokenCard.padding(.bottom, 16) }
            ForEach(Array(devices.enumerated()), id: \.offset) { _, d in row(d).padding(.bottom, 8) }
            if loaded && devices.isEmpty && error == nil { EmptyNote(title: "No tokens issued yet.") }
            if !loaded { LoadingNote(text: "Loading the tokens…") }
            SettingsNote(text: "A token is held to the projects it was issued for, except an Admin token, which reaches every project and Settings. Revoking one signs out whatever uses it at once.")
                .padding(.top, 8)
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .refreshScreen)) { _ in Task { await load() } }
    }

    private var header: PaneHeader {
        var buttons: [HeaderButton] = []
        if store.supports("create_device") {
            buttons.append(HeaderButton(glyph: Glyph.symbol(0xE710), label: "＋ New token", tip: "Issue a new token", enabled: !composing && !creating) {
                composing = true; issued = nil; label = ""; permission = "manage"; days = "90"; repos = []
                DispatchQueue.main.async { focus = .label }
            })
        }
        return PaneHeader(title: "Devices and clients", subtitle: "The tokens that may use this server's client API.", buttons: buttons)
    }

    // MARK: Rows

    private func row(_ d: JSON) -> some View {
        let id = d["id"].string ?? ""
        let mine = id == store.device?.id
        let expires = d["expiresAt"].number.map { Date(timeIntervalSince1970: $0 / 1000) }
        let created = d["createdAt"].number.map { Date(timeIntervalSince1970: $0 / 1000) }
        let expired = expires.map { $0 < Date() } ?? false
        let repoList = d["repos"].strings
        var facts = [Self.permissionTitle(d["permission"].string), repoList.isEmpty ? "every project" : repoList.joined(separator: ", ")]
        if let created { facts.append("issued \(formatDateAbbrev(created))") }
        if let expires { facts.append(expired ? "expired \(formatDateAbbrev(expires))" : "expires \(formatDateAbbrev(expires))") }
        return Card {
            HStack(alignment: .top, spacing: 10) {
                StatusDot(status: expired ? "" : "idle").padding(.top, 6)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(d["label"].nonEmpty ?? id).font(Theme.subheadlineSemibold).foregroundStyle(Theme.ink).lineLimit(1)
                        if mine { Badge(text: "this Mac", color: Theme.accent) }
                    }
                    Text(facts.joined(separator: " · ")).font(Theme.caption).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                Spacer(minLength: 8)
                if store.supports("delete_device") {
                    Button { revoke(d) } label: { Image(systemName: Glyph.symbol(0xE74D)) }
                        .buttonStyle(IconButtonStyle(destructive: true))
                        .disabled(revoking != nil)
                        .help("Revoke this token")
                }
            }
        }
    }

    // MARK: A new token

    private var newTokenCard: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Text("New token").font(Theme.subheadlineSemibold).foregroundStyle(Theme.ink).padding(.bottom, 12)
                SettingsPair {
                    SettingsFieldBox(def: SettingsField(key: "label", kind: .text, label: "Name", cue: "MacBook, CI, Pat's phone"),
                                     text: $label, focus: $focus, key: .label) { focus = .days }
                } right: {
                    SettingsLabeledSelect(label: "Permission", text: Self.permissionTitle(permission)) {
                        let items = Self.permissions.map { PopupMenu.Item(title: $0.title, checked: $0.id == permission) }
                        if let i = PopupMenu.choose(items) { permission = Self.permissions[i].id }
                    }
                }
                HStack(alignment: .top, spacing: 14) {
                    SettingsFieldBox(def: SettingsField(key: "days", kind: .number, label: "Days until it expires", cue: "1–365"),
                                     text: Binding(get: { days }, set: { days = String($0.filter { $0.isASCII && $0.isNumber }.prefix(3)) }),
                                     focus: $focus, key: .days) { create() }
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                }
                if permission != "admin" {
                    Text("Projects").font(Theme.footnote).foregroundStyle(Theme.ink).padding(.bottom, 6)
                    ForEach(Array(projects.enumerated()), id: \.offset) { _, p in
                        if let repo = p["repo"].string {
                            SettingsCheck(label: p["label"].nonEmpty.map { "\($0) (\(repo))" } ?? repo, on: repos.contains(repo)) {
                                if repos.contains(repo) { repos.remove(repo) } else { repos.insert(repo) }
                            }
                        }
                    }
                    if projects.isEmpty { SettingsNote(text: "No projects yet: a Read-only or Manage token is held to at least one.") }
                    Color.clear.frame(height: 14)
                } else {
                    SettingsNote(text: "An Admin token reaches every project, including ones added later, and Settings.", after: 14)
                }
                HStack(spacing: 8) {
                    Button(creating ? "Issuing…" : "Issue token") { create() }.dashButton(.prominent).disabled(creating)
                    Button("Cancel") { composing = false }.dashButton().disabled(creating)
                }
            }
        }
    }

    private func issuedCard(_ t: (label: String, token: String)) -> some View {
        Card(padding: 16, border: Theme.accentDim) {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(t.label) is issued. Copy its token now: it is shown only this once.").font(Theme.footnote).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    Text(t.token).font(Theme.mono).foregroundStyle(Theme.ink).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Button("Copy") { Clipboard.copy(t.token) }.dashButton(.plain)
                    Spacer(minLength: 0)
                    Button("Done") { issued = nil }.dashButton()
                }
            }
        }
    }

    // MARK: Requests

    private func load() async {
        guard store.supports("settings_devices") else { loaded = true; return }
        do {
            let r = try await store.call("settings_devices")
            devices = r["devices"].items
            projects = r["projects"].items
            error = nil
        } catch {
            if !error.isCancellation { self.error = errorText(error) }
        }
        loaded = true
    }

    private func create() {
        guard !creating, store.supports("create_device") else { return }
        let name = label.cTrimmed
        guard !name.isEmpty else { error = "Enter a name for the token."; return }
        guard let n = Int(days), (1...365).contains(n) else { error = "Choose 1–365 days."; return }
        if permission != "admin" && repos.isEmpty { error = "Select at least one project."; return }
        var body: JSON = ["label": .string(name), "permission": .string(permission), "days": JSON(n)]
        if permission != "admin" { body["repos"] = JSON(repos.sorted()) }
        creating = true
        Task {
            defer { creating = false }
            do {
                let r = try await store.call("create_device", body)
                guard let token = r["token"].nonEmpty else { error = unexpectedResponse; return }
                error = nil
                composing = false
                issued = (r["device"]["label"].nonEmpty ?? name, token)
                await load()
            } catch {
                if !error.isCancellation { self.error = errorText(error) }
            }
        }
    }

    private func revoke(_ d: JSON) {
        guard let id = d["id"].string, revoking == nil else { return }
        let mine = id == store.device?.id
        let message = mine
            ? "This is the token this Mac is connected with: revoking it signs Briareus out here."
            : "Whatever uses it is signed out at once. This cannot be undone."
        guard Dialogs.confirm("Revoke \(d["label"].nonEmpty ?? "this token")?", message, continueLabel: "Revoke", destructive: true) else { return }
        revoking = id
        Task {
            defer { revoking = nil }
            do {
                _ = try await store.call("delete_device", ["id": .string(id)])
                await load()
            } catch {
                if !error.isCancellation { self.error = errorText(error) }
            }
        }
    }
}
