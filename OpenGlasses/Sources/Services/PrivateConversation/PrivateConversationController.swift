import Foundation

/// The one owner of the private conversation's state and transcript (Plan LU §1, P1).
///
/// `AppState` holds one instance (`appState.privateConversation`) and is its only caller, through
/// `beginPrivate(entry:)` and `endPrivate(reason:)`; the phone and watch surfaces observe it, the
/// way they observe `GuidedJobFlow`. Headless by construction — a clock seam and nothing else — so
/// starting, the refusals, every end and the transcript are testable with no `AppState`.
///
/// It also keeps `PrivateConversationGate` in step with its state, which is how the services that
/// cannot see `AppState` know a private conversation is open. Nothing else writes the gate.
@MainActor
final class PrivateConversationController: ObservableObject {

    /// Inactive, or the open private conversation. The id is never written anywhere.
    @Published private(set) var state: PrivateConversationState = .inactive

    /// The private conversation's turns. In memory only; emptied at every end.
    @Published private(set) var transcript = PrivateTranscript()

    private let clock: () -> Date

    init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    var isActive: Bool { state.isActive }

    /// Time since the last private turn, or since the start before the first one. Zero with no
    /// private conversation open.
    var quietFor: TimeInterval {
        guard let since = transcript.lastTurnAt ?? state.startedAt else { return 0 }
        return max(0, clock().timeIntervalSince(since))
    }

    /// Start a private conversation, or say why not. Already private: nothing changes, no refusal.
    ///
    /// - Returns: nil when one is open afterwards; the refusal when none could start.
    @discardableResult
    func begin(entry: PrivateEntry, conditions: PrivateStartConditions) -> PrivateStartRefusal? {
        if let refusal = conditions.refusal {
            PrivacyLog.privateConversation(.refused(refusal))
            return refusal
        }
        guard !state.isActive else { return nil }
        transcript.clear()
        state = .active(id: UUID(), startedAt: clock(), entry: entry)
        PrivateConversationGate.setActive(true)
        PrivacyLog.privateConversation(.started(entry))
        return nil
    }

    /// End the private conversation: its transcript is emptied and it cannot be reopened.
    ///
    /// - Returns: whether one was open.
    @discardableResult
    func end(_ reason: PrivateEndReason) -> Bool {
        guard state.isActive else { return false }
        transcript.clear()
        state = .inactive
        PrivateConversationGate.setActive(false)
        PrivacyLog.privateConversation(.ended(reason))
        return true
    }

    /// Something happened that might end the private conversation (`PrivateEndPolicy`).
    ///
    /// - Returns: why it ended, or nil when it stays open (or none was open).
    @discardableResult
    func handle(_ event: PrivateEndEvent) -> PrivateEndReason? {
        guard case .end(let reason) = PrivateEndPolicy.decide(state, event) else { return nil }
        return end(reason) ? reason : nil
    }

    /// Add one turn to the private transcript. Ignored with no private conversation open, so a
    /// caller never has to check first.
    func append(role: String, content: String) {
        guard state.isActive, !content.isEmpty else { return }
        transcript.append(role: role, content: content, at: clock())
    }
}
