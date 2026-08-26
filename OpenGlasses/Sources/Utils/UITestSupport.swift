#if DEBUG
import Foundation

/// Deterministic launch state for the UI-test target (Plan DF P4).
///
/// **This exists only inside a Debug build.** The whole file is behind `#if DEBUG`, so a Release
/// binary contains none of it, and every path is inert unless the process was launched with
/// `-OGUITest`. Nothing here changes how the app *behaves*: it seeds state a screen would
/// otherwise need a real account, a real device, or a real conversation to reach, so an audit can
/// stand in front of a known screen instead of whatever the last run left behind. There is no
/// branch that skips a check, shortens an animation, or fakes a result.
///
/// The seam is deliberately narrow — two call sites, both in `OpenGlassesApp`:
/// `applyLaunchState()` before anything reads a default, and `seedRuntime(_:)` once `AppState`
/// exists for the state that has no defaults key.
enum UITestSupport {
    /// Present on the launch arguments of a UI-test run, and nowhere else.
    static let activation = "-OGUITest"

    enum Flag: String, CaseIterable {
        /// A never-launched install: onboarding is the first thing on screen.
        case freshInstall = "-OGUITestFreshInstall"
        /// Past onboarding, with the settings journey in its folded first-run shape.
        case configured = "-OGUITestConfigured"
        /// "Show everything" already on, so the hub renders every category as a row.
        case showAllSettings = "-OGUITestShowAllSettings"
        /// Captions overlay on screen with a short history and a live line.
        case seedCaptions = "-OGUITestSeedCaptions"
    }

    static var isActive: Bool { arguments.contains(activation) }

    static func isSet(_ flag: Flag) -> Bool { isActive && arguments.contains(flag.rawValue) }

    private static var arguments: [String] { ProcessInfo.processInfo.arguments }

    // MARK: - Defaults-backed state

    /// Seed the persisted state, before anything can read it.
    ///
    /// Called first thing in `OpenGlassesApp.init()` — ahead of the secrets migration and the
    /// settings-journey migration, both of which read what this writes.
    static func applyLaunchState() {
        guard isActive else { return }

        // Every run starts from the same defaults, whatever the simulator was left holding.
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        // Saved models live in the Keychain, which outlives an app delete on a simulator — so
        // wiping the defaults domain is not on its own enough to produce a first-run app. One
        // keyless model is what a device with nothing configured actually holds.
        Config.setSavedModels([Config.appleIntelligenceDefault])

        if isSet(.freshInstall) {
            Config.setHasCompletedOnboarding(false)
        }

        if isSet(.configured) {
            Config.setHasCompletedOnboarding(true)
            // Write the journey state directly rather than letting the migration infer it: a
            // completed onboarding reads as a prior install, which unfolds every category and
            // leaves no Discover card to audit. The folded hub is the shape this seeds.
            seedJourney(showsEverything: isSet(.showAllSettings))
        }
    }

    private static func seedJourney(showsEverything: Bool) {
        var state = SettingsJourneyMigration.initialState(
            signals: .init(hasPriorInstall: false, configuredCategoryIDs: [])
        )
        state.showsEverything = showsEverything
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: "settingsJourneyState")
    }

    // MARK: - Runtime state

    /// Seed the state that has no defaults key, once `AppState` exists.
    @MainActor
    static func seedRuntime(_ appState: AppState) {
        guard isActive else { return }

        if isSet(.seedCaptions) {
            // The overlay only draws while a recognition session is live, and a simulator has no
            // microphone worth transcribing. These are the lines a session would have produced;
            // the service is left `isActive` so the view renders exactly as it does in the room.
            let now = Date()
            appState.ambientCaptions.captionHistory = [
                .init(text: "That's the one on the left, next to the window.",
                      timestamp: now.addingTimeInterval(-8), seq: 3),
                .init(text: "We should be there by about half past.",
                      timestamp: now.addingTimeInterval(-16), seq: 2),
                .init(text: "Did you want the long or the short version?",
                      timestamp: now.addingTimeInterval(-24), seq: 1),
            ]
            appState.ambientCaptions.currentCaption = "I'll send the details over this afternoon."
            appState.ambientCaptions.isActive = true
        }
    }
}
#endif
