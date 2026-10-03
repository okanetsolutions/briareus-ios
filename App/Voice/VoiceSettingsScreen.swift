// Settings › Voice: the OpenAI API key the voice mode connects with, its voice, the model that runs its tools, and
// how long a silence ends a conversation.
import SwiftUI

struct VoiceSettingsScreen: View {
    @ObservedObject private var settings = VoiceSettings.shared
    @State private var key = ""
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                if settings.hasKey {
                    Label("API key saved on this iPhone", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.success)
                }
                SecureField(settings.hasKey ? "Replace the API key" : "OpenAI API key", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                    .accessibilityIdentifier("openAIKey")
                Button("Save key") { attempt { try settings.save(key: key); key = "" } }
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                if settings.hasKey {
                    Button("Remove key", role: .destructive) { attempt { try settings.removeKey() } }
                }
                if let error { ErrorNotice(message: error) }
            } header: {
                Text("OpenAI")
            } footer: {
                Text("The voice mode talks to GPT-Live with this key, which stays in this iPhone's Keychain. GPT-Live bills each minute a conversation is open, and the backend model's tokens apart.")
            }
            .listRowBackground(Theme.row)

            Section {
                Picker("Voice", selection: $settings.voice) {
                    ForEach(Voice.voices, id: \.self) { Text($0.capitalized).tag($0) }
                }
                LabeledContent("Backend model") {
                    TextField(Voice.defaultBackend, text: $settings.backend)
                        .multilineTextAlignment(.trailing).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Stepper(value: $settings.idleMinutes, in: 0...30) {
                    LabeledContent("End after silence", value: settings.idleMinutes == 0 ? "Never" : "\(settings.idleMinutes) min")
                }
            } header: {
                Text("Conversation")
            } footer: {
                Text("The backend model chooses which action to run on the server. A change of voice applies to the next conversation.")
            }
            .listRowBackground(Theme.row)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func attempt(_ work: () throws -> Void) {
        do { try work(); error = nil } catch { self.error = error.localizedDescription }
    }
}
