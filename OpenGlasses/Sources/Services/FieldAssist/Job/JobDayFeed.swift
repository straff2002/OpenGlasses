import Combine
import Foundation

/// Gathers the facts the job-day card is composed from and re-composes when any of them moves
/// (Plan HB). Thin on purpose: every decision is `JobDayComposer`'s.
///
/// An observable rather than a computed property because two of the facts are not cheap: whether a
/// finished job's report went out comes off that session's log on disk, and the card's view body is
/// re-evaluated far more often than a report is sent. So the feed reads them once per change of the
/// services it watches — and on the minute, so "overdue" and "today" roll over on their own.
@MainActor
final class JobDayFeed: ObservableObject {

    @Published private(set) var day: JobDay = .empty

    private let sessions: FieldSessionService
    private let flow: GuidedJobFlow
    private let upcoming: UpcomingJobStore
    private let sends: JobSendService
    private let myDay: MyDayService
    private var cancellables: Set<AnyCancellable> = []

    /// Whether My Day's items are folded in (`HomeDayCard.jobDay(showsPersonal:)`). Set by the card,
    /// which knows the switches and the lockdown.
    var showsPersonal = false {
        didSet { if showsPersonal != oldValue { refresh() } }
    }

    init(sessions: FieldSessionService, flow: GuidedJobFlow, upcoming: UpcomingJobStore,
         sends: JobSendService, myDay: MyDayService) {
        self.sessions = sessions
        self.flow = flow
        self.upcoming = upcoming
        self.sends = sends
        self.myDay = myDay

        // `@Published` fires before the value lands, so the changes are coalesced and read a beat
        // later — which also folds a burst (a job closing moves the session, the history and the
        // queue at once) into one composition.
        let changes: [AnyPublisher<Void, Never>] = [
            sessions.$activeSession.map { _ in () }.eraseToAnyPublisher(),
            sessions.$history.map { _ in () }.eraseToAnyPublisher(),
            flow.$debrief.map { _ in () }.eraseToAnyPublisher(),
            upcoming.$jobs.map { _ in () }.eraseToAnyPublisher(),
            sends.$revision.map { _ in () }.eraseToAnyPublisher(),
            sends.queue.$queue.map { _ in () }.eraseToAnyPublisher(),
            myDay.$state.map { _ in () }.eraseToAnyPublisher(),
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
        let startOfToday = calendar.startOfDay(for: now)
        var gathered: [JobDaySession] = []
        if let open = sessions.activeSession, open.endedAt == nil, open.outcome != .cancelled {
            gathered.append(Self.session(open, reportSent: false))
        }
        // Only today's finished jobs reach the disk read; the composer would ignore the rest.
        for session in sessions.history where session.id != sessions.activeSession?.id {
            guard let ended = session.endedAt, ended >= startOfToday, session.outcome != .cancelled else {
                continue
            }
            gathered.append(Self.session(session, reportSent: sessions.reportWasSent(sessionId: session.id)))
        }

        let debrief = flow.debrief.flatMap { active -> JobDayDebrief? in
            active.state.isSettled ? nil : JobDayDebrief(sessionId: active.sessionId, label: active.jobNumber)
        }

        var personal: [MyDayItem]?
        if showsPersonal {
            if case .loaded(let snapshot) = myDay.state {
                personal = snapshot.allItems
            } else if case .loading(let previous?) = myDay.state {
                personal = previous.allItems
            } else {
                personal = []
            }
        }

        let next = JobDayComposer.compose(JobDayInputs(
            now: now,
            calendar: calendar,
            upcoming: upcoming.jobs,
            sessions: gathered,
            queue: sends.queue.queue.entries,
            debrief: debrief,
            signOffRequired: sessions.customerSignOffRequired,
            personal: personal))
        if next != day { day = next }
    }

    private static func session(_ session: FieldSession, reportSent: Bool) -> JobDaySession {
        JobDaySession(
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
            openPartsRequests: session.partsRequests.filter { $0.status != .answered }.count)
    }
}
