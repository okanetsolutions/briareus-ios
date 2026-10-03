// Settings › Voice: the OpenAI API key the voice mode connects with, the model it talks to, its voice, how long a
// silence ends a conversation, and what each model's conversations have taken in time and cost, side by side.
import SwiftUI

struct VoiceSettingsScreen: View {
    @ObservedObject private var settings = VoiceSettings.shared
    @ObservedObject private var history = VoiceHistory.shared
    @State private var key = ""
    @State private var error: String?
    @State private var clearing = false

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
                Text("The voice mode talks to OpenAI with this key, which stays in this iPhone's Keychain.")
            }
            .listRowBackground(Theme.row)

            Section {
                Picker("Model", selection: $settings.engine) {
                    ForEach(VoiceEngine.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Voice", selection: $settings.voice) {
                    ForEach(settings.engine.voices, id: \.self) { Text($0.capitalized).tag($0) }
                }
                if settings.engine == .live {
                    LabeledContent("Backend model") {
                        TextField(Voice.defaultBackend, text: $settings.backend)
                            .multilineTextAlignment(.trailing).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }
                Stepper(value: $settings.idleMinutes, in: 0...30) {
                    LabeledContent("End after silence", value: settings.idleMinutes == 0 ? "Never" : "\(settings.idleMinutes) min")
                }
            } header: {
                Text("Conversation")
            } footer: {
                Text(settings.engine == .live
                     ? "GPT-Live bills each minute a conversation is open, by the second; its backend model chooses the actions and bills its tokens apart. Changes apply to the next conversation."
                     : "GPT-Realtime mini chooses the actions itself and bills the audio and text it hears and says, and the transcription of your speech apart. Changes apply to the next conversation.")
            }
            .listRowBackground(Theme.row)

            comparison
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Clear the comparison?", isPresented: $clearing, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { history.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The time and cost of every voice conversation kept on this iPhone are removed.")
        }
    }

    // MARK: Comparison

    private var comparison: some View {
        Section {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Model")
                    Text("Time").gridColumnAlignment(.trailing)
                    Text("Cost").gridColumnAlignment(.trailing)
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Divider()
                ForEach(history.tallies, id: \.engine) { row in
                    GridRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.engine.title).font(.subheadline.weight(.medium))
                            Text("\(row.conversations) conversation\(row.conversations == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(VoiceCost.time(row.seconds)).font(.subheadline.monospacedDigit())
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(VoiceCost.dollars(row.dollars)).font(.subheadline.monospacedDigit())
                            Text(row.perMinute.map { "\(VoiceCost.dollars($0))/min" } ?? "—")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.vertical, 4)
            if !history.records.isEmpty {
                Button("Clear comparison", role: .destructive) { clearing = true }
            }
        } header: {
            Text("Comparison")
        } footer: {
            Text("Every voice conversation on this iPhone, by the model it was with: how long they ran and what they cost, estimated at OpenAI's published prices. OpenAI's bill is the reference.")
        }
        .listRowBackground(Theme.row)
    }

    private func attempt(_ work: () throws -> Void) {
        do { try work(); error = nil } catch { self.error = error.localizedDescription }
    }
}
