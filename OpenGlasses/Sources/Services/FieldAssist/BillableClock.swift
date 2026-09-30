import Foundation

/// The time a job was worked, recovered after the app died mid-job (Plan GB P3).
///
/// Job 1011 lost about twenty minutes. Billable time is kept as a running total plus "resumed at",
/// and the total is written only on pause or end; the resume moment lived in memory. When the app
/// was killed and relaunched, the restore paused the job *now*, with nothing to count from, so
/// everything since the last pause vanished. The session already persisted when it was last
/// started or resumed, and its own log says when the app was last alive — the last thing it wrote.
/// Between the two is time that was worked; after the last sign of life is time nobody can vouch
/// for, and it is not counted.
///
/// Pure: the session, the heartbeat and the clock are all inputs.
enum BillableClock {

    struct Recovery: Equatable {
        /// Seconds to add to the job's total.
        let creditedSeconds: TimeInterval
        /// Where the job is paused from now on: the last sign of life.
        let pausedAt: Date
        /// From the last sign of life to the relaunch — not counted, and said so.
        let uncountedSeconds: TimeInterval
        /// False when the job was already paused when the app went away: nothing was running, so
        /// nothing is recovered and nothing is lost.
        let wasRunning: Bool
    }

    /// - Parameters:
    ///   - lastEvidenceOfLife: the newest timestamp in the job's `log.jsonl`, or nil for none.
    ///   - now: the relaunch.
    static func recover(session: FieldSession, lastEvidenceOfLife: Date?, now: Date) -> Recovery {
        if let pausedAt = session.pausedAt {
            return Recovery(creditedSeconds: 0, pausedAt: pausedAt, uncountedSeconds: 0, wasRunning: false)
        }
        // Counted from the later of the last resume (or the start, for a job never paused — which
        // is also every job recorded before `resumedAt` was kept) and the last checkpoint, because
        // a checkpoint has already added everything before it to the total.
        let resumed = session.resumedAt ?? session.startedAt
        let anchor = max(resumed, session.billableCheckpointAt ?? resumed)
        // The last sign of life: the log's newest line or the checkpoint, never later than now and
        // never earlier than the anchor — a heartbeat before the anchor credits nothing rather than
        // something negative.
        let seen = max(lastEvidenceOfLife ?? anchor, session.billableCheckpointAt ?? anchor)
        let heartbeat = min(max(seen, anchor), max(now, anchor))
        return Recovery(creditedSeconds: heartbeat.timeIntervalSince(anchor),
                        pausedAt: heartbeat,
                        uncountedSeconds: max(0, now.timeIntervalSince(heartbeat)),
                        wasRunning: true)
    }

    /// "Paused when the app closed at 5:18 PM; 2 minutes not counted." Minute grain, like the job
    /// clock it sits under (FO).
    static func note(pausedAt: Date, uncountedSeconds: TimeInterval,
                     timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "h:mm a"
        let minutes = Int((uncountedSeconds / 60).rounded())
        return "Paused when the app closed at \(formatter.string(from: pausedAt)); "
            + "\(WorkRecord.minutesPhrase(minutes: minutes)) not counted."
    }
}

extension FieldSession {
    /// Where the job was left when the app closed under it (Plan GB P3), until it is resumed.
    struct AppClosedPause: Codable, Equatable {
        let pausedAt: Date
        let uncountedSeconds: TimeInterval
    }
}
