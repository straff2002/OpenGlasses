import Foundation

/// Which document a debrief belongs in (Plan FO §6, P3b).
///
/// One decision, and it is the one that keeps a promise: **a job whose record was already
/// delivered keeps the original work order unchanged**. A customer holding a PDF and a technician
/// re-rendering the same job must get the same bytes, whatever was said about the job afterwards.
/// So a debrief that arrives after the report has gone is a *second document* — the addendum —
/// and never a line added to the first.
///
/// Before the report goes, there is no first document to protect and the debrief simply prints in
/// the work order, where a reader will actually find it.
enum DebriefDocumentPolicy {

    enum Placement: Equatable {
        /// The work order prints these; there is no addendum.
        case inWorkOrder([JobDebrief])
        /// The work order prints none of them; these go in an addendum of their own.
        case asAddendum([JobDebrief])
        /// Nothing to place.
        case nothing

        /// What the work order is handed.
        var workOrderDebriefs: [JobDebrief] {
            if case .inWorkOrder(let debriefs) = self { return debriefs }
            return []
        }

        /// What an addendum would carry.
        var addendumDebriefs: [JobDebrief] {
            if case .asAddendum(let debriefs) = self { return debriefs }
            return []
        }
    }

    /// - Parameters:
    ///   - debriefs: every debrief saved on the job, in the order they were saved.
    ///   - reportAlreadySent: whether a work order for this job has left the device by any
    ///     channel. Read off the session's own append-only log, which is what actually records a
    ///     send and survives a relaunch.
    static func placement(debriefs: [JobDebrief], reportAlreadySent: Bool) -> Placement {
        let ordered = debriefs.sorted { $0.recordedAt < $1.recordedAt }
        guard !ordered.isEmpty else { return .nothing }
        return reportAlreadySent ? .asAddendum(ordered) : .inWorkOrder(ordered)
    }

    // MARK: - What the addendum says

    /// The addendum's title.
    static let addendumTitle = "Debrief addendum"

    /// The sentence under it, which exists to stop anybody reading the addendum as a replacement.
    static let addendumLede =
        "This is an addition to the work order already sent for this job. Nothing in the original "
        + "record has changed: the work, the time on the job and anything the customer signed are "
        + "as they were."

    /// The heading a work order prints the debrief under.
    static let workOrderSectionTitle = JobDebrief.blockTitle
}
