import Foundation

/// Which cards the Voice tab shows (Plan KH P1, Decision 3).
///
/// **Nothing on the home screen is permanent.** Plan HA removed an always-visible shelf because the
/// suggestions always being there looked wrong, and that requirement is the owner's. So this is a
/// finite offer: at most three cards, each leaves when tried or dismissed, and after three tried or
/// dismissed in total the shelf ends for good. Things to Try remains for anyone who wants the list.
///
/// Topics are not read here. Any ranking by what the app has learned is later work.
enum ScenarioShelfPolicy {
    /// The most cards shown at once.
    static let maximumCards = 3
    /// How many tried or dismissed scenarios end the shelf.
    static let endsAfter = 3

    /// Whether the shelf has ended. It counts ids as stored, not against today's catalogue: a
    /// scenario dropped in a later release must not reopen a shelf the person already finished.
    static func hasEnded(_ progress: ScenarioProgress) -> Bool {
        progress.triedOrDismissed.count >= endsAfter
    }

    /// The cards to show: the chosen intent first, ready before needing setup, then catalogue order.
    /// Untried and undismissed only. A step with nowhere to go is left for Things to Try, and with
    /// no usable model the shelf stays empty, because three cards saying so is noise. Pure.
    static func cards(from entries: [ScenarioEntry], progress: ScenarioProgress) -> [ScenarioEntry] {
        guard !hasEnded(progress) else { return [] }
        let spent = progress.triedOrDismissed
        let offered = entries.enumerated().filter { _, entry in
            guard !spent.contains(entry.id) else { return false }
            switch entry.readiness {
            case .ready: return true
            case .hidden: return false
            case .needsSetup(let step): return step != .chooseModel && step.destination != nil
            }
        }
        let ranked = offered.sorted { lhs, rhs in
            rank(lhs.offset, lhs.element, progress) < rank(rhs.offset, rhs.element, progress)
        }
        return ranked.prefix(maximumCards).map(\.element)
    }

    /// Whether the Voice tab should start on the conversation, where the cards are. The dock opens
    /// on the grid, so without this nearly nobody would see them.
    ///
    /// At most once per launch, and only from the untouched resting position: a move the wearer
    /// made always wins. Nothing moves during a live turn, in a realtime mode, or with a conversation
    /// already showing, and once the shelf has ended `hasCards` is false and the grid stands, as it
    /// does for everyone else. The last two inputs are the costly ones, so they are read last. Pure.
    static func opensOnConversation(pager: DockPagerState, voiceState: VoiceVisualState,
                                    directMode: Bool, onboardingDone: Bool, alreadySettled: Bool,
                                    conversationIsEmpty: @autoclosure () -> Bool,
                                    hasCards: @autoclosure () -> Bool) -> Bool {
        guard onboardingDone, directMode, !alreadySettled,
              pager.page == DockPage.home, pager.gridAnchor == nil, !pager.userMovedThisTurn,
              !DockPagerPolicy.isTurnActive(voiceState) else { return false }
        return conversationIsEmpty() && hasCards()
    }

    private static func rank(_ index: Int, _ entry: ScenarioEntry,
                             _ progress: ScenarioProgress) -> (Int, Int, Int) {
        (entry.scenario.intent == progress.chosenIntent ? 0 : 1,
         entry.readiness == .ready ? 0 : 1,
         index)
    }
}

/// The Ready page's choice and the first turn it leads to (Plan KH P1).
enum ScenarioFirstRun {
    /// Whether the Ready page offers the choice. A managed phone or a Field Assist first run has a
    /// job to do, so it goes straight to the field set.
    static func showsPicker(isManaged: Bool, fieldAssistSetUp: Bool) -> Bool {
        !isManaged && !fieldAssistSetUp
    }

    /// The scenario to run as a first turn, or nil, in which case the person gets cards instead.
    ///
    /// A ready `.prompt` only: a photo needs a camera in hand. Not one that needs glasses, which may
    /// not have connected yet, nor one that needs a job already open. And nil with no usable model,
    /// because such a scenario is not ready: a first turn that fails is worse than none. Pure.
    static func firstTurn(for intent: ScenarioIntent, in context: ScenarioContext,
                          scenarios: [Scenario]) -> Scenario? {
        scenarios.first { scenario in
            scenario.intent == intent && scenario.kind == .prompt
                && !scenario.needs.contains(.glasses) && !scenario.needs.contains(.fieldJobOpen)
                && ScenarioReadiness.evaluate(scenario, in: context) == .ready
        }
    }

    /// What the Voice tab does with a pending first turn.
    enum Consumption: Equatable {
        /// Onboarding is still up, or the app would drop a turn right now. It stays stored and is
        /// looked at again.
        case wait
        /// Run it. The record is cleared first, so nothing can fire it twice.
        case run(Scenario)
        /// It can no longer run. Clear it, and the cards stand in.
        case discard
    }

    /// Pure. `directMode` is the grid's own rule (`HomeSurfaceVisibility.showsActionTiles`): these
    /// are ordinary Direct-mode turns, and a realtime session runs its own spine.
    /// `busy` is `AppState.acceptsTypedTurn` turned over: a turn sent while busy is dropped without
    /// a word, so it would be lost and still count as tried.
    static func consumption(of pendingID: String?, pastOnboarding: Bool, directMode: Bool, busy: Bool,
                            context: ScenarioContext, scenarios: [Scenario]) -> Consumption {
        guard let pendingID else { return .wait }
        guard pastOnboarding, !busy else { return .wait }
        guard directMode, let scenario = scenarios.first(where: { $0.id == pendingID }),
              ScenarioReadiness.evaluate(scenario, in: context) == .ready else { return .discard }
        return .run(scenario)
    }
}

/// The ready scenarios as words the model can use (Plan KH P1). The answer to "what can you do for
/// me?" is a few situations that fit, not a list of tools. Pure.
enum ScenarioSpokenAnswer {
    /// How many from each group the model is given. Enough to pick from, too few to recite.
    static let perIntent = 4

    static func text(from entries: [ScenarioEntry]) -> String {
        let ready = entries.filter { $0.readiness == .ready }
        guard !ready.isEmpty else {
            return "## Things to try\nNothing is ready to suggest right now. Say that plainly, and offer to help with whatever they need."
        }
        var lines = ["## Things to try",
                     "Answer in plain words: pick two or three of these that suit the person and say them as things they could do. Do not read out the list, and do not name tools or settings."]
        for intent in ScenarioIntent.allCases {
            let group = ready.filter { $0.scenario.intent == intent }.prefix(perIntent)
            guard !group.isEmpty else { continue }
            lines.append("\(intent.title):")
            lines += group.map { "- \($0.scenario.title): \($0.scenario.situation)" }
        }
        return lines.joined(separator: "\n")
    }
}

/// The support report's line. A count and nothing else: no ids, no titles, no intent (Plan KH P1).
/// The total comes from the catalogue, so it cannot drift from it.
enum ScenarioReportLine {
    static func line(progress: ScenarioProgress, catalogIDs: [String]) -> String {
        let known = Set(catalogIDs)
        return "Things to try: \(progress.tried.filter(known.contains).count) of \(known.count)"
    }
}
