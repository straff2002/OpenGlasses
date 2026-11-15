import Foundation

/// When to tell the wearer, once, that the phone's mic hears better than the glasses in a loud room.
///
/// A hint, not a route change: the default route stays the glasses, and switching is the wearer's
/// choice in Settings. Shown, never spoken — a sentence about the mic said over the very noise
/// that defeated it would only add to it.
///
/// A small ledger plus a decision, pure, so "at most once per process" is tested rather than hoped.
struct MicRouteHintPolicy: Equatable, Sendable {

    /// How a dictation turn ended, as far as the hint cares.
    enum TurnOutcome: Equatable, Sendable {
        /// The recogniser delivered words.
        case recognised
        /// The wearer opened the turn (the wake word or a tap) and nothing was recognised — the
        /// case a loud room produces.
        case noSpeech
        /// The mic reopened after a reply and the wearer said nothing — the ordinary end of a
        /// conversation, not a sign of noise. Never hints.
        case followUpUnanswered
    }

    /// The sentence the hint shows. Names the real place the switch lives: the Microphone picker
    /// on the Hardware & Privacy screen under Devices & Privacy.
    static let message = String(localized: "The phone's mic hears better in a loud room — choose iPhone Mic in Settings › Devices & Privacy › Hardware & Privacy.")

    private(set) var hasHinted = false

    init() {}

    /// True at most once until `reset()`: on the glasses mic, after a turn the wearer opened ended
    /// with nothing recognised, in Direct mode. Never in the Realtime modes or Gemini Live, whose
    /// audio does not go through dictation at all.
    mutating func shouldHint(route: MicRoute, outcome: TurnOutcome, mode: AppMode) -> Bool {
        guard !hasHinted else { return false }
        guard route == .glasses, outcome == .noSpeech, mode == .direct else { return false }
        hasHinted = true
        return true
    }

    mutating func reset() {
        hasHinted = false
    }
}
