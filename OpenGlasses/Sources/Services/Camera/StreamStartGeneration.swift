import Foundation

/// Which start a video stream is currently obeying, so that a stop issued *during* a cold start
/// wins over the start it interrupted.
///
/// # The failure this exists to stop
///
/// The glasses camera cold-starts in seconds — a session, then a stream, then the first frame —
/// and device-traced 2026-08-23 that was up to 20 s. A stop arriving inside that window used to be
/// lost: the stop guarded on "is a stream running", nothing was running yet, so it returned having
/// done nothing, and the start that was still climbing then finished and declared the stream up.
/// A cancelled stream came back to life, held the process-wide camera capability, and kept the
/// glasses LED on with nothing consuming the frames. Only programmatic stops reach that window —
/// the camera button is disabled while a start is in flight — so the shapes it took were
/// backgrounding with no glasses attached, and a live session ending on top of its own warm-up.
///
/// # The rule
///
/// A start takes a token when it begins and presents it when it finishes. A stop invalidates every
/// token outstanding. A start whose token no longer matches has been superseded: it must **not**
/// claim the stream, and it must release whatever its cold start acquired on the way out. That is
/// what makes a late start a no-op rather than a resurrection.
///
/// Pure value type — no camera, no clock, no I/O. The owner applies the outcome, which is why the
/// same rule can sit in both the backend (which owns the device stream) and the coordinator
/// (which owns the published state and the claims) without either one guessing at the other.
struct StreamStartGeneration: Equatable {

    /// Handed to a start when it begins, presented back when it finishes. Opaque on purpose:
    /// the only question a caller may ask of it is the one `finish(_:)` answers.
    struct Token: Equatable {
        fileprivate let generation: Int
    }

    /// What a finishing start should do about the stream it just brought up.
    enum Completion: Equatable {
        /// Nothing overtook this start. Claim the stream.
        case commit
        /// A stop landed while this start was warming up. Release what the cold start acquired
        /// and stay stopped.
        case abandon
    }

    /// Bumped by every stop. A token carries the value it was issued under, so comparing the two
    /// is the whole test — no flags to keep in sync, and any number of starts can be outstanding.
    private var generation = 0

    /// Whether a start is currently in flight. Reported by `recordStop()` so an owner can tell a
    /// stop that cancelled a cold start from one that stopped a running stream or did nothing.
    private(set) var isStartPending = false

    init() {}

    /// Begin a start. Keep the token; `finish(_:)` needs it.
    mutating func beginStart() -> Token {
        isStartPending = true
        return Token(generation: generation)
    }

    /// Finish a start. `.abandon` means a stop won the race while this start was warming up.
    mutating func finish(_ token: Token) -> Completion {
        guard token.generation == generation else { return .abandon }
        isStartPending = false
        return .commit
    }

    /// Record a stop. Every start in flight becomes stale.
    ///
    /// - Returns: whether this stop cancelled a cold start that was still climbing. A caller that
    ///   guards its teardown on "a stream is running" needs this: during a cold start the answer
    ///   is no, and that used to be the end of it.
    @discardableResult
    mutating func recordStop() -> Bool {
        generation += 1
        let cancelledAStart = isStartPending
        isStartPending = false
        return cancelledAStart
    }
}
