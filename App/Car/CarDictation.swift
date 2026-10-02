#if os(iOS)
import AVFoundation

/// The car's ears: a dictation that ends by itself when the speaker stops. Nothing is ever said back.
/// The audio session is held only while listening, so the car's own audio comes back after it.
@MainActor
final class CarDictation: NSObject, AVAudioRecorderDelegate {
    enum Failure: LocalizedError {
        case microphone, recorder(String)
        var errorDescription: String? {
            switch self {
            case .microphone: return "Allow Briareus to use the microphone in Settings on your iPhone."
            case .recorder(let why): return "The recording could not start: \(why)"
            }
        }
    }
    /// Speech needs no more than this, as a voice note records it; the server writes it out.
    private static let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 22_050, AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000, AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
    ]
    /// Past this a dictation stops by itself, as a voice note does: a forgotten microphone would record on.
    private static let limit: TimeInterval = 5 * 60
    /// Quieter than this is silence, in decibels below full scale.
    private static let quiet: Float = -38
    /// How long a pause ends a dictation once something was said, and how long nothing at all is waited for.
    private static let pause: TimeInterval = 2.2, patience: TimeInterval = 9

    private var recorder: AVAudioRecorder?
    private var heard: CheckedContinuation<Data?, Never>?
    private var meter: Task<Void, Never>?

    var isListening: Bool { recorder != nil }

    /// Records until the speaker pauses, `finish()` is called or the note's limit is reached.
    /// Answers nil when nothing was said or the dictation was dropped.
    func listen() async throws -> Data? {
        guard recorder == nil else { return nil }
        guard await AVAudioApplication.requestRecordPermission() else { throw Failure.microphone }
        guard recorder == nil else { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("car-note-\(UUID().uuidString).m4a")
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playAndRecord, mode: .default, options: [])
            try audio.setActive(true)
            let recorder = try AVAudioRecorder(url: file, settings: Self.settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.record(forDuration: Self.limit) else { throw CocoaError(.fileWriteUnknown) }
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

    private func release() {
        guard recorder == nil else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
#endif
