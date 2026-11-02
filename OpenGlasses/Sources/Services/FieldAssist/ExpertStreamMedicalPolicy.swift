import Foundation

/// Whether a live expert stream may run (pure). Owner decision: Medical Compliance has no live expert
/// stream, whether or not Local Only is on. A clinical room's camera and microphone do not go to a
/// remote viewer.
///
/// This covers the stream only. A help request is not a stream: the technician can still ask for an
/// expert, the escalation is recorded and the pool is paged, and the expert gets the job record.
/// Every transport asks here: `WebRTCStreamingService`, `WebRTCPeerTransport`,
/// `MeetingLinkTransport`, and `ExpertStreamBridge` in front of them.
enum ExpertStreamMedicalPolicy {
    enum Decision: Equatable {
        case allow
        case refuse
    }

    /// Local Only binds only with Medical Compliance on (`MedicalEgressGuard.Mode.isEnforcing`), so
    /// this one flag is the whole of the rule, and Local Only is refused with it.
    static func decide(_ mode: MedicalEgressGuard.Mode) -> Decision {
        mode.hipaaMode ? .refuse : .allow
    }

    /// The mode in force now, through the same seam tests use for the egress guard.
    static var refusesNow: Bool { decide(MedicalEgressGuard.currentMode()) == .refuse }

    enum RunningAction: Equatable {
        case carryOn
        case end
    }

    /// A stream that is up when the mode changes.
    static func whileRunning(isStreaming: Bool, mode: MedicalEgressGuard.Mode) -> RunningAction {
        isStreaming && decide(mode) == .refuse ? .end : .carryOn
    }

    /// Why a start was refused, wherever it is shown.
    static var refusalMessage: String {
        String(localized: "A live view to an expert is off in Medical Compliance mode, so your camera and microphone stay on this phone. You can still ask for an expert, and they get the job record.")
    }

    /// Said and shown when the mode ends a running stream. A meeting runs in its own app, where
    /// stopping the transport reaches nothing: the wearer is told it is still up and is theirs to
    /// leave, never that it has ended.
    static func endedMessage(externalCall: Bool) -> String {
        externalCall
            ? String(localized: "Medical Compliance mode is on, but your expert call runs in another app and is still going. Leave the call in that app to stop it. The job carries on, and the expert has the job record.")
            : String(localized: "The live view to your expert has ended, because Medical Compliance mode is on. The job carries on, and the expert has the job record.")
    }

    /// What the escalation tools report, for the assistant to say. In the same shape as the other
    /// two sentences in `EscalationCoordinator.liveViewSummary()`.
    static let liveViewOffSummary =
        "The live view is off in Medical Compliance mode, so the expert has the job record and can't see the camera."
}
