import Foundation

/// A live session that has to end when medical local-only turns on mid-flight.
///
/// The guard stops a *new* request being built. It cannot stop a socket that is already open, and
/// a realtime session that is already streaming audio is exactly the case the mode exists for. So
/// each session-bearing service says which routes it holds open and how to close them.
@MainActor
protocol MedicalEgressTeardown: AnyObject {
    /// The routes this service keeps open. Teardown runs when any of them is refused.
    var openRoutes: [NetworkRoute] { get }
    /// End the session now. Must be safe to call when nothing is running.
    func tearDownForMedicalEgress()
}

/// Watches the medical mode and ends live sessions on routes the mode has just closed.
///
/// It holds weak references only: it is a listener, not an owner, and a service that has already
/// been released is not a session that needs closing. Deliberately separate from
/// `HIPAAComplianceService` — that type owns the audit log and the mode flag, and does not need to
/// know which services exist.
@MainActor
final class MedicalEgressCoordinator {

    /// Posted when the Local Only switch changes. Compliance mode itself already has
    /// `HIPAAComplianceService.onModeChanged`; the routing switch had no such signal, which is why
    /// turning it on mid-session used to change nothing until the next restart.
    static let modeDidChangeNotification = Notification.Name("MedicalEgressModeDidChange")

    private struct WeakParticipant {
        weak var value: (any MedicalEgressTeardown)?
    }

    private var participants: [WeakParticipant] = []
    private var observer: NSObjectProtocol?

    /// Routes torn down by the most recent mode change, newest last. Read by tests and by the
    /// diagnostics surface; it is not user-facing state.
    private(set) var lastTornDownRoutes: [NetworkRoute] = []

    init(observing center: NotificationCenter? = .default) {
        guard let center else { return }
        observer = center.addObserver(forName: Self.modeDidChangeNotification,
                                      object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.modeDidChange() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func register(_ participant: any MedicalEgressTeardown) {
        prune()
        guard !participants.contains(where: { $0.value === participant }) else { return }
        participants.append(WeakParticipant(value: participant))
    }

    var registeredCount: Int {
        participants.compactMap(\.value).count
    }

    /// Call after any change to the medical flags. Idempotent: a service whose routes are still
    /// permitted is left alone, and tearing down twice is the service's problem to make cheap.
    func modeDidChange() {
        prune()
        var torn: [NetworkRoute] = []
        for participant in participants.compactMap(\.value) {
            let blocked = participant.openRoutes.filter { MedicalEgressGuard.blocks($0) }
            guard !blocked.isEmpty else { continue }
            participant.tearDownForMedicalEgress()
            torn.append(contentsOf: blocked)
        }
        lastTornDownRoutes = torn
    }

    /// Fire-and-forget signal for the settings switch, which writes `Config` directly.
    static func announceModeChange(via center: NotificationCenter = .default) {
        center.post(name: modeDidChangeNotification, object: nil)
    }

    private func prune() {
        participants.removeAll { $0.value == nil }
    }
}

// MARK: - The live participants
//
// Conformances live here rather than in each service so the list of what holds a session open can
// be read in one place, and so adding a service to the teardown does not mean editing it.

// The realtime services are owned privately by their session managers, and ending a session is
// more than closing its socket — the audio graph has to come down too — so the manager is the
// participant, not the service.
extension OpenAIRealtimeSessionManager: MedicalEgressTeardown {
    var openRoutes: [NetworkRoute] { [.openAIRealtimeSession] }
    func tearDownForMedicalEgress() { stopSession() }
}

extension GeminiLiveSessionManager: MedicalEgressTeardown {
    var openRoutes: [NetworkRoute] { [.geminiLiveSession] }
    func tearDownForMedicalEgress() { stopSession() }
}

extension DeepgramSTTService: MedicalEgressTeardown {
    var openRoutes: [NetworkRoute] { [.deepgramLiveTranscription] }
    func tearDownForMedicalEgress() { stop() }
}

extension GeminiTranslationProvider: MedicalEgressTeardown {
    var openRoutes: [NetworkRoute] { [.cloudTranslationCaptions] }
    func tearDownForMedicalEgress() { stop() }
}

extension OpenClawEventClient: MedicalEgressTeardown {
    var openRoutes: [NetworkRoute] { [.openClawEventStream] }
    func tearDownForMedicalEgress() { disconnect() }
}

extension OpenClawBridge: MedicalEgressTeardown {
    var openRoutes: [NetworkRoute] { [.openClawGatewaySocket] }
    func tearDownForMedicalEgress() { disconnectWebSocket() }
}

extension HermesBridgeService: MedicalEgressTeardown {
    var openRoutes: [NetworkRoute] { [.hermesBridgeSession] }
    func tearDownForMedicalEgress() { disconnect() }
}

extension WebRTCStreamingService: MedicalEgressTeardown {
    var openRoutes: [NetworkRoute] { [.webRTCBrowserStreaming] }
    func tearDownForMedicalEgress() { stopStreaming() }
}

extension MCPGlassesServer: MedicalEgressTeardown {
    var openRoutes: [NetworkRoute] { [.mcpGlassesListener] }
    func tearDownForMedicalEgress() { stop() }
}
