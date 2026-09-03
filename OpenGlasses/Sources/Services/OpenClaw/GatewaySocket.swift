import Foundation

/// The one seam between the gateway clients and the network: a text-frame socket. Production
/// wraps `URLSessionWebSocketTask`; tests script frames so both handshakes can be driven
/// headlessly — challenge → connect → hello-ok → request → reply — without a gateway.
protocol GatewaySocket: AnyObject {
    func send(_ text: String) async throws
    func receive() async throws -> String
    func cancel()
}

typealias GatewaySocketFactory = (URLRequest) -> GatewaySocket

final class URLSessionGatewaySocket: GatewaySocket {
    private let task: URLSessionWebSocketTask
    private let session: URLSession

    init(request: URLRequest, timeout: TimeInterval = 30) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        session = URLSession(configuration: config)
        task = session.webSocketTask(with: request)
        task.resume()
    }

    static func make(_ request: URLRequest) -> GatewaySocket {
        URLSessionGatewaySocket(request: request)
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> String {
        switch try await task.receive() {
        case .string(let text): return text
        case .data(let data): return String(data: data, encoding: .utf8) ?? ""
        @unknown default: return ""
        }
    }

    func cancel() {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }
}
