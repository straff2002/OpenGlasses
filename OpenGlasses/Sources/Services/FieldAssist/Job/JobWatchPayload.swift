import Foundation

/// The job, as the watch shows it (Plan FO P3a).
///
/// **Read-only, and four short strings.** The watch surface gains no controls: there is nothing
/// here that starts, closes or answers anything, because every one of those is a decision the
/// technician makes on the phone, by voice, or on the car screen where the question can actually be
/// put. What the wrist is for is the glance — which job, running or paused, which machine, and
/// what the app is waiting on.
///
/// Bounded on purpose. The payload rides in `WCSession.updateApplicationContext`, which is a
/// fixed-size dictionary delivered on the system's schedule; every value is length-capped here so
/// a long machine name or a long task title cannot push the rest of the status update out.
enum JobWatchPayload {

    /// The dictionary key the whole block rides under, so a watch that has not been updated simply
    /// does not find it.
    static let key = "job"

    /// The cap on any one value. Generous for a job number, tight for a title.
    static let valueLimit = 48

    /// The four fields, in the order the watch draws them.
    struct Payload: Equatable {
        /// "Job 1005" or "No job number".
        let jobNumber: String
        /// "Running" or "Paused".
        let state: String
        /// The machine in hand, or empty when none has been identified.
        let unit: String
        /// What the app is waiting on, or empty when it is waiting on nothing.
        let nextAction: String

        var dictionary: [String: String] {
            ["jobNumber": jobNumber, "state": state, "unit": unit, "nextAction": nextAction]
        }
    }

    /// The payload for the job as it stands, or nil when no job is open — in which case the key is
    /// absent from the context and the watch shows nothing rather than a stale job.
    static func payload(for session: FieldSession?) -> Payload? {
        guard let session, session.endedAt == nil, session.outcome != .cancelled else { return nil }
        return Payload(
            jobNumber: clip(session.jobReference.flatMap { $0.isEmpty ? nil : "Job \($0)" }
                            ?? JobTabModel.noJobNumber),
            state: session.pausedAt == nil ? "Running" : "Paused",
            unit: clip(session.equipment?.modelToken ?? ""),
            nextAction: clip(nextAction(for: session)))
    }

    /// What the app is waiting on, in the fewest words that are still true.
    ///
    /// The unit question outranks the job number for the same reason it does on the lens: it is
    /// the one holding a re-scope. A task in hand is not a question, so it is reported last and
    /// only when there is no question at all.
    static func nextAction(for session: FieldSession) -> String {
        if session.pendingUnitChange != nil { return "Answer: same job, or finished?" }
        switch session.jobIntake {
        case .confirming(let candidate, _): return "Confirm job \(candidate)"
        case .asked, .needsReference: return "Job number needed"
        case .outstanding: return "Job number can be typed in"
        case .recorded, .declined, .notRequired: break
        }
        if let task = session.activeTask { return "On: \(task.title)" }
        return ""
    }

    private static func clip(_ value: String) -> String {
        guard value.count > valueLimit else { return value }
        return String(value.prefix(valueLimit - 1)) + "…"
    }
}
