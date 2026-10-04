import Foundation

/// What may be removed from the phone for a recorded job, and when (Plan HE §4).
///
/// The rule everything else hangs from: **until the office has acknowledged a recording, the phone
/// keeps all of it and removes nothing by itself.** After acknowledgement the media is trimmed
/// once a waiting period has passed; the timeline, the transcript, the manifest and the receipt
/// stay with the job. A recording that goes too long without an acknowledgement is not removed
/// either — the technician is asked.
///
/// Also the size limits: how large one recording may grow, and how much unsent recording the phone
/// will hold before it declines to start another.
///
/// Pure: the dates and sizes are inputs, and nothing here deletes anything.
enum RetentionDecision {

    struct Limits: Equatable, Sendable {
        /// The most media one recorded job may hold. At the limit the recording stops and is saved.
        var sessionBytes: Int64 = 2_000_000_000
        /// The most media the phone holds for recordings the office has not acknowledged. At the
        /// limit a new recording is declined.
        var unsyncedBytes: Int64 = 8_000_000_000
        /// How long after acknowledgement the media stays on the phone.
        var trimAfterAcknowledgement: TimeInterval = 7 * 86_400
        /// How long a recording waits for an acknowledgement before the technician is asked.
        var expiryAfter: TimeInterval = 30 * 86_400

        /// The defaults: 2 GB a recording, 8 GB unsent in total, trimmed after 7 days, asked at 30.
        static let standard = Limits()
    }

    /// What is known about one recording.
    struct Recording: Equatable, Sendable {
        /// When it stopped — or, if the technician has since chosen to keep waiting, when they did.
        var waitingSince: Date
        /// When a verified receipt from the office arrived; nil until one has.
        var acknowledgedAt: Date?
        var mediaTrimmed = false
    }

    enum Action: Equatable, Sendable {
        /// Leave everything where it is.
        case keepEverything
        /// Remove the media. The timeline, transcript, manifest and receipt stay with the job.
        case trimMedia
        /// Unacknowledged for too long. Remove nothing; ask whether to keep waiting or delete.
        case askTechnician
        /// Already trimmed; what is left stays.
        case keepRecord
    }

    static func decide(_ recording: Recording, now: Date, limits: Limits = .standard) -> Action {
        guard let acknowledgedAt = recording.acknowledgedAt else {
            // Not acknowledged: nothing is ever removed on the phone's own say.
            return now.timeIntervalSince(recording.waitingSince) >= limits.expiryAfter ? .askTechnician : .keepEverything
        }
        if recording.mediaTrimmed { return .keepRecord }
        return now.timeIntervalSince(acknowledgedAt) >= limits.trimAfterAcknowledgement ? .trimMedia : .keepEverything
    }

    /// The same decision read from the sync state, so the two cannot disagree about whether the
    /// office has the recording.
    static func decide(_ state: BundleSyncState, waitingSince: Date, acknowledgedAt: Date?, now: Date,
                       limits: Limits = .standard) -> Action {
        decide(Recording(waitingSince: waitingSince, acknowledgedAt: state.isAcknowledged ? acknowledgedAt : nil,
                         mediaTrimmed: state.phase == .trimmed),
               now: now, limits: limits)
    }

    // MARK: - Size limits

    enum StartVerdict: Equatable, Sendable {
        case allowed
        /// With the reason and what to do about it, as sentences for the technician.
        case refused(String)
    }

    /// Whether a new recording may start, given the media already held for recordings the office
    /// has not acknowledged.
    static func mayStartRecording(unsyncedBytes: Int64, limits: Limits = .standard) -> StartVerdict {
        guard unsyncedBytes >= limits.unsyncedBytes else { return .allowed }
        return .refused(unsyncedLimitNote)
    }

    /// Said when a new recording is declined because too much is waiting to be sent: the reason,
    /// and what to do about it.
    static let unsyncedLimitNote = "This phone is holding as many unsent recordings as it can. "
        + "Connect to the office Wi-Fi and plug the phone in so they can be sent, then try again."

    /// Whether a running recording has reached the most one job may hold and must stop.
    static func mustStopRecording(sessionBytes: Int64, limits: Limits = .standard) -> Bool {
        sessionBytes >= limits.sessionBytes
    }

    /// Said when a recording stops at the limit. It is saved, not lost.
    static let stoppedAtLimitNote = "The recording reached its size limit and has stopped. What was recorded is saved."

    // MARK: - Deleting the job

    /// Deleting a job deletes its recording with it. When the office has not acknowledged that
    /// recording, the only copy is about to go, so the person is asked first.
    static func deletionNeedsConfirmation(_ recording: Recording) -> Bool {
        recording.acknowledgedAt == nil
    }

    static let unacknowledgedDeletionWarning =
        "The office hasn't received this job's recording yet. Deleting the job deletes the recording for good."

    /// The same warning for deleting the recording by itself, and leaving the job.
    static let unacknowledgedRecordingDeletionWarning =
        "The office hasn't received this recording yet. Deleting it removes the only copy."
}
