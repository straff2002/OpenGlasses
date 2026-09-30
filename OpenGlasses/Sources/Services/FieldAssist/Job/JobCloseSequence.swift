import Foundation

/// The one sequence every job close runs (Plan GB P3).
///
/// Closing by voice called the flow's close directly and skipped what the Job tab's close did —
/// the sign-off rule, the evidence decision, the record snapshot — although the tab's comment said
/// every close came through it. Now both come through `GuidedJobFlow.closeJob`, which runs this:
/// open checks → the evidence decision → the sign-off rule → then the record is taken, the job
/// ended, and the report can be staged.
///
/// **By voice nothing is skipped silently.** An owed check and an undecided set of photos become
/// questions the model puts to the technician; the screen answers the evidence question with its
/// own review step, and a check still owed there closes the job as deferred rather than resolved.
///
/// Pure over its inputs.
enum JobCloseSequence {

    enum Route: Equatable {
        /// `field_session end` — questions are put back to the model to ask.
        case voice
        /// The Job tab, or the app itself: its own sheets have already asked what they ask.
        case screen
    }

    struct Inputs: Equatable {
        var requestedOutcome: FieldSession.Outcome
        /// Titles of checks still owed ("Verify: run a full heat cycle").
        var openVerifications: [String]
        /// Photos and clips on the job.
        var evidenceCount: Int
        /// Whether the technician has said anything about which of them go.
        var evidenceDecided: Bool
        var signOff: SignOffPolicy.Decision
        var route: Route
    }

    enum Decision: Equatable {
        /// Take the record, end the job with this outcome.
        case proceed(outcome: FieldSession.Outcome)
        /// Not yet: the model asks the technician this, and the close is tried again.
        case ask(String)
        /// Not at all, for the reason given.
        case refuse(String)
    }

    static func decide(_ inputs: Inputs) -> Decision {
        var outcome = inputs.requestedOutcome
        // A job with a check still owed is not resolved (Plan GB P3).
        if !inputs.openVerifications.isEmpty, outcome == .resolved {
            switch inputs.route {
            case .voice:
                let owed = inputs.openVerifications.joined(separator: "; ")
                return .ask("Not closed yet: \(owed) is still open, so this job cannot be recorded as "
                            + "resolved. Ask the technician whether the check passed — if it did, close "
                            + "that task with verified true, then close the job — or close the job now "
                            + "with outcome 'deferred' and the check stays on the record as open.")
            case .screen:
                outcome = .deferred
            }
        }
        if inputs.route == .voice, inputs.evidenceCount > 0, !inputs.evidenceDecided {
            let items = inputs.evidenceCount == 1 ? "1 photo or clip is" : "\(inputs.evidenceCount) photos or clips are"
            return .ask("Not closed yet: \(items) on this job and nobody has said which go with the "
                        + "report. Ask the technician: send them as they are, or leave any out? Then "
                        + "call the evidence tool (keep, include or exclude) and close the job again.")
        }
        if case .blocked(let reason) = inputs.signOff { return .refuse(reason) }
        return .proceed(outcome: outcome)
    }
}
