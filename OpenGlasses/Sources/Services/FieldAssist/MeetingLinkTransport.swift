import Foundation
import Combine
import UIKit

/// Zero-infrastructure expert transport: hands the escalation off to an external meeting tool the
/// customer already runs (Zoom, Teams, Google Meet, Whereby, …). No media stack, no signaling, no
/// TURN, nothing for us to host — the vendor's app handles A/V on both ends.
///
/// On `start`, the technician's device opens the configured meeting URL (so they join the call), and
/// the same URL is returned as the room URL so `EscalationCoordinator` pages it to the expert via the
/// notifier. The expert opens it in their own client.
@MainActor
final class MeetingLinkTransport: ExpertStreamTransport {
    var displayName: String { ExpertStreamKind.meetingLink.label }

    /// Available once a meeting URL is configured.
    var isAvailable: Bool { !Config.expertMeetingURL.trimmingCharacters(in: .whitespaces).isEmpty }

    private(set) var isStreaming = false

    /// Injectable for testing; defaults to opening the URL on the device.
    var opener: (URL) -> Void = { url in UIApplication.shared.open(url) }

    func start(framePublisher: PassthroughSubject<UIImage, Never>) async throws -> String? {
        let urlString = Config.expertMeetingURL.trimmingCharacters(in: .whitespaces)
        guard !urlString.isEmpty, let url = URL(string: urlString) else {
            throw ExpertStreamError.transportUnavailable(
                "Set a meeting URL (Zoom/Teams/Meet/Whereby) in Field Assist settings, or pick another transport.")
        }
        opener(url)          // technician joins the call on this device
        isStreaming = true
        return urlString     // paged to the expert by the escalation notifier
    }

    func stop() async {
        isStreaming = false
    }
}
