import Combine
import Foundation

/// Gathers the facts the Jobs list is composed from and re-composes when any of them moves
/// (Plan HC). Thin on purpose: every decision is `JobListComposer`'s.
///
/// The same shape as the job-day card's `JobDayFeed`, and for the same reason: whether a finished
/// job's report went out comes off that session's log on disk, and a list's body is evaluated far
/// more often than a report is sent. So the feed reads it once per session — only for the recent
/// jobs, the only ones that badge on it — and forgets those reads when a send moves.
@MainActor
final class JobListFeed: ObservableObject {

    @Published private(set) var list: JobList = JobListComposer.compose(JobListInputs(now: Date()))

    /// What is typed in the search field.
    var query = "" {
        didSet { if query != oldValue { refresh() } }
    }

    private let sessions: FieldSessionService
    private let flow: GuidedJobFlow
    private let upcoming: UpcomingJobStore
    private let sends: JobSendService
    private let vaultName: (String) -> String
    /// Recorded jobs not yet with the office (Plan HE). None in a build with no office transport.
    private let recordings: @MainActor () -> [JobDayRecording]
    /// Updates from the office not yet opened, by office job identifier. None in a build with no
    /// office transport.
    private let newUpdates: @MainActor () -> [String: Int]
    private var reportSent: [String: Bool] = [:]
    private var cancellables: Set<AnyCancellable> = []

    init(sessions: FieldSessionService, flow: GuidedJobFlow, upcoming: UpcomingJobStore,
         sends: JobSendService, vaultName: ((String) -> String)? = nil,
         recordings: @escaping @MainActor () -> [JobDayRecording] = { [] },
         recordingChanges: AnyPublisher<Void, Never> = Empty().eraseToAnyPublisher(),
         newUpdates: @escaping @MainActor () -> [String: Int] = { [:] },
         updateChanges: AnyPublisher<Void, Never> = Empty().eraseToAnyPublisher()) {
        self.sessions = sessions
        self.flow = flow
        self.upcoming = upcoming
        self.sends = sends
        self.recordings = recordings
        self.newUpdates = newUpdates
        self.vaultName = vaultName ?? { VaultRegistry.shared.manifest(id: $0)?.name ?? $0 }

        // A send — staged, sent or failed — is what changes whether a report went out.
        Publishers.Merge(sends.$revision.map { _ in () }, sends.queue.$queue.map { _ in () })
            .sink { [weak self] in self?.reportSent = [:] }
            .store(in: &cancellables)

        // `@Published` fires before the value lands, so the changes are coalesced and read a beat
        // later — which also folds a burst (closing a job moves the session, the history and the
        // queue at once) into one composition.
        let changes: [AnyPublisher<Void, Never>] = [
            sessions.$activeSession.map { _ in () }.eraseToAnyPublisher(),
            sessions.$history.map { _ in () }.eraseToAnyPublisher(),
            flow.$debrief.map { _ in () }.eraseToAnyPublisher(),
            upcoming.$jobs.map { _ in () }.eraseToAnyPublisher(),
            sends.$revision.map { _ in () }.eraseToAnyPublisher(),
            sends.queue.$queue.map { _ in () }.eraseToAnyPublisher(),
            recordingChanges,
            updateChanges,
            // "Overdue", "today" and "recent" roll over on their own.
            Timer.publish(every: 60, tolerance: 5, on: .main, in: .common).autoconnect()
                .map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(changes)
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &cancellables)
        refresh()
    }

    func refresh(now: Date = Date()) {
        let calendar = Calendar.current
        let recentSince = calendar.date(byAdding: .day, value: -(JobListComposer.recentDays - 1),
                                        to: calendar.startOfDay(for: now)) ?? now

        var open: JobListSession?
        if let session = sessions.activeSession, session.endedAt == nil, session.outcome != .cancelled {
            open = gathered(session, reportSent: false)
        }
        var finished: [JobListSession] = []
        for session in sessions.history where session.endedAt != nil && session.id != open?.facts.id {
            // Only the recent jobs' logs are read: the older ones never badge on it.
            let sent = (session.endedAt ?? now) >= recentSince ? wasSent(session.id) : true
            finished.append(gathered(session, reportSent: sent))
        }

        let debrief = flow.debrief.flatMap { active -> JobDayDebrief? in
            active.state.isSettled ? nil : JobDayDebrief(sessionId: active.sessionId, label: active.jobNumber)
        }

        let next = JobListComposer.compose(JobListInputs(
            now: now, calendar: calendar, open: open, finished: finished,
            upcoming: upcoming.jobs, queue: sends.queue.queue.entries, debrief: debrief,
            signOffRequired: sessions.customerSignOffRequired, recordings: recordings(), newUpdates: newUpdates(), query: query))
        if next != list { list = next }
    }

    /// What the routing needs to know about the phone right now.
    var routingFacts: JobListRouting.Facts {
        let openSession = sessions.activeSession.flatMap {
            $0.endedAt == nil && $0.outcome != .cancelled ? $0 : nil
        }
        return JobListRouting.Facts(
            openSessionId: openSession?.id,
            openJobLabel: openSession.map { JobDaySession.label(reference: $0.jobReference) },
            finishedSessionIds: Set(sessions.history.filter { $0.endedAt != nil }.map(\.id)),
            upcomingIds: Set(upcoming.jobs.map(\.id)))
    }

    private func wasSent(_ sessionId: String) -> Bool {
        if let known = reportSent[sessionId] { return known }
        let sent = sessions.reportWasSent(sessionId: sessionId)
        reportSent[sessionId] = sent
        return sent
    }

    private func gathered(_ session: FieldSession, reportSent: Bool) -> JobListSession {
        JobListSession(
            facts: JobDaySession(
                id: session.id,
                jobReference: session.jobReference,
                customer: session.site?.customer,
                siteHeadline: session.site?.headline,
                startedAt: session.startedAt,
                endedAt: session.endedAt,
                isPaused: session.pausedAt != nil,
                cancelled: session.outcome == .cancelled,
                reportSent: reportSent,
                signedOff: session.signOff != nil,
                openPartsRequests: session.partsRequests.filter { $0.status != .answered }.count),
            vaultName: vaultName(session.vaultId),
            equipment: session.equipment?.modelToken,
            officeJobID: session.jobFile?.identity?.jobID,
            outcomeLabel: session.outcome.displayName,
            billingLine: WorkRecord.billingSummary(seconds: session.billableSeconds,
                                                   basis: session.billingBasis,
                                                   minutesPerUnit: session.minutesPerBillingUnit))
    }
}
