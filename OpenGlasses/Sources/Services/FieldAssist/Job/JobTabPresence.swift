import Foundation

/// Whether the root tab bar carries a Job tab, and what happens to the selection when it stops.
///
/// Three facts decide it and all three matter:
///
///  1. **An open job outranks everything.** A licence that lapses in the middle of a visit must not
///     take the job away with it — the technician still has to close it, read it back and send it.
///     So an un-ended session shows the tab whatever the entitlement says, which is the same rule
///     the tools already follow (a lapse refuses *new* actions and leaves an open session alone).
///  2. **"Not entitled" and "not asked yet" are different answers.** `StoreKitService` sets
///     `hasCheckedEntitlements` only after it has recorded verified evidence, and until then a
///     false `fieldAssistUnlocked` means *unknown*, not *no*. Showing the tab on a guess would put
///     a fifth tab in front of someone who has not bought anything; hiding it permanently on the
///     same guess would take it away from someone who has. So an unresolved entitlement is
///     `.undetermined` — drawn exactly like `.hidden`, and allowed to become `.shown` a moment
///     later without anything having flickered, because nothing was ever drawn.
///  3. **A tab that goes away must not take the wearer somewhere they did not ask to be**, so the
///     selection falls back to Voice and only ever from `.job`.
///
/// Pure, so the whole matrix is a table test rather than a screen recording.
enum JobTabPresence {

    /// Everything the decision depends on.
    struct Inputs: Equatable {
        /// The wearer's own Field Assist switch (`Config.fieldAssistEnabled`).
        var featureEnabled: Bool = false
        /// Whether the entitlement evaluator grants the feature right now
        /// (`Config.fieldAssistUnlocked`).
        var entitled: Bool = false
        /// Whether the store entitlement check has run at all this launch
        /// (`StoreKitService.hasCheckedEntitlements`). A signed organisation licence answers
        /// synchronously and so arrives as `entitled` without ever needing this.
        var entitlementChecked: Bool = false
        /// A field session that has not ended — running *or* paused. A paused job is still the job
        /// (Plan FO P1), and launch-restore pauses every recovered session on purpose.
        var hasOpenJob: Bool = false
    }

    enum Decision: Equatable {
        /// Draw the tab.
        case shown
        /// Do not draw it, and nothing is expected to change that.
        case hidden
        /// Do not draw it *yet* — the entitlement has not been resolved. Same pixels as `.hidden`;
        /// a separate case so the rule is stated rather than inferred from a false boolean.
        case undetermined

        var showsTab: Bool { self == .shown }
    }

    static func decide(_ inputs: Inputs) -> Decision {
        // An open job keeps its tab, whatever happened to the licence while it was running.
        if inputs.hasOpenJob { return .shown }
        // The wearer's own switch is a definite answer and needs no store round trip.
        guard inputs.featureEnabled else { return .hidden }
        if inputs.entitled { return .shown }
        return inputs.entitlementChecked ? .hidden : .undetermined
    }

    /// The bar, in order, for a decision.
    static func tabs(for decision: Decision) -> [MainTab] {
        MainTab.visibleOrder(showingJob: decision.showsTab)
    }

    /// Where the selection ends up once the bar is what `decision` says it is.
    ///
    /// Only `.job` ever moves. A tab bar that reshuffles the wearer's place in the app because an
    /// entitlement resolved in the background would be worse than the missing tab.
    static func selection(_ selected: MainTab, after decision: Decision) -> MainTab {
        guard selected == .job, !decision.showsTab else { return selected }
        return .voice
    }
}
