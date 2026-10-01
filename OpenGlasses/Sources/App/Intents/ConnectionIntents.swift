import AppIntents

/// Siri Intent: Connect to glasses and start listening.
/// "Hey Siri, connect OpenGlasses" — works from HomePod, Watch, Lock Screen.
struct ConnectGlassesIntent: AppIntent {
    static var title: LocalizedStringResource = "Connect Avenkin"
    static var description = IntentDescription("Connect to your smart glasses and start listening")

    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try IntentSupport.requireEnabled("connect_glasses")
        guard let appState = AppStateProvider.shared else {
            throw IntentError.appNotRunning
        }

        // Phone-first (`TalkEntryPolicy`): this starts listening whether or not the glasses are
        // here, and says which microphone it is on rather than reporting a failure.
        await appState.connectAndListen()

        if appState.isConnected {
            return .result(value: "Connected and listening")
        } else {
            return .result(value: "Listening on your phone — glasses aren't connected")
        }
    }

    enum IntentError: Error, CustomLocalizedStringResourceConvertible {
        case appNotRunning
        var localizedStringResource: LocalizedStringResource { "Avenkin is not running. Open the app first." }
    }
}

/// Siri Intent: Disconnect / sleep glasses.
/// "Hey Siri, disconnect OpenGlasses" — works from HomePod, Watch, Lock Screen.
struct DisconnectGlassesIntent: AppIntent {
    static var title: LocalizedStringResource = "Disconnect Avenkin"
    static var description = IntentDescription("Disconnect from your smart glasses to save battery")

    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try IntentSupport.requireEnabled("disconnect_glasses")
        guard let appState = AppStateProvider.shared else {
            throw IntentError.appNotRunning
        }

        if appState.isConnected {
            appState.disconnectGlasses()
            return .result(value: "Glasses disconnected")
        } else {
            return .result(value: "Glasses are already disconnected")
        }
    }

    enum IntentError: Error, CustomLocalizedStringResourceConvertible {
        case appNotRunning
        var localizedStringResource: LocalizedStringResource { "Avenkin is not running." }
    }
}

/// Siri Intent: Toggle glasses connection.
/// "Hey Siri, toggle OpenGlasses" — connects if off, disconnects if on.
struct ToggleGlassesIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Avenkin"
    static var description = IntentDescription("Connect or disconnect your smart glasses")

    static var isDiscoverable: Bool { true }
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try IntentSupport.requireEnabled("toggle_glasses")
        guard let appState = AppStateProvider.shared else {
            throw IntentError.appNotRunning
        }

        if appState.isConnected {
            appState.disconnectGlasses()
            return .result(value: "Glasses disconnected")
        } else {
            await appState.connectAndListen()
            return .result(value: appState.isConnected ? "Connected and listening"
                                                       : "Listening on your phone — glasses aren't connected")
        }
    }

    enum IntentError: Error, CustomLocalizedStringResourceConvertible {
        case appNotRunning
        var localizedStringResource: LocalizedStringResource { "Avenkin is not running." }
    }
}
