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
    /// The Voice tab's "Things to try" card was closed with its X, for good.
    var introCardDismissed = false
    /// How many launches have shown that card (`ScenarioIntroCard`), this one included.
    var introCardShownLaunches = 0

    var triedOrDismissed: Set<String> { tried.union(dismissed) }

    static let empty = ScenarioProgress()
}

extension ScenarioProgress {
    private enum CodingKeys: String, CodingKey {
        case tried, dismissed, chosenIntent, pendingFirstTurn, introCardDismissed, introCardShownLaunches
    }

    /// Spelled out because a synthesized decoder demands every key, defaults or not, and the store
    /// treats a record it cannot read as empty. A missing field must stay a default: failing here
    /// would hand back cards the person tried or dismissed under an earlier build. In an extension,
    /// so the memberwise initialiser stays.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tried = try container.decodeIfPresent(Set<String>.self, forKey: .tried) ?? []
        dismissed = try container.decodeIfPresent(Set<String>.self, forKey: .dismissed) ?? []
        chosenIntent = try container.decodeIfPresent(ScenarioIntent.self, forKey: .chosenIntent)
        pendingFirstTurn = try container.decodeIfPresent(String.self, forKey: .pendingFirstTurn)
        introCardDismissed = try container.decodeIfPresent(Bool.self, forKey: .introCardDismissed) ?? false
        introCardShownLaunches = try container.decodeIfPresent(Int.self, forKey: .introCardShownLaunches) ?? 0
    }
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

    /// Whether this launch has already been counted against the intro card. In memory on purpose:
    /// a new process is a new launch.
    private(set) var introCardCountedThisLaunch = false

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

    /// Plan KH: the X on the Voice tab's card. There is no way back, on purpose (Decision 3).
    func dismissIntroCard() {
        update { $0.introCardDismissed = true }
    }

    /// Counts this launch against the intro card, once per process. The view calls it only while
    /// the card is really on screen, so a launch that never showed the card costs nothing.
    func noteIntroCardShown() {
        guard !introCardCountedThisLaunch else { return }
        introCardCountedThisLaunch = true
        update { $0.introCardShownLaunches += 1 }
    }

    /// What a tap on a scenario does now, recording it as tried only if its turn will really run.
    func begin(_ entry: ScenarioEntry, acceptsTurn: Bool) -> ScenarioCardTap {
        let tap = ScenarioCardTap.resolve(entry, acceptsTurn: acceptsTurn)
        if tap == .run { markTried(entry.id) }
        return tap
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
