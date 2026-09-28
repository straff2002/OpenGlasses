import Combine
import Foundation

/// When the job-following surfaces have to be redrawn (Plan FO P3a).
///
/// The plan names three triggers — a tool mutation, an equipment change, an intake change — and
/// all three are the same event underneath: every one of them writes `FieldSession` back through
/// `FieldSessionService.mutateSession`, which republishes `activeSession`. So the trigger *set* is
/// one publisher, and what this adds is the other half: whether anything a surface can actually
/// show has moved.
///
/// The key is the three renderings concatenated, deliberately. A key built from hand-picked fields
/// is a fourth place to remember that the job number matters, and the field it forgets is the one
/// that stops reaching the model. Rendering the surfaces and comparing what came out cannot forget
/// anything they draw.
enum JobSurfaceRefresh {

    /// A value that changes exactly when one of the three surfaces would draw something different.
    static func key(for session: FieldSession?) -> String {
        let block = LiveJobContract.block(session: session) ?? ""
        let cue = JobQuestionHUDCue.cue(for: session)?.line ?? ""
        let watch = JobWatchPayload.payload(for: session).map {
            [$0.jobNumber, $0.state, $0.unit, $0.nextAction].joined(separator: "\u{1F}")
        } ?? ""
        return [block, cue, watch].joined(separator: "\u{1E}")
    }

    /// The trigger itself: `FieldSessionService.$activeSession`, de-duplicated on ``key(for:)`` and
    /// delivered on the next main-queue turn.
    ///
    /// The delivery is the half that matters. `@Published` emits in `willSet`, so a subscriber run
    /// synchronously still sees the *previous* value in `FieldSessionService.activeSession` — and
    /// three of the four surfaces read it there rather than from the value they are handed:
    /// `LiveJobBridge.refresh()` through its `activeSession` seam, the watch through
    /// `WatchConnectivityManager.sendStatusUpdate()`, and CarPlay through `refreshJobsTab()`. Run
    /// in `willSet`, the bridges and the watch are one change behind. (CarPlay reads inside a
    /// `Task { @MainActor }`, which already ran after the set; now it no longer depends on that.)
    /// A turn later the property has been set.
    static func trigger<Sessions: Publisher>(_ sessions: Sessions) -> AnyPublisher<FieldSession?, Never>
    where Sessions.Output == FieldSession?, Sessions.Failure == Never {
        sessions
            .removeDuplicates { key(for: $0) == key(for: $1) }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
}
