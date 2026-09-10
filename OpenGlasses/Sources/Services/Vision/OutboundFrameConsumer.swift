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
/// `OpenGlasses/Sources` for every frame subscription, every `filtered(_:for:)` call, every
/// `filteredStill(for:)` request and every raw `latestFrame` read, and fails if it finds an owning
/// type that is not listed here — so the roster cannot silently fall behind the code, and a new
/// consumer that subscribes to `CameraService.framePublisher`, or reads a raw still, has to be
/// argued for in this file rather than added quietly.
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

    // MARK: - Chokepoint-filtered still readers (W04.1)
    //
    // Every one of these used to read `CameraService.latestFrame` and hand the bytes straight to a
    // model, a session log, a Photos entry or another process. They now ask
    // `CameraService.filteredStill(for:source:)` for a still *for a purpose*, and the purpose
    // decides whether the blur runs. See `FilteredStill`.

    /// Structured-vision assessment of a still, schema attached, to a cloud model.
    case structuredVisionAssessment
    /// The HECA safety assessment, same shape, on a job site full of other people.
    case safetyAssessment
    /// Assistive mode's continuous guidance loop.
    case assistiveGuidanceLoop
    /// Navigation assist's hazard/landmark loop.
    case navigationAssist
    /// The live coach's periodic form/technique frame.
    case liveCoach
    /// `capture_photo` — the still the wearer asks for, base64'd into the model turn.
    case capturePhotoTool
    /// `photo_log` — attached to a Field Assist session log *and* sent to the model.
    case photoLogTool
    /// The money identifier, which sends the note itself to the model rather than OCR text.
    case moneyIdentifierTool
    /// The local MCP server's `see_glasses`, which serves a still to another process.
    case mcpFrameRequest
    /// The crop dwell capture writes to the Photos library. Separate from `dwellCapture` below on
    /// purpose: the saliency subscription needs raw pixels and stays exempt, while the crop it
    /// produces leaves the app and does not.
    case dwellCaptureSave

    // MARK: - On-device still readers (exempt, and asked to say so)
    //
    // These consume a still and emit only text or geometry — Vision OCR, barcode and QR decoding,
    // colour sampling, body-pose analysis. Nothing leaves the process, so there is nothing to
    // filter; they still request their still through the same accessor, under an on-device scope,
    // so that the classification is written down at the call site rather than inferred from the
    // absence of a filter call.

    /// Study's page scan → on-device OCR → flashcard text.
    case studyScan
    /// Teleprompter's page scan → on-device OCR → script text.
    case teleprompterScan
    /// `read_this` — on-device OCR for the wearer.
    case readingAccessibilityTool
    /// `smart_capture` — business cards, receipts, flyers, parsed on device.
    case smartCaptureTool
    /// The medication identifier's label OCR (the cross-check reads a local vault).
    case medicationIdentifierTool
    /// Manual lookup reading a fault code off a label.
    case manualLookupTool
    /// Equipment lookup reading a nameplate.
    case equipmentLookupTool
    /// Barcode/QR scanning through Vision.
    case barcodeScannerTool
    /// QR context scanning through Vision.
    case qrContextTool
    /// Dominant-colour naming, a one-pixel downscale on device.
    case colorIdentifierTool
    /// Conference badge OCR + QR reconciliation.
    case badgeScanTool
    /// `identify_person` — face matching, exempt for the same reason the service is.
    case faceRecognitionTool
    /// The fitness coach's form check: `NativeToolRegistry` hands the tool a frame provider that
    /// feeds an on-device Vision pose pass. Still a raw read, because the provider is synchronous.
    case fitnessPoseFrame

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
    /// The crop it then writes to the Photos library is a separate question from this subscription,
    /// and `dwellCaptureSave` is where that one is answered: the loop reads raw pixels, the crop is
    /// filtered before it is saved.
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
        /// `CameraService.latestFrame` — a raw still, pulled on demand. Legal only for a consumer
        /// that filters it at its own chokepoint, or whose scope says it must not be filtered.
        case latestFrameStill
        /// `CameraService.filteredStill(for:source:)` — a still that has already been through the
        /// chokepoint, or an explicit `.unavailable`. The tap a still reader should be using.
        case filteredStill
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
        case .dwellCapture, .dwellCaptureSave: return "DwellCaptureService"
        case .structuredVisionAssessment: return "StructuredVisionService"
        case .safetyAssessment: return "SafetyAssessmentService"
        case .assistiveGuidanceLoop: return "AssistiveModeService"
        case .navigationAssist: return "NavigationAssistService"
        case .liveCoach: return "LiveCoachService"
        case .capturePhotoTool: return "CapturePhotoTool"
        case .photoLogTool: return "PhotoLogTool"
        case .moneyIdentifierTool: return "MoneyIdentifierTool"
        case .mcpFrameRequest: return "MCPGlassesServer"
        case .studyScan: return "StudyService"
        case .teleprompterScan: return "TeleprompterService"
        case .readingAccessibilityTool: return "ReadingAccessibilityTool"
        case .smartCaptureTool: return "SmartCaptureTool"
        case .medicationIdentifierTool: return "MedicationIdentifierTool"
        case .manualLookupTool: return "ManualLookupTool"
        case .equipmentLookupTool: return "EquipmentLookupTool"
        case .barcodeScannerTool: return "BarcodeScannerTool"
        case .qrContextTool: return "QRContextTool"
        case .colorIdentifierTool: return "ColorIdentifierTool"
        case .badgeScanTool: return "BadgeScanTool"
        case .faceRecognitionTool: return "FaceRecognitionTool"
        case .fitnessPoseFrame: return "NativeToolRegistry"
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
        case .structuredVisionAssessment, .safetyAssessment: return .visionAssessment
        case .assistiveGuidanceLoop, .navigationAssist, .liveCoach: return .assistiveGuidance
        case .capturePhotoTool, .photoLogTool, .moneyIdentifierTool: return .toolPhotoCapture
        case .dwellCaptureSave: return .photoLibrary
        case .mcpFrameRequest: return .remoteFrameRequest
        case .faceRecognitionTool: return .faceRecognition
        case .studyScan, .teleprompterScan, .readingAccessibilityTool, .smartCaptureTool,
             .medicationIdentifierTool, .manualLookupTool, .equipmentLookupTool,
             .barcodeScannerTool, .qrContextTool, .colorIdentifierTool, .badgeScanTool,
             .fitnessPoseFrame: return .onDeviceVision
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
             .sceneNarration, .fitnessPoseFrame: return .latestFrameStill
        case .dwellCaptureSave: return .rawCameraPublisher
        case .structuredVisionAssessment, .safetyAssessment, .assistiveGuidanceLoop,
             .navigationAssist, .liveCoach, .capturePhotoTool, .photoLogTool, .moneyIdentifierTool,
             .mcpFrameRequest, .studyScan, .teleprompterScan, .readingAccessibilityTool,
             .smartCaptureTool, .medicationIdentifierTool, .manualLookupTool, .equipmentLookupTool,
             .barcodeScannerTool, .qrContextTool, .colorIdentifierTool, .badgeScanTool,
             .faceRecognitionTool: return .filteredStill
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
        case .structuredVisionAssessment, .safetyAssessment, .assistiveGuidanceLoop,
             .navigationAssist, .liveCoach, .capturePhotoTool, .photoLogTool, .moneyIdentifierTool,
             .mcpFrameRequest, .dwellCaptureSave: return .chokepoint
        case .studyScan, .teleprompterScan, .readingAccessibilityTool, .smartCaptureTool,
             .medicationIdentifierTool, .manualLookupTool, .equipmentLookupTool,
             .barcodeScannerTool, .qrContextTool, .colorIdentifierTool, .badgeScanTool,
             .faceRecognitionTool, .fitnessPoseFrame: return .exemptByScope
        }
    }

    /// Types allowed to read the raw camera publisher or callback. Everything here is either the
    /// blur pass itself or a consumer whose scope says the blur must not be applied.
    static var typesAllowedOnTheRawCameraTap: Set<String> {
        Set(allCases.filter { $0.tap == .rawCameraPublisher || $0.tap == .rawCameraCallback }
                    .map(\.owningType))
    }

    /// Types allowed to read a raw still — `CameraService.latestFrame` — rather than going through
    /// `filteredStill(for:source:)`. Everything whose tap is a raw one: the on-device consumers, the
    /// preview, face recognition, and the chokepoint readers that filter the still themselves.
    static var typesAllowedOnARawStill: Set<String> {
        Set(allCases.filter { $0.tap != .filteredStill && $0.tap != .outboundRelay }
                    .map(\.owningType))
    }

    static var owningTypes: Set<String> { Set(allCases.map(\.owningType)) }
}
