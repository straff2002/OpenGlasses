#if !AVENKIN_PHONE_ONLY
import AppIntents

// MARK: - Plan BQ P3 — camera App Schema adoption
//
// OpenGlasses is a camera app; adopting the camera schema gives its glasses capture the
// pre-trained Siri phrasing ("start recording", "take a photo") instead of relying on our
// own App Shortcut phrase list. The `@AppIntent(schema:)` macro supplies title/description
// and the appintentsmetadataprocessor validates the shape at build time — the Release pass
// is the gate. (The iOS 18 `@AssistantIntent(schema:)` spelling is deprecated in the
// current SDK; `camera.startCapture` requires `captureMode`/`timerDuration`/`device`.)

/// What the glasses capture — the schema's CaptureMode, with this app's two real modes.
@AppEnum(schema: .camera.captureMode)
enum GlassesCaptureMode: String, AppEnum {
    case photo
    case video

    static var caseDisplayRepresentations: [GlassesCaptureMode: DisplayRepresentation] = [
        .photo: "Photo",
        .video: "Video",
    ]
}

/// Which camera — the glasses are the point of this app; the phone is the fallback.
@AppEnum(schema: .camera.captureDevice)
enum GlassesCaptureDevice: String, AppEnum {
    case glasses
    case phone

    static var caseDisplayRepresentations: [GlassesCaptureDevice: DisplayRepresentation] = [
        .glasses: "Glasses",
        .phone: "Phone",
    ]
}

/// Timer delay before capture. The glasses hardware has no capture timer — `.off` is the
/// only honoured value; others fall back to immediate capture.
@AppEnum(schema: .camera.captureDuration)
enum GlassesCaptureDuration: String, AppEnum {
    case off
    case threeSeconds
    case tenSeconds

    static var caseDisplayRepresentations: [GlassesCaptureDuration: DisplayRepresentation] = [
        .off: "Off",
        .threeSeconds: "3 seconds",
        .tenSeconds: "10 seconds",
    ]
}

/// "Take a photo" / "start recording" via the pre-trained camera phrasing.
/// v1 honours `captureMode`; `timerDuration` and `device` are accepted (schema-required)
/// but capture is immediate and always on the glasses camera.
@AppIntent(schema: .camera.startCapture)
struct StartGlassesCaptureIntent {
    static var openAppWhenRun: Bool = true

    var captureMode: GlassesCaptureMode
    var timerDuration: GlassesCaptureDuration?
    var device: GlassesCaptureDevice?

    @MainActor
    func perform() async throws -> some IntentResult {
        try IntentSupport.requireEnabled(captureMode == .video ? "record_video" : "capture_photo")
        let appState = try await IntentSupport.awaitConnectedAppState()
        guard appState.isConnected else {
            throw IntentConnectionError.appNotRunning
        }
        switch captureMode {
        case .photo:
            await appState.capturePhotoSilently()
        case .video:
            if !appState.videoRecorder.isRecording {
                await appState.toggleRecording()
            }
        }
        return .result()
    }
}

/// "Stop recording" → end glasses video capture (no-op if idle).
@AppIntent(schema: .camera.stopCapture)
struct StopGlassesCaptureIntent {
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        try IntentSupport.requireEnabled("record_video")
        let appState = try await IntentSupport.awaitConnectedAppState()
        if appState.videoRecorder.isRecording {
            await appState.toggleRecording()
        }
        return .result()
    }
}

#endif
