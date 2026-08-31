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
        /// My Day set up and loaded with a full card's worth of rows — the state that needs a
        /// calendar, a permission grant and a real morning to reach otherwise.
        case seedMyDay = "-OGUITestSeedMyDay"
        /// A delete-and-reinstall: the Keychain kept a provider key, `UserDefaults` kept nothing.
        case reinstall = "-OGUITestReinstall"
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
        //
        // A reinstall is the same wipe with the *other* half left standing: the same absent
        // defaults, and a saved model still carrying a real key. That is the whole state — no
        // flag says "this is a reinstall", the app works it out from these two facts, which is
        // exactly what the test is here to check.
        Config.setSavedModels(isSet(.reinstall)
                              ? [Config.appleIntelligenceDefault, keyedModelThatSurvivedTheDelete]
                              : [Config.appleIntelligenceDefault])

        if isSet(.freshInstall) {
            Config.setHasCompletedOnboarding(false)
        }

        if isSet(.seedMyDay) {
            // The opt-in the setup card writes. The card's *content* is seeded at runtime below;
            // this is only the switch that decides which card is drawn.
            UserDefaults.standard.set(true, forKey: "myDayEnabled")
            UserDefaults.standard.set(false, forKey: "myDayCollapsed")
        }

        if isSet(.configured) {
            Config.setHasCompletedOnboarding(true)
            // Write the journey state directly rather than letting the migration infer it: a
            // completed onboarding reads as a prior install, which unfolds every category and
            // leaves no Discover card to audit. The folded hub is the shape this seeds.
            seedJourney(showsEverything: isSet(.showAllSettings))
        }
    }

    /// The one fact a reinstall is made of, stated directly because the store that carries it
    /// does not exist here.
    ///
    /// A simulator build with code signing off has **no Keychain**: every read and write returns
    /// `errSecMissingEntitlement`, which is also why ~13 Keychain-backed unit tests fail in the
    /// same environment. A surviving *Keychain* credential is exactly what separates a reinstall
    /// from a fresh install, so writing one and hoping to read it back seeds nothing at all.
    /// `Config.captureLaunchProvenance()` takes this instead.
    ///
    /// Still only state, on the terms at the top of this file: the detection rule, the page it
    /// produces and both of its exits are the shipping ones, and nothing here compiles into a
    /// Release binary. `nil` on every launch that is not seeding a reinstall, so the real probe
    /// answers for all of them.
    static var seededSurvivingCredentials: Bool? {
        guard isSet(.reinstall) else { return nil }
        return true
    }

    /// The saved model a reinstall finds waiting for it — written for the sake of a device or a
    /// signed build, where it is the whole seed. Not a real credential; nothing in a UI test ever
    /// sends it anywhere. Just a non-empty key, which is what the gate reads.
    private static let keyedModelThatSurvivedTheDelete = ModelConfig(
        id: "uitest-surviving-key",
        name: "Anthropic",
        provider: LLMProvider.anthropic.rawValue,
        apiKey: "sk-ant-uitest-not-a-real-key",
        model: LLMProvider.anthropic.defaultModel,
        baseURL: LLMProvider.anthropic.defaultBaseURL
    )

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

        if isSet(.seedMyDay) {
            appState.myDayService.seedForUITest(seededDay())
        }

        if isSet(.seedCaptions) {
            seedCaptions(appState)
            // Re-applied on a tick rather than written once. With no glasses to talk to, the app
            // correctly decides the wearer is away and *suspends* captions a few seconds in, which
            // clears the live line and reshapes the overlay — and a screen that changes shape while
            // an audit is walking it produces findings about a layout that has already gone (a
            // caption measured for contrast against the canvas, because the scrim it actually sits
            // on left with the rest of the panel). That is the app behaving correctly and the
            // *seed* being too short-lived, and it stayed invisible while this surface's contrast
            // was deferred.
            //
            // Still only state: every tick writes exactly what the initial seed wrote, and only
            // when the app has cleared it. Nothing branches on this timer, and none of it exists
            // outside a Debug build launched with `-OGUITest`.
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak appState] _ in
                guard let appState else { return }
                MainActor.assumeIsolated { seedCaptions(appState) }
            }
        }
    }

    /// A full card: the three rows the home surface draws plus the ones behind "See all", with a
    /// long title in the mix because a row that wraps is what makes the card tall enough to test
    /// the layout that has to hold it.
    private static func seededDay() -> MyDaySnapshot {
        let now = Date()
        func item(_ id: String, _ kind: MyDayKind, _ title: String, _ detail: String,
                  _ urgency: MyDayUrgency, in minutes: Int) -> MyDayItem {
            MyDayItem(id: .init(source: .calendar, rawValue: id), kind: kind, title: title,
                      detail: detail, dueAt: now.addingTimeInterval(TimeInterval(minutes * 60)),
                      urgency: urgency, actions: [.open])
        }

        return MyDaySnapshot(
            generatedAt: now,
            period: .morning,
            headline: "Four things today, first one in 25 minutes.",
            items: [
                item("standup", .event, "Design review with the hardware team",
                     "9:30 AM · Meeting room 2, second floor", .immediate, in: 25),
                item("call", .event, "Call back the supplier about the lens order",
                     "11:00 AM", .important, in: 120),
                item("errand", .reminder, "Pick up the replacement charging case",
                     "Due today", .upcoming, in: 300),
                item("write-up", .reminder, "Send the field notes from yesterday's test",
                     "Due today", .upcoming, in: 400),
            ],
            sourceStates: MyDaySource.allCases.map(MyDaySourceState.available),
            nextRefreshAt: now.addingTimeInterval(900)
        )
    }

    /// The lines a real session would have produced. Two of the three carry a diarized speaker, so
    /// the speaker chip is on screen for the audit to measure — without one the chip never renders
    /// and its touch target, which two phases deferred, would be gated by nothing at all.
    ///
    /// Idempotent: a no-op while the seeded state is already on screen.
    @MainActor
    private static func seedCaptions(_ appState: AppState) {
        let captions = appState.ambientCaptions
        guard !captions.isActive
            || captions.currentCaption.isEmpty
            || captions.captionHistory.count != 3 else { return }

        let now = Date()
        captions.captionHistory = [
            .init(text: "That's the one on the left, next to the window.",
                  timestamp: now.addingTimeInterval(-8), seq: 3, speaker: 1),
            .init(text: "We should be there by about half past.",
                  timestamp: now.addingTimeInterval(-16), seq: 2, speaker: 0),
            .init(text: "Did you want the long or the short version?",
                  timestamp: now.addingTimeInterval(-24), seq: 1),
        ]
        captions.currentCaption = "I'll send the details over this afternoon."
        captions.isActive = true
    }
}
#endif
