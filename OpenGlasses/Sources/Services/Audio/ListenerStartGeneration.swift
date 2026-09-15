import Foundation

/// Which start the wake-word listener is currently obeying, and whether anybody still wants one.
///
/// # The failure this exists to stop
///
/// Starting the listener is not instant: it awaits microphone and speech authorization, then an
/// audio-session activation, then sleeps between retries when CoreAudio reports the session was
/// lost mid-start. A `stopListening()` arriving inside that window used to be lost — it cleared
/// the flag and tore down an engine that did not exist yet, and the start still climbing then
/// finished and declared a listener. The microphone came back on after the wearer had turned it
/// off, and nothing in the service noticed.
///
/// # The rule
///
/// A start takes a token when it begins and re-presents it after every suspension. A stop
/// invalidates every token outstanding **and withdraws intent**; a pause invalidates them but
/// keeps intent, because a route change or a handoff to another consumer is not the wearer
/// changing their mind. A start whose token no longer matches has been superseded: it must not
/// claim the listener, and it must release the graph it built on the way out.
///
/// Same shape as the camera's `StreamStartGeneration`, one axis over — the extra axis is intent,
/// which is what makes "an explicit stop is not undone by a route change" expressible at all.
///
/// Pure value type: no engine, no session, no clock.
struct ListenerStartGeneration: Equatable {

    /// Handed to a start when it begins, re-presented at each checkpoint. Opaque on purpose.
    struct Token: Equatable {
        fileprivate let generation: Int
    }

    /// Whether a start that has just resumed may carry on.
    enum Checkpoint: Equatable {
        /// Nothing overtook this start.
        case proceed
        /// A stop or a pause landed while this start was suspended. Release whatever it built and
        /// stay stopped.
        case abandon
    }

    /// Bumped by every stop and every pause. A token carries the value it was issued under, so
    /// comparing the two is the whole test — no flags to keep in sync, and any number of starts
    /// can be outstanding.
    private var generation = 0

    /// Whether anybody wants listening. Set by an explicit request, withdrawn only by an explicit
    /// stop. Automatic restarts read it; they never set it.
    private(set) var wantsListening = false

    init() {}

    /// Record that a caller asked for listening. This is the only thing that grants intent.
    mutating func recordIntent() { wantsListening = true }

    /// Begin a start. Keep the token; every checkpoint needs it.
    mutating func beginStart() -> Token { Token(generation: generation) }

    /// Re-check after a suspension. `.abandon` means a stop or pause won the race.
    func checkpoint(_ token: Token) -> Checkpoint {
        token.generation == generation && wantsListening ? .proceed : .abandon
    }

    /// Record an explicit stop: every start in flight becomes stale and intent is withdrawn.
    mutating func recordStop() {
        generation += 1
        wantsListening = false
    }

    /// Record a pause that keeps the wearer's intent — a shared-engine handoff, an interruption,
    /// a route flap, a wake word that just fired. Starts in flight still become stale, because the
    /// graph they were building is no longer the graph that exists.
    mutating func recordPause() {
        generation += 1
    }
}
