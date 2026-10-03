import AVFoundation

/// The microphone and the speaker of a voice session, in the format GPT-Live speaks: mono PCM16 at 24 kHz both ways.
/// The iPhone's voice processing cancels the echo of what is played, so the user can talk over the voice. The audio
/// session stays active for as long as the conversation does, which keeps it going with the phone locked.
final class VoiceAudio: @unchecked Sendable {
    enum Failure: LocalizedError {
        case microphone, start(String)
        var errorDescription: String? {
            switch self {
            case .microphone: return "Allow Briareus to use the microphone in Settings on your iPhone."
            case .start(let why): return "The microphone could not start: \(why)"
            }
        }
    }

    /// Microphone audio ready to send, raw PCM16 bytes. Called on the audio thread.
    var heard: (Data) -> Void = { _ in }
    /// The voice started or finished playing what it was sent. Called on the main thread.
    var playing: (Bool) -> Void = { _ in }
    /// A phone call or another app took the audio; the conversation cannot go on. Called on the main thread.
    var interrupted: () -> Void = {}

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let wire = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Voice.sampleRate, channels: 1, interleaved: true)!
    private let speaker = AVAudioFormat(standardFormatWithSampleRate: Voice.sampleRate, channels: 1)!
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var queued = 0
    private var muted = false
    private var observers: [NSObjectProtocol] = []

    func start() async throws {
        guard await AVAudioApplication.requestRecordPermission() else { throw Failure.microphone }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            try engine.inputNode.setVoiceProcessingEnabled(true)
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: speaker)
            try layTap()
        } catch {
            stop()
            throw Failure.start(error.localizedDescription)
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let kind = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            if kind == .began { self?.interrupted() }
        })
        // A headset plugged in or out changes the input's format; the tap is laid again for the new one.
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self else { return }
            do { try self.layTap() } catch { self.interrupted() }
        })
    }

    /// Lays the tap at the input's current format and (re)starts the engine.
    private func layTap() throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let converter = AVAudioConverter(from: format, to: wire) else {
            throw Failure.start("The microphone has no usable format.")
        }
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 10), format: format) { [weak self] buffer, _ in
            self?.convert(buffer)
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        player.play()
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        lock.withLock { queued = 0 }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// While muted, silence is sent in place of the microphone: the session expects audio to keep flowing.
    func mute(_ on: Bool) { lock.withLock { muted = on } }

    private func convert(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = wire.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: wire, frameCapacity: capacity) else { return }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData else { return }
        let bytes = Int(out.frameLength) * MemoryLayout<Int16>.size
        heard(lock.withLock { muted } ? Data(count: bytes) : Data(bytes: samples[0], count: bytes))
    }

    /// Queues what the voice said, raw PCM16 bytes, after what is already playing.
    func play(_ pcm: Data) {
        let frames = pcm.count / MemoryLayout<Int16>.size
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: speaker, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<frames { channel[i] = Float(Int16(littleEndian: samples[i])) / 32768 }
        }
        let first = lock.withLock { queued += 1; return queued == 1 }
        if first { DispatchQueue.main.async { self.playing(true) } }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            let last = self.lock.withLock { self.queued = max(0, self.queued - 1); return self.queued == 0 }
            if last { DispatchQueue.main.async { self.playing(false) } }
        }
    }

    var isPlaying: Bool { lock.withLock { queued > 0 } }
}
