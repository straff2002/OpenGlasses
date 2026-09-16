import Foundation

/// Plan FF P1/PR5 — everything a live session decides when its socket comes back, lifted out of the
/// callback it used to live in.
///
/// # Why it is its own type
///
/// The realtime session managers build a `RealtimeAudioEngine` at init and cannot be constructed
/// headlessly, so the reconnect handler — which re-declares tools, rebuilds the instruction,
/// restarts the microphone, restarts frame capture and reports the lifecycle — was reachable only
/// on a device. That is the one path this phase has to prove, and the interesting failures in it
/// are all ordering: a stop that lands mid-restart, a camera the outage left paused, a conversation
/// that has to be rebuilt before the new setup goes out rather than after.
///
/// So the decisions sit here behind seams, the manager's handler becomes the wiring, and the tests
/// drive the same object the manager drives.
///
/// # The rules it holds
///
/// * **The handover is assembled before the reconfigure**, because the rebuilt context has to be
///   part of the setup message the new session opens with. Afterwards it would be a mid-session
///   injection into a conversation that has already started without it.
/// * **A stop cancels everything after it.** The generation is captured at the top and re-checked
///   after every await; a stop during the handover, during the microphone restart or during the
///   camera start leaves the rest undone and reports nothing.
/// * **A paused camera is never started.** The decision goes through
///   ``LiveRecoveryCameraPolicy``, which has no case that starts into a hold.
/// * **The report is four facts, not one.** ``LiveRecoveryAssessment`` is returned as well as
///   reported, so a caller — and a test — sees what was actually established.
@MainActor
final class LiveRecoveryDriver {

    /// Everything the reconnect path touches, as functions. The manager supplies the real ones.
    struct Seams {
        /// Whether the session is still running at all.
        var isSessionActive: () -> Bool
        /// Whether the transport resumed the previous conversation server-side.
        var resumedOnServer: () -> Bool
        /// The phone's own record of the last turns, newest last.
        var recentTurns: (Int) -> [LiveTurnRecord]
        /// Side-effecting operations whose outcome is unknown. Names only.
        var interruptedOperations: () -> [String]
        /// The camera's own snapshot, or `nil` when no camera is wired to this session.
        var cameraReadiness: () -> CameraReadiness?
        /// Whether this session answers questions about what the wearer is looking at.
        var sessionNeedsVision: () -> Bool
        /// Re-declare tools and rebuild the system instruction, carrying the handover block when
        /// there is one.
        var reconfigure: (String?) -> Void
        /// Restart microphone capture. Throwing is the degraded case the wearer has to hear about.
        var restartMicrophone: () async throws -> Void
        /// Restart the frame polling loop.
        var restartFrameCapture: () -> Void
        /// Ask the camera to start. Called only where ``LiveRecoveryCameraPolicy`` allows it.
        var startCamera: () async -> Bool
        /// Report to the audible lifecycle.
        var report: (AudibleLifecycleCoordinator.Signal) -> Void

        init(isSessionActive: @escaping () -> Bool,
             resumedOnServer: @escaping () -> Bool,
             recentTurns: @escaping (Int) -> [LiveTurnRecord],
             interruptedOperations: @escaping () -> [String] = { [] },
             cameraReadiness: @escaping () -> CameraReadiness? = { nil },
             sessionNeedsVision: @escaping () -> Bool = { false },
             reconfigure: @escaping (String?) -> Void,
             restartMicrophone: @escaping () async throws -> Void,
             restartFrameCapture: @escaping () -> Void = {},
             startCamera: @escaping () async -> Bool = { false },
             report: @escaping (AudibleLifecycleCoordinator.Signal) -> Void) {
            self.isSessionActive = isSessionActive
            self.resumedOnServer = resumedOnServer
            self.recentTurns = recentTurns
            self.interruptedOperations = interruptedOperations
            self.cameraReadiness = cameraReadiness
            self.sessionNeedsVision = sessionNeedsVision
            self.reconfigure = reconfigure
            self.restartMicrophone = restartMicrophone
            self.restartFrameCapture = restartFrameCapture
            self.startCamera = startCamera
            self.report = report
        }
    }

    private let seams: Seams

    /// Bumped by every stop. Captured at the top of a recovery and re-checked after every await, so
    /// work begun for a session the wearer has since stopped stops too — the same shape
    /// `LiveSessionActivator` uses for a stop during a pending start.
    private var stopGeneration = 0

    /// Whether a recovery is currently in flight. Exposed so "nothing is left running" is an
    /// assertion rather than an inference.
    private(set) var isRecovering = false

    init(seams: Seams) {
        self.seams = seams
    }

    /// The wearer stopped the session (or it was torn down). Everything in flight is abandoned.
    func noteStop() {
        stopGeneration &+= 1
        isRecovering = false
    }

    /// The socket came back. Returns what the recovery actually established, or `nil` when a stop
    /// (or an already-ended session) cancelled it.
    @discardableResult
    func handleReconnected() async -> LiveRecoveryAssessment? {
        guard seams.isSessionActive() else { return nil }
        let generation = stopGeneration
        isRecovering = true
        defer { if generation == stopGeneration { isRecovering = false } }

        // 1. The conversation, before anything else — the rebuilt block has to ride in the setup
        //    message this reconfigure produces.
        let resumed = seams.resumedOnServer()
        var handoverTurns = 0
        var handover: String?
        if !resumed {
            let turns = seams.recentTurns(LiveContextHandover.maxTurns)
            handoverTurns = LiveContextHandover.carriedTurnCount(turns)
            handover = LiveContextHandover.build(turns: turns,
                                                 interruptedOperations: seams.interruptedOperations())
        }
        guard generation == stopGeneration else { return nil }

        seams.reconfigure(handover)
        guard generation == stopGeneration else { return nil }

        // 2. The microphone. A throw here is the degraded ending, not a log line.
        var microphoneRestored = true
        do {
            try await seams.restartMicrophone()
        } catch {
            microphoneRestored = false
            PrivacyLog.realtimeSession(.gemini, .audioRestartFailed, error: SafeErrorSummary(error))
        }
        guard generation == stopGeneration else { return nil }

        // 3. The camera, through the policy that cannot express a start into a pause.
        let needsVision = seams.sessionNeedsVision()
        if LiveRecoveryCameraPolicy.mayStartCamera(readiness: seams.cameraReadiness(),
                                                   sessionNeedsVision: needsVision) {
            _ = await seams.startCamera()
            guard generation == stopGeneration else { return nil }
        }
        seams.restartFrameCapture()
        guard generation == stopGeneration else { return nil }

        // 4. What is actually true now.
        let assessment = LiveRecoveryAssessment(
            socketReady: true,
            microphoneRestored: microphoneRestored,
            visualEvidenceFresh: seams.cameraReadiness()?.hasFreshVisualEvidence ?? false,
            needsVisualEvidence: needsVision,
            contextContinuity: LiveRecoveryAssessment.continuity(
                resumedOnServer: resumed, handoverTurns: handoverTurns))

        seams.report(.reconnected(audioRestored: assessment.microphoneRestored,
                                  needsVisualEvidence: assessment.needsVisualEvidence,
                                  contextCarried: assessment.contextContinuity.carriesPriorContext))
        return assessment
    }
}
