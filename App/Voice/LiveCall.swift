import AVFoundation
import WebRTC

/// A WebRTC call to GPT-Live: the microphone goes out and the voice comes back on audio tracks, which WebRTC plays with
/// its own echo cancellation and jitter buffer; JSON events travel on a data channel. The OpenAI key is sent from
/// this device, where it is kept in the Keychain, only to start the session.
final class LiveCall: NSObject, @unchecked Sendable {
    enum Failure: LocalizedError {
        case microphone, refused, offer, answer(String), dropped
        var errorDescription: String? {
            switch self {
            case .microphone: return "Allow Briareus to use the microphone in Settings on your iPhone."
            case .refused: return "OpenAI refused the API key. Check it in Settings › Voice."
            case .offer: return "The call could not be prepared on this iPhone."
            case .answer(let why): return "GPT-Live did not start the conversation: \(why)"
            case .dropped: return "The connection with GPT-Live was lost."
            }
        }
    }

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        // A voice chat on the loudspeaker unless a headset is in use, with Bluetooth headsets' microphones allowed.
        let audio = RTCAudioSessionConfiguration.webRTC()
        audio.category = AVAudioSession.Category.playAndRecord.rawValue
        audio.mode = AVAudioSession.Mode.voiceChat.rawValue
        audio.categoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP, headset]
        RTCAudioSessionConfiguration.setWebRTC(audio)
        return RTCPeerConnectionFactory()
    }()
    /// A Bluetooth headset's microphone: named apart from iOS 26's SDK on, which CI's older Xcode does not have.
    private static var headset: AVAudioSession.CategoryOptions {
        #if compiler(>=6.2)
        .allowBluetoothHFP
        #else
        .allowBluetooth
        #endif
    }

    private var peer: RTCPeerConnection?
    private var channel: RTCDataChannel?
    private var microphone: RTCAudioTrack?
    private let lock = NSLock()
    private var events: AsyncThrowingStream<JSON, Error>.Continuation?
    private var gathered: CheckedContinuation<Void, Never>?

    /// Starts the call: asks for the microphone, offers the call to GPT-Live with `body(offer)` as the session, and
    /// answers the events of the data channel until the call ends.
    func open(key: String, body: @escaping (String) -> JSON) async throws -> AsyncThrowingStream<JSON, Error> {
        guard await AVAudioApplication.requestRecordPermission() else { throw Failure.microphone }
        let (stream, continuation) = AsyncThrowingStream<JSON, Error>.makeStream()
        lock.withLock { events = continuation }

        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherOnce
        let none = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peer = Self.factory.peerConnection(with: config, constraints: none, delegate: self) else { throw Failure.offer }
        self.peer = peer
        let source = Self.factory.audioSource(with: none)
        let microphone = Self.factory.audioTrack(with: source, trackId: "microphone")
        peer.add(microphone, streamIds: ["microphone"])
        self.microphone = microphone
        guard let channel = peer.dataChannel(forLabel: Voice.channel, configuration: RTCDataChannelConfiguration()) else { throw Failure.offer }
        channel.delegate = self
        self.channel = channel

        let receive = RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true"], optionalConstraints: nil)
        let offer = try await peer.offer(for: receive)
        try await peer.setLocalDescription(offer)
        await gathering()
        guard let sdp = peer.localDescription?.sdp else { throw Failure.offer }

        var request = URLRequest(url: Voice.endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body(sdp).data
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw Failure.refused }
        let answer = JSON.parse(data) ?? .null
        guard (200..<300).contains(status), let remote = answer["transport"]["sdp"].string else {
            throw Failure.answer(answer["error"]["message"].string ?? "HTTP \(status)")
        }
        try await peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: remote))
        return stream
    }

    /// Waits for the local network candidates to be in the offer, for a few seconds at most.
    private func gathering() async {
        guard peer?.iceGatheringState != .complete else { return }
        await withCheckedContinuation { continuation in
            lock.withLock { gathered = continuation }
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) { [weak self] in self?.doneGathering() }
        }
    }
    private func doneGathering() {
        lock.withLock { let c = gathered; gathered = nil; return c }?.resume()
    }

    func send(_ event: JSON) {
        channel?.sendData(RTCDataBuffer(data: event.data, isBinary: false))
    }

    /// While muted, the microphone's track sends silence.
    func mute(_ on: Bool) { microphone?.isEnabled = !on }

    func close() {
        doneGathering()
        channel?.close()
        peer?.close()
        channel = nil; peer = nil; microphone = nil
        finish(nil)
    }

    private func finish(_ error: Error?) {
        lock.withLock { let c = events; events = nil; return c }?.finish(throwing: error)
    }
}

extension LiveCall: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete { doneGathering() }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        if newState == .failed || newState == .closed { finish(newState == .failed ? Failure.dropped : nil) }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

extension LiveCall: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if dataChannel.readyState == .closed { finish(nil) }
    }
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let event = JSON.parse(buffer.data) else { return }
        _ = lock.withLock { events }?.yield(event)
    }
}
