import Foundation

/// What the voice mode connects with: the OpenAI API key, kept in this device's Keychain, and the choices kept in
/// its defaults.
@MainActor
final class VoiceSettings: ObservableObject {
    static let shared = VoiceSettings()

    private static let account = "openai"
    private enum Key {
        static let engine = "voice.engine", voice = "voice.voice", backend = "voice.backend", idle = "voice.idleMinutes"
    }

    @Published private(set) var hasKey: Bool
    /// The model the next conversation is with.
    @Published var engine: VoiceEngine {
        didSet {
            UserDefaults.standard.set(engine.rawValue, forKey: Key.engine)
            voice = engine.voice(voice)
        }
    }
    /// The voice, one the model has.
    @Published var voice: String { didSet { UserDefaults.standard.set(voice, forKey: Key.voice) } }
    /// The Responses model that runs GPT-Live's tools.
    @Published var backend: String { didSet { UserDefaults.standard.set(backend, forKey: Key.backend) } }
    /// Minutes of silence after which a conversation ends by itself, as either model bills one left open.
    @Published var idleMinutes: Int { didSet { UserDefaults.standard.set(idleMinutes, forKey: Key.idle) } }

    private init() {
        let d = UserDefaults.standard
        hasKey = ((try? Keychain.read(Self.account, service: Keychain.voice)) ?? nil) != nil
        let engine = d.string(forKey: Key.engine).flatMap(VoiceEngine.init) ?? .live
        self.engine = engine
        voice = engine.voice(d.string(forKey: Key.voice) ?? Voice.defaultVoice)
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

/// The finished conversations, kept on this phone to compare the models' time and cost in Settings.
@MainActor
final class VoiceHistory: ObservableObject {
    static let shared = VoiceHistory()
    private static let key = "voice.history"
    /// The newest kept; older ones fall off.
    private static let limit = 1000

    @Published private(set) var records: [VoiceRecord]

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.key).flatMap(JSON.parse) ?? []
        records = saved.items.compactMap(VoiceRecord.init)
    }

    var tallies: [VoiceTally] { VoiceTally.rows(records) }

    func add(_ record: VoiceRecord) {
        records.append(record)
        if records.count > Self.limit { records.removeFirst(records.count - Self.limit) }
        save()
    }

    func clear() {
        records = []
        save()
    }

    private func save() {
        UserDefaults.standard.set(JSON.array(records.map(\.json)).serialized(), forKey: Self.key)
    }
}
