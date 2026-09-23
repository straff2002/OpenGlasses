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
}
