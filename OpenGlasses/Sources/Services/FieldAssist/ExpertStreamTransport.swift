import Foundation
import Combine
import UIKit

/// Selectable transport for streaming the glasses view to a remote expert during an escalation.
///
/// Two implementations:
///   - `MJPEGExpertTransport` — the shipped one-way MJPEG-over-WebSocket stream to a browser viewer.
///   - `WebRTCPeerTransport` — a drop-in seam for a real peer-to-peer WebRTC stream (two-way A/V,
///     lower latency). Not bundled: it requires a WebRTC library plus signaling + TURN servers.
///     `isAvailable` is false until that's wired, so selecting it reports clearly rather than failing
///     silently or pretending to be MJPEG.
@MainActor
protocol ExpertStreamTransport {
    var displayName: String { get }
    /// Whether this transport can actually stream in the current build.
    var isAvailable: Bool { get }
    var isStreaming: Bool { get }
    /// Start streaming; returns a shareable join URL for the expert (nil if none).
    func start(framePublisher: PassthroughSubject<UIImage, Never>) async throws -> String?
    func stop() async
}

enum ExpertStreamKind: String, CaseIterable {
    case mjpeg
    case webrtc

    var label: String {
        switch self {
        case .mjpeg: return "MJPEG (browser viewer)"
        case .webrtc: return "WebRTC (peer-to-peer)"
        }
    }
}

enum ExpertStreamError: LocalizedError {
    case transportUnavailable(String)
    var errorDescription: String? {
        switch self {
        case .transportUnavailable(let msg): return msg
        }
    }
}

/// Working transport: wraps the existing `WebRTCStreamingService` (MJPEG over WebSocket).
@MainActor
final class MJPEGExpertTransport: ExpertStreamTransport {
    private let streamer: WebRTCStreamingService
    init(streamer: WebRTCStreamingService) { self.streamer = streamer }

    var displayName: String { ExpertStreamKind.mjpeg.label }
    var isAvailable: Bool { true }
    var isStreaming: Bool { streamer.isStreaming }

    func start(framePublisher: PassthroughSubject<UIImage, Never>) async throws -> String? {
        streamer.startStreaming(framePublisher: framePublisher)
    }
    func stop() async { streamer.stopStreaming() }
}

/// Drop-in seam for a real WebRTC peer connection. Reports unavailable until a WebRTC package +
/// signaling/TURN are added; replace the body of `start` (and flip `isAvailable`) at that point.
@MainActor
final class WebRTCPeerTransport: ExpertStreamTransport {
    var displayName: String { ExpertStreamKind.webrtc.label }
    var isAvailable: Bool { false }
    var isStreaming: Bool { false }

    func start(framePublisher: PassthroughSubject<UIImage, Never>) async throws -> String? {
        throw ExpertStreamError.transportUnavailable(
            "WebRTC transport isn't bundled in this build. Switch the Expert Stream transport to MJPEG, or add a WebRTC package + signaling/TURN to enable peer-to-peer.")
    }
    func stop() async {}
}

/// `ExpertBridge` that streams via the transport selected in `Config.expertStreamTransport`.
/// Used by `EscalationCoordinator` (Field Assist Phase 5).
@MainActor
final class ExpertStreamBridge: ExpertBridge {
    private let transports: [ExpertStreamKind: ExpertStreamTransport]
    private let framePublisher: PassthroughSubject<UIImage, Never>
    private var active: ExpertStreamTransport?

    private(set) var roomURL: String?

    init(transports: [ExpertStreamKind: ExpertStreamTransport],
         framePublisher: PassthroughSubject<UIImage, Never>) {
        self.transports = transports
        self.framePublisher = framePublisher
    }

    /// Convenience: MJPEG backed by the app's streamer + the WebRTC seam.
    convenience init(streamer: WebRTCStreamingService, framePublisher: PassthroughSubject<UIImage, Never>) {
        self.init(transports: [.mjpeg: MJPEGExpertTransport(streamer: streamer),
                               .webrtc: WebRTCPeerTransport()],
                  framePublisher: framePublisher)
    }

    var isConnected: Bool { active?.isStreaming ?? false }

    func connect(sessionId: String, expertId: String?) async throws {
        let kind = Config.expertStreamTransport
        guard let transport = transports[kind] else {
            throw ExpertStreamError.transportUnavailable("No transport for \(kind.rawValue).")
        }
        guard transport.isAvailable else {
            throw ExpertStreamError.transportUnavailable("\(transport.displayName) isn't available in this build.")
        }
        roomURL = try await transport.start(framePublisher: framePublisher)
        active = transport
        NSLog("[ExpertBridge] Streaming via %@ for session %@ (expert %@): %@",
              transport.displayName, sessionId, expertId ?? "-", roomURL ?? "-")
    }

    func disconnect() async {
        await active?.stop()
        active = nil
        roomURL = nil
    }
}
