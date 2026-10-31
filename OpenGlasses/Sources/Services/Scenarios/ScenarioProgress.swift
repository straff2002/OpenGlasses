import Combine
import Foundation

/// What this person has done with the scenarios, on this phone only (Plan KH P1). Ids from the
/// app's own catalogue and nothing they said, so there is no content here to send anywhere: the
/// app has no analytics by design, and the only way this leaves the phone is the support report's
/// one-line count.
struct ScenarioProgress: Codable, Equatable, Sendable {
    var tried: Set<String> = []
    var dismissed: Set<String> = []
    var chosenIntent: ScenarioIntent?
    /// The scenario the Ready page asked to run, until the Voice tab takes it.
    var pendingFirstTurn: String?

    var triedOrDismissed: Set<String> { tried.union(dismissed) }

    static let empty = ScenarioProgress()
}

/// The record's home. `UserDefaults`, as `MyDayDismissalStore` is: one small record, read on the
/// main actor, and losing it costs a person three cards.
///
/// Registered in `DataStoreRegistry` as `scenarioProgress`. It is about the wearer and names nobody
/// else, so a subject erasure has nothing to find in it. `deleteAll()` is what clears it. There is
/// deliberately no button for it: the shelf ends for good, and a reset would bring the cards back.
@MainActor
final class ScenarioProgressStore: ObservableObject {
    static let shared = ScenarioProgressStore()

    @Published private(set) var progress: ScenarioProgress

    /// Whether the Voice tab's one chance to start on the cards has passed, for this launch: it
    /// opened there, the wearer moved the panel, or a turn began. In memory on purpose.
    private(set) var shelfOpeningSettled = false

    private let defaults: UserDefaults
    private static let key = "scenarioProgress"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode(ScenarioProgress.self, from: data) {
            progress = stored
        } else {
            progress = .empty
        }
    }

    func markTried(_ id: String) {
        update { $0.tried.insert(id) }
    }

    func dismiss(_ id: String) {
        update { $0.dismissed.insert(id) }
    }

    func choose(_ intent: ScenarioIntent) {
        update { $0.chosenIntent = intent }
    }

    func setPendingFirstTurn(_ id: String?) {
        update { $0.pendingFirstTurn = id }
    }

    /// Hands over the pending first turn and clears it, in one step and on disk before anything
    /// runs. That is what stops a re-appear, a tab change or a relaunch firing it twice.
    func takePendingFirstTurn() -> String? {
        guard let id = progress.pendingFirstTurn else { return nil }
        update { $0.pendingFirstTurn = nil }
        return id
    }

    func settleShelfOpening() {
        shelfOpeningSettled = true
    }

    func deleteAll() {
        defaults.removeObject(forKey: Self.key)
        progress = .empty
    }

    private func update(_ change: (inout ScenarioProgress) -> Void) {
        var next = progress
        change(&next)
        guard next != progress else { return }
        progress = next
        guard let data = try? JSONEncoder().encode(next) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
