import Foundation

/// What is still owed on recorded jobs, for the Jobs list and the job-day card (Plan HE §4).
///
/// A recording is owed from the moment it stops until the office's own verified receipt has been
/// taken in: waiting to be prepared, waiting for the right moment, on its way, sent and not yet
/// confirmed, refused, or left too long. **Once the office has confirmed it there is nothing
/// here**, and nothing here ever says the office has a recording.
///
/// The reasons are the sentences the job's page already uses — the sync service's and the
/// coordinator's own. This only chooses the title, and whether the technician has something to
/// decide.
enum JobRecordingOwed {

    /// A sealed recording, from where the sync service says it stands. Nil once the office has
    /// confirmed it.
    static func sealed(_ row: JobRecordingSyncService.Row, label: String) -> JobDayRecording? {
        func item(_ title: String, _ reason: String?, attention: Bool = false) -> JobDayRecording {
            JobDayRecording(sessionId: row.sessionID, label: label, title: title, reason: reason,
                            needsAttention: attention)
        }
        switch row.phase {
        case .acknowledged, .trimmed:
            return nil
        case .recording, .preparing:
            return item(JobDayRecording.waitingTitle, JobRecordingCoordinator.preparingNote)
        case .sealed:
            return item(JobDayRecording.waitingTitle, nil)
        case .waiting(.notEligible(.blurRequired)):
            // Not waiting for anything: it is held, and all a technician can do is delete it.
            return item(JobDayRecording.attentionTitle, SyncEligibility.Reason.blurRequired.explanation,
                        attention: true)
        case .waiting(let reason):
            return item(JobDayRecording.waitingTitle, reason.explanation)
        case .transferring(let sent, let total):
            return item(JobDayRecording.sendingTitle,
                        JobRecordingSyncService.progressWords(sentBytes: sent, totalBytes: total))
        case .delivered:
            // Every file has been served. That is sent; it is not the office having it.
            return item(JobDayRecording.sentTitle, JobRecordingSyncService.awaitingConfirmation)
        case .failed, .expired:
            // Kept whole, and nothing more happens until the technician chooses.
            return item(JobDayRecording.attentionTitle, JobRecordingSyncService.words(row), attention: true)
        }
    }

    /// A recording that has stopped and is not sealed yet. It has never left the phone, so it is
    /// always owed.
    static func unsealed(sessionId: String, waiting: JobRecordingCoordinator.Waiting,
                         label: String) -> JobDayRecording {
        JobDayRecording(sessionId: sessionId, label: label, title: JobDayRecording.waitingTitle,
                        reason: waiting.explanation)
    }

    /// Every recording on this phone the office has not confirmed, one a job: the sealed ones,
    /// then the ones still to be sealed. Empty with no office transport in the build — both
    /// services are nil there — and on a phone that has recorded nothing.
    @MainActor
    static func gather(coordinator: JobRecordingCoordinator?, sync: JobRecordingSyncService?,
                       label: (String) -> String) -> [JobDayRecording] {
        var owed: [JobDayRecording] = []
        for row in sync?.rows ?? [] {
            if let item = sealed(row, label: label(row.sessionID)) { owed.append(item) }
        }
        // One row a job. A job with something sealed and owed says that; unsealed parts beside a
        // bundle the office has confirmed are still owed, and say so.
        let sealedAndOwed = Set(owed.map(\.sessionId))
        for recording in coordinator?.unsealedRecordings() ?? [] where !sealedAndOwed.contains(recording.sessionID) {
            owed.append(unsealed(sessionId: recording.sessionID, waiting: recording.waiting,
                                 label: label(recording.sessionID)))
        }
        return owed
    }
}
