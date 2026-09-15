import Foundation

/// The one seam between the agent bridge client and the network: a WebSocket that carries the
/// bridge's JSON text frames (and the PCM binary frames the client always drops). Production wraps
/// `URLSessionWebSocketTask`; a test scripts frames so the reset handshake — `new_session` out
/// before the next query — can be driven and asserted without a bridge on the network.
///
/// Mirrors `GatewaySocket`, deliberately: the same shape for the same reason.
protocol HermesSocket: AnyObject {
    func send(_ text: String) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel()
}

typealias HermesSocketFactory = (URL) -> HermesSocket

final class URLSessionHermesSocket: HermesSocket {
    private let task: URLSessionWebSocketTask

    init(url: URL) {
        task = URLSession.shared.webSocketTask(with: url)
        task.resume()
    }

    static func make(_ url: URL) -> HermesSocket {
        URLSessionHermesSocket(url: url)
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await task.receive()
    }

    func cancel() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
