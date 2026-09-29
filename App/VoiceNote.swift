import SwiftUI
import AVFoundation

/// One voice note at a time: recorded on the phone, transcribed by the server, its text handed to the composer.
@MainActor
final class VoiceNote: NSObject, ObservableObject, AVAudioRecorderDelegate {
    enum State { case idle, starting, recording, transcribing }
    @Published private(set) var state: State = .idle
    @Published private(set) var started = Date()
    @Published var error: String?
    func refuse(_ reason: String) { if state == .idle { error = reason } }
    /// Past this a note stops by itself and is transcribed, as on the dashboard: a forgotten microphone would record on.
    static let limit: TimeInterval = 5 * 60
    /// Speech needs no more than this, and five minutes of it stay near a megabyte.
    static let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 22_050, AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000, AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
    ]
    private var recorder: AVAudioRecorder?
    private var upload: Task<Void, Never>?
    private var transcribe: ((Data) async throws -> String)?
    private var deliver: ((String) -> Void)?

    func start(transcribe: @escaping (Data) async throws -> String, deliver: @escaping (String) -> Void) async {
        guard state == .idle else { return }
        state = .starting; error = nil
        guard await AVAudioApplication.requestRecordPermission() else {
            state = .idle; error = "Allow Briareus to use the microphone in Settings to record voice notes."
            return
        }
        // Dropped while the permission prompt was up.
        guard state == .starting else { return }
        do {
            // A Mac has no audio session to claim: the recorder takes the input by itself.
            #if !os(macOS)
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.record, mode: .default)
            try audio.setActive(true)
            #endif
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("voice-note-\(UUID().uuidString).m4a")
            let recorder = try AVAudioRecorder(url: file, settings: Self.settings)
            recorder.delegate = self
            guard recorder.record(forDuration: Self.limit) else { throw CocoaError(.fileWriteUnknown) }
            self.recorder = recorder; self.transcribe = transcribe; self.deliver = deliver
            started = Date(); state = .recording
        } catch {
            finish(); self.error = "The voice note could not be recorded: \(error.localizedDescription)"
        }
    }
    /// Ends the recording; its text is on the way once the recorder has closed the file.
    func stop() {
        guard state == .recording else { return }
        state = .transcribing; recorder?.stop()
    }
    /// Throws the note away, recorded or on its way to the server, so nothing is transcribed for nobody.
    func drop() {
        guard state != .idle else { return }
        upload?.cancel(); finish()
    }
    private func finish() {
        let file = recorder?.url
        recorder?.delegate = nil; recorder?.stop(); recorder = nil
        if let file { try? FileManager.default.removeItem(at: file) }
        upload = nil; transcribe = nil; deliver = nil; state = .idle
        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
    private func recorded(_ file: URL, complete: Bool) {
        // Reached by stop(), the time limit or an interruption; a dropped note has no recorder left.
        guard recorder?.url == file, let transcribe, let deliver else { return }
        guard complete, let audio = try? Data(contentsOf: file), !audio.isEmpty else {
            finish(); error = "The voice note could not be recorded."
            return
        }
        state = .transcribing
        upload = Task {
            do {
                let text = try await transcribe(audio)
                guard !Task.isCancelled else { return }
                finish()
                if !text.isEmpty { deliver(text) }
            } catch {
                guard !Task.isCancelled else { return }
                finish(); self.error = "The voice note could not be transcribed: \(error.localizedDescription)"
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

/// The composer's microphone: tap to record, tap again to have the note transcribed onto the end of the text.
struct VoiceNoteButton: View {
    @Binding var text: String
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var phase
    @StateObject private var note = VoiceNote()
    var body: some View {
        HStack(spacing: 8) {
            switch note.state {
            case .idle, .starting: EmptyView()
            case .recording:
                TimelineView(.periodic(from: note.started, by: 1)) { context in
                    let elapsed = Duration.seconds(max(0, context.date.timeIntervalSince(note.started)))
                    Text(elapsed.formatted(.time(pattern: .minuteSecond)))
                        .font(.caption.monospacedDigit()).foregroundStyle(Theme.danger)
                }
                Button("Discard", systemImage: "xmark") { note.drop() }
                    .labelStyle(.iconOnly).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .accessibilityLabel("Discard the voice note")
            case .transcribing:
                Button("Discard", systemImage: "xmark") { note.drop() }
                    .labelStyle(.iconOnly).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .accessibilityLabel("Discard the voice note")
            }
            Button {
                if note.state == .recording { note.stop() } else { record() }
            } label: {
                Group {
                    switch note.state {
                    case .recording: Image(systemName: "stop.fill").foregroundStyle(.white)
                    case .transcribing, .starting: ProgressView()
                    case .idle: Image(systemName: "mic.fill").foregroundStyle(.primary)
                    }
                }
                .font(.footnote).frame(width: 32, height: 32)
                .background(note.state == .recording ? Theme.danger : Theme.bubble, in: Circle())
            }
            .disabled(note.state == .starting || note.state == .transcribing)
            .accessibilityIdentifier("voiceNote")
            .accessibilityLabel(note.state == .recording ? "Stop and transcribe the voice note"
                                : note.state == .transcribing ? "Transcribing the voice note" : "Record a voice note")
        }
        // Recording cannot go on in the background: what was said until then is transcribed, as if stopped.
        .onChange(of: phase) { if !phase.isInUse { note.stop() } }
        .onDisappear { note.drop() }
        .alert("Voice note", isPresented: Binding(get: { note.error != nil }, set: { if !$0 { note.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(note.error ?? "") }
    }
    private func record() {
        Task {
            if let reason = await store.voiceNotesOff() { note.refuse(reason); return }
            guard store.canTranscribe else { return }
            // No language is named: the server detects the spoken one, as for the dashboard's notes.
            await note.start(transcribe: { try await store.transcribe($0) }) { transcript in
                // It lands at the end of the box, to correct before sending.
                let gap = text.isEmpty || text.last?.isWhitespace == true ? "" : " "
                text += gap + transcript
            }
        }
    }
}
