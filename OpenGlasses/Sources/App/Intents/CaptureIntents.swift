import AppIntents

/// Shortcut: silently take a photo on the glasses and save it (no LLM, no TTS).
///
/// Distinct from `TakePhotoIntent`, which captures *and describes* the scene. This one is the plain
/// "snap a photo on my glasses" action — it saves to Documents/Photos and drops a timestamped note
/// into the caption stream, with a soft tone + haptic. Available as a Shortcuts action and addable
/// to Siri / the Action button; deliberately not in `OpenGlassesShortcuts` so it doesn't push past
/// iOS's 10 App-Shortcut cap (the describe-photo phrase already covers "take a photo").
struct CaptureGlassesPhotoIntent: AppIntent {
    static var title: LocalizedStringResource = "Capture Glasses Photo"
    static var description = IntentDescription("Take a photo on the glasses and save it")

    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        try IntentSupport.requireEnabled("capture_photo")
        guard let appState = AppStateProvider.shared else {
            throw IntentError.appNotRunning
        }
        guard appState.isConnected else {
            throw IntentError.glassesNotConnected
        }
        await appState.capturePhotoSilently()
        return .result()
    }

    enum IntentError: Error, CustomLocalizedStringResourceConvertible {
        case appNotRunning
        case glassesNotConnected

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .appNotRunning: return "Avenkin is not running. Open the app first."
            case .glassesNotConnected: return "Connect your glasses first."
            }
        }
    }
}

/// Shortcut: start/stop glasses video recording.
///
/// Toggles the same recorder the in-app record button drives. Returns the resulting state so a
/// Shortcut can branch on it. A Shortcuts action (and Action-button / Siri-addable); not in
/// `OpenGlassesShortcuts` to respect the 10 App-Shortcut cap.
struct RecordGlassesVideoIntent: AppIntent {
    static var title: LocalizedStringResource = "Record Glasses Video"
    static var description = IntentDescription("Start or stop recording video on the glasses")

    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        try IntentSupport.requireEnabled("record_video")
        guard let appState = AppStateProvider.shared else {
            throw IntentError.appNotRunning
        }
        guard appState.isConnected else {
            throw IntentError.glassesNotConnected
        }
        await appState.toggleRecording()
        return .result(value: appState.videoRecorder.isRecording)
    }

    enum IntentError: Error, CustomLocalizedStringResourceConvertible {
        case appNotRunning
        case glassesNotConnected

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .appNotRunning: return "Avenkin is not running. Open the app first."
            case .glassesNotConnected: return "Connect your glasses first."
            }
        }
    }
}
