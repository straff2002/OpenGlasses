import Foundation
import Combine

/// What the rest of the app may know about Assisting (Plan KW §2): whether it is the owner's, the
/// one Home card, and whether a card exists. Nothing else.
///
/// The hub, Home and Things to Try read this, never `AssistingService` or the store:
/// `AssistingIsolationTests` holds that only Assisting, the app's wiring and the privacy walks name
/// those, so a screen that only needs to know whether to draw a row can't reach a handover.
/// `AssistingService` is the one writer.
@MainActor
final class AssistingPresenceFeed: ObservableObject {
    static let shared = AssistingPresenceFeed()

    @Published private(set) var presence: AssistingPresence = .absent
    /// This phone's owner has made an expert card.
    @Published private(set) var hasCard = false

    init() {}

    func publish(_ presence: AssistingPresence, hasCard: Bool) {
        if presence != self.presence { self.presence = presence }
        if hasCard != self.hasCard { self.hasCard = hasCard }
    }
}
