import BackgroundTasks
import Foundation

/// Plan LM P1 — the app's one background wake, shared by every plan that needs background time.
///
/// The only file that talks to `BGTaskScheduler`. It registers the shared identifier at launch,
/// asks iOS for the next wake when a participant wants one, runs the participants inside the
/// budget when iOS obliges, and writes what happened to `ledger` — whichever of "finished" and
/// "expired" comes first. A plan joins by calling `add(_:)`; it never registers a task of its own.
///
/// What it cannot do is promise a time. iOS decides when, often runs nothing overnight, and runs
/// less for an app the wearer seldom opens; the ledger is how the device pass finds out (P4).
@MainActor
final class BackgroundRefreshCoordinator {
    static let shared = BackgroundRefreshCoordinator()

    let ledger: BackgroundRunLedger
    private(set) var participants: [BackgroundWorkParticipant] = []
    private var registered = false
    /// A pass in flight, so a second wake or a Run now does not overlap it.
    private var passInFlight = false

    init(ledger: BackgroundRunLedger = BackgroundRunLedger()) {
        self.ledger = ledger
    }

    // MARK: - Participants

    /// Add a participant, replacing any with the same id — so a second `AppState` (a scene
    /// rebuilt) re-registers instead of doubling up.
    func add(_ participant: BackgroundWorkParticipant) {
        participants.removeAll { $0.id == participant.id }
        participants.append(participant)
    }

    func remove(id: String) {
        participants.removeAll { $0.id == id }
    }

    // MARK: - Registration

    /// Register the shared identifier. Must run before the app finishes launching — it is called
    /// from `application(_:didFinishLaunchingWithOptions:)` — and only once per process.
    func registerWithSystem() {
        guard !registered else { return }
        registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundRefreshPolicy.taskIdentifier, using: nil
        ) { task in
            Task { @MainActor in BackgroundRefreshCoordinator.shared.handle(task) }
        }
        PrivacyLog.agent(.background, .backgroundRegistered,
                         reason: PrivacyToken(registered ? "registered" : "refused"))
    }

    // MARK: - Asking for the next wake

    /// Ask iOS for the next wake: the soonest any participant wants, never sooner than the policy
    /// allows. With no participant wanting one, any pending request is cancelled instead. Called
    /// when the app goes to the background and at the start and end of every pass.
    func scheduleNext(now: Date = Date()) {
        let wanted = participants.map { $0.nextWake(now) }
        guard let begin = BackgroundRefreshPolicy.earliestBeginDate(now: now, wanted: wanted) else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: BackgroundRefreshPolicy.taskIdentifier)
            ledger.setLastRequest(BackgroundRequestRecord(submittedAt: now, earliestBegin: nil, failure: nil))
            PrivacyLog.agent(.background, .backgroundRequestCancelled)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: BackgroundRefreshPolicy.taskIdentifier)
        request.earliestBeginDate = begin
        do {
            try BGTaskScheduler.shared.submit(request)
            ledger.setLastRequest(BackgroundRequestRecord(submittedAt: now, earliestBegin: begin, failure: nil))
            PrivacyLog.agent(.background, .backgroundRequested,
                             minutes: Int((begin.timeIntervalSince(now) / 60).rounded()))
        } catch {
            // Always on the Simulator, and when the wearer has switched Background App Refresh off.
            // Recorded, not retried: the next trip to the background asks again.
            let reason = Self.failureReason(error)
            ledger.setLastRequest(BackgroundRequestRecord(submittedAt: now, earliestBegin: begin, failure: reason))
            PrivacyLog.agent(.background, .backgroundRequestFailed, reason: PrivacyToken(reason))
        }
    }

    /// A fixed token for a submit failure — never the error's own text.
    nonisolated static func failureReason(_ error: Error) -> String {
        guard let scheduling = error as? BGTaskScheduler.Error else { return "other" }
        switch scheduling.code {
        case .unavailable: return "unavailable"
        case .tooManyPendingTaskRequests: return "tooManyPending"
        case .notPermitted: return "notPermitted"
        @unknown default: return "other"
        }
    }

    // MARK: - A wake

    /// iOS woke the app with the shared task.
    private func handle(_ task: BGTask) {
        let requested = ledger.lastRequest?.failure == nil ? ledger.lastRequest?.earliestBegin : nil
        // Ask for the next wake first: if iOS ends this one early, the next is already asked for.
        scheduleNext()
        guard !passInFlight else {
            task.setTaskCompleted(success: true)
            return
        }
        let progress = BackgroundRunProgress(startedAt: Date(), trigger: .systemRefresh,
                                             requestedEarliest: requested)
        PrivacyLog.agent(.background, .backgroundWake, reason: PrivacyToken("systemRefresh"),
                         count: participants.count)
        passInFlight = true
        let work = Task { @MainActor in
            await BackgroundWorkRunner.run(self.participants, progress: progress)
            self.finish(progress, expired: false, task: task)
        }
        task.expirationHandler = {
            Task { @MainActor in
                work.cancel()
                BackgroundRefreshCoordinator.shared.finish(progress, expired: true, task: task)
            }
        }
    }

    /// The Developer panel's Run now: the same pass in the foreground, recorded as `manual`.
    func runNow() async {
        guard !passInFlight else { return }
        let progress = BackgroundRunProgress(startedAt: Date(), trigger: .manual, requestedEarliest: nil)
        PrivacyLog.agent(.background, .backgroundWake, reason: PrivacyToken("manual"),
                         count: participants.count)
        passInFlight = true
        await BackgroundWorkRunner.run(participants, progress: progress)
        finish(progress, expired: false, task: nil)
    }

    /// Write the record once — whichever of completion and expiry comes first — complete the task
    /// and ask for the next wake with the participants' state after the pass.
    private func finish(_ progress: BackgroundRunProgress, expired: Bool, task: BGTask?) {
        guard let record = progress.finish(at: Date(), expired: expired) else { return }
        passInFlight = false
        ledger.append(record)
        let notRun: Set<BackgroundWorkOutcome> = [.notDue, .skippedNoTime]
        let ran = record.results.filter { !notRun.contains($0.outcome) }.count
        PrivacyLog.agent(.background, expired ? .backgroundExpired : .backgroundCompleted,
                         count: ran, seconds: record.seconds)
        task?.setTaskCompleted(success: !expired)
        if !expired { scheduleNext() }
    }
}
