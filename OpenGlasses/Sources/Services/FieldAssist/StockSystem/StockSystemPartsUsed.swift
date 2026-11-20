import Foundation
import Combine

/// Parts used, out per job (Plan MM P4): the noted lines read back and confirmed by a person, one
/// yes per batch, then queued for the system through `StockSystemSyncSink`.
///
/// **Nothing is sent without a person's yes** (Decision 5): `confirm` takes a
/// `StockUseConfirmation`, which has only a person's case, and is called from the close-of-job
/// question the app itself asks and from the parts step on the screen. No tool and no agent has a
/// path here; `StockSystemConfirmationGuardTests` fails on one. A no keeps the lines on the job,
/// noted and unsent, until someone sends or discards them.
///
/// When sending is not offered (sending back off, Medical Local Only, the office posting stock, no
/// connection), the job's noted lines go on its record as not sent, with the reason, when it
/// closes. With no reason the system keeps chosen, they stay noted on the job instead, waiting to
/// send once one is. Vendor-neutral: the system's name comes from the connection.
@MainActor
final class StockSystemPartsUsed: ObservableObject {

    struct Seams {
        /// The job's reference in another system, for a system with jobs.
        var reference: @MainActor (_ sessionID: String) -> ExternalJobReference? = { _ in nil }
        /// The job's lines for the system, as its record carries them.
        var recordOnJob: @MainActor (_ sessionID: String, StockSystemJobUses?) -> Void = { _, _ in }
        /// Run the offline queue now.
        var flush: @MainActor () async -> Void = {}
        var now: @MainActor () -> Date = { Date() }
        var makeID: @MainActor () -> String = { UUID().uuidString }
        var calendar: Calendar = .current
    }

    /// What a confirmation did, in a sentence for the person.
    struct Outcome: Equatable {
        let sentence: String
        let queued: Int
        let notSent: Int
    }

    let service: StockSystemService
    let sink: StockSystemSyncSink
    private let seams: Seams
    private var recorded: [String: StockSystemJobUses?] = [:]
    private var cancellables = Set<AnyCancellable>()

    init(service: StockSystemService, sink: StockSystemSyncSink, seams: Seams = Seams()) {
        self.service = service
        self.sink = sink
        self.seams = seams
        service.partsUsed = self
        // A use noted by `van_stock`, a confirmation or a delivery: the job's record follows.
        service.staged.$entries
            .sink { [weak self] entries in self?.recordJobs(entries) }
            .store(in: &cancellables)
        service.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
    }

    // MARK: - Reading

    var system: String { service.snapshot?.source.displayName ?? service.displayName }

    /// Whether sending is offered now for the chosen system, for parts not on a job of its own.
    var offer: StockSystemSendOffer { offer(for: nil) }

    /// Whether sending is offered now for the lines in `scope`: a job whose reference is the
    /// system's own sends part lines, which need no reason; anything else needs one the system
    /// keeps.
    func offer(for scope: StagedStockUseEntry.Scope?) -> StockSystemSendOffer {
        var reasonNeeded = true
        if case .job(let id) = scope, let capabilities = service.capabilities,
           case .jobPartLines = PartsUsedWritePlan.route(capabilities: capabilities, reference: seams.reference(id)) {
            reasonNeeded = false
        }
        return StockSystemSendOffer.decide(officeRoute: service.connection.officeRoute, connected: service.isRunning,
                                           sendingBack: service.connection.sendingBack,
                                           localOnly: service.isBlockedByMedical,
                                           reason: service.effectiveReason, reasonNeeded: reasonNeeded)
    }

    func entries(in scope: StagedStockUseEntry.Scope) -> [StagedStockUseEntry] { service.staged.entries(in: scope) }

    /// The lines in `scope` still waiting for a person.
    func awaiting(in scope: StagedStockUseEntry.Scope) -> [StagedStockUseEntry] {
        entries(in: scope).filter(\.isAwaitingConfirmation)
    }

    /// The premises day's scope for now.
    var today: StagedStockUseEntry.Scope {
        .day(StagedStockUseStore.dayKey(seams.now(), calendar: seams.calendar))
    }

    /// The one question for `scope`, when it has lines waiting and sending is offered; nil
    /// otherwise.
    func question(for scope: StagedStockUseEntry.Scope) -> String? {
        let waiting = awaiting(in: scope).filter { $0.connectorID == service.connection.selectedConnectorID }
        guard !waiting.isEmpty, offer(for: scope).isOffered else { return nil }
        if case .job = scope { return StockSystemPartsQuestion.question(waiting, system: system, onJob: true) }
        return StockSystemPartsQuestion.question(waiting, system: system, onJob: false)
    }

    /// What the job's row and the parts step say.
    func rowLines(for scope: StagedStockUseEntry.Scope) -> [String] {
        StockSystemJobRowState.lines(entries(in: scope), system: system)
    }

    /// The stepper for a noted line, from its unit and the system's figure for the item.
    func stepper(for entry: StagedStockUseEntry) -> StockSystemQuantityStepper {
        let line = entry.use.itemID.flatMap { id in service.snapshot?.lines.first { $0.itemID == id } }
        return StockSystemQuantityStepper(unit: entry.use.unit, decimalPlaces: line?.decimalPlaces,
                                          wholeNumbersOnly: service.capabilities?.wholeNumbersOnly ?? false)
    }

    // MARK: - Changing

    /// The parts step's stepper changed a line's amount before it is confirmed.
    @discardableResult
    func setQuantity(_ quantity: StockQuantity, for entry: StagedStockUseEntry) -> Bool {
        guard stepper(for: entry).accepts(quantity) else { return false }
        return service.staged.setQuantity(quantity, for: entry.id)
    }

    /// Keep these lines off the system for good: they stay on the record as not sent, discarded.
    @discardableResult
    func discard(_ ids: Set<String>) -> Bool {
        let now = seams.now()
        let system = self.system
        var updates: [String: StockSystemLineDelivery] = [:]
        for entry in service.staged.entries where ids.contains(entry.id) && entry.isAwaitingConfirmation {
            updates[entry.id] = .init(state: .notSent, reason: StockSystemNotSentReason.discarded.rawValue,
                                      sentence: StockSystemNotSentReason.discarded.sentence(system: system),
                                      changedAt: now)
        }
        return service.staged.setDelivery(updates)
    }

    /// The person said yes to the lines waiting in `scope`: one batch per location and reason,
    /// each through `PartsUsedWritePlan`, and queued. A line the system does not carry, or cannot
    /// take in that amount, is kept on the phone with the plan's sentence. Nothing is queued when
    /// sending is not offered or there are no figures to check the lines against.
    func confirm(_ scope: StagedStockUseEntry.Scope, by confirmation: StockUseConfirmation,
                 jobNumber: String? = nil) -> Outcome {
        let system = self.system
        let connectorID = service.connection.selectedConnectorID
        let waiting = awaiting(in: scope)
        guard !waiting.isEmpty else { return Outcome(sentence: "There are no parts waiting to send.", queued: 0, notSent: 0) }
        if case .notOffered(let reason) = offer(for: scope) {
            return Outcome(sentence: reason.sentence(system: system), queued: 0, notSent: 0)
        }
        guard let registration = service.registration, let snapshot = service.snapshot else {
            return Outcome(sentence: "No figures from \(system) are on this phone yet, so nothing was sent. Pull down on "
                           + "the Stock screen, then send them again.", queued: 0, notSent: 0)
        }
        let now = seams.now()
        let jobID: String
        let sessionID: String
        var reference: ExternalJobReference?
        switch scope {
        case .job(let id):
            jobID = id
            sessionID = id
            reference = seams.reference(id)
        case .day:
            jobID = scope.key
            sessionID = "stock-system-" + scope.key
        }
        var updates: [String: StockSystemLineDelivery] = [:]
        // Lines noted for another system than the one connected now cannot go anywhere.
        for entry in waiting where entry.connectorID != connectorID {
            updates[entry.id] = .init(state: .notSent, reason: StockSystemNotSentReason.disconnected.rawValue,
                                      sentence: StockSystemNotSentReason.disconnected.sentence(system: system),
                                      changedAt: now)
        }
        let sendable = waiting.filter { $0.connectorID == connectorID }
        var groups: [(key: String, entries: [StagedStockUseEntry])] = []
        for entry in sendable {
            let key = entry.locationID + "\u{0}" + (entry.reason?.rawValue ?? "")
            if let index = groups.firstIndex(where: { $0.key == key }) {
                groups[index].entries.append(entry)
            } else {
                groups.append((key, [entry]))
            }
        }
        var queued = 0
        var notSent = 0
        var kept: [String] = []
        for group in groups {
            guard let first = group.entries.first else { continue }
            // A line's own reason (written off as damaged) is the person's and is kept as said;
            // otherwise the reason parts used are sent with.
            let capabilities = registration.adapter.capabilities(chosenReason: first.reason ?? service.effectiveReason)
            let batch = ConfirmedStockUseBatch(jobID: jobID, jobNumber: jobNumber ?? first.jobReference,
                                               locationID: first.locationID, lines: group.entries.map(\.use),
                                               confirmation: confirmation)
            let plan = PartsUsedWritePlan(batch: batch, reference: reference, capabilities: capabilities, snapshot: snapshot)
            for entry in plan.notSent {
                updates[entry.stagedLineID] = .init(state: .notSent, reason: entry.reason.code, sentence: entry.sentence,
                                                    changedAt: now)
                notSent += 1
                kept.append(StockSystemJobRowState.reasonOnly(entry.sentence))
            }
            guard !plan.steps.isEmpty else { continue }
            let batchID = seams.makeID()
            if sink.enqueue(plan, system: system, scope: scope, sessionID: sessionID, confirmedAt: now,
                            batchID: batchID) != nil {
                for step in plan.steps {
                    updates[step.stagedLineID] = .init(state: .queued, batchID: batchID, changedAt: now)
                }
                queued += plan.steps.count
            }
        }
        service.staged.setDelivery(updates)
        if case .job(let id) = scope { recordJob(id) }
        if queued > 0 { Task { await seams.flush() } }
        var sentence: String
        switch queued {
        case 0: sentence = "Nothing could be sent to \(system)."
        case 1: sentence = "Sending one part to \(system)."
        default: sentence = "Sending \(StockSystemPartsQuestion.numberWord(queued)) parts to \(system)."
        }
        if notSent > 0 {
            var unique: [String] = []
            for reason in kept where !unique.contains(reason) { unique.append(reason) }
            sentence += " \(StockPlaceWording.capitalised(StockSystemPartsQuestion.numberWord(notSent))) kept on the "
                + "phone: " + unique.joined(separator: "; ") + "."
        }
        return Outcome(sentence: sentence, queued: queued, notSent: notSent)
    }

    /// The job is closing. When sending is not offered, its noted lines go on the record as not
    /// sent, with the reason; either way the record then carries every line as it stands. With no
    /// reason chosen they are not settled: they stay noted on the job, waiting to send, and are
    /// offered again once a reason is set.
    func settleAtClose(sessionID: String) {
        if case .notOffered(let reason) = offer(for: .job(sessionID)), reason != .noReason {
            let now = seams.now()
            let system = self.system
            var updates: [String: StockSystemLineDelivery] = [:]
            for entry in awaiting(in: .job(sessionID)) {
                updates[entry.id] = .init(state: .notSent, reason: reason.rawValue, sentence: reason.sentence(system: system),
                                          changedAt: now)
            }
            service.staged.setDelivery(updates)
        }
        recordJob(sessionID)
    }

    /// Put the job's lines on its session, so its record says what went where.
    func recordJob(_ sessionID: String) {
        let uses = StockSystemJobUses(entries: entries(in: .job(sessionID)), displayName: system)
        if let last = recorded[sessionID], last == uses { return }
        recorded[sessionID] = uses
        seams.recordOnJob(sessionID, uses)
    }

    private func recordJobs(_ entries: [StagedStockUseEntry]) {
        var ids: [String] = []
        for entry in entries {
            if case .job(let id) = entry.scope, !ids.contains(id) { ids.append(id) }
        }
        let system = self.system
        for id in ids {
            let uses = StockSystemJobUses(entries: entries.filter { $0.scope == .job(id) }, displayName: system)
            if let last = recorded[id], last == uses { continue }
            recorded[id] = uses
            seams.recordOnJob(id, uses)
        }
    }
}
