import XCTest
@testable import OpenGlasses

/// The settings capability journey (Plan DE P1), as pure data and pure functions.
///
/// The three named invariants get their own sections: accessibility is never
/// foldable, migration never hides a configured category, and a suggestion never
/// repeats. Everything here runs headlessly — no views, no `.shared` services,
/// and the store tests use their own `UserDefaults` suite.
final class SettingsJourneyTests: XCTestCase {

    // MARK: - Fixtures

    private func fixtureCatalog() -> [CapabilityCategory] {
        [
            .everyday(id: "voice", title: "Voice", icon: "waveform", subtitle: "sub"),
            .pinnedAssistive(id: "accessibility", title: "Accessibility",
                             icon: "accessibility", subtitle: "sub"),
            .discover(id: "capture", title: "Capture", icon: "video", subtitle: "sub",
                      pitch: "pitch", tier: .creator),
            .discover(id: "tools", title: "Tools", icon: "wrench", subtitle: "sub",
                      pitch: "pitch", tier: .power),
            .discover(id: "connections", title: "Connections", icon: "link", subtitle: "sub",
                      pitch: "pitch", tier: .proAndOrg, hiddenInSimpleMode: true),
        ]
    }

    // MARK: - Catalog shape

    func testEveryCategoryIDIsUnique() {
        let ids = CapabilityCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testEveryFoldableCategoryHasAPitch() {
        for category in CapabilityCatalog.foldable {
            XCTAssertFalse(category.pitch.isEmpty, "\(category.id) folds but pitches nothing")
        }
    }

    func testEverydayCategoriesNeverPitch() {
        for category in CapabilityCatalog.all where !category.isFoldable {
            XCTAssertTrue(category.pitch.isEmpty, "\(category.id) is Everyday but carries a pitch")
        }
    }

    func testEveryTierIsRepresented() {
        let tiers = Set(CapabilityCatalog.all.map(\.tier))
        XCTAssertEqual(tiers, Set(CapabilityTier.allCases))
    }

    // MARK: - Invariant: accessibility is never foldable

    func testAccessibilityIsPinnedEveryday() {
        guard let accessibility = CapabilityCatalog.category(id: CapabilityCatalog.accessibility) else {
            return XCTFail("the accessibility category is missing from the catalog")
        }
        XCTAssertEqual(accessibility.placement, .everyday)
        XCTAssertEqual(accessibility.tier, .everyday)
        XCTAssertFalse(accessibility.isFoldable)
        // Assistive features are free forever and no profile may withhold them, so
        // Simple Mode must not remove the row either.
        XCTAssertFalse(accessibility.hiddenInSimpleMode)
    }

    func testAccessibilityIsVisibleUnderEveryPossibleJourneyState() {
        guard let accessibility = CapabilityCatalog.category(id: CapabilityCatalog.accessibility) else {
            return XCTFail("the accessibility category is missing from the catalog")
        }
        // Every combination of the switches that could conceivably hide something.
        for showsEverything in [true, false] {
            for unfolded in [Set<String>(), CapabilityCatalog.foldableIDs] {
                for simpleMode in [true, false] {
                    var state = SettingsJourneyState()
                    state.showsEverything = showsEverything
                    state.unfolded = unfolded
                    XCTAssertTrue(state.isVisible(accessibility))
                    XCTAssertTrue(
                        state.visibleCategories(simpleMode: simpleMode).contains(accessibility),
                        "hidden with showsEverything=\(showsEverything) simpleMode=\(simpleMode)"
                    )
                    XCTAssertFalse(state.discoverCards(simpleMode: simpleMode).contains(accessibility))
                }
            }
        }
    }

    func testPinnedAssistiveConstructorCannotPlaceElsewhere() {
        // The constructor takes no placement and no Simple Mode flag: whatever it is
        // handed, the result is an always-visible Everyday category.
        let category = CapabilityCategory.pinnedAssistive(
            id: "x", title: "X", icon: "a", subtitle: "s"
        )
        XCTAssertEqual(category.placement, .everyday)
        XCTAssertFalse(category.hiddenInSimpleMode)
    }

    func testFoldableTierCannotExpressEveryday() {
        // The structural half of the pin: there is no Everyday case to fold into.
        XCTAssertEqual(Set(FoldableTier.allCases.map(\.tier)), [.creator, .power, .proAndOrg])
        XCTAssertFalse(FoldableTier.allCases.map(\.tier).contains(.everyday))
    }

    // MARK: - Visibility

    func testFreshStateShowsEverydayOnly() {
        let catalog = fixtureCatalog()
        let state = SettingsJourneyState()
        XCTAssertEqual(state.visibleCategories(in: catalog).map(\.id), ["voice", "accessibility"])
        XCTAssertEqual(state.discoverCards(in: catalog).map(\.id), ["capture", "tools", "connections"])
    }

    func testUnfoldingRevealsExactlyOneCategory() {
        let catalog = fixtureCatalog()
        var state = SettingsJourneyState()
        XCTAssertTrue(state.unfold("tools"))
        XCTAssertEqual(state.visibleCategories(in: catalog).map(\.id),
                       ["voice", "accessibility", "tools"])
        XCTAssertEqual(state.discoverCards(in: catalog).map(\.id), ["capture", "connections"])
        // Idempotent: a second tap changes nothing.
        XCTAssertFalse(state.unfold("tools"))
    }

    func testShowEverythingRevealsEverythingWithoutUnfolding() {
        let catalog = fixtureCatalog()
        var state = SettingsJourneyState()
        state.showsEverything = true
        XCTAssertTrue(state.discoverCards(in: catalog).isEmpty)
        XCTAssertEqual(state.visibleCategories(in: catalog).count, catalog.count)
        // Turning it back off returns to what was explicitly unfolded — reversible,
        // because it is a view switch and not a decision about the user's setup.
        state.showsEverything = false
        XCTAssertEqual(state.visibleCategories(in: catalog).map(\.id), ["voice", "accessibility"])
    }

    func testSimpleModeHidesOwnerSurfaceWithoutTouchingJourneyState() {
        let catalog = fixtureCatalog()
        var state = SettingsJourneyState()
        state.unfold("connections")
        XCTAssertTrue(state.visibleCategories(in: catalog, simpleMode: false).map(\.id).contains("connections"))
        XCTAssertFalse(state.visibleCategories(in: catalog, simpleMode: true).map(\.id).contains("connections"))
        // Simple Mode hides it outright rather than pitching it as something to discover.
        XCTAssertFalse(state.discoverCards(in: catalog, simpleMode: true).map(\.id).contains("connections"))
        // …and the journey state itself is untouched by Simple Mode.
        XCTAssertTrue(state.unfolded.contains("connections"))
    }

    func testDiscoverCardsAreOrderedByTier() {
        let catalog = fixtureCatalog()
        let state = SettingsJourneyState()
        XCTAssertEqual(state.discoverCards(in: catalog).map(\.tier),
                       [.creator, .power, .proAndOrg])
    }

    // MARK: - Invariant: migration never hides a configured category

    func testFreshInstallStartsWithEverydayOnly() {
        let state = SettingsJourneyMigration.initialState(
            signals: .init(hasPriorInstall: false, configuredCategoryIDs: [])
        )
        XCTAssertTrue(state.unfolded.isEmpty)
        XCTAssertFalse(state.showsEverything)
        XCTAssertTrue(state.hasMigrated)
        XCTAssertFalse(state.discoverCards().isEmpty)
    }

    func testPriorInstallMigratesFullyUnfolded() {
        let state = SettingsJourneyMigration.initialState(
            signals: .init(hasPriorInstall: true, configuredCategoryIDs: [])
        )
        XCTAssertEqual(state.unfolded, CapabilityCatalog.foldableIDs)
        XCTAssertTrue(state.discoverCards().isEmpty)
        for category in CapabilityCatalog.all {
            XCTAssertTrue(state.isVisible(category), "\(category.id) vanished on update")
        }
    }

    func testMigrationNeverHidesAConfiguredCategory() {
        // Every non-empty subset of the foldable set, without the prior-install marker:
        // whatever the user configured stays visible, and nothing else is forced open.
        for configured in CapabilityCatalog.foldableIDs {
            let state = SettingsJourneyMigration.initialState(
                signals: .init(hasPriorInstall: false, configuredCategoryIDs: [configured])
            )
            guard let category = CapabilityCatalog.category(id: configured) else {
                return XCTFail("unknown category id \(configured)")
            }
            XCTAssertTrue(state.isVisible(category), "\(configured) was configured but folded away")
            XCTAssertEqual(state.unfolded, [configured])
        }
    }

    func testMigrationIgnoresUnknownConfiguredIDs() {
        let state = SettingsJourneyMigration.initialState(
            signals: .init(hasPriorInstall: false, configuredCategoryIDs: ["a-category-that-left"])
        )
        XCTAssertTrue(state.unfolded.isEmpty)
    }

    func testMigrationNeverFoldsAnEverydayCategory() {
        for signals in [
            SettingsJourneyMigration.Signals(hasPriorInstall: false),
            SettingsJourneyMigration.Signals(hasPriorInstall: true),
        ] {
            let state = SettingsJourneyMigration.initialState(signals: signals)
            for category in CapabilityCatalog.all where !category.isFoldable {
                XCTAssertTrue(state.isVisible(category))
            }
        }
    }

    // MARK: - Invariant: suggestions never repeat

    func testEveryMomentHasExactlyOneSuggestion() {
        for moment in UnlockMoment.allCases {
            let matches = UnlockSuggestionPolicy.suggestions.filter { $0.moment == moment }
            XCTAssertEqual(matches.count, 1, "\(moment) has \(matches.count) suggestions")
        }
    }

    func testMomentsAreCappedAtFour() {
        // The plan's cap: this stays a journey, not a marketing channel.
        XCTAssertLessThanOrEqual(UnlockMoment.allCases.count, 4)
        XCTAssertEqual(UnlockSuggestionPolicy.suggestions.count, UnlockMoment.allCases.count)
    }

    func testEverySuggestionTargetsAFoldableCategory() {
        for suggestion in UnlockSuggestionPolicy.suggestions {
            guard let category = CapabilityCatalog.category(id: suggestion.categoryID) else {
                return XCTFail("\(suggestion.moment) points at a category that doesn't exist")
            }
            XCTAssertTrue(category.isFoldable,
                          "\(suggestion.moment) suggests \(category.id), which is never folded")
            XCTAssertFalse(suggestion.note.isEmpty)
        }
    }

    func testSuggestionIsRaisedOnceThenNeverAgain() {
        var state = SettingsJourneyState()
        let moment = UnlockMoment.firstPhotoCaptured
        guard let first = UnlockSuggestionPolicy.suggestion(for: moment, state: state) else {
            return XCTFail("the first occurrence should suggest")
        }
        state.deliveredMoments.insert(moment.rawValue)
        state.pendingMoments.insert(moment.rawValue)
        XCTAssertNil(UnlockSuggestionPolicy.suggestion(for: moment, state: state))
        // …and still nothing after the user dismisses it.
        state.pendingMoments.remove(moment.rawValue)
        state.dismissedMoments.insert(moment.rawValue)
        XCTAssertNil(UnlockSuggestionPolicy.suggestion(for: moment, state: state))
        XCTAssertEqual(first.categoryID, CapabilityCatalog.capture)
    }

    func testSuggestionStaysQuietWhenTheCategoryIsAlreadyVisible() {
        var state = SettingsJourneyState()
        state.unfold(CapabilityCatalog.capture)
        XCTAssertNil(UnlockSuggestionPolicy.suggestion(for: .firstPhotoCaptured, state: state))

        var showAll = SettingsJourneyState()
        showAll.showsEverything = true
        for moment in UnlockMoment.allCases {
            XCTAssertNil(UnlockSuggestionPolicy.suggestion(for: moment, state: showAll))
        }
    }

    func testUnfoldingClearsAPendingSuggestionForThatCategory() {
        var state = SettingsJourneyState()
        state.pendingMoments = [UnlockMoment.firstPhotoCaptured.rawValue,
                                UnlockMoment.highImpactActionConfirmed.rawValue]
        state.unfold(CapabilityCatalog.capture)
        XCTAssertNil(UnlockSuggestionPolicy.pendingSuggestion(
            forCategory: CapabilityCatalog.capture, state: state))
        // The unrelated category keeps its highlight.
        XCTAssertNotNil(UnlockSuggestionPolicy.pendingSuggestion(
            forCategory: CapabilityCatalog.tools, state: state))
    }

    // MARK: - Store round-trip

    @MainActor
    private func makeStore(_ name: String = #function) -> (SettingsJourneyStore, UserDefaults) {
        let suite = "SettingsJourneyTests.\(name)"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (SettingsJourneyStore(defaults: defaults), defaults)
    }

    @MainActor
    func testStoreMigratesOnceAndPersists() {
        let (store, defaults) = makeStore()
        store.migrateIfNeeded(signals: .init(hasPriorInstall: true))
        XCTAssertEqual(store.state.unfolded, CapabilityCatalog.foldableIDs)

        // A second call must not re-run against different signals.
        store.migrateIfNeeded(signals: .init(hasPriorInstall: false))
        XCTAssertEqual(store.state.unfolded, CapabilityCatalog.foldableIDs)

        // …and it survives a relaunch.
        let reloaded = SettingsJourneyStore(defaults: defaults)
        XCTAssertEqual(reloaded.state.unfolded, CapabilityCatalog.foldableIDs)
        XCTAssertTrue(reloaded.state.hasMigrated)
    }

    @MainActor
    func testStoreRecordsAMomentAtMostOnce() {
        let (store, defaults) = makeStore()
        store.migrateIfNeeded(signals: .init(hasPriorInstall: false))

        store.record(.firstPhotoCaptured)
        XCTAssertNotNil(store.pendingSuggestion(forCategory: CapabilityCatalog.capture))

        store.dismiss(.firstPhotoCaptured)
        XCTAssertNil(store.pendingSuggestion(forCategory: CapabilityCatalog.capture))

        // Dismissal persists across relaunch, and the moment never fires again.
        let reloaded = SettingsJourneyStore(defaults: defaults)
        reloaded.record(.firstPhotoCaptured)
        XCTAssertNil(reloaded.pendingSuggestion(forCategory: CapabilityCatalog.capture))
        XCTAssertTrue(reloaded.state.dismissedMoments.contains(UnlockMoment.firstPhotoCaptured.rawValue))
    }

    @MainActor
    func testStoreSpendsAMomentWhoseCategoryIsAlreadyVisible() {
        let (store, _) = makeStore()
        store.migrateIfNeeded(signals: .init(hasPriorInstall: true))
        store.record(.firstPhotoCaptured)
        XCTAssertTrue(store.state.deliveredMoments.contains(UnlockMoment.firstPhotoCaptured.rawValue))
        XCTAssertTrue(store.state.pendingMoments.isEmpty)
    }

    @MainActor
    func testStoreUnfoldIsPermanentAndUngated() {
        let (store, defaults) = makeStore()
        store.migrateIfNeeded(signals: .init(hasPriorInstall: false))
        store.unfold(CapabilityCatalog.tools)

        let reloaded = SettingsJourneyStore(defaults: defaults)
        XCTAssertTrue(reloaded.state.unfolded.contains(CapabilityCatalog.tools))
        guard let tools = CapabilityCatalog.category(id: CapabilityCatalog.tools) else {
            return XCTFail("missing category")
        }
        XCTAssertTrue(reloaded.state.isVisible(tools))
    }

    // MARK: - Spoken wording

    func testDiscoverCardSpeaksTitlePitchAndSuggestion() {
        XCTAssertEqual(
            OGDiscoverCard.spokenLabel(title: "Capture", pitch: "Record what you see",
                                       suggestion: "You took your first photo"),
            "Capture. Record what you see. You took your first photo"
        )
        XCTAssertEqual(
            OGDiscoverCard.spokenLabel(title: "Capture", pitch: "Record what you see", suggestion: nil),
            "Capture. Record what you see"
        )
    }

    func testModelRowSaysKeyStateInWords() {
        XCTAssertEqual(
            AIPersonalitySettingsScreen.spokenModelRow(
                name: "Claude Sonnet", provider: "Anthropic",
                badge: .init(label: "Key set", isReady: true), vision: true),
            "Claude Sonnet, Anthropic, vision enabled, Key set"
        )
        XCTAssertEqual(
            AIPersonalitySettingsScreen.spokenModelRow(
                name: "Local", provider: "On-device",
                badge: .init(label: "On-device", isReady: true), vision: false),
            "Local, On-device, On-device"
        )
        XCTAssertEqual(
            AIPersonalitySettingsScreen.spokenModelRow(
                name: "ChatGPT", provider: "ChatGPT (Subscription)",
                badge: .init(label: "Not signed in", isReady: false), vision: false),
            "ChatGPT, ChatGPT (Subscription), needs setup: Not signed in"
        )
    }

    /// Auth is key OR account OR on-device; the badge must never warn about a provider that
    /// cannot take the missing thing.
    func testModelAuthBadgeTruthTable() {
        func badge(_ p: LLMProvider, key: Bool = false, claude: Bool = false,
                   chatgpt: Bool = false, google: Bool = false)
            -> AIPersonalitySettingsScreen.ModelAuthBadge {
            AIPersonalitySettingsScreen.modelAuthBadge(
                provider: p, hasKey: key, claudeConnected: claude,
                chatgptConnected: chatgpt, googleConnected: google)
        }
        // On-device providers are always ready and never mention keys.
        XCTAssertEqual(badge(.local), .init(label: "On-device", isReady: true))
        XCTAssertEqual(badge(.appleOnDevice), .init(label: "On-device", isReady: true))
        // Subscription providers report the account, not a key.
        XCTAssertEqual(badge(.chatgpt, chatgpt: true),
                       .init(label: "ChatGPT account connected", isReady: true))
        XCTAssertEqual(badge(.chatgpt), .init(label: "Not signed in", isReady: false))
        XCTAssertEqual(badge(.geminiVertex, google: true),
                       .init(label: "Google account connected", isReady: true))
        XCTAssertEqual(badge(.geminiVertex), .init(label: "Not signed in", isReady: false))
        // Anthropic: explicit key wins, account suffices, neither warns.
        XCTAssertEqual(badge(.anthropic, key: true, claude: true),
                       .init(label: "Key set", isReady: true))
        XCTAssertEqual(badge(.anthropic, claude: true),
                       .init(label: "Claude account connected", isReady: true))
        XCTAssertEqual(badge(.anthropic), .init(label: "No account or key", isReady: false))
        // Custom servers often need no key; absence is not a warning.
        XCTAssertEqual(badge(.custom), .init(label: "Key optional", isReady: true))
        XCTAssertEqual(badge(.custom, key: true), .init(label: "Key set", isReady: true))
        // Plain key providers keep the original behaviour.
        XCTAssertEqual(badge(.openai), .init(label: "No API key", isReady: false))
        XCTAssertEqual(badge(.openai, key: true), .init(label: "Key set", isReady: true))
        // A connected account for a different provider changes nothing.
        XCTAssertEqual(badge(.openai, claude: true, chatgpt: true, google: true),
                       .init(label: "No API key", isReady: false))
    }
}
