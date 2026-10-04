import Foundation

/// Delivers job records and stock checks to the office over the managed folders
/// (Contracts/office-reports.md), beside the endpoint and email paths.
///
/// It **waits**. An office that is off, asleep or out of reach, and one that has the record and
/// has not yet said so, both leave the operation queued with no attempt counted: being away from
/// the office is not a failure. An operation is delivered only when the office's signed receipt
/// says the record and every required attachment are committed. A finished transfer is not that.
///
/// It handles the two kinds a report can carry and hands every other kind, and everything when
/// the office is not this phone's destination, to the sink that was there before.
@MainActor
final class OfficeReportSink: SyncSink {

    struct Seams {
        var fallback: SyncSink
        /// Whether this phone's records go to an office over the managed folders now.
        var officeIsDestination: @MainActor () -> Bool
        var reports: OfficeReportService
        /// The evidence that goes with a job's record — each attachment's exact bytes in a file
        /// this phone keeps until the office has them — and where its transcript is.
        var evidence: @MainActor (QueuedOp) async throws
            -> (evidence: [OfficeReportService.Evidence], transcript: OfficeReport.Transcript)
    }

    /// Ops a report can carry; everything else is the fallback's.
    static let handledKinds: Set<OpKind> = [.workRecord, .partsRequest]

    static let waitingReason = "waiting for the office"
    static let evidencePendingReason = "the office has the record and is waiting for its evidence"

    private let seams: Seams

    init(seams: Seams) { self.seams = seams }

    func deliver(_ op: QueuedOp) async -> SyncOutcome {
        guard Self.handledKinds.contains(op.kind), seams.officeIsDestination() else {
            return await seams.fallback.deliver(op)
        }
        do {
            var evidence: [OfficeReportService.Evidence] = []
            var transcript = OfficeReport.Transcript.none
            if op.kind == .workRecord { (evidence, transcript) = try await seams.evidence(op) }
            guard let submission = Self.submission(for: op, evidence: evidence, transcript: transcript) else {
                return .permanent(reason: "this record can't be written as a report for the office")
            }
            switch try await seams.reports.submit(submission) {
            case .recordAccepted, .fullyAccepted, .superseded:
                return .done
            case .evidencePending:
                return .waiting(reason: Self.evidencePendingReason)
            case .waiting:
                return .waiting(reason: Self.waitingReason)
            }
        } catch OfficeReportService.Failure.notReportable(let reason) {
            return .permanent(reason: reason)
        } catch {
            // The gate did not pass, the folders are closed, the key could not sign: nothing was
            // refused, and nothing is counted against the operation.
            return .waiting(reason: Self.waitingReason)
        }
    }

    /// The report a queued operation becomes. Nil when the operation has no usable identity.
    static func submission(for op: QueuedOp, evidence: [OfficeReportService.Evidence],
                           transcript: OfficeReport.Transcript) -> OfficeReportService.Submission? {
        let fields = op.payloadJSON
        let kind: OfficeReport.RecordKind
        let recordID: String
        var jobReference = ""
        var jobID = ""
        var jobRevision: Int64 = 0
        switch op.kind {
        case .workRecord:
            kind = .workRecord
            recordID = op.sessionId
            // For a person, and only when it has one spelling; the record carries it either way.
            if let reference = fields["job_reference"] as? String, OfficeReport.plain(reference, maximum: 120) {
                jobReference = reference
            }
            // The office's own job and revision, when the job came from a format-2 job file.
            if let file = fields["job_file"] as? [String: Any], let id = file["job_id"] as? String,
               let revision = (file["revision"] as? NSNumber)?.int64Value,
               OfficeManualAssignment.safeIdentifier(id), revision > 0 {
                jobID = id
                jobRevision = revision
            }
        case .partsRequest:
            kind = .partsRequest
            guard let id = fields["id"] as? String else { return nil }
            recordID = id
        default:
            return nil
        }
        guard OfficeManualAssignment.safeIdentifier(op.id), OfficeManualAssignment.safeIdentifier(recordID),
              !op.payload.isEmpty else { return nil }
        return OfficeReportService.Submission(
            operationID: op.id, recordKind: kind, recordID: recordID, jobReference: jobReference,
            jobID: jobID, jobRevision: jobRevision, record: op.payload, evidence: evidence,
            transcript: transcript, createdAt: op.createdAt)
    }
}
