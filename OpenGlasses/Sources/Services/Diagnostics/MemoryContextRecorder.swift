import Foundation

/// Where a `MemoryContextSnapshot` goes once it has been measured (Plan FC P3).
///
/// Two destinations, both of which already exist and neither of which is new plumbing:
/// - the **turn ledger**, so the developer turn export can say what memory a specific turn saw.
///   Off-turn work and a disabled recorder are handled by `TurnRecorder` itself — a background
///   agent run cannot land its snapshot on the wearer's turn.
/// - the **privacy log**, so the snapshot reaches the diagnostics export the wearer can send. That
///   export is built from the `PrivacyLog` ring, so emitting the event *is* the export wiring.
///
/// The live backends keep their snapshot here instead, because they have no turn boundaries to
/// record against: their instruction is built once at connect, so one current value per backend is
/// the whole truth, and reading it back ages it rather than pretending it was retrieved this turn.
@MainActor
enum MemoryContextRecorder {

    // MARK: - Per-turn

    /// Record the block assembled for the prompt in flight.
    ///
    /// The route is read from `TurnRecorder.isOffTurnWork` rather than passed: every call site
    /// that assembles memory for the app's own background work already runs inside
    /// `TurnRecorder.offTurn`, so asking the recorder is both accurate and impossible to forget.
    static func record(_ snapshot: MemoryContextSnapshot) {
        let route: MemoryContextSnapshot.Route = TurnRecorder.isOffTurnWork ? .background : .turn
        TurnRecorder.update { $0.memoryContext = snapshot }
        emit(.assembled, snapshot, route: route)
    }

    /// A prompt tier took only `renderedCharacters` of the block the turn was given.
    ///
    /// Updates the turn's snapshot in place — the recorded number has to be what the backend
    /// received, not what the store handed over — and returns the updated snapshot so a caller
    /// (a test, mostly) can assert on it. `nil` when there is no turn in flight to clip.
    @discardableResult
    static func noteClip(renderedCharacters: Int, droppedCharacters: Int) -> MemoryContextSnapshot? {
        var clipped: MemoryContextSnapshot?
        TurnRecorder.update { timeline in
            guard let existing = timeline.memoryContext else { return }
            let updated = existing.clipped(to: renderedCharacters, dropped: droppedCharacters)
            timeline.memoryContext = updated
            clipped = updated
        }
        guard let clipped else { return nil }
        emit(.clipped, clipped, route: .turn)
        return clipped
    }

    // MARK: - Live sessions

    /// The connect-time snapshot for each live backend, as recorded. Read through
    /// `liveSnapshots(asOf:)` rather than directly, so nothing reports a stale snapshot without
    /// its age.
    private static var live: [MemoryContextSnapshot.Route: MemoryContextSnapshot] = [:]

    /// A live backend built (or rebuilt) its system instruction. `snapshot.assembledAt` is that
    /// moment, and every turn of the session reads back against it.
    static func recordLive(_ snapshot: MemoryContextSnapshot,
                           route: MemoryContextSnapshot.Route) {
        live[route] = snapshot
        emit(.assembled, snapshot, route: route)
    }

    /// The live backends' snapshots as they stand at `now` — each one aged, so a session's turns
    /// are labelled `connectSnapshot(age:)` and never `perTurn`.
    static func liveSnapshots(asOf now: Date = Date()) -> [MemoryContextSnapshot.Route: MemoryContextSnapshot] {
        live.mapValues { $0.asOf(now) }
    }

    /// Forget the live snapshots. The session ended, or a test wants a known state.
    static func forgetLive(_ route: MemoryContextSnapshot.Route? = nil) {
        if let route { live[route] = nil } else { live.removeAll() }
    }

    // MARK: - Emission

    private static func emit(_ event: PrivacyLog.MemoryContextEvent,
                             _ snapshot: MemoryContextSnapshot,
                             route: MemoryContextSnapshot.Route) {
        PrivacyLog.memoryContext(
            event,
            route: PrivacyToken(route.rawValue),
            availability: PrivacyToken(snapshot.availability.label),
            reason: snapshot.availability.unavailableReason.map { PrivacyToken($0.rawValue) },
            stored: snapshot.stored,
            retrieved: snapshot.retrieved,
            included: snapshot.included,
            characters: snapshot.renderedCharacters,
            tokens: snapshot.estimatedTokens,
            truncation: PrivacyToken(snapshot.truncation.label),
            dropped: snapshot.truncation.droppedEntries > 0 ? snapshot.truncation.droppedEntries : nil,
            clamped: snapshot.truncation.clampedValues > 0 ? snapshot.truncation.clampedValues : nil,
            freshness: PrivacyToken(snapshot.freshness.label),
            ageSeconds: snapshot.freshness.ageSeconds)
    }
}
