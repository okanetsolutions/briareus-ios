// Voice notes, as the Mac's (voice.c): one at a time, recorded on the phone as AAC, transcribed by the server, its text
// handed to a composer. The server is asked whether it transcribes before the microphone opens.
import AVFoundation
import SwiftUI

@MainActor
final class PhoneVoiceNote: NSObject, ObservableObject, AVAudioRecorderDelegate {
    enum State { case idle, starting, recording, transcribing }
    @Published private(set) var state: State = .idle
    @Published private(set) var started = Date()
    /// Why the last note came to nothing, for an alert.
    @Published var error: String?
    /// Past this a note stops by itself and is transcribed: a forgotten microphone would record on.
    static let limit: TimeInterval = 300
    /// Speech needs no more than this, and five minutes of it stay near a megabyte.
    private static let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 22_050, AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000, AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
    ]
    private var recorder: AVAudioRecorder?
    private var work: Task<Void, Never>?
    private var generation = 0
    /// The transcribed text, for the composer to append.
    var onText: (String) -> Void = { _ in }

    var busy: Bool { state != .idle }

    /// Asks the server whether it transcribes, then for the microphone, then records.
    func record() {
        guard state == .idle else { return }
        state = .starting; error = nil
        generation += 1
        let mine = generation
        work = Task {
            if let reason = await Store.shared.voiceNotesOff() {
                guard generation == mine, state == .starting else { return }
                state = .idle; error = reason; return
            }
            guard generation == mine, state == .starting else { return }
            guard Store.shared.canTranscribe else { state = .idle; return }
            let allowed = await AVAudioApplication.requestRecordPermission()
            // Dropped while the permission prompt was up.
            guard generation == mine, state == .starting else { return }
            guard allowed else {
                state = .idle; error = "Allow Briareus to use the microphone in Settings to record voice notes."; return
            }
            do {
                let audio = AVAudioSession.sharedInstance()
                try audio.setCategory(.record, mode: .default)
                try audio.setActive(true)
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("voice-note-\(UUID().uuidString).m4a")
                let recorder = try AVAudioRecorder(url: file, settings: Self.settings)
                recorder.delegate = self
                guard recorder.record(forDuration: Self.limit) else { throw CocoaError(.fileWriteUnknown) }
                self.recorder = recorder
                started = Date(); state = .recording
            } catch {
                finish(); self.error = "The voice note could not be recorded: \(error.localizedDescription)"
            }
        }
    }
    /// Ends the recording; its text is on the way once the file is closed and transcribed.
    func stop() {
        guard state == .recording else { return }
        state = .transcribing
        recorder?.stop()
    }
    /// Throws the note away, recorded or on its way to the server, so nothing is transcribed for nobody.
    func drop() {
        guard state != .idle else { return }
        finish()
    }
    private func finish() {
        generation += 1
        work?.cancel(); work = nil
        if let recorder {
            recorder.delegate = nil
            recorder.stop()
            try? FileManager.default.removeItem(at: recorder.url)
        }
        recorder = nil
        state = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func recorded(_ file: URL, complete: Bool) {
        // Reached by stop(), the time limit or an interruption; a dropped note has no recorder left.
        guard let recorder, recorder.url == file else { return }
        state = .transcribing
        guard complete, let audio = try? Data(contentsOf: file), !audio.isEmpty else {
            finish(); error = "The voice note could not be recorded."; return
        }
        let mine = generation
        work = Task {
            do {
                let text = try await Store.shared.transcribe(audio, contentType: "audio/mp4")
                guard generation == mine else { return }
                finish()
                if !text.isEmpty { onText(text) }
            } catch {
                guard generation == mine, !error.isCancellation else { return }
                finish()
                self.error = "The voice note could not be transcribed: \(errorText(error))"
            }
        }
    }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let file = recorder.url
        Task { @MainActor in self.recorded(file, complete: flag) }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let file = recorder.url
        Task { @MainActor in self.recorded(file, complete: false) }
    }
}

/// The composer's microphone: tap to record, tap again to have the note transcribed onto the end of the text; while
/// recording, its clock and a button that discards it.
struct VoiceNoteControls: View {
    @ObservedObject var voice: PhoneVoiceNote
    var enabled = true
    var body: some View {
        HStack(spacing: 6) {
            if voice.state == .recording {
                TimelineView(.periodic(from: voice.started, by: 1)) { context in
                    Text(formatClock(Int(context.date.timeIntervalSince(voice.started))))
                        .font(.caption.monospacedDigit()).foregroundStyle(Theme.danger)
                }
            }
            if voice.state == .recording || voice.state == .transcribing {
                Button { voice.drop() } label: {
                    Image(systemName: "xmark").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 32, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Discard the voice note")
            }
            Button {
                if voice.state == .recording { voice.stop() } else { voice.record() }
            } label: {
                Group {
                    switch voice.state {
                    case .recording: Image(systemName: "stop.fill").foregroundStyle(.white)
                    case .transcribing, .starting: ProgressView().controlSize(.small)
                    case .idle: Image(systemName: "mic.fill").foregroundStyle(.primary)
                    }
                }
                .font(.footnote).frame(width: 32, height: 32)
                .background(voice.state == .recording ? Theme.danger : Theme.bubble, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled || voice.state == .starting || voice.state == .transcribing)
            .accessibilityIdentifier("voiceNote")
            .accessibilityLabel(voice.state == .recording ? "Stop and transcribe the voice note"
                                : voice.state == .transcribing ? "Transcribing the voice note" : "Record a voice note")
        }
        .alert("Voice note", isPresented: Binding(get: { voice.error != nil }, set: { if !$0 { voice.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(voice.error ?? "") }
    }
}
