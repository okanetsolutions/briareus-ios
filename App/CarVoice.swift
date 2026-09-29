#if os(iOS)
import AVFoundation
import NaturalLanguage

/// The car's ears and mouth: a dictation that ends by itself when the speaker stops, and replies read aloud.
/// The audio session is held only while one of the two is going on, so the car's own audio comes back after it.
@MainActor
final class CarVoice: NSObject, AVSpeechSynthesizerDelegate, AVAudioRecorderDelegate {
    enum Failure: LocalizedError {
        case microphone, recorder(String)
        var errorDescription: String? {
            switch self {
            case .microphone: return "Allow Briareus to use the microphone in Settings on your iPhone."
            case .recorder(let why): return "The recording could not start: \(why)"
            }
        }
    }
    /// Quieter than this is silence, in decibels below full scale.
    private static let quiet: Float = -38
    /// How long a pause ends a dictation once something was said, and how long nothing at all is waited for.
    private static let pause: TimeInterval = 2.2, patience: TimeInterval = 9

    private let synthesizer = AVSpeechSynthesizer()
    private var spoken: CheckedContinuation<Void, Never>?
    private var remaining = 0
    private var recorder: AVAudioRecorder?
    private var heard: CheckedContinuation<Data?, Never>?
    private var meter: Task<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { spoken != nil }
    var isListening: Bool { recorder != nil }

    // MARK: Speaking

    /// Says the text and returns once it was said or stopped. Each paragraph is said in the language it is written in.
    func speak(_ text: String) async {
        stopSpeaking()
        let parts = Self.utterances(text)
        guard !parts.isEmpty, !isListening else { return }
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            try audio.setActive(true)
        } catch { return }
        remaining = parts.count
        await withCheckedContinuation { continuation in
            spoken = continuation
            for part in parts { synthesizer.speak(part) }
        }
        release()
    }
    func stopSpeaking() {
        guard spoken != nil else { return }
        synthesizer.stopSpeaking(at: .immediate)
        said(all: true)
    }
    private func said(all: Bool) {
        remaining = all ? 0 : remaining - 1
        guard remaining <= 0, let done = spoken else { return }
        spoken = nil; done.resume()
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.said(all: false) }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.said(all: true) }
    }

    static func utterances(_ text: String) -> [AVSpeechUtterance] {
        // Sentences keep each utterance short enough to be stopped between two of them and to be given its own voice.
        var parts: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .localized]) { sentence, _, _, _ in
            guard let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty else { return }
            // A few words alone say too little about their language, so they go with their neighbours.
            if let last = parts.last, last.count < 60 || sentence.count < 25 { parts[parts.count - 1] = last + " " + sentence }
            else { parts.append(sentence) }
        }
        return parts.map { part in
            let utterance = AVSpeechUtterance(string: part)
            utterance.voice = voice(for: part)
            utterance.prefersAssistiveTechnologySettings = false
            return utterance
        }
    }
    /// The voice of the language the text is written in, or the phone's own when that cannot be told.
    static func voice(for text: String) -> AVSpeechSynthesisVoice? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage, (recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0) > 0.6 else {
            return AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        }
        let current = AVSpeechSynthesisVoice.currentLanguageCode()
        // The phone's own accent where it speaks that language.
        if current.hasPrefix(language.rawValue + "-") || current == language.rawValue { return AVSpeechSynthesisVoice(language: current) }
        return AVSpeechSynthesisVoice(language: language.rawValue) ?? AVSpeechSynthesisVoice(language: current)
    }

    // MARK: Listening

    /// Records until the speaker pauses, `finish()` is called or the note's limit is reached.
    /// Answers nil when nothing was said or the dictation was dropped.
    func listen() async throws -> Data? {
        stopSpeaking()
        guard recorder == nil else { return nil }
        guard await AVAudioApplication.requestRecordPermission() else { throw Failure.microphone }
        guard recorder == nil else { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("car-note-\(UUID().uuidString).m4a")
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playAndRecord, mode: .default, options: [])
            try audio.setActive(true)
            let recorder = try AVAudioRecorder(url: file, settings: VoiceNote.settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.record(forDuration: VoiceNote.limit) else { throw CocoaError(.fileWriteUnknown) }
            self.recorder = recorder
        } catch {
            release()
            throw Failure.recorder(error.localizedDescription)
        }
        let audio = await withCheckedContinuation { continuation in
            heard = continuation
            meter = Task { [weak self] in await self?.watch() }
        }
        try? FileManager.default.removeItem(at: file)
        release()
        return audio
    }
    /// Ends the dictation and keeps what was said.
    func finish() { recorder?.stop() }
    /// Throws the dictation away.
    func drop() { close(keeping: false) }

    private func watch() async {
        let started = Date()
        var spoke = false
        var quietSince = Date()
        while !Task.isCancelled, let recorder, recorder.isRecording {
            recorder.updateMeters()
            let now = Date()
            if recorder.averagePower(forChannel: 0) > Self.quiet { spoke = true; quietSince = now }
            if spoke, now.timeIntervalSince(quietSince) > Self.pause { finish(); return }
            if !spoke, now.timeIntervalSince(started) > Self.patience { drop(); return }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }
    private func close(keeping: Bool) {
        guard let recorder else { return }
        self.recorder = nil
        meter?.cancel(); meter = nil
        recorder.delegate = nil; recorder.stop()
        let audio = keeping ? try? Data(contentsOf: recorder.url) : nil
        heard?.resume(returning: audio.flatMap { $0.isEmpty ? nil : $0 }); heard = nil
    }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in if self.recorder === recorder { self.close(keeping: flag) } }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in if self.recorder === recorder { self.close(keeping: false) } }
    }

    /// Stops whatever is going on, as when the car is left.
    func silence() { stopSpeaking(); drop(); release() }

    private func release() {
        guard spoken == nil, recorder == nil else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
#endif
