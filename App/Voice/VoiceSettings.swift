import Foundation

/// What the voice mode connects with: the OpenAI API key, kept in this device's Keychain, and the choices kept in
/// its defaults.
@MainActor
final class VoiceSettings: ObservableObject {
    static let shared = VoiceSettings()

    private static let account = "openai"
    private enum Key { static let voice = "voice.voice", backend = "voice.backend", idle = "voice.idleMinutes" }

    @Published private(set) var hasKey: Bool
    @Published var voice: String { didSet { UserDefaults.standard.set(voice, forKey: Key.voice) } }
    /// The Responses model that runs the tools behind the voice.
    @Published var backend: String { didSet { UserDefaults.standard.set(backend, forKey: Key.backend) } }
    /// Minutes of silence after which a conversation ends by itself, as GPT-Live bills by the minute.
    @Published var idleMinutes: Int { didSet { UserDefaults.standard.set(idleMinutes, forKey: Key.idle) } }

    private init() {
        let d = UserDefaults.standard
        hasKey = ((try? Keychain.read(Self.account, service: Keychain.voice)) ?? nil) != nil
        voice = d.string(forKey: Key.voice) ?? Voice.defaultVoice
        backend = d.string(forKey: Key.backend) ?? Voice.defaultBackend
        idleMinutes = d.object(forKey: Key.idle) as? Int ?? 3
    }

    func key() throws -> String? { try Keychain.read(Self.account, service: Keychain.voice) }

    func save(key: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        try Keychain.save(key, origin: Self.account, service: Keychain.voice)
        hasKey = true
    }

    func removeKey() throws {
        try Keychain.remove(Self.account, service: Keychain.voice)
        hasKey = false
    }

    var backendModel: String {
        let model = backend.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? Voice.defaultBackend : model
    }
}
