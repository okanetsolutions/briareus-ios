import SwiftUI

@main
struct BriareusApp: App {
    @StateObject private var store = AppStore()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            ZStack {
                Group {
                    if store.client != nil {
                        TabView {
                            ProjectsView().tabItem { Label("Projects", systemImage: "square.stack.3d.up") }
                            SettingsView().tabItem { Label("Connection", systemImage: "network") }
                        }
                    } else { PairingView() }
                }
                if phase != .active {
                    Color(.systemBackground).ignoresSafeArea()
                    Label("Briareus", systemImage: "square.stack.3d.up.fill").font(.largeTitle.bold())
                }
            }
            .tint(.indigo)
            .environmentObject(store)
            .task { await store.restore() }
        }
    }
}

struct PairingView: View {
    @EnvironmentObject private var store: AppStore
    @State private var token = ""
    private enum Field { case server, token }
    @FocusState private var focusedField: Field?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "square.stack.3d.up.fill").font(.system(size: 44)).foregroundStyle(.indigo)
                        Text("Your agents, with you.").font(.largeTitle.bold())
                        Text("Connect to your Briareus dashboard to follow work and keep conversations moving.")
                            .foregroundStyle(.secondary)
                    }.padding(.vertical)
                }
                Section("Connect your dashboard") {
                    TextField("https://briareus.example.com", text: $store.server)
                        .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never)
                        .autocorrectionDisabled().accessibilityIdentifier("serverAddress")
                        .focused($focusedField, equals: .server)
                        .submitLabel(.next).onSubmit { focusedField = .token }
                    SecureField("Device token", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .privacySensitive().accessibilityIdentifier("deviceToken")
                        .focused($focusedField, equals: .token)
                        .submitLabel(.done).onSubmit { focusedField = nil }
                    Button {
                        focusedField = nil
                        Task { await store.connect(server: store.server, token: token); if store.client != nil { token = "" } }
                    } label: {
                        HStack { Text("Connect"); Spacer(); if store.connecting { ProgressView() } }
                    }.disabled(store.connecting || store.server.isEmpty || token.isEmpty)
                        .accessibilityIdentifier("connectButton")
                }
                if let error = store.connectionError { Section { ErrorNotice(message: error) } }
                Section {
                    Text("On the web dashboard, open Settings → Mobile devices and create a token for this iPhone. Choose the projects and permissions it needs, then paste the token above.")
                    Text("Tokens stay in this iPhone’s Keychain. Your server must allow the mobile API through Cloudflare Access.")
                        .foregroundStyle(.secondary)
                }
            }.navigationTitle("Briareus")
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { focusedField = nil }
                            .accessibilityIdentifier("dismissKeyboard")
                    }
                }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var confirm: String?
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Connected dashboard") {
                    Text(store.server).textSelection(.enabled)
                    if let device = store.device {
                        LabeledContent("Device", value: device.label)
                        LabeledContent("Access", value: device.canManage ? "Manage" : "Read only")
                        LabeledContent("Expires", value: device.expiry.formatted(date: .abbreviated, time: .omitted))
                    }
                }
                Section("Permitted projects") {
                    ForEach(store.device?.repos ?? [], id: \.self) { Text($0) }
                }
                Section {
                    Button("Revoke token and disconnect", role: .destructive) { confirm = "revoke" }
                    Button("Forget this connection", role: .destructive) { confirm = "forget" }
                } footer: {
                    Text("Revoking disables this token on the server. Forgetting removes it from this phone only; revoke it later in web Settings. Neither action stops running agents.")
                }.disabled(busy)
                if let error { Section { ErrorNotice(message: error) } }
                Section { Text("Briareus for iPhone · 1.0").foregroundStyle(.secondary) }
            }.navigationTitle("Connection")
                .confirmationDialog(confirm == "revoke" ? "Revoke this device token?" : "Forget this connection?",
                                    isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
                    Button("Continue", role: .destructive) {
                        let action = confirm; busy = true
                        Task {
                            defer { busy = false }
                            do { if action == "revoke" { try await store.revoke() } else { try store.forget() } }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                }
        }
    }
}

struct ErrorNotice: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.callout).foregroundStyle(.red).textSelection(.enabled)
            .accessibilityIdentifier("errorNotice")
    }
}
struct StatusLabel: View {
    let status: String
    var body: some View {
        Label(status.capitalized, systemImage: ["running", "preparing"].contains(status) ? "circle.fill" : "circle")
            .font(.caption).foregroundStyle(status == "running" ? .green : .secondary)
    }
}
