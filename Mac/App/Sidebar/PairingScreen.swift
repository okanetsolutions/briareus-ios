// Pairing with a server: its HTTPS address and the device token, in a 520px column under the logo.
import SwiftUI

struct PairingScreen: View {
    @EnvironmentObject private var store: Store
    @State private var server = ""
    @State private var token = ""
    @FocusState private var focus: Field?
    private enum Field { case server, token }

    private var canConnect: Bool {
        !store.connecting && !server.trimmingCharacters(in: .whitespaces).isEmpty && !token.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: Glyph.symbol(0xE81E)).font(.system(size: 30)).foregroundStyle(Theme.accent)
                    .frame(width: 52, height: 52)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Theme.accent.opacity(0.14)))
                    .padding(.bottom, 14)
                Text("Connect to Briareus").font(Theme.largeTitle).foregroundStyle(Theme.ink)
                    .padding(.bottom, 24)
                VStack(spacing: 0) {
                    row(glyph: 0xE774) {
                        TextField("https://briareus.example.com", text: $server)
                            .focused($focus, equals: .server)
                            .onSubmit { focus = .token }
                    }
                    Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 44)
                    row(glyph: 0xE8D7) {
                        SecureField("Token", text: $token)
                            .focused($focus, equals: .token)
                            .onSubmit(connect)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 18).fill(Theme.raise))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.line, lineWidth: 1))
                Text("Create a token on the web dashboard under Settings → Devices and clients, with Manage or Read-only access.")
                    .font(Theme.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4).padding(.top, 8)
                Button(action: connect) { Text(store.connecting ? "Connecting…" : "Connect") }
                    .dashButton(.prominent, stretch: true)
                    .disabled(!canConnect)
                    .padding(.top, 24)
                if let error = store.connectionError {
                    NoticeBox(message: error).padding(.top, 16)
                }
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 16)
            .padding(.top, 48).padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.canvas)
        .onAppear {
            server = store.server
            focus = store.server.isEmpty ? .server : .token
        }
    }

    private func row<F: View>(glyph: UInt32, @ViewBuilder field: () -> F) -> some View {
        HStack(spacing: 10) {
            Image(systemName: Glyph.symbol(glyph)).font(.system(size: 14)).foregroundStyle(Theme.muted).frame(width: 20)
            field().textFieldStyle(.plain).font(Theme.body)
        }
        .padding(.horizontal, 14).frame(height: 48)
    }

    private func connect() {
        guard canConnect else { return }
        store.connect(server: server, token: token)
    }
}
