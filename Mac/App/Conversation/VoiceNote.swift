// Voice notes (voice.c): one at a time, recorded from the microphone as AAC, transcribed by the server, its text handed to
// a composer. The server is asked whether it transcribes before the microphone opens.
import AVFoundation
import SwiftUI

@MainActor
final class VoiceNote: NSObject, ObservableObject, AVAudioRecorderDelegate {
    enum State { case idle, starting, recording, transcribing }
    @Published private(set) var state: State = .idle
    @Published private(set) var started = Date()
    /// Past this a note stops by itself and is transcribed: a forgotten microphone would record on.
    static let limit: TimeInterval = 300
    /// Speech needs no more than this: 96 kbit/s keeps five minutes near three megabytes.
    private static let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000,
    ]
    private var recorder: AVAudioRecorder?
    private var work: Task<Void, Never>?
    private var generation = 0
    /// The transcribed text, for the composer to append.
    var onText: (String) -> Void = { _ in }

    /// Seconds recorded so far.
    func elapsed(at now: Date = Date()) -> Int { state == .recording ? Int(now.timeIntervalSince(started)) : 0 }

    private func fail(_ message: String) { Dialogs.alert("Voice note", message) }

    /// Asks the server whether it transcribes, then the microphone, then records.
    func record() {
        guard state == .idle else { return }
        state = .starting
        generation += 1
        let mine = generation
        work = Task {
            if let reason = await Store.shared.voiceNotesOff() {
                guard self.generation == mine, self.state == .starting else { return }
                self.state = .idle; self.fail(reason); return
            }
            guard self.generation == mine, self.state == .starting else { return }
            guard Store.shared.canTranscribe else { self.state = .idle; return }
            guard AVCaptureDevice.default(for: .audio) != nil else { self.state = .idle; self.fail("No microphone was found."); return }
            var allowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                allowed = await AVCaptureDevice.requestAccess(for: .audio)
            }
            // Dropped while the permission prompt was up.
            guard self.generation == mine, self.state == .starting else { return }
            guard allowed else {
                self.state = .idle
                self.fail("Allow Briareus to use the microphone in System Settings \u{2192} Privacy & Security \u{2192} Microphone to record voice notes.")
                return
            }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("briareus-voice-\(UUID().uuidString).m4a")
            guard let recorder = try? AVAudioRecorder(url: file, settings: VoiceNote.settings) else {
                self.state = .idle; self.fail("The microphone could not be started."); return
            }
            recorder.delegate = self
            guard recorder.record(forDuration: VoiceNote.limit) else {
                try? FileManager.default.removeItem(at: file)
                self.state = .idle; self.fail("The microphone could not be started."); return
            }
            self.recorder = recorder
            self.started = Date()
            self.state = .recording
        }
    }
    /// Ends the recording; its text is on the way once the file is closed and transcribed.
    func stop() {
        guard state == .recording else { return }
        state = .transcribing
        recorder?.stop()
    }
    /// Throws the note away, recorded or on its way to the server.
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
    }

    private func recorded(_ file: URL, complete: Bool) {
        // Reached by stop() or the time limit; a dropped note has no recorder left.
        guard let recorder, recorder.url == file else { return }
        state = .transcribing
        guard complete, let audio = try? Data(contentsOf: file), !audio.isEmpty else {
            finish(); fail("The voice note could not be recorded."); return
        }
        let mine = generation
        work = Task {
            do {
                let text = try await Store.shared.transcribe(audio, contentType: "audio/mp4")
                guard self.generation == mine else { return }
                self.finish()
                if !text.isEmpty { self.onText(text) }
            } catch {
                guard self.generation == mine, !error.isCancellation else { return }
                self.finish()
                self.fail("The voice note could not be transcribed: \(errorText(error))")
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

/// The microphone button: 🎤, ■ while recording on the danger colour, … while starting or transcribing.
struct MicButton: View {
    @ObservedObject var voice: VoiceNote
    var body: some View {
        let rec = voice.state == .recording
        Button {
            if rec { voice.stop() } else if voice.state == .idle { voice.record() }
        } label: {
            Text(rec ? "\u{25A0}" : (voice.state == .transcribing || voice.state == .starting) ? "\u{2026}" : "\u{1F3A4}")
                .font(.system(size: 15)).foregroundStyle(rec ? Color.white : Theme.muted)
                .frame(width: 32, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(rec ? Theme.danger : Theme.raise))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(rec ? Theme.danger : Theme.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(rec ? "Stop and transcribe" : "Record a voice note")
    }
}

/// The recording's clock, `m:ss` in the danger colour.
struct VoiceClock: View {
    @ObservedObject var voice: VoiceNote
    var body: some View {
        if voice.state == .recording {
            TimelineView(.periodic(from: voice.started, by: 1)) { context in
                Text(formatClock(voice.elapsed(at: context.date))).font(Theme.caption).foregroundStyle(Theme.danger).monospacedDigit()
            }
        }
    }
}
