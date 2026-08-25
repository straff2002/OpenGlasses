import Foundation

/// Persistence and event intake for the settings journey (Plan DE).
///
/// Every decision lives in the pure types next door; this holds the state, saves
/// it, and hops event recording onto the main actor. Injectable `UserDefaults`
/// so the suite exercises a real round-trip without touching the app's domain.
@MainActor
final class SettingsJourneyStore: ObservableObject {
    static let shared = SettingsJourneyStore()

    private static let storageKey = "settingsJourneyState"

    @Published private(set) var state: SettingsJourneyState

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.state = Self.load(from: defaults) ?? SettingsJourneyState()
    }

    // MARK: - Migration

    /// Establish the starting state for this device, once.
    ///
    /// Must run at launch, *before* onboarding: a user installing this build for
    /// the first time has not completed onboarding yet, which is exactly what
    /// distinguishes them from the upgrader who did so on a previous version.
    /// The signals are read lazily so a device that has already migrated does no
    /// Keychain work at all.
    func migrateIfNeeded(signals: @autoclosure () -> SettingsJourneyMigration.Signals) {
        guard !state.hasMigrated else { return }
        state = SettingsJourneyMigration.initialState(signals: signals())
        save()
    }

    // MARK: - Journey actions

    /// One tap, permanent, no gate of any kind.
    func unfold(_ categoryID: String) {
        guard state.unfold(categoryID) else { return }
        save()
    }

    func setShowsEverything(_ on: Bool) {
        guard state.showsEverything != on else { return }
        state.showsEverything = on
        if on {
            // The switch reveals; turning it back off returns to whatever the
            // user had explicitly unfolded, rather than stranding them.
            state.pendingMoments.removeAll()
        }
        save()
    }

    // MARK: - Unlock moments

    /// Record that a moment happened. Raises a suggestion only if the policy
    /// says it may — at most once ever, and never for a category already shown.
    func record(_ moment: UnlockMoment) {
        guard let suggestion = UnlockSuggestionPolicy.suggestion(for: moment, state: state) else {
            // Still spend the moment when its category is already visible, so a
            // later refold can't resurrect it.
            if !state.deliveredMoments.contains(moment.rawValue),
               let target = UnlockSuggestionPolicy.suggestion(for: moment),
               let category = CapabilityCatalog.category(id: target.categoryID),
               state.isVisible(category) {
                state.deliveredMoments.insert(moment.rawValue)
                save()
            }
            return
        }
        state.deliveredMoments.insert(suggestion.moment.rawValue)
        state.pendingMoments.insert(suggestion.moment.rawValue)
        save()
    }

    /// The user waved the highlight away. Dismissal persists.
    func dismiss(_ moment: UnlockMoment) {
        var changed = state.pendingMoments.remove(moment.rawValue) != nil
        changed = state.dismissedMoments.insert(moment.rawValue).inserted || changed
        changed = state.deliveredMoments.insert(moment.rawValue).inserted || changed
        guard changed else { return }
        save()
    }

    func pendingSuggestion(forCategory categoryID: String) -> UnlockSuggestion? {
        UnlockSuggestionPolicy.pendingSuggestion(forCategory: categoryID, state: state)
    }

    /// Call site sugar for services that aren't on the main actor. Fire and
    /// forget: a moment that arrives during teardown is simply not offered.
    nonisolated static func note(_ moment: UnlockMoment) {
        Task { @MainActor in shared.record(moment) }
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func load(from defaults: UserDefaults) -> SettingsJourneyState? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(SettingsJourneyState.self, from: data)
    }
}
