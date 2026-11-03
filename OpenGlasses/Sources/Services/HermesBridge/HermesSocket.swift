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
    /// What the transport learned about the connection, read when it fails so Test Connection can
    /// say why (Plan JP). Defaults to nothing known, so a scripted socket need not implement it.
    func diagnostics() -> HermesSocketDiagnostics
}

/// The evidence a failed WebSocket leaves behind: the HTTP status of the upgrade answer (101 when
/// the socket opened; anything else means something answered plain HTTP instead) and the close
/// code the far side sent. Read by `HermesConnectionDiagnosis.bridgeFailure`.
struct HermesSocketDiagnostics: Equatable, Sendable {
    var httpStatus: Int?
    var closeCode: Int?
}

extension HermesSocket {
    func diagnostics() -> HermesSocketDiagnostics { HermesSocketDiagnostics() }
}

typealias HermesSocketFactory = (URL) -> HermesSocket

final class URLSessionHermesSocket: HermesSocket {
    private let authorization = CloudProcessingSocketAuthorization()
    private let task: URLSessionWebSocketTask

    init(url: URL) {
        task = URLSession.shared.webSocketTask(with: url)
        // Deliberately suspended until send/receive obtains sharing permission.
    }

    static func make(_ url: URL) -> HermesSocket {
        URLSessionHermesSocket(url: url)
    }

    func send(_ text: String) async throws {
        try await authorization.prepare(task, session: URLSession.shared, scope: .conversation)
        try authorization.requireValid()
        try await task.send(.string(text))
    }

    func receive() async throws -> HermesFrame {
        try await authorization.prepare(task, session: URLSession.shared, scope: .conversation)
        switch try await task.receive() {
        case .string(let text): return .text(text)
        case .data: return .nonText
        @unknown default: return .nonText
        }
    }

    func cancel() {
        authorization.cancel()
        task.cancel(with: .normalClosure, reason: nil)
    }

    func diagnostics() -> HermesSocketDiagnostics {
        let status = (task.response as? HTTPURLResponse)?.statusCode
        let close = task.closeCode == .invalid ? nil : task.closeCode.rawValue
        return HermesSocketDiagnostics(httpStatus: status, closeCode: close)
    }
}
