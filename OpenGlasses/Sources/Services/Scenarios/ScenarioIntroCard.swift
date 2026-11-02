import Foundation

/// The Voice tab's "Things to try" card (Plan KH P1).
///
/// The shelf sits on the empty conversation page, and `ConversationStore` restores the last
/// conversation at launch, so anyone who has used the app rarely sees that page. This card is how
/// they reach the same scenarios. It keeps the shelf's promise (Decision 3): nothing on the home
/// screen is permanent, so it leaves for good on its X, when the shelf ends, or after
/// `shownLaunchLimit` launches that showed it. There is deliberately no way to bring it back.
enum ScenarioIntroCard {
    /// How many launches may show the card.
    static let shownLaunchLimit = 5

    /// Whether the card has left for good.
    ///
    /// The launch counted a moment ago is the one on screen, so it is left out: the last allowed
    /// launch keeps its card rather than losing it the moment it is counted. Pure.
    static func isOver(_ progress: ScenarioProgress, countedThisLaunch: Bool) -> Bool {
        if progress.introCardDismissed || ScenarioShelfPolicy.hasEnded(progress) { return true }
        let earlierLaunches = progress.introCardShownLaunches - (countedThisLaunch ? 1 : 0)
        return earlierLaunches >= shownLaunchLimit
    }

    /// Whether the card is on screen now.
    ///
    /// **It needs a conversation on the page, and that alone keeps it off the shelf.** The shelf
    /// draws only when the conversation is empty, so the two can never be up together. It also
    /// needs no knowledge of the dock's page: the card does not come and go with each swipe, and an
    /// empty conversation already opens on the shelf once per launch. A new user meets the card
    /// once there is a conversation, not before.
    ///
    /// `directMode` is the grid's own rule (`HomeSurfaceVisibility.showsActionTiles`). `surfaceFree`
    /// says no turn is running and captions are not using the zone. `hasOffer` is the costly one:
    /// the caller works it out once, because reading the app into a context goes to the Keychain,
    /// and this runs on every render. Pure.
    static func shows(progress: ScenarioProgress, countedThisLaunch: Bool, pastOnboarding: Bool,
                      directMode: Bool, surfaceFree: Bool, hasOffer: Bool,
                      conversationIsEmpty: @autoclosure () -> Bool) -> Bool {
        pastOnboarding && directMode && surfaceFree && hasOffer
            && !isOver(progress, countedThisLaunch: countedThisLaunch)
            && !conversationIsEmpty()
    }

    /// What the sheet leads with: the field set on a phone with no picker, as the Ready page does,
    /// otherwise what the person chose, if it is one of the choices on offer. Nil until they choose.
    static func intent(showsPicker: Bool, chosen: ScenarioIntent?) -> ScenarioIntent? {
        guard showsPicker else { return .field }
        return chosen.flatMap { ScenarioIntent.offeredOnReadyPage.contains($0) ? $0 : nil }
    }

    /// The scenarios the sheet offers for one intent, on the shelf's own rules. Pure.
    static func scenarios(for intent: ScenarioIntent, from entries: [ScenarioEntry],
                          progress: ScenarioProgress) -> [ScenarioEntry] {
        ScenarioShelfPolicy.cards(from: entries.filter { $0.scenario.intent == intent }, progress: progress)
    }

    /// Whether the sheet would have anything in it. A card that opens on nothing is worse than no
    /// card, and a launch with nothing to offer must not count towards retiring it. Pure.
    static func hasOffer(from entries: [ScenarioEntry], progress: ScenarioProgress, showsPicker: Bool) -> Bool {
        let intents = showsPicker ? ScenarioIntent.offeredOnReadyPage : [.field]
        return intents.contains { !scenarios(for: $0, from: entries, progress: progress).isEmpty }
    }
}

/// What a tap on a scenario card does: the shelf and the Voice tab's sheet share it.
enum ScenarioCardTap: Equatable {
    /// Start the turn.
    case run
    /// It needs a setup step that lives in Settings.
    case openSettings(SettingsCategoryID)
    /// Nothing, and nothing is recorded. A turn sent while busy is dropped without a word, so it
    /// must not count as tried.
    case nothing

    /// Pure. `acceptsTurn` is `AppState.acceptsTypedTurn`.
    static func resolve(_ entry: ScenarioEntry, acceptsTurn: Bool) -> ScenarioCardTap {
        switch entry.readiness {
        case .needsSetup(let step): return step.destination.map(ScenarioCardTap.openSettings) ?? .nothing
        case .hidden: return .nothing
        case .ready: return acceptsTurn ? .run : .nothing
        }
    }
}

/// Where the Voice tab's sheet asked to go. It goes once the sheet has gone, because neither the
/// camera nor another tab can come up from under it.
enum ScenarioSheetExit {
    case close
    case settings(SettingsCategoryID)
    case livePreview
    case run(ScenarioEntry)
}
