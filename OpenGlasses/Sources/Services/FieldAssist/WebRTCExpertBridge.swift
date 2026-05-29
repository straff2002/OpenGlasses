import Foundation
import Combine
import UIKit

/// Live expert bridge (Plan K2 / Field Assist Phase 5) backed by the existing `WebRTCStreamingService`.
/// On escalation it starts streaming the glasses camera so a remote expert can see what the technician
/// sees; `disconnect` stops the stream. Swap this in for `PendingExpertBridge` on `EscalationCoordinator`.
///
/// Note: this brings up the outbound video stream (reusing the shipped WebRTC viewer). Full
/// bidirectional expert audio and the expert-side join client are external/Phase 5 and not exercised
/// here.
@MainActor
final class WebRTCExpertBridge: ExpertBridge {
    private let streamer: WebRTCStreamingService
    private let framePublisher: PassthroughSubject<UIImage, Never>

    /// The shareable room URL produced when streaming starts (hand to the expert).
    private(set) var roomURL: String?

    init(streamer: WebRTCStreamingService, framePublisher: PassthroughSubject<UIImage, Never>) {
        self.streamer = streamer
        self.framePublisher = framePublisher
    }

    var isConnected: Bool { streamer.isStreaming }

    func connect(sessionId: String, expertId: String?) async throws {
        guard !streamer.isStreaming else { return }
        roomURL = streamer.startStreaming(framePublisher: framePublisher)
        NSLog("[ExpertBridge] Streaming started for session %@ (expert %@): %@",
              sessionId, expertId ?? "-", roomURL ?? "-")
    }

    func disconnect() async {
        streamer.stopStreaming()
        roomURL = nil
    }
}
