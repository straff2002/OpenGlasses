import Foundation

/// Plan LM P1 — one piece of work a background wake may run.
///
/// A value, not a subclass: a plan joins the shared wake by handing the coordinator one of these.
/// The rules every participant keeps (Plan LM, "Participants"): no model call unless its own plan
/// says so and names the budget; nothing spoken, no microphone, no camera; cancellation honoured;
/// nothing that would ask for confirmation in the foreground.
struct BackgroundWorkParticipant {
    /// A fixed literal (`goal-check-ins`). It is stored and logged, so never wearer content.
    let id: String
    /// How much of the wake it needs to start at all.
    let minimumSeconds: TimeInterval
    /// When it next wants a wake — `now` or earlier when due — or nil for never (switched off,
    /// nothing to do).
    let nextWake: @MainActor (_ now: Date) -> Date?
    /// Do the work, finishing by `deadline`, and say how it went.
    let run: @MainActor (_ deadline: Date) async -> BackgroundWorkOutcome
}

/// The record of a pass as it happens, so a wake that iOS ends early still leaves a true record:
/// whichever of "the pass finished" and "the wake expired" comes first writes it, once.
@MainActor
final class BackgroundRunProgress {
    let startedAt: Date
    let trigger: BackgroundRunTrigger
    let requestedEarliest: Date?
    private(set) var results: [BackgroundParticipantResult] = []
    /// The participant running now, if any — marked `cancelled` if the wake expires under it.
    private(set) var running: (id: String, since: Date)?
    private(set) var record: BackgroundRunRecord?

    var isFinished: Bool { record != nil }

    init(startedAt: Date, trigger: BackgroundRunTrigger, requestedEarliest: Date?) {
        self.startedAt = startedAt
        self.trigger = trigger
        self.requestedEarliest = requestedEarliest
    }

    func note(_ id: String, _ outcome: BackgroundWorkOutcome, seconds: TimeInterval = 0) {
        guard !isFinished else { return }
        results.append(BackgroundParticipantResult(id: id, outcome: outcome, seconds: seconds))
    }

    func begin(_ id: String, at now: Date) {
        guard !isFinished else { return }
        running = (id, now)
    }

    func end(_ id: String, _ outcome: BackgroundWorkOutcome, at now: Date) {
        guard !isFinished, let current = running, current.id == id else { return }
        running = nil
        note(id, outcome, seconds: max(0, now.timeIntervalSince(current.since)))
    }

    /// The finished record. The first call decides it; a later call returns nil, so the caller
    /// that got nil knows the record was already written.
    func finish(at now: Date, expired: Bool) -> BackgroundRunRecord? {
        guard !isFinished else { return nil }
        if let current = running {
            results.append(BackgroundParticipantResult(id: current.id, outcome: .cancelled,
                                                       seconds: max(0, now.timeIntervalSince(current.since))))
            running = nil
        }
        let finished = BackgroundRunRecord(startedAt: startedAt, trigger: trigger,
                                           requestedEarliest: requestedEarliest, results: results,
                                           seconds: max(0, now.timeIntervalSince(startedAt)),
                                           expired: expired)
        record = finished
        return finished
    }
}

/// Plan LM P1 — runs the participants of one wake in order, inside the budget.
@MainActor
enum BackgroundWorkRunner {

    /// Run `participants` in registration order, recording each into `progress`. A participant
    /// that is not due is noted `notDue`; one that cannot start in the time left, `skippedNoTime`;
    /// once the surrounding task is cancelled (the wake expired), the rest are `cancelled`. Does not
    /// finish `progress` — the caller does, so expiry and completion share one path.
    static func run(_ participants: [BackgroundWorkParticipant], progress: BackgroundRunProgress,
                    budget: TimeInterval = BackgroundRefreshPolicy.budget,
                    clock: @MainActor () -> Date = { Date() }) async {
        let deadline = progress.startedAt.addingTimeInterval(budget)
        for participant in participants {
            if progress.isFinished { return }
            if Task.isCancelled {
                progress.note(participant.id, .cancelled)
                continue
            }
            let now = clock()
            guard BackgroundRefreshPolicy.isDue(nextWake: participant.nextWake(now), now: now) else {
                progress.note(participant.id, .notDue)
                continue
            }
            guard BackgroundRefreshPolicy.mayStart(minimumSeconds: participant.minimumSeconds,
                                                   remaining: deadline.timeIntervalSince(now)) else {
                progress.note(participant.id, .skippedNoTime)
                continue
            }
            progress.begin(participant.id, at: now)
            let outcome = await participant.run(deadline)
            progress.end(participant.id, outcome, at: clock())
        }
    }
}

/// Plan LM P1 — the last wakes and the last request, kept for the Developer panel and the device
/// pass (P4). Diagnostic only: participant ids are literals and outcomes an enum.
@MainActor
final class BackgroundRunLedger: ObservableObject {
    @Published private(set) var records: [BackgroundRunRecord]
    @Published private(set) var lastRequest: BackgroundRequestRecord?

    static let recordsKey = "backgroundRunRecords"
    static let requestKey = "backgroundLastRequest"

    private let defaults: UserDefaults
    /// False after a record blob failed to decode: the backup is on disk, and nothing is written
    /// over the slot until a fresh record replaces it (Plan BB).
    private var recordsReadable = true

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let loaded = JSONStore.decodeArray(BackgroundRunRecord.self, from: defaults.data(forKey: Self.recordsKey), name: "background_runs")
        switch loaded {
        case .loaded(let values), .recovered(let values, _):
            records = values
        case .corrupt:
            records = []
            recordsReadable = false
        case .unreadable, .absent:
            records = []
        }
        lastRequest = defaults.data(forKey: Self.requestKey)
            .flatMap { try? JSONDecoder().decode(BackgroundRequestRecord.self, from: $0) }
    }

    func append(_ record: BackgroundRunRecord) {
        records = BackgroundRunRecord.appending(record, to: recordsReadable ? records : [])
        recordsReadable = true
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: Self.recordsKey)
        }
    }

    func setLastRequest(_ request: BackgroundRequestRecord) {
        lastRequest = request
        if let data = try? JSONEncoder().encode(request) {
            defaults.set(data, forKey: Self.requestKey)
        }
    }

    func clear() {
        records = []
        lastRequest = nil
        recordsReadable = true
        defaults.removeObject(forKey: Self.recordsKey)
        defaults.removeObject(forKey: Self.requestKey)
    }
}
