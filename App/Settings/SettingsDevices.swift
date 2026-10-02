// The tokens issued for this dashboard, as the web's Settings → Devices and clients: each with what it may do, the
// projects it is held to and when it stops working; another one revoked with a swipe, a new one issued from a sheet that
// shows its secret once. This device's own token is revoked from the Connection section, which also disconnects.
import SwiftUI

struct SettingsDevicesSection: View {
    @EnvironmentObject private var store: Store
    @ObservedObject private var lists = SettingsLists.shared
    @State private var revoking: JSON?
    @State private var busy: String?
    @State private var error: String?
    @State private var creating = false

    var body: some View {
        let s = lists.devices
        Section {
            if let error = error ?? s.error { ErrorNotice(message: error) }
            ForEach(Array(s.list.enumerated()), id: \.offset) { _, row in
                let own = row["id"].string == store.device?.id
                SettingsDeviceRow(row: row, own: own)
                    .opacity(busy != nil && busy == row["id"].string ? 0.4 : 1)
                    .swipeActions(edge: .trailing) {
                        if !own && store.supports("delete_device") {
                            Button("Revoke", systemImage: "xmark.circle", role: .destructive) { revoking = row }
                        }
                    }
                    .contextMenu {
                        if !own && store.supports("delete_device") {
                            Button("Revoke", systemImage: "xmark.circle", role: .destructive) { revoking = row }
                        }
                    }
            }
            if !s.loaded { HStack(spacing: 10) { ProgressView(); Text("Loading tokens…").foregroundStyle(.secondary) } }
        } header: {
            SettingsSectionHeader(title: "Devices and clients", newLabel: "New token",
                                  onNew: store.supports("create_device") ? { creating = true } : nil)
        } footer: {
            Text(s.loaded && s.list.isEmpty && s.error == nil
                 ? "No tokens issued yet."
                 : "Each token is one device or client. Swipe one to revoke it; it stops working at once.")
        }
        .listRowBackground(Theme.row)
        .confirmationDialog("Revoke \(revoking?["label"].nonEmpty ?? "this token")?",
                            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
                            titleVisibility: .visible, presenting: revoking) { row in
            Button("Revoke", role: .destructive) { revoke(row) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The device or client using it is signed out at once and cannot reconnect with it.")
        }
        .sheet(isPresented: $creating) {
            NewDeviceTokenSheet(projects: s.defaults.items)
        }
    }

    private func revoke(_ row: JSON) {
        guard let id = row["id"].string, busy == nil else { return }
        busy = id
        error = nil
        Task {
            defer { busy = nil }
            do {
                try await store.call("delete_device", ["id": .string(id)])
                lists.devices.list.removeAll { $0["id"].string == id }
                try? await lists.loadDevices()
            } catch {
                self.error = failure(error)
            }
        }
    }
}

/// A token: its label (this device's marked), what it may do, the projects it is held to and when it expires.
private struct SettingsDeviceRow: View {
    var row: JSON
    var own: Bool
    var body: some View {
        let permission = row["permission"].string ?? ""
        let repos = row["repos"].strings
        let expires = row["expiresAt"].number.map { Date(timeIntervalSince1970: $0 / 1000) }
        let expired = expires.map { $0 <= Date() } ?? false
        HStack(alignment: .top, spacing: 12) {
            SettingsRowIcon(systemImage: own ? "iphone" : "key", on: !expired)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row["label"].nonEmpty ?? "Token").lineLimit(1)
                    if own { SettingsTag(text: "this device") }
                }
                HStack(spacing: 6) {
                    SettingsTag(text: settingsPermissionTitle(permission))
                    if let expires {
                        Text(expired ? "Expired \(expires.formatted(date: .abbreviated, time: .omitted))"
                                     : "Expires \(expires.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(expired ? Theme.danger : .secondary)
                    }
                }
                Text(permission == "admin" || repos.isEmpty ? "All projects" : repos.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Issues a token: its name, what it may do, the projects a Read only or Manage one is held to, and how long it lasts;
/// then shows its secret, once.
struct NewDeviceTokenSheet: View {
    /// The projects a token can be held to: `{repo, label}`.
    let projects: [JSON]
    @EnvironmentObject private var store: Store
    @ObservedObject private var lists = SettingsLists.shared
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var permission = "read"
    @State private var repos: Set<String> = []
    @State private var days = 90
    @State private var creating = false
    @State private var error: String?
    /// The new token's secret and record, once issued.
    @State private var issued: (token: String, device: JSON)?
    @State private var copied = false
    @FocusState private var labelFocused: Bool

    private static let lengths = [1, 7, 30, 90, 180, 365]

    private var valid: Bool {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name.count <= 100 && (permission == "admin" || !repos.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let issued { issuedView(issued) } else { form }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(issued == nil ? "New token" : "Token issued")
            .navigationBarTitleDisplayMode(.inline)
        }
        // A half-filled form, or a secret not copied yet, is not swiped away by accident.
        .interactiveDismissDisabled(issued != nil || !label.isEmpty || !repos.isEmpty)
    }

    private var form: some View {
        Form {
            if let error { Section { ErrorNotice(message: error) }.listRowBackground(Theme.danger.opacity(0.08)) }
            Section {
                TextField("Name", text: $label, prompt: Text("Pixel tablet, CI runner…"))
                    .focused($labelFocused)
                    .submitLabel(.done)
            } header: { Text("Name") } footer: { Text("Shown in this list, to tell the token apart.") }
                .listRowBackground(Theme.row)
            Section {
                Picker("Access", selection: $permission) {
                    Text("Read only").tag("read")
                    Text("Manage").tag("manage")
                    Text("Admin").tag("admin")
                }
                .pickerStyle(.segmented)
            } header: { Text("Access") } footer: {
                Text(permission == "admin"
                     ? "Admin can do everything, these settings included, on every project, including ones added later."
                     : permission == "manage"
                        ? "Manage can start, message and stop sessions and act on pull requests in the projects below."
                        : "Read only can see sessions and pull requests in the projects below, and change nothing.")
            }
            .listRowBackground(Theme.row)
            if permission != "admin" {
                Section {
                    ForEach(Array(projects.enumerated()), id: \.offset) { _, p in
                        let repo = p["repo"].string ?? ""
                        Button {
                            if repos.contains(repo) { repos.remove(repo) } else { repos.insert(repo) }
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(p["label"].nonEmpty ?? repo).foregroundStyle(.primary)
                                    if p["label"].nonEmpty != nil { Text(repo).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                if repos.contains(repo) { Image(systemName: "checkmark").foregroundStyle(Theme.accent).fontWeight(.semibold) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(repos.contains(repo) ? .isSelected : [])
                    }
                    if projects.isEmpty { Text("No projects yet.").foregroundStyle(.secondary) }
                } header: {
                    HStack {
                        Text("Projects")
                        Spacer()
                        if !projects.isEmpty {
                            Button(repos.count == projects.count ? "None" : "All") {
                                repos = repos.count == projects.count ? [] : Set(projects.compactMap { $0["repo"].string })
                            }
                            .buttonStyle(.borderless).font(.footnote)
                        }
                    }
                } footer: { Text("The token sees these projects and no other.") }
                .listRowBackground(Theme.row)
            }
            Section {
                Picker("Expires after", selection: $days) {
                    ForEach(Self.lengths, id: \.self) { d in Text(d == 1 ? "1 day" : "\(d) days").tag(d) }
                }
                Stepper("\(days) day\(days == 1 ? "" : "s")", value: $days, in: 1...365)
            } header: { Text("Expiry") } footer: {
                Text("Stops working on \((Date().addingTimeInterval(Double(days) * 86400)).formatted(date: .abbreviated, time: .omitted)).")
            }
            .listRowBackground(Theme.row)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(action: create) {
                    if creating { ProgressView() } else { Text("Create").fontWeight(.semibold) }
                }
                .disabled(!valid || creating)
            }
        }
        .onAppear { labelFocused = true }
    }

    private func issuedView(_ issued: (token: String, device: JSON)) -> some View {
        Form {
            Section {
                Text(issued.token).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Pasteboard.copy(issued.token)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy token", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            } header: {
                Text(issued.device["label"].nonEmpty ?? "Token")
            } footer: {
                Label("Copy it now: it is not shown again. Anyone holding it can use this dashboard as \(settingsPermissionTitle(issued.device["permission"].string ?? permission)) until it expires or is revoked.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
            }
            .listRowBackground(Theme.row)
            Section {
                LabeledContent("Server", value: store.server)
            } footer: {
                Text("Pair the device with this server address and the token.")
            }
            .listRowBackground(Theme.row)
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.fontWeight(.semibold) }
        }
    }

    private func create() {
        guard valid, !creating else { return }
        var body: JSON = ["label": .string(label.trimmingCharacters(in: .whitespacesAndNewlines)), "permission": .string(permission),
                          "days": JSON(days)]
        // An admin token is held to no project list.
        body["repos"] = JSON(permission == "admin" ? [] : projects.compactMap { $0["repo"].string }.filter { repos.contains($0) })
        creating = true
        error = nil
        Task {
            defer { creating = false }
            do {
                let r = try await store.call("create_device", body)
                guard let token = r["token"].nonEmpty else { error = settingsUnexpectedResponse; return }
                issued = (token, r["device"])
                try? await lists.loadDevices()
            } catch {
                self.error = failure(error)
            }
        }
    }
}
