import Foundation

/// Every place in the app that receives camera pixels, and what protects each one (W04.1).
///
/// `PrivacyFilterScope` answers "should this kind of consumer be filtered?". It does not answer the
/// question an auditor actually asks, which is "have you found them all?" — and that gap is how the
/// bystander blur shipped uncalled in the first place (Plan CO Item 0), and how a recording started
/// by voice kept subscribing to the raw camera publisher long after the app-side recording button
/// had been moved onto the blur relay.
///
/// So this is the roster. Each case names one consumer, the type that owns its subscription, where
/// it taps the pixels, and which mechanism protects it. `OutboundFrameConsumerTests` scrapes
/// `OpenGlasses/Sources` for every frame subscription and every `filtered(_:for:)` call and fails
/// if it finds an owning type that is not listed here — so the roster cannot silently fall behind
/// the code, and a new consumer that subscribes to `CameraService.framePublisher` directly has to
/// be argued for in this file rather than added quietly.
enum OutboundFrameConsumer: String, CaseIterable {

    // MARK: - The blur pass itself

    /// `OutboundFrameRelay.attach(to:)` — the one subscription to the raw camera publisher that is
    /// supposed to exist. Everything downstream of it receives blurred pixels.
    case outboundRelayInput
    /// `AppState` wiring the relay to `cameraService.framePublisher` at launch.
    case appRelayAttachment

    // MARK: - Relay-fed egress (camera rate)

    /// Video recording to disk, started from the app UI or the remote-invoke bridge.
    case videoRecording
    /// Video recording started by the `video_recording` native tool — i.e. by voice.
    case videoRecordingTool
    /// RTMP broadcast.
    case rtmpBroadcast
    /// WebRTC/MJPEG browser streaming (`WebRTCStreamingService`).
    case webRTCBrowserStream
    /// Field Assist escalation bridge that hands a transport the outbound frames.
    case expertStreamBridge
    /// Field Assist MJPEG expert transport.
    case expertMJPEGTransport
    /// Field Assist meeting-link transport.
    case expertMeetingLinkTransport
    /// Field Assist peer-to-peer WebRTC transport.
    case expertPeerTransport
    /// The transport protocol that declares the `start(framePublisher:)` seam. Listed because the
    /// seam's type is what fixes, for every conforming transport, *which* publisher it can be
    /// handed — the relay's, never the camera's.
    case expertTransportProtocol

    // MARK: - Chokepoint-filtered model paths (~1 fps)

    /// Frames pushed into an active realtime session (Gemini Live / OpenAI Realtime).
    case liveSessionPush
    /// The realtime sessions' pull fallback, when they ask for a frame instead of being pushed one.
    case liveSessionPollFallback
    /// The still attached to a Direct-mode LLM turn.
    case directModelTurn
    /// The frame frozen by frame pinning — filtered once, at pin time.
    case pinnedFrame
    /// A still attached to a delegated remote-agent task.
    case agentAttachment

    // MARK: - Exempt (no egress, or the blur would break the feature)

    /// Face enrolment and matching. Needs raw pixels by definition.
    case faceRecognition
    /// Continuous scene narration on the on-device VLM.
    case sceneNarration
    /// The live camera preview on the phone's own screen.
    case livePreview
    /// Reading companion page detection — on-device OCR, emits text.
    case readingCompanion
    /// Sign-language fingerspelling decoding — on-device, emits letters.
    case fingerspelling
    /// Dwell capture's saliency loop — on-device Vision, emits candidate boxes.
    ///
    /// The crop it then writes to the Photos library is a separate question from this subscription
    /// and is *not* settled by this entry; see the W04.1 row in `docs/plans/EU-remediation-roadmap.md`.
    case dwellCapture

    /// Where the consumer taps the pixels.
    enum Tap: String {
        /// `CameraService.framePublisher` — unfiltered, camera rate. Only the relay and the exempt
        /// on-device consumers may use this.
        case rawCameraPublisher
        /// `CameraService.onVideoFrame` — the unfiltered single-slot callback.
        case rawCameraCallback
        /// `OutboundFrameRelay.publisher` — blurred, camera rate.
        case outboundRelay
        /// `CameraService.latestFrame` — a still, pulled on demand.
        case latestFrameStill
    }

    /// What protects the consumer.
    enum Mechanism: String {
        /// Receives pixels the shared relay has already blurred.
        case relay
        /// Calls `PrivacyFilterService.filtered(_:for:)` itself, at ~1 fps.
        case chokepoint
        /// Not filtered, because its scope says so — see the scope's own documentation.
        case exemptByScope
        /// Is the blur pass, or wires it up. Reads raw pixels by construction.
        case relayInput
    }

    /// The Swift type that owns the subscription or the call. The exhaustiveness test matches
    /// scraped source against these names, so they must stay exact.
    var owningType: String {
        switch self {
        case .outboundRelayInput: return "OutboundFrameRelay"
        case .appRelayAttachment, .liveSessionPush, .liveSessionPollFallback,
             .directModelTurn, .pinnedFrame, .agentAttachment: return "AppState"
        case .videoRecording: return "VideoRecordingService"
        case .videoRecordingTool: return "VideoRecordingTool"
        case .rtmpBroadcast: return "BroadcastService"
        case .webRTCBrowserStream: return "WebRTCStreamingService"
        case .expertStreamBridge: return "ExpertStreamBridge"
        case .expertMJPEGTransport: return "MJPEGExpertTransport"
        case .expertMeetingLinkTransport: return "MeetingLinkTransport"
        case .expertPeerTransport: return "WebRTCPeerTransport"
        case .expertTransportProtocol: return "ExpertStreamTransport"
        case .faceRecognition: return "FaceRecognitionService"
        case .sceneNarration: return "SceneNarrationService"
        case .livePreview: return "LivePreviewView"
        case .readingCompanion: return "ReadingCompanionService"
        case .fingerspelling: return "FingerspellingSessionService"
        case .dwellCapture: return "DwellCaptureService"
        }
    }

    /// The privacy scope this consumer is filtered under. `nil` for the relay itself, which is the
    /// mechanism rather than a consumer of it — the only honest answer, and the tests pin that it
    /// is nil for exactly the `.relayInput` cases.
    var scope: PrivacyFilterScope? {
        switch self {
        case .outboundRelayInput, .appRelayAttachment: return nil
        case .videoRecording, .videoRecordingTool: return .recording
        case .rtmpBroadcast, .webRTCBrowserStream: return .broadcast
        case .expertStreamBridge, .expertMJPEGTransport, .expertMeetingLinkTransport,
             .expertPeerTransport, .expertTransportProtocol: return .expertStream
        case .liveSessionPush, .liveSessionPollFallback: return .liveSession
        case .directModelTurn: return .directModelTurn
        case .pinnedFrame: return .pinnedFrame
        case .agentAttachment: return .agentAttachment
        case .faceRecognition: return .faceRecognition
        case .sceneNarration: return .sceneNarration
        case .livePreview: return .onDevicePreview
        case .readingCompanion, .fingerspelling, .dwellCapture: return .onDeviceVision
        }
    }

    var tap: Tap {
        switch self {
        case .outboundRelayInput, .appRelayAttachment, .faceRecognition, .readingCompanion,
             .fingerspelling, .dwellCapture: return .rawCameraPublisher
        case .liveSessionPush, .livePreview: return .rawCameraCallback
        case .videoRecording, .videoRecordingTool, .rtmpBroadcast, .webRTCBrowserStream,
             .expertStreamBridge, .expertMJPEGTransport, .expertMeetingLinkTransport,
             .expertPeerTransport, .expertTransportProtocol: return .outboundRelay
        case .liveSessionPollFallback, .directModelTurn, .pinnedFrame, .agentAttachment,
             .sceneNarration: return .latestFrameStill
        }
    }

    var mechanism: Mechanism {
        switch self {
        case .outboundRelayInput, .appRelayAttachment: return .relayInput
        case .videoRecording, .videoRecordingTool, .rtmpBroadcast, .webRTCBrowserStream,
             .expertStreamBridge, .expertMJPEGTransport, .expertMeetingLinkTransport,
             .expertPeerTransport, .expertTransportProtocol: return .relay
        case .liveSessionPush, .liveSessionPollFallback, .directModelTurn, .pinnedFrame,
             .agentAttachment: return .chokepoint
        case .faceRecognition, .sceneNarration, .livePreview, .readingCompanion,
             .fingerspelling, .dwellCapture: return .exemptByScope
        }
    }

    /// Types allowed to read the raw camera publisher or callback. Everything here is either the
    /// blur pass itself or a consumer whose scope says the blur must not be applied.
    static var typesAllowedOnTheRawCameraTap: Set<String> {
        Set(allCases.filter { $0.tap == .rawCameraPublisher || $0.tap == .rawCameraCallback }
                    .map(\.owningType))
    }

    static var owningTypes: Set<String> { Set(allCases.map(\.owningType)) }
}
