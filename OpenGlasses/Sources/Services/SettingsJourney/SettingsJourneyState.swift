import Foundation

/// What the hub remembers about a user's journey through the settings surface
/// (Plan DE P1).
///
/// Folded is never locked: every value here only decides whether a category is
/// rendered as a full row or as a Discover card. Nothing in this type gates a
/// capability, changes a setting, or affects what the assistant can do by voice.
struct SettingsJourneyState: Equatable, Codable, Sendable {
    /// Category ids the user has unfolded. Permanent — a category never folds
    /// back on its own.
    var unfolded: Set<String> = []
    /// Unlock moments already offered. The at-most-once ledger: a moment in here
    /// is never suggested again, whatever the user did with it.
    var deliveredMoments: Set<String> = []
    /// Moments the user waved away. Kept separately from `deliveredMoments` so
    /// the reason a moment is spent stays legible.
    var dismissedMoments: Set<String> = []
    /// Moments currently highlighting a Discover card in the hub.
    var pendingMoments: Set<String> = []
    /// "Show everything" — one switch, the whole surface, permanently.
    var showsEverything: Bool = false
    /// Set once the migration has run, so it never runs twice.
    var hasMigrated: Bool = false

    /// Whether the hub renders `category` as a row rather than a Discover card.
    ///
    /// An Everyday category is visible unconditionally — there is no branch here
    /// that can hide one, which is what pins the assistive surface.
    func isVisible(_ category: CapabilityCategory) -> Bool {
        guard category.isFoldable else { return true }
        return showsEverything || unfolded.contains(category.id)
    }

    /// The rows the hub draws, in catalog order.
    func visibleCategories(
        in catalog: [CapabilityCategory] = CapabilityCatalog.all,
        simpleMode: Bool = false
    ) -> [CapabilityCategory] {
        catalog.filter { isVisible($0) && !(simpleMode && $0.hiddenInSimpleMode) }
    }

    /// The Discover cards the hub draws, grouped-order by tier then catalog order.
    ///
    /// Simple Mode hides the owner-configuration surface outright, so a category
    /// it hides is not pitched either — offering a card that leads nowhere would
    /// be worse than saying nothing.
    func discoverCards(
        in catalog: [CapabilityCategory] = CapabilityCatalog.all,
        simpleMode: Bool = false
    ) -> [CapabilityCategory] {
        catalog
            .filter { !isVisible($0) && !(simpleMode && $0.hiddenInSimpleMode) }
            .sorted { lhs, rhs in
                let l = lhs.placement.foldableTier?.order ?? 0
                let r = rhs.placement.foldableTier?.order ?? 0
                if l != r { return l < r }
                return index(of: lhs, in: catalog) < index(of: rhs, in: catalog)
            }
    }

    private func index(of category: CapabilityCategory, in catalog: [CapabilityCategory]) -> Int {
        catalog.firstIndex(of: category) ?? 0
    }

    /// One tap, permanently. Returns whether anything changed, so a caller can
    /// skip an animation it doesn't need.
    @discardableResult
    mutating func unfold(_ categoryID: String) -> Bool {
        guard !unfolded.contains(categoryID) else { return false }
        unfolded.insert(categoryID)
        // A card that has been opened has nothing left to suggest.
        for moment in UnlockSuggestionPolicy.moments(targeting: categoryID) {
            pendingMoments.remove(moment.rawValue)
        }
        return true
    }
}

// MARK: - Migration

/// Turning a pre-journey install into a journey state.
///
/// The one failure this plan is not allowed to have is a setting that was
/// visible yesterday disappearing on update — so the migration's bias is
/// entirely towards unfolding, and the fresh-install case is the only one that
/// produces a folded hub.
enum SettingsJourneyMigration {
    /// What the caller measured about this device. Pure input: the adapter that
    /// reads `Config` lives in `SettingsJourneySignals`.
    struct Signals: Equatable, Sendable {
        /// The app has been used before this build — onboarding was completed,
        /// or credentials arrived from an even older pre-onboarding version.
        var hasPriorInstall: Bool
        /// Categories holding configuration the user must have set themselves.
        var configuredCategoryIDs: Set<String>

        init(hasPriorInstall: Bool = false, configuredCategoryIDs: Set<String> = []) {
            self.hasPriorInstall = hasPriorInstall
            self.configuredCategoryIDs = configuredCategoryIDs
        }
    }

    /// The state a device starts the journey in.
    ///
    /// - A prior install sees everything, exactly as it did yesterday.
    /// - A fresh install sees Everyday only.
    /// - Anything configured is visible either way, which is the belt to the
    ///   prior-install brace: even if the marker were somehow missed, a category
    ///   the user has touched cannot be folded away from them.
    static func initialState(
        catalog: [CapabilityCategory] = CapabilityCatalog.all,
        signals: Signals
    ) -> SettingsJourneyState {
        var state = SettingsJourneyState()
        state.hasMigrated = true

        let foldable = Set(catalog.filter(\.isFoldable).map(\.id))
        if signals.hasPriorInstall {
            state.unfolded = foldable
        } else {
            state.unfolded = foldable.intersection(signals.configuredCategoryIDs)
        }
        return state
    }
}

// MARK: - Unlock moments

/// The fixed, small set of moments at which the app may point at the next
/// capability. Capped deliberately: this is a journey, not a marketing channel.
enum UnlockMoment: String, CaseIterable, Codable, Sendable {
    /// The first photo lands in the album — recording and streaming are next door.
    case firstPhotoCaptured
    /// Glasses with an in-lens display connect.
    case displayGlassesConnected
    /// A live broadcast starts — chat read-aloud is the thing they don't know exists.
    case broadcastStarted
    /// The assistant asks permission to do something consequential for the first
    /// time. That prompt is the moment a user learns the assistant *acts*; the
    /// tool surface is where they decide what it may act on.
    case highImpactActionConfirmed
}

/// What a moment offers: a category, and the sentence that goes on its card.
struct UnlockSuggestion: Equatable, Sendable {
    let moment: UnlockMoment
    let categoryID: String
    let note: String
}

/// Event in, at-most-once suggestion out. Pure — the store holds the state.
enum UnlockSuggestionPolicy {
    /// Exactly one suggestion per moment, and never more moments than the plan's
    /// cap of four.
    static let suggestions: [UnlockSuggestion] = [
        UnlockSuggestion(
            moment: .firstPhotoCaptured,
            categoryID: CapabilityCatalog.capture,
            note: "You took your first photo — video and live streaming live here too."
        ),
        UnlockSuggestion(
            moment: .displayGlassesConnected,
            categoryID: CapabilityCatalog.display,
            note: "Your glasses have a display. Here's what can be drawn on it."
        ),
        UnlockSuggestion(
            moment: .broadcastStarted,
            categoryID: CapabilityCatalog.capture,
            note: "You're live. Your glasses can read the chat back to you."
        ),
        UnlockSuggestion(
            moment: .highImpactActionConfirmed,
            categoryID: CapabilityCatalog.tools,
            note: "The assistant just asked before acting. Choose what it may do."
        ),
    ]

    static func suggestion(for moment: UnlockMoment) -> UnlockSuggestion? {
        suggestions.first { $0.moment == moment }
    }

    static func moments(targeting categoryID: String) -> [UnlockMoment] {
        suggestions.filter { $0.categoryID == categoryID }.map(\.moment)
    }

    /// The suggestion to raise for `moment`, or nil if it must stay quiet.
    ///
    /// Quiet when: the moment has already been offered (at most once, ever), the
    /// category is already on screen, or the category isn't one that folds.
    static func suggestion(
        for moment: UnlockMoment,
        state: SettingsJourneyState,
        catalog: [CapabilityCategory] = CapabilityCatalog.all
    ) -> UnlockSuggestion? {
        guard let suggestion = suggestion(for: moment) else { return nil }
        guard !state.deliveredMoments.contains(moment.rawValue) else { return nil }
        guard let category = catalog.first(where: { $0.id == suggestion.categoryID }),
              category.isFoldable,
              !state.isVisible(category)
        else { return nil }
        return suggestion
    }

    /// The suggestion currently highlighting `categoryID`, if any.
    static func pendingSuggestion(
        forCategory categoryID: String,
        state: SettingsJourneyState
    ) -> UnlockSuggestion? {
        suggestions.first {
            $0.categoryID == categoryID && state.pendingMoments.contains($0.moment.rawValue)
        }
    }
}
