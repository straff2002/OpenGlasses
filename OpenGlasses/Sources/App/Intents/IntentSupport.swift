import AppIntents

/// Shared helpers for the Siri App Intents.
enum IntentSupport {
    /// Await the app "connection signal" — poll for `AppStateProvider.shared`.
    ///
    /// Siri can invoke a background intent before the app scene is fully resident
    /// (more so under iOS 27's background-driven conversational Siri), so we wait
    /// briefly rather than failing the instant `.shared` is nil. Returns as soon as
    /// the app is up; throws `appNotRunning` only if the signal never arrives.
    @MainActor
    static func awaitConnectedAppState(
        timeout: Duration = .seconds(4),
        pollInterval: Duration = .milliseconds(100)
    ) async throws -> AppState {
        if let appState = AppStateProvider.shared { return appState }

        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: pollInterval)
            if let appState = AppStateProvider.shared { return appState }
        }
        throw IntentConnectionError.appNotRunning
    }

    /// Plan BQ runtime guard: static intents can't be removed from the compiled metadata,
    /// so a built-in the user turned off in Settings → Siri & Search refuses here instead.
    /// (The Live Activity listening intents are deliberately unguarded — they're in-app
    /// surface controls, not Siri exposure.)
    @MainActor
    static func requireEnabled(_ builtinActionId: String) throws {
        guard !Config.siriExposure.disabledBuiltinActions.contains(builtinActionId) else {
            throw SiriActionError.disabled
        }
    }

    /// Execute one native tool, mapping failures to speakable text so Siri reads something
    /// useful instead of a generic error.
    @MainActor
    static func runTool(_ name: String, args: [String: Any], appState: AppState) async -> String {
        // Every intent tool call lands here, and goes through the same authority a model tool call
        // does — a user-authored Siri Action is a saved binding replayed by a machine, so the
        // composition floor applies to it exactly as it does to a skill pack.
        let call = ResolvedToolCall.root(name: name, arguments: ToolArguments(args),
                                         origin: .siriAction)
        switch await appState.nativeToolRouter.execute(call) {
        case .success(let text): return text
        case .failure(let message): return message
        }
    }
}

/// Error thrown when a Siri intent can't reach a running app.
enum IntentConnectionError: Error, CustomLocalizedStringResourceConvertible {
    case appNotRunning

    var localizedStringResource: LocalizedStringResource {
        "OpenGlasses is not running. Open the app first."
    }
}
