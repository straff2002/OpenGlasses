import Foundation

/// When a deferred result may be pushed into a live voice session.
///
/// Device-traced: the deferred-result path injected the moment the result existed. On the
/// Realtime wire that is `conversation.item.create` + `response.create` sent blind, and the API
/// has exactly **one** active-response slot — so an injection that lands while the model is still
/// speaking is either refused (`conversation_already_has_active_response`) or collides with the
/// barge-in machinery. Either way the wearer gets dead air where the answer should have been, and
/// the result is simply lost: nothing retries it. Gemini has the same collision in different
/// clothes — a `clientContent` turn arriving mid-utterance cuts the model off mid-sentence.
///
/// It is also wrong to wait forever. A wearer who is talking continuously would never get the
/// answer they asked for, and a stuck speaking flag would swallow it silently — the exact class
/// of failure this is meant to end. So the wait is bounded, and past the bound we deliver into
/// the collision rather than drop the result: a clipped answer is recoverable, a vanished one is
/// not.
///
/// Pure so the table is exercised without a socket, a model or a clock.
enum LiveInjectionAdmission {

    enum Decision: Equatable {
        /// The wire is quiet — send it.
        case injectNow
        /// Someone is talking; look again after this long.
        case retry(after: TimeInterval)
        /// The bounded wait is spent. Send anyway: losing the result is the worse failure.
        case injectAnyway
    }

    /// How often to re-check. Half a second is below the gap between conversational turns, so a
    /// result lands in the first natural pause rather than the one after it.
    static let pollInterval: TimeInterval = 0.5

    /// The longest an answer may be held back waiting for quiet.
    static let maxWait: TimeInterval = 20

    /// The table. `waited` is wall-clock spent waiting so far.
    static func decide(modelSpeaking: Bool, userSpeaking: Bool, waited: TimeInterval) -> Decision {
        decide(busy: modelSpeaking || userSpeaking, waited: waited)
    }

    static func decide(busy: Bool, waited: TimeInterval) -> Decision {
        guard busy else { return .injectNow }
        return waited >= maxWait ? .injectAnyway : .retry(after: pollInterval)
    }

    /// What a completed wait did, so the caller can log it honestly.
    enum Outcome: Equatable {
        /// The session went quiet on its own after this long.
        case clear(waited: TimeInterval)
        /// The bound was reached and the injection goes out over the top.
        case timedOut(waited: TimeInterval)

        var waited: TimeInterval {
            switch self {
            case .clear(let waited), .timedOut(let waited): return waited
            }
        }

        var deferred: Bool { waited > 0 }

        /// Whether the injection is going out over a busy session because the bound ran out.
        var isTimedOut: Bool {
            if case .timedOut = self { return true }
            return false
        }
    }

    /// Poll until the session is clear or the bound is spent. The clock and the sleep are
    /// injected so a test drives the whole loop in no time at all — the alternative is a unit
    /// test that really waits twenty seconds, which is how this kind of loop stops being tested.
    @MainActor
    static func waitUntilClear(
        isBusy: () -> Bool,
        sleep: (TimeInterval) async -> Void,
        now: () -> Date
    ) async -> Outcome {
        let start = now()
        while true {
            let waited = now().timeIntervalSince(start)
            switch decide(busy: isBusy(), waited: waited) {
            case .injectNow:
                return .clear(waited: waited)
            case .injectAnyway:
                return .timedOut(waited: waited)
            case .retry(let after):
                await sleep(after)
            }
        }
    }
}
