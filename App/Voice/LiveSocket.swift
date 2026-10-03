import Foundation

/// The WebSocket to GPT-Live: JSON events both ways, audio inside them as base64. The OpenAI key is sent from this
/// device, where it is kept in the Keychain.
final class LiveSocket: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let session: URLSession

    init(key: String) {
        var request = URLRequest(url: Voice.endpoint)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        session = URLSession(configuration: .default)
        task = session.webSocketTask(with: request)
        // Output audio arrives in events of its own; a generous limit keeps a long one from closing the socket.
        task.maximumMessageSize = 16 * 1024 * 1024
    }

    /// Opens the socket; the events arrive until it closes, or end with the error that closed it.
    func open() -> AsyncThrowingStream<JSON, Error> {
        task.resume()
        let task = self.task
        return AsyncThrowingStream { continuation in
            let reader = Task {
                do {
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        let event: JSON?
                        switch message {
                        case .string(let text): event = JSON.parse(text)
                        case .data(let data): event = JSON.parse(data)
                        @unknown default: event = nil
                        }
                        if let event { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: task.closeCode == .normalClosure ? nil : LiveSocket.failure(task, error))
                }
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
    }

    func send(_ event: JSON) {
        task.send(.string(event.serialized())) { _ in }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
        session.finishTasksAndInvalidate()
    }

    /// What closed the socket, as the user can act on it: a refused key says so.
    private static func failure(_ task: URLSessionWebSocketTask, _ error: Error) -> Error {
        if let http = task.response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
            return APIError.refused("OpenAI refused the API key. Check it in Settings › Voice.")
        }
        if let reason = task.closeReason.flatMap({ String(data: $0, encoding: .utf8) }), !reason.isEmpty {
            return APIError(.network, message: "GPT-Live closed the conversation: \(reason)")
        }
        return error
    }
}
