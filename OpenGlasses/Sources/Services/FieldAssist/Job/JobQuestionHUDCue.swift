import Foundation

/// The one line the lens carries about a question the app is waiting on (Plan FO P3a).
///
/// The guided flow asks two questions out loud — "what's the job number?" and "is this job
/// finished, or another unit on the same job?" — and a plant room is exactly where a spoken
/// question gets lost. So the lens carries the short form of whichever one is outstanding, on the
/// same transient path `TaskHUDCue` uses: a notification over whatever the HUD is showing, never a
/// screen of its own, never anything to press.
///
/// Three rules it exists to keep:
///  - **It never blocks speech.** The cue is drawn; the question is still spoken, by the app, in
///    its own words. Nothing here waits on the display or is skipped because of it.
///  - **It clears on the answer or on its own.** Every cue is transient, so the HUD clears it
///    after `duration` whether or not an answer came; `cue(for:)` returning nil is what a screen
///    that polls uses to clear early.
///  - **It is a no-op without a display.** `GlassesDisplayService` decides that, once, in
///    `present`; this type does not second-guess it and holds no capability state of its own.
enum JobQuestionHUDCue {

    /// What the lens is being asked to say, and for how long.
    struct Cue: Equatable {
        enum Kind: Equatable {
            /// The app has asked for the number and is waiting.
            case jobNumberOutstanding
            /// The app heard a number and is reading it back.
            case readBack(String)
            /// The app is holding a re-scope and waiting on the answer.
            case unitChange(jobReference: String?)
        }

        let kind: Kind
        let line: String
        let duration: TimeInterval
    }

    /// A question read back is worth longer than a standing reminder: it is the one the technician
    /// has to answer *now*, and it carries a number they have to check character by character.
    static let questionSeconds: TimeInterval = 8
    /// The standing "still owed" reminder. Same four seconds `TaskHUDCue` uses, for the same
    /// reason: long enough to read, short enough not to become a banner.
    static let reminderSeconds: TimeInterval = 4

    /// The cue for the job as it stands, or nil when nothing is outstanding.
    ///
    /// The unit question outranks the intake: it is the one holding a re-scope, and two cues at
    /// once is a HUD nobody can read. A closed, cancelled or absent job has no cue at all.
    static func cue(for session: FieldSession?) -> Cue? {
        guard let session, session.endedAt == nil, session.outcome != .cancelled else { return nil }

        if session.pendingUnitChange != nil {
            let job = session.jobReference.map { "Job \($0)" } ?? "This job"
            return Cue(kind: .unitChange(jobReference: session.jobReference),
                       line: "Different unit — \(job) finished?",
                       duration: questionSeconds)
        }

        switch session.jobIntake {
        case .confirming(let candidate, _):
            return Cue(kind: .readBack(candidate),
                       line: "Job \(candidate) — right?",
                       duration: questionSeconds)
        case .asked, .outstanding:
            return Cue(kind: .jobNumberOutstanding,
                       line: "Job number outstanding",
                       duration: reminderSeconds)
        case .needsReference, .recorded, .declined, .notRequired:
            return nil
        }
    }

    /// Flash it. A no-op without a display, which the display service itself decides.
    @MainActor
    static func show(_ cue: Cue, on display: GlassesDisplayService) {
        display.showNotification(title: nil, body: cue.line, icon: .info, duration: cue.duration)
    }
}
