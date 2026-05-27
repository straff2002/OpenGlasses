import AppIntents
import WidgetKit
import WatchConnectivity

// MARK: - WCSession activation helper for widget extension

private class SessionActivator: NSObject, WCSessionDelegate {
    static let shared = SessionActivator()
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {}
    #endif
}

private func sendWatchCommand(_ command: String) {
    guard WCSession.isSupported() else { return }
    let session = WCSession.default
    if session.activationState != .activated {
        session.delegate = SessionActivator.shared
        session.activate()
    }
    // transferUserInfo queues delivery — works even when iPhone not immediately reachable
    session.transferUserInfo(["command": command, "source": "complication"])
}

// MARK: - Configuration Intents (required by AppIntentTimelineProvider)

struct ListenComplicationConfig: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Listen Configuration"
    static var description = IntentDescription("Configure the listen complication.")
}

struct RecordComplicationConfig: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Transcribe Configuration"
    static var description = IntentDescription("Configure the transcribe complication.")
}

struct PhotoComplicationConfig: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Photo Note Configuration"
    static var description = IntentDescription("Configure the photo note complication.")
}

// MARK: - Action Intents (used by Button(intent:) inside complication views)

struct ToggleListenIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Listen"
    static var description = IntentDescription("Start or stop listening on your glasses.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        sendWatchCommand("toggleListen")
        return .result()
    }
}

struct ToggleRecordIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Transcribe"
    static var description = IntentDescription("Start or stop transcription without AI response.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        sendWatchCommand("toggleRecord")
        return .result()
    }
}

struct CapturePhotoNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Capture Photo Note"
    static var description = IntentDescription("Take a photo and add it to the meeting transcript silently — no AI response, transcription keeps running.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        sendWatchCommand("capturePhoto")
        return .result()
    }
}
