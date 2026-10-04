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
    /// A length-capped job clip recorded as evidence (Plan FO P2b), started by `record_clip` or by
    /// the Job tab's record button. Listed under `.recording` rather than a scope of its own: a
    /// clip is frames written to a file on this device, which is what that scope already means,
    /// and the egress that makes it interesting — the file going out with a work order — is the
    /// same shape a recording shared from the Recordings folder has. What differs is the length
    /// cap and where the file is filed, neither of which is a privacy classification.
    case jobClipRecording
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
    /// `look_closely` — one sharp full-resolution still injected into an active realtime session
    /// (Plan FF P1/PR4). Until PR4 this was the roster's blind spot: the tool was wired straight to
    /// `capturePhoto()` and the pixels went to a cloud model unfiltered, while the sink test looked
    /// for `IMAGE_CAPTURED` and `analyzeFrame(` and never for `injectSharpImage`. Both halves are
    /// fixed together — the capture goes through the chokepoint under the same `liveSession` scope
    /// as the streamed frames, and the sink pattern is now one the scraper knows.
    case lookCloselyCapture
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
    /// A picture the *phone* took, or one chosen from its library, attached to an open job's
    /// evidence (Plan FO P2a). Listed although its pixels never came from `CameraService`: the
    /// roster's question is "did these pixels pass the chokepoint before they became egress", and
    /// a phone photo in a work order that reaches a customer is egress by any reading. It was the
    /// one job-evidence route with no chokepoint at all — `handlePhoneCapture` filtered by
    /// neither the relay nor the still accessor — which is precisely the gap this file exists to
    /// stop being invisible.
    case jobPhoneEvidence
    /// A parking sign read through the glasses (Plan GH): the still is filtered, read by on-device
    /// OCR, and kept on disk with the parking spot. Kept means egress by this file's reading — a
    /// stored picture of a car park with somebody in it — so it is filtered under the same scope as
    /// any other still a tool keeps on the wearer's instruction.
    case parkingSignCapture
    /// The same sign photo taken or picked on the phone, from the Parking card. Pixels that never
    /// came from `CameraService`, filtered at their own chokepoint before OCR or storage.
    case parkingPhonePhoto

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

    // MARK: - "Record this job" (Plan HE)
    //
    // The entries below are the whole of a recorded job's path: in, blurred where it has to be,
    // and out — and there is deliberately no other. A recorded job is written raw into the job's
    // own folder and leaves that folder one way only, to the organisation's office. It is not
    // offered to a share sheet, saved to Photos or attached to a report — a clip for a report
    // stays `jobClipRecording`'s work, off the blurred relay. `JobRecordingExitTests` reads the
    // sources and holds the folder to that.

    /// The raw tap for "Record this job": `JobRecordingCoordinator` hands the unfiltered camera
    /// publisher to its own recorder, which writes the frames into the job's folder
    /// (`Documents/FieldSessions/{id}/recording/`), protected and out of backup.
    ///
    /// **Justified exemption.** Private, protected storage on the phone is not egress, so there is
    /// nothing to filter at capture; and filtering at capture is what puts holes in a recording —
    /// the relay drops every frame while the blur cannot run, which is whenever the phone is
    /// locked in a pocket. The person recording has been told the footage is unblurred and where
    /// it goes (`RecordingConsent`), and it is refused outright in Medical Compliance mode, where
    /// the organisation forbids it, and where the organisation requires a blur and the app has no
    /// blur pass to apply it with (`JobRecordingAvailability`).
    case jobRecordingCapture
    /// The blur pass, where the organisation requires faces blurred before a recording goes to
    /// its office: `BundleBlurPass` reads each recorded part out of the job's folder, puts every
    /// picture through the face blur, and writes the blurred part back into the same folder.
    ///
    /// **Not an exit.** It moves pixels from one file in the job's folder to another and nowhere
    /// else. It is on the roster because it holds raw pixels and is what stands between them and
    /// a bundle marked blurred, so what it promises is written here: a picture is written only if
    /// the filter returned one, under a scope that is filtered whatever the app-wide switch says
    /// (`PrivacyFilterScope.officeRecordingBlur`); a picture the filter cannot process is dropped
    /// and counted; and the raw part is removed only once its blurred replacement is whole.
    case jobRecordingBlurPass
    /// The one exit: the sealed bundle sent to the organisation's own office over the managed
    /// connection (`JobRecordingSyncService`), to the office the phone's current pairing names and
    /// to nobody else.
    ///
    /// **Raw by default, by the organisation's decision** — the destination is the organisation's
    /// own computer and its analysis is better for it. Where the organisation requires faces
    /// blurred first, a recording is blurred on the phone before it is sealed
    /// (`jobRecordingBlurPass`), and a bundle whose own manifest does not say it is blurred is not
    /// sent (`SyncEligibility.Reason.blurRequired`). The app-wide blur switch does not govern this
    /// exit either way.
    case jobRecordingOfficeSync

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
        /// Pixels the consumer already holds and that never came from `CameraService` at all — a
        /// phone-camera capture, a library picture. There is no camera tap to police, but there is
        /// still an egress, so the consumer filters at its own chokepoint through
        /// `StillImageFiltering` before the bytes go anywhere.
        case heldImage
        /// A recorded job already written to its own folder on this phone. Not a camera tap at all:
        /// the consumer reads files, and what is being policed is where those files may go — to
        /// the office, or through the blur and back into the same folder.
        case jobRecordingFolder
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
        /// Leaves the device unfiltered by the app-wide blur, to one destination the organisation
        /// has named — its own office — under the organisation's own rule about blurring. Only
        /// the recorded job's sealed bundle uses this, and the consumer must refuse to send where
        /// that rule is not met.
        case organisationExit
    }

    /// The Swift type that owns the subscription or the call. The exhaustiveness test matches
    /// scraped source against these names, so they must stay exact.
    var owningType: String {
        switch self {
        case .outboundRelayInput: return "OutboundFrameRelay"
        case .appRelayAttachment, .liveSessionPush, .liveSessionPollFallback,
             .directModelTurn, .pinnedFrame, .agentAttachment: return "AppState"
        case .videoRecording: return "VideoRecordingService"
        case .jobClipRecording: return "JobClipRecorder"
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
        case .jobPhoneEvidence: return "JobPhotoEvidenceService"
        case .parkingSignCapture, .parkingPhonePhoto: return "ParkingPhotoFlow"
        case .structuredVisionAssessment: return "StructuredVisionService"
        case .safetyAssessment: return "SafetyAssessmentService"
        case .assistiveGuidanceLoop: return "AssistiveModeService"
        case .navigationAssist: return "NavigationAssistService"
        case .liveCoach: return "LiveCoachService"
        case .lookCloselyCapture: return "SharpStillCapture"
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
        case .jobRecordingCapture: return "JobRecordingCoordinator"
        case .jobRecordingBlurPass: return "BundleBlurPass"
        case .jobRecordingOfficeSync: return "JobRecordingSyncService"
        }
    }

    /// The privacy scope this consumer is filtered under. `nil` for the relay itself, which is the
    /// mechanism rather than a consumer of it — the only honest answer, and the tests pin that it
    /// is nil for exactly the `.relayInput` cases.
    var scope: PrivacyFilterScope? {
        switch self {
        case .outboundRelayInput, .appRelayAttachment: return nil
        case .videoRecording, .videoRecordingTool, .jobClipRecording: return .recording
        case .rtmpBroadcast, .webRTCBrowserStream: return .broadcast
        case .expertStreamBridge, .expertMJPEGTransport, .expertMeetingLinkTransport,
             .expertPeerTransport, .expertTransportProtocol: return .expertStream
        case .liveSessionPush, .liveSessionPollFallback, .lookCloselyCapture: return .liveSession
        case .directModelTurn: return .directModelTurn
        case .pinnedFrame: return .pinnedFrame
        case .agentAttachment: return .agentAttachment
        case .faceRecognition: return .faceRecognition
        case .sceneNarration: return .sceneNarration
        case .livePreview: return .onDevicePreview
        case .readingCompanion, .fingerspelling, .dwellCapture: return .onDeviceVision
        case .structuredVisionAssessment, .safetyAssessment: return .visionAssessment
        case .assistiveGuidanceLoop, .navigationAssist, .liveCoach: return .assistiveGuidance
        case .capturePhotoTool, .photoLogTool, .moneyIdentifierTool,
             .jobPhoneEvidence, .parkingSignCapture, .parkingPhonePhoto: return .toolPhotoCapture
        case .dwellCaptureSave: return .photoLibrary
        case .mcpFrameRequest: return .remoteFrameRequest
        case .faceRecognitionTool: return .faceRecognition
        case .studyScan, .teleprompterScan, .readingAccessibilityTool, .smartCaptureTool,
             .medicationIdentifierTool, .manualLookupTool, .equipmentLookupTool,
             .barcodeScannerTool, .qrContextTool, .colorIdentifierTool, .badgeScanTool,
             .fitnessPoseFrame: return .onDeviceVision
        case .jobRecordingCapture, .jobRecordingOfficeSync: return .officeRecording
        case .jobRecordingBlurPass: return .officeRecordingBlur
        }
    }

    var tap: Tap {
        switch self {
        case .outboundRelayInput, .appRelayAttachment, .faceRecognition, .readingCompanion,
             .fingerspelling, .dwellCapture, .jobRecordingCapture: return .rawCameraPublisher
        case .jobRecordingBlurPass, .jobRecordingOfficeSync: return .jobRecordingFolder
        case .liveSessionPush, .livePreview: return .rawCameraCallback
        case .videoRecording, .videoRecordingTool, .jobClipRecording, .rtmpBroadcast,
             .webRTCBrowserStream, .expertStreamBridge, .expertMJPEGTransport,
             .expertMeetingLinkTransport, .expertPeerTransport,
             .expertTransportProtocol: return .outboundRelay
        case .liveSessionPollFallback, .directModelTurn, .pinnedFrame, .agentAttachment,
             .sceneNarration, .fitnessPoseFrame: return .latestFrameStill
        case .dwellCaptureSave: return .rawCameraPublisher
        case .jobPhoneEvidence, .parkingPhonePhoto: return .heldImage
        case .structuredVisionAssessment, .safetyAssessment, .assistiveGuidanceLoop,
             .navigationAssist, .liveCoach, .capturePhotoTool, .photoLogTool, .moneyIdentifierTool,
             .mcpFrameRequest, .studyScan, .teleprompterScan, .readingAccessibilityTool,
             .smartCaptureTool, .medicationIdentifierTool, .manualLookupTool, .equipmentLookupTool,
             .barcodeScannerTool, .qrContextTool, .colorIdentifierTool, .badgeScanTool,
             .faceRecognitionTool, .lookCloselyCapture, .parkingSignCapture: return .filteredStill
        }
    }

    var mechanism: Mechanism {
        switch self {
        case .outboundRelayInput, .appRelayAttachment: return .relayInput
        case .videoRecording, .videoRecordingTool, .jobClipRecording, .rtmpBroadcast,
             .webRTCBrowserStream, .expertStreamBridge, .expertMJPEGTransport,
             .expertMeetingLinkTransport, .expertPeerTransport,
             .expertTransportProtocol: return .relay
        case .liveSessionPush, .liveSessionPollFallback, .directModelTurn, .pinnedFrame,
             .agentAttachment: return .chokepoint
        case .faceRecognition, .sceneNarration, .livePreview, .readingCompanion,
             .fingerspelling, .dwellCapture, .jobRecordingCapture: return .exemptByScope
        case .jobRecordingOfficeSync: return .organisationExit
        case .structuredVisionAssessment, .safetyAssessment, .assistiveGuidanceLoop,
             .navigationAssist, .liveCoach, .capturePhotoTool, .photoLogTool, .moneyIdentifierTool,
             .mcpFrameRequest, .dwellCaptureSave, .lookCloselyCapture,
             .jobPhoneEvidence, .parkingSignCapture, .parkingPhonePhoto,
             .jobRecordingBlurPass: return .chokepoint
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
    ///
    /// A `heldImage` consumer is **not** among them: it never asked the camera for anything, so a
    /// raw still appearing in it would be a new tap nobody argued for.
    static var typesAllowedOnARawStill: Set<String> {
        Set(allCases.filter { $0.tap != .filteredStill && $0.tap != .outboundRelay
                              && $0.tap != .heldImage && $0.tap != .jobRecordingFolder
                              && $0 != .jobRecordingCapture }
                    .map(\.owningType))
    }

    /// The consumers through which a recorded job's pixels may move: into the job's folder,
    /// through the blur where the organisation requires it, and from the folder to the office.
    /// Anything else touching that folder is a new exit nobody argued for.
    static var jobRecordingPath: [OutboundFrameConsumer] {
        allCases.filter { $0.scope == .officeRecording || $0.scope == .officeRecordingBlur }
    }

    static var owningTypes: Set<String> { Set(allCases.map(\.owningType)) }
}
