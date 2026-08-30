import AppIntents
import Foundation

// MARK: - Plan BQ P1 — curated intents for OpenGlasses data/hardware actions
//
// Discoverable in Shortcuts, the Action-button picker, and Siri suggestions without App
// Shortcut phrases (the 10-phrase cap is spent) — the parameterized "Run … on OpenGlasses"
// shortcut covers voice. Background-safe ones don't set `openAppWhenRun`, so Siri can run
// them without foregrounding the app. Free-form `String` parameters are fine on plain
// intents — the AppEntity/AppEnum restriction applies only to App Shortcut *phrases*.

/// "What did they just say?" — transcribe the rolling ambient-audio buffer.
struct MemoryRewindIntent: AppIntent {
    static var title: LocalizedStringResource = "Memory Rewind"
    static var description = IntentDescription("Replay what was just said from the ambient audio buffer")

    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Minutes", default: 2)
    var minutes: Int

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        try IntentSupport.requireEnabled("memory_rewind")
        let appState = try await IntentSupport.awaitConnectedAppState()
        let result = await IntentSupport.runTool(
            "memory_rewind", args: ["action": "rewind", "minutes": minutes], appState: appState)
        return .result(value: result, dialog: IntentDialog(stringLiteral: result))
    }
}

/// Calendar + reminders + weather My Day rundown, spoken by Siri.
struct DailyBriefingIntent: AppIntent {
    static var title: LocalizedStringResource = "Daily Briefing"
    static var description = IntentDescription("Get a spoken My Day briefing with your calendar, due reminders, and weather")

    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        try IntentSupport.requireEnabled("daily_briefing")
        let appState = try await IntentSupport.awaitConnectedAppState()
        let result = await IntentSupport.runTool("daily_briefing", args: [:], appState: appState)
        return .result(value: result, dialog: IntentDialog(stringLiteral: result))
    }
}

/// Start the teleprompter, optionally with a saved script by name.
struct StartTeleprompterIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Teleprompter"
    static var description = IntentDescription("Start the teleprompter, optionally with a saved script")

    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Script Name")
    var scriptName: String?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        try IntentSupport.requireEnabled("teleprompter_start")
        let appState = try await IntentSupport.awaitConnectedAppState()
        var args: [String: Any] = ["action": "start"]
        if let scriptName, !scriptName.isEmpty { args["script"] = scriptName }
        let result = await IntentSupport.runTool("teleprompter", args: args, appState: appState)
        return .result(value: result, dialog: IntentDialog(stringLiteral: result))
    }
}

struct StopTeleprompterIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Teleprompter"
    static var description = IntentDescription("Stop the running teleprompter")

    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        try IntentSupport.requireEnabled("teleprompter_stop")
        let appState = try await IntentSupport.awaitConnectedAppState()
        let result = await IntentSupport.runTool("teleprompter", args: ["action": "stop"], appState: appState)
        return .result(value: result, dialog: IntentDialog(stringLiteral: result))
    }
}

/// Summarize the ambient-caption conversation history.
struct MeetingSummaryIntent: AppIntent {
    static var title: LocalizedStringResource = "Meeting Summary"
    static var description = IntentDescription("Summarize the conversation captured by ambient captions")

    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        try IntentSupport.requireEnabled("meeting_summary")
        let appState = try await IntentSupport.awaitConnectedAppState()
        let result = await IntentSupport.runTool("meeting_summary", args: [:], appState: appState)
        return .result(value: result, dialog: IntentDialog(stringLiteral: result))
    }
}

/// Save the current location under a spoken label ("my car", "trailhead").
struct SaveLocationIntent: AppIntent {
    static var title: LocalizedStringResource = "Save This Location"
    static var description = IntentDescription("Save your current location under a name you choose")

    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Label")
    var label: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        try IntentSupport.requireEnabled("save_location")
        let appState = try await IntentSupport.awaitConnectedAppState()
        let result = await IntentSupport.runTool("save_location", args: ["label": label], appState: appState)
        return .result(value: result, dialog: IntentDialog(stringLiteral: result))
    }
}

/// Start/stop RTMP broadcasting of the glasses camera.
struct ToggleBroadcastIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Broadcast"
    static var description = IntentDescription("Start or stop broadcasting the glasses camera over RTMP")

    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        try IntentSupport.requireEnabled("broadcast_toggle")
        let appState = try await IntentSupport.awaitConnectedAppState()
        await appState.toggleBroadcast()
        let isOn = appState.broadcastService.isBroadcasting
        return .result(
            value: isOn,
            dialog: IntentDialog(stringLiteral: isOn ? "Broadcasting started." : "Broadcasting stopped.")
        )
    }
}
