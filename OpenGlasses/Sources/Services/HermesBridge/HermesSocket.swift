import Foundation

/// A frame from the bridge. Text carries the protocol's JSON; everything else is the bridge's PCM
/// audio, which this client always declines — so the socket hands it over unopened rather than
/// making every caller re-learn that.
enum HermesFrame: Equatable {
    case text(String)
    case nonText
}

/// The one seam between the agent bridge client and the network: a WebSocket that carries the
/// bridge's frames. Production wraps a web-socket task; a test scripts frames so the reset
/// handshake — `new_session` out before the next query — can be driven and asserted without a
/// bridge on the network.
///
/// Mirrors `GatewaySocket`, deliberately: the same shape for the same reason.
protocol HermesSocket: AnyObject {
    func send(_ text: String) async throws
    func receive() async throws -> HermesFrame
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

    func receive() async throws -> HermesFrame {
        switch try await task.receive() {
        case .string(let text): return .text(text)
        case .data: return .nonText
        @unknown default: return .nonText
        }
    }

    func cancel() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
