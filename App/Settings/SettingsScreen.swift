// The Settings tab: this device's connection (who it is, what it may do, revoke or forget it), the Voice tab's OpenAI key, then for an Admin token
// the Mac app's settings page as the Mac's settings sidebar lists it: the projects (in the server's order, which Edit
// rearranges), the providers sessions start on, the database pool, the SSH servers, and the tokens issued. Each row opens
// its form.
import SwiftUI

struct SettingsScreen: View {
    @EnvironmentObject private var store: Store
    @ObservedObject private var lists = SettingsLists.shared
    @Environment(\.navigate) private var navigate
    @State private var confirm: ConnectionAction?
    @State private var busy = false
    @State private var error: String?

    private enum ConnectionAction: Identifiable {
        case revoke, forget
        var id: Self { self }
    }

    /// Any of the settings lists is this token's to read.
    private var managesServer: Bool {
        ["settings_projects", "settings_providers", "settings_db_servers", "settings_ssh_servers"].contains { store.supports($0) }
    }

    var body: some View {
        List {
            connection
            Section {
                DestinationLink(destination: .voiceSettings) {
                    Label("Voice", systemImage: "waveform")
                }
            } footer: {
                Text("The OpenAI API key the Voice tab talks to GPT-Live with.")
            }
            .listRowBackground(Theme.row)
            let why = settingsUnavailableReason("settings_projects", path: "settings/projects", what: "Project settings", manage: "projects")
            if let why {
                Section { EmptyView() } header: { Text("Server settings") } footer: { Text(why) }
            } else {
                projects
                if store.supports("settings_providers") { providers }
                if store.supports("settings_db_servers") { servers }
                ssh
            }
            Section {
                Text("Briareus for \(Platform.name) · \(Platform.version)").font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Settings")
        .toolbar {
            if store.supports("order_projects") && lists.projects.list.count > 1 {
                ToolbarItem(placement: .topBarTrailing) { EditButton().disabled(lists.ordering) }
            }
        }
        .refreshable { try? await lists.refresh() }
        // Read afresh each time the tab comes back to this screen, then now and then while it stays.
        .task {
            guard managesServer else { return }
            await poll(every: 60) { await reading { try await lists.refresh() } }
        }
        .confirmationDialog(confirm == .revoke ? "Revoke this device token?" : "Forget this connection?",
                            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible, presenting: confirm) { action in
            Button(action == .revoke ? "Revoke and disconnect" : "Forget", role: .destructive) { run(action) }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(action == .revoke
                 ? "The token stops working on the server and this device disconnects."
                 : "The token and the saved conversations are removed from this device. The token itself keeps working until it is revoked.")
        }
    }

    // MARK: Connection

    @ViewBuilder private var connection: some View {
        Section("Connection") {
            Label { Text(store.server).textSelection(.enabled) } icon: {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.success)
            }
            if let device = store.device {
                LabeledContent("Device", value: device.label)
                LabeledContent("Access", value: settingsPermissionTitle(device.permission))
                LabeledContent("Expires", value: device.expiry.formatted(date: .abbreviated, time: .omitted))
            }
        }
        .listRowBackground(Theme.row)
        if let device = store.device {
            Section("Permitted projects") {
                if device.isAdmin || device.repos.isEmpty {
                    Label("All projects", systemImage: "square.stack.3d.up")
                } else {
                    ForEach(device.repos, id: \.self) { repo in
                        Text(repo).textSelection(.enabled)
                    }
                }
            }
            .listRowBackground(Theme.row)
        }
        Section {
            if store.supports("revoke_token") {
                Button("Revoke token and disconnect", role: .destructive) { confirm = .revoke }
            }
            Button("Forget this connection", role: .destructive) { confirm = .forget }
            if let error { ErrorNotice(message: error) }
        } footer: {
            Text("Revoking disables this token on the server. Forgetting removes it and the saved conversations from this device only; revoke it later on the server with `npm run create-token -- --revoke`. Neither action stops running agents.")
        }
        .listRowBackground(Theme.row)
        .disabled(busy)
    }

    private func run(_ action: ConnectionAction) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            // Named both ways: a token meant to be revoked must never be merely forgotten.
            do {
                switch action {
                case .revoke: try await store.revoke()
                case .forget: try store.forget()
                }
            } catch {
                self.error = failure(error)
            }
        }
    }

    // MARK: Projects

    @ViewBuilder private var projects: some View {
        let s = lists.projects
        Section {
            if let error = s.error { ErrorNotice(message: error) }
            ForEach(Array(s.list.enumerated()), id: \.offset) { _, row in
                DestinationLink(destination: .projectSettings(row: row, defaults: s.defaults)) { SettingsProjectRow(row: row) }
            }
            .onMove(perform: store.supports("order_projects") ? { lists.moveProjects(from: $0, to: $1) } : nil)
            if !s.loaded { SettingsLoadingRow(text: "Loading projects…") }
        } header: {
            SettingsSectionHeader(title: "Projects", newLabel: "New project",
                                  onNew: store.supports("create_project") ? { navigate(.projectSettings(row: nil, defaults: s.defaults)) } : nil)
        } footer: {
            if s.loaded && s.list.isEmpty && s.error == nil {
                Text("No projects yet. ＋ adds a repository sessions can be started against.")
            } else if store.supports("order_projects") && s.list.count > 1 {
                Text("The order here is the order the apps list them in; Edit rearranges it.")
            }
        }
        .listRowBackground(Theme.row)
    }

    // MARK: Providers

    @ViewBuilder private var providers: some View {
        let s = lists.providers
        Section {
            if let error = s.error { ErrorNotice(message: error) }
            ForEach(Array(s.list.enumerated()), id: \.offset) { _, row in
                DestinationLink(destination: .providerSettings(row: row, defaults: s.defaults)) { SettingsProviderRow(row: row) }
            }
            if !s.loaded { SettingsLoadingRow(text: "Loading providers…") }
        } header: {
            SettingsSectionHeader(title: "Providers", newLabel: "New provider",
                                  onNew: store.supports("create_provider") ? { navigate(.providerSettings(row: nil, defaults: s.defaults)) } : nil)
        } footer: {
            if s.loaded && s.list.isEmpty && s.error == nil { Text("No providers yet. Add one so sessions can be started.") }
        }
        .listRowBackground(Theme.row)
    }

    // MARK: Database pool

    @ViewBuilder private var servers: some View {
        let s = lists.servers
        let n = lists.poolCapacity
        Section {
            if let error = s.error { ErrorNotice(message: error) }
            ForEach(Array(s.list.enumerated()), id: \.offset) { _, row in
                let address = DBServerFormState.address(row)
                DestinationLink(destination: .dbServerSettings(row: row, defaults: s.defaults)) {
                    SettingsItemRow(title: row["label"].nonEmpty ?? address, subtitle: address, on: row["enabled"].is(true),
                                    systemImage: "cylinder.split.1x2")
                }
            }
            if !s.loaded { SettingsLoadingRow(text: "Loading the database pool…") }
        } header: {
            // One open session with a database per server in the pool, so the pool's size heads the section.
            SettingsSectionHeader(title: "Database pool", note: n > 0 ? "· \(n) session\(n == 1 ? "" : "s")" : nil, newLabel: "New database server",
                                  onNew: store.supports("create_db_server") ? { navigate(.dbServerSettings(row: nil, defaults: s.defaults)) } : nil)
        } footer: {
            if s.loaded && s.list.isEmpty && s.error == nil {
                Text("No servers yet. Add one so sessions can claim a database of their own.")
            } else if s.loaded {
                Text(DBServerFormState.poolText(capacity: n, total: s.list.count))
            }
        }
        .listRowBackground(Theme.row)
    }

    // MARK: SSH servers

    @ViewBuilder private var ssh: some View {
        let why = settingsUnavailableReason("settings_ssh_servers", path: "settings/ssh/servers", what: "SSH servers", manage: "them")
        let s = lists.ssh
        Section {
            if why == nil {
                if let error = s.error { ErrorNotice(message: error) }
                ForEach(Array(s.list.enumerated()), id: \.offset) { _, row in
                    DestinationLink(destination: .sshServerSettings(row: row, defaults: s.defaults)) {
                        SettingsItemRow(title: row["label"].nonEmpty ?? row["host"].nonEmpty ?? "SSH server", subtitle: row["repo"].string ?? "",
                                        on: !row["enabled"].is(false), systemImage: "terminal")
                    }
                }
                if !s.loaded { SettingsLoadingRow(text: "Loading SSH servers…") }
            }
        } header: {
            SettingsSectionHeader(title: "SSH servers", newLabel: "New SSH server",
                                  onNew: why == nil && store.supports("create_ssh_server") ? { navigate(.sshServerSettings(row: nil, defaults: s.defaults)) } : nil)
        } footer: {
            if let why {
                Text(why)
            } else if s.loaded && s.list.isEmpty && s.error == nil {
                Text("No SSH servers registered. ＋ lets a project's sessions run commands on one, with approval.")
            }
        }
        .listRowBackground(Theme.row)
    }
}

/// What a token may do, as the Mac app names it.
func settingsPermissionTitle(_ permission: String) -> String {
    switch permission {
    case "admin": return "Admin"
    case "manage": return "Manage"
    case "read": return "Read only"
    default: return permission.capitalized
    }
}

// MARK: - Rows

/// A section's title, a muted note after it, and its ＋.
struct SettingsSectionHeader: View {
    var title: String
    var note: String? = nil
    var newLabel: String
    var onNew: (() -> Void)?
    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            if let note { Text(note).foregroundStyle(.secondary) }
            Spacer(minLength: 8)
            if let onNew {
                Button(action: onNew) {
                    Image(systemName: "plus.circle.fill").font(.title3).frame(minWidth: 32, minHeight: 32)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.accent)
                .accessibilityLabel(newLabel)
            }
        }
    }
}

/// "Loading…" in place of a list not read yet.
private struct SettingsLoadingRow: View {
    var text: String
    var body: some View {
        HStack(spacing: 10) { ProgressView(); Text(text).foregroundStyle(.secondary) }
    }
}

/// A project: its monogram, label and repository, with the pool's `db` tag on one that claims a server; a project switched
/// off reads faded.
private struct SettingsProjectRow: View {
    var row: JSON
    var body: some View {
        let repo = row["repo"].string ?? ""
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row["label"].nonEmpty ?? repo).font(.body).lineLimit(1)
                HStack(spacing: 6) {
                    Text(repo).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if row["dbPoolEnabled"].is(true) { SettingsTag(text: "db") }
                    if !(row["localDir"].nonEmpty ?? "").isEmpty { SettingsTag(text: "local") }
                }
            }
        }
        .opacity(row["enabled"].is(false) ? 0.55 : 1)
        .padding(.vertical, 2)
    }
}

/// A provider: its dot, label, and the Mac app's badges: the CLI it runs, and what sets it apart.
private struct SettingsProviderRow: View {
    var row: JSON
    var body: some View {
        let active = !row["active"].is(false)
        let tags = [row["binary"].string ?? "", active ? "" : "inactive", row["hasLogin"].is(true) ? "own login" : "",
                    row["baseUrl"].nonEmpty != nil ? "custom endpoint" : ""].filter { !$0.isEmpty }
        HStack(spacing: 12) {
            SettingsRowIcon(systemImage: "cpu", on: active)
            VStack(alignment: .leading, spacing: 3) {
                Text(row["label"].nonEmpty ?? "Provider #\(row["id"].int32 ?? 0)").lineLimit(1)
                if !tags.isEmpty {
                    HStack(spacing: 6) { ForEach(tags, id: \.self) { SettingsTag(text: $0) } }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// A database server or an SSH server: its icon (tinted while on), its name and what is under it.
private struct SettingsItemRow: View {
    var title: String
    var subtitle: String
    var on: Bool
    var systemImage: String
    var body: some View {
        HStack(spacing: 12) {
            SettingsRowIcon(systemImage: systemImage, on: on)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityValue(on ? "On" : "Off")
    }
}

/// A row's rounded icon: the accent while the row is on, grey while it is off.
struct SettingsRowIcon: View {
    var systemImage: String
    var on: Bool
    var body: some View {
        Image(systemName: systemImage).font(.system(size: 14, weight: .semibold))
            .foregroundStyle(on ? Theme.accent : .secondary)
            .frame(width: 32, height: 32)
            .background((on ? Theme.accent : Color.secondary).opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A small bordered tag.
struct SettingsTag: View {
    var text: String
    var body: some View {
        Text(text).font(.caption2).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border, lineWidth: 1))
    }
}
