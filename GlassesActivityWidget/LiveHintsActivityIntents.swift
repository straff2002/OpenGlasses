import AppIntents

// The live-hints buttons on the Live Activity (Plan MO P2). Each runs in the widget extension, as
// the Lock Screen's power button does (`DisableListeningIntent`): it records the press for the app
// (`PendingLiveHintsCommand`), which is running, because a session is. None opens the app.

struct RepeatLiveHintIntent: AppIntent {
    static var title: LocalizedStringResource = "Repeat Hint"
    static var description = IntentDescription("Say or show the last live hint again.")
    static var isDiscoverable: Bool { false }

    func perform() async throws -> some IntentResult {
        PendingLiveHintsCommand.submit(.repeatHint)
        return .result()
    }
}

struct SkipLiveHintIntent: AppIntent {
    static var title: LocalizedStringResource = "Skip Hint"
    static var description = IntentDescription("Stop the live hint being spoken.")
    static var isDiscoverable: Bool { false }

    func perform() async throws -> some IntentResult {
        PendingLiveHintsCommand.submit(.skipHint)
        return .result()
    }
}

struct StopLiveHintsIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Live Hints"
    static var description = IntentDescription("End the live hints session.")
    static var isDiscoverable: Bool { false }

    func perform() async throws -> some IntentResult {
        PendingLiveHintsCommand.submit(.stop)
        return .result()
    }
}
