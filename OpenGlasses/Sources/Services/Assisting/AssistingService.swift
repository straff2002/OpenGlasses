import Foundation
import Combine

/// Assisting mode (Plan KM §7, P2): what the app shows when an expert opens an `.ogcase` they
/// were sent.
///
/// **Not a mode anyone turns on, and it unlocks nothing.** There is no switch, setting or sign-up;
/// Assisting is only what opening a handover shows. It needs no Field Assist seat, licence or
/// profile — this type and everything it calls never ask `FieldAssistEntitlement` — and it opens
/// none of Field Assist: no job flow, vault, procedure, manual page, calculator, parts, export or
/// tool. `AssistingIsolationTests` holds each row of the plan's "never opens" table as a test.
///
/// What it does, which is the whole of the plan's "opens" column for this phase:
/// - keeps the handovers it was sent, read-only and grouped by organisation (`AssistingHandoverStore`);
/// - **Take this job**, **Pause**, **Resume** and **Done**, and the expert's own clock, which
///   survives the app dying (`AssistingClock`);
/// - the **time reply**, staged: built and shown on Done, and sent only from the share sheet the
///   expert opens with their own tap;
/// - **coaching steps** for that handover (Plan KM P3): written, reordered and kept as a draft on
///   the held handover, and sent the same way as the time reply — staged, by the expert's share;
/// - the **expert card** (`ExpertCardStore`).
///
/// Medical Compliance mode does not close it: holding a handover sent to you is not an egress, the
/// view is read-only, and the only thing that leaves is the expert's own reply by their own share.
@MainActor
final class AssistingService: ObservableObject {

    static let shared = AssistingService()

    let store: AssistingHandoverStore
    let cards: ExpertCardStore
    /// The expert's own ledger (Plan KM P4): every time reply whose share completed.
    let ledger: ExpertLedgerStore
    private let replies: StagedExportCoordinator
    private let now: () -> Date
    /// The call observer, made on the first clock that runs, so a phone that never takes a job
    /// never observes. Injectable for tests.
    var makeCallObserver: () -> CallObserving = { SystemCallObserver() }
    private var callObserver: CallObserving?
    private var calls = AssistingCallTally()

    /// A handover the app just opened, for the sheet that shows it.
    @Published var presented: Presented?

    /// An invite the app just opened, or Home asked for, for the sheet that shows it (Plan KW §4).
    @Published var presentedInvite: OpenInvite?

    /// Whether Assisting is this phone's owner's, and what Home says about it (Plan KW §2). The hub
    /// and Home read this, never the store.
    @Published private(set) var presence: AssistingPresence = .absent

    private var watchers: Set<AnyCancellable> = []
    /// Where the rest of the app reads presence from (Plan KW §2).
    let feed: AssistingPresenceFeed

    struct Presented: Identifiable, Equatable {
        let id: String
        /// What opening it said: "Update 2 replaced the earlier one: 2 new readings."
        let message: String
    }

    /// - Parameter ledger: the expert's ledger; by default the shared one, or — for a store given
    ///   here — one beside that store's files, so a test's handovers and ledger stay together.
    init(store: AssistingHandoverStore? = nil, cards: ExpertCardStore = .shared,
         replies: StagedExportCoordinator = .assistingReply, ledger: ExpertLedgerStore? = nil,
         feed: AssistingPresenceFeed? = nil, now: @escaping () -> Date = Date.init) {
        self.store = store ?? .shared
        self.cards = cards
        self.replies = replies
        self.ledger = ledger ?? (store.map { ExpertLedgerStore(directory: $0.storeDirectory, now: now) } ?? .shared)
        self.now = now
        // A test's service gets its own feed, so it never draws the app's hub.
        self.feed = feed ?? (store == nil ? .shared : AssistingPresenceFeed())
        refreshPresence()
        // Any change to what makes Assisting the owner's redraws the hub and Home.
        self.store.$held.dropFirst().sink { [weak self] _ in Task { @MainActor in self?.refreshPresence() } }
            .store(in: &watchers)
        self.store.$invites.dropFirst().sink { [weak self] _ in Task { @MainActor in self?.refreshPresence() } }
            .store(in: &watchers)
        self.ledger.$entries.dropFirst().sink { [weak self] _ in Task { @MainActor in self?.refreshPresence() } }
            .store(in: &watchers)
    }

    // MARK: - Presence (Plan KW §2)

    /// Recompute `presence` from what is held now. The card is a preference, not a published
    /// store, so its editor calls this when it saves or deletes.
    func refreshPresence() {
        let at = now()
        let held = store.held.filter { !$0.isExpired(at: at) }.map { entry in
            AssistingPresence.HeldFact(id: entry.id, organisation: entry.organisationName,
                                       taken: entry.clock != nil, running: entry.clock?.isRunning == true,
                                       receivedAt: entry.lastReceivedAt, dismissed: entry.homeDismissed == true)
        }
        let invites = store.invites.filter { !$0.invite.isExpired(at: at) }.map { entry in
            AssistingPresence.InviteFact(id: entry.id, organisation: entry.invite.senderName,
                                         receivedAt: entry.receivedAt, dismissed: entry.homeDismissed == true)
        }
        let next = AssistingPresence.make(hasCard: cards.card != nil, held: held,
                                          hasLedger: !ledger.entries.isEmpty, invites: invites)
        if next != presence { presence = next }
        feed.publish(next, hasCard: cards.card != nil)
    }

    /// The minutes on a handover's clock, for Home's running card.
    func clockMinutes(for id: String, at date: Date) -> Int? {
        store.handover(id: id)?.clock?.minutes(at: date)
    }

    /// Put a held handover on screen, as opening its file does.
    func show(handoverId id: String) {
        guard store.handover(id: id) != nil else { return }
        presented = Presented(id: id, message: "")
    }

    /// Put a held invite on screen.
    func showInvite(_ id: String) {
        guard let invite = store.invite(id: id) else { return }
        presentedInvite = invite
    }

    /// The Home card's Remove from Home. It hides the card for what it shows now; a new job or
    /// invite brings it back.
    func dismissFromHome(_ card: AssistingPresence.HomeCard) {
        switch card {
        case .clock: return
        case .newJobs(let ids, _): ids.forEach { store.dismissFromHome(id: $0) }
        case .invite(let id, _): store.dismissInviteFromHome(id: id)
        }
    }

    // MARK: - Invites (Plan KW §4)

    /// An invite file's bytes, from the app's file opening. Keeps it and shows the card form.
    /// Returns what to tell the expert when it can't be shown.
    @discardableResult
    func openInvite(_ data: Data) -> String? {
        switch ExpertInviteCodec.read(data) {
        case .failure(.refused(let why)):
            return String(localized: "That invite can't be used: \(why).")
        case .failure:
            return String(localized: "That isn't an invite this app can read.")
        case .success(let invite):
            switch store.openInvite(invite) {
            case .added, .alreadyHeld:
                presentedInvite = store.invite(id: invite.inviteId)
                return nil
            case .expired:
                return String(localized: "That invite has run out. Ask \(invite.senderName) to send a new one.")
            case .couldNotSave:
                return String(localized: "The invite couldn't be saved on this phone. Try opening it again.")
            }
        }
    }

    /// The card's share to the inviter completed.
    func answerInvite(_ id: String) {
        store.removeInvite(id: id)
        if presentedInvite?.id == id { presentedInvite = nil }
        refreshPresence()
    }

    /// Declined: dropped, and nothing is sent.
    func declineInvite(_ id: String) {
        store.removeInvite(id: id)
        if presentedInvite?.id == id { presentedInvite = nil }
    }

    // MARK: - Opening a handover

    /// What opening a file did: what to tell the expert, and whether the handover is now on screen
    /// (when it is not, the caller says the message some other way).
    struct OpenReport: Equatable {
        let outcome: AssistingHandoverStore.OpenOutcome
        let message: String
        let shown: Bool
    }

    /// Keep an opened handover and show it.
    @discardableResult
    func open(_ opened: ExpertHandoverFile.Opened) -> OpenReport {
        let outcome = store.open(opened)
        let message = Self.message(for: outcome, handover: opened.handover)
        switch outcome {
        case .added, .replaced, .alreadyHeld, .olderThanHeld:
            presented = Presented(id: opened.handover.handoverId, message: message)
            startHeartbeat()
            return OpenReport(outcome: outcome, message: message, shown: true)
        case .conflicting, .full, .couldNotSave:
            return OpenReport(outcome: outcome, message: message, shown: false)
        }
    }

    static func message(for outcome: AssistingHandoverStore.OpenOutcome, handover: ExpertHandover) -> String {
        let from = handover.organisation.name.isEmpty ? "" : " from \(handover.organisation.name)"
        switch outcome {
        case .added:
            return "Job handover\(from) opened. Tap Take this job to start your clock."
        case .replaced(let changes):
            let what = changes.lines.isEmpty ? "" : " " + changes.lines.joined(separator: " ")
            return "Update \(handover.generation) replaced the earlier one.\(what)"
        case .alreadyHeld:
            return "You already have update \(handover.generation) of this handover."
        case .olderThanHeld(let held):
            return "That's an older update than the one you have (update \(held)), so yours was kept as it was."
        case .conflicting:
            return "That file says it updates a handover you hold, but it comes from someone else, so it wasn't opened."
        case .full:
            return "This phone is holding as many handovers as it keeps. Delete some you're done with, then open it again."
        case .couldNotSave:
            return "The handover couldn't be saved on this phone. Try opening it again."
        }
    }

    // MARK: - The clock

    func take(_ id: String) { store.take(id: id); startHeartbeat(); watchCalls() }
    func pause(_ id: String) { store.pause(id: id) }
    func resume(_ id: String) { store.resume(id: id); startHeartbeat(); watchCalls() }
    func done(_ id: String) { store.done(id: id) }

    // MARK: - Calls while a clock runs (Plan KM P4)

    /// Start watching the phone's calls once a clock runs: a call taken while exactly one handover's
    /// clock is running is that handover's call minutes. `CXCallObserver` needs no permission and
    /// never says who was called.
    func watchCalls() {
        guard callObserver == nil, store.hasRunningClock else { return }
        let observer = makeCallObserver()
        observer.onChange = { [weak self] call in self?.callChanged(call) }
        callObserver = observer
    }

    func callChanged(_ call: ObservedCall) {
        guard let completed = calls.observe(call, at: now(), running: store.runningClockIds) else { return }
        store.recordObservedCall(id: completed.handoverId, call: completed.call)
    }

    private var heartbeat: Task<Void, Never>?

    /// A checkpoint a minute while any clock runs, so a kill loses at most a minute.
    func startHeartbeat() {
        guard heartbeat == nil, store.hasRunningClock else { return }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard self.store.hasRunningClock else { self.heartbeat = nil; return }
                self.store.checkpointRunningClocks()
            }
        }
    }

    /// The app is leaving the foreground: the last sign of life it can promise.
    func appWillResignActive() {
        store.checkpointRunningClocks()
    }

    func appDidBecomeActive() {
        startHeartbeat()
        watchCalls()
    }

    // MARK: - The time reply

    /// The reply for a handover the expert is done with, for the sheet to show. Nothing is written
    /// and nothing leaves.
    func reply(for id: String, note: String?) -> Result<ExpertTimeReply, ExpertTimeReply.Refusal>? {
        guard let held = store.handover(id: id) else { return nil }
        return ExpertTimeReply.build(for: held, card: cards.card, note: note, now: now())
    }

    /// Why the reply could not be staged, in the words the view shows.
    struct Refusal: Error, Equatable {
        let message: String
        init(_ message: String) { self.message = message }
    }

    struct StagedReply {
        let reply: ExpertTimeReply
        let lease: StagedExportLease
    }

    /// The expert tapped Send reply: write the file into protected staging for the share sheet.
    /// Still nothing has left — the share sheet's own Send is the tap that sends.
    func stageReply(for id: String, note: String?) -> Result<StagedReply, Refusal> {
        guard let result = reply(for: id, note: note) else { return .failure(Refusal("That handover is no longer on this phone.")) }
        let reply: ExpertTimeReply
        switch result {
        case .failure(.notTaken): return .failure(Refusal("Tap Take this job first; the reply carries your time."))
        case .failure(.notDone): return .failure(Refusal("Tap Done first; the reply carries your time to the minute you finished."))
        case .success(let built): reply = built
        }
        do {
            let data = try ExpertTimeReplyFile.write(reply)
            let name = ExpertTimeReplyFile.fileName(reply)
            let lease = try replies.makeLease(data: data, fileExtension: ExpertHandoverFile.fileExtension,
                                              displayName: name, fallbackName: "time-reply.ogcase")
            PrivacyLog.transfer(.assistingReply, .exported, count: 1)
            return .success(StagedReply(reply: reply, lease: lease))
        } catch {
            PrivacyLog.transfer(.assistingReply, .fileFailed, error: SafeErrorSummary(error))
            return .failure(Refusal("The reply couldn't be written on this phone. Try again."))
        }
    }

    func beginShare(_ staged: StagedReply) { replies.beginShare(staged.lease) }

    /// The share sheet closed. Only a completed share marks the reply sent.
    func finishShare(_ staged: StagedReply, for id: String, completed: Bool) {
        replies.finishShare(staged.lease, outcome: completed ? .completed : .cancelled)
        if completed {
            store.markReplySent(id: id)
            // The expert's own ledger is built from the replies they sent, and only those.
            ledger.record(staged.reply, sentAt: now())
        }
    }

    // MARK: - The ledger (Plan KM P4)

    struct StagedLedger {
        let lease: StagedExportLease
        let rows: Int
    }

    /// One organisation's month of the ledger, as CSV or PDF, into protected staging for the
    /// expert's own share. One organisation per file, always.
    func stageLedger(organisation key: String, month: CalendarMonth, pdf: Bool,
                     calendar: Calendar = .current) -> Result<StagedLedger, Refusal> {
        let ledger = ledger.ledger
        let rows = ledger.rows(organisation: key, month: month, calendar: calendar)
        guard !rows.isEmpty else { return .failure(Refusal("There's no time for that organisation in that month.")) }
        let document = ledger.document(organisation: key, month: month, calendar: calendar, preparedAt: now())
        let ext = pdf ? "pdf" : "csv"
        do {
            let lease = try replies.makeLease(data: pdf ? document.pdfData() : document.csvData, fileExtension: ext,
                                              displayName: ledger.fileStem(organisation: key, month: month) + "." + ext,
                                              fallbackName: "time-ledger." + ext)
            PrivacyLog.transfer(.assistingReply, .exported, count: rows.count)
            return .success(StagedLedger(lease: lease, rows: rows.count))
        } catch {
            PrivacyLog.transfer(.assistingReply, .fileFailed, error: SafeErrorSummary(error))
            return .failure(Refusal("The ledger couldn't be written on this phone. Try again."))
        }
    }

    func beginShare(_ staged: StagedLedger) { replies.beginShare(staged.lease) }

    func finishShare(_ staged: StagedLedger, completed: Bool) {
        replies.finishShare(staged.lease, outcome: completed ? .completed : .cancelled)
    }

    // MARK: - The note

    /// The note for the time reply as far as the expert has written it (kept across a relaunch).
    func noteDraft(for id: String) -> String { store.handover(id: id)?.noteDraft ?? "" }

    func saveNote(_ note: String, for id: String) { store.setNoteDraft(id: id, note: note) }

    // MARK: - Coaching steps (Plan KM §5, P3)

    /// The steps the expert has written for this handover, in order.
    func coachingSteps(for id: String) -> [CoachingStep] { store.handover(id: id)?.coachingDraft ?? [] }

    /// Add a step, or replace the one with the same id. Returns why it can't be kept, or nil.
    @discardableResult
    func saveCoachingStep(_ step: CoachingStep, for id: String) -> String? {
        if let why = step.problem { return String(why.prefix(1)).uppercased() + String(why.dropFirst()) + "." }
        var steps = coachingSteps(for: id)
        if let index = steps.firstIndex(where: { $0.id == step.id }) {
            steps[index] = step
        } else {
            guard steps.count < CoachingStep.maxSteps else { return ExpertCoachingReply.Refusal.tooManySteps.message }
            steps.append(step)
        }
        store.setCoachingDraft(id: id, steps: steps)
        return nil
    }

    func moveCoachingSteps(for id: String, from source: IndexSet, to destination: Int) {
        store.setCoachingDraft(id: id, steps: Self.moved(coachingSteps(for: id), from: source, to: destination))
    }

    func deleteCoachingSteps(for id: String, at offsets: IndexSet) {
        let steps = coachingSteps(for: id).enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        store.setCoachingDraft(id: id, steps: steps)
    }

    /// The list a drag in the editor makes: the rows at `source` moved to before `destination`, as
    /// SwiftUI's `onMove` reports it. Pure.
    static func moved<T>(_ items: [T], from source: IndexSet, to destination: Int) -> [T] {
        let moving = source.filter { $0 < items.count }.map { items[$0] }
        var rest: [T] = []
        var insertAt = 0
        for (index, item) in items.enumerated() where !source.contains(index) {
            if index < destination { insertAt += 1 }
            rest.append(item)
        }
        rest.insert(contentsOf: moving, at: min(insertAt, rest.count))
        return rest
    }

    /// The coaching reply for the steps written so far, for the view to show. Nothing is written
    /// and nothing leaves.
    func coachingReply(for id: String) -> Result<ExpertCoachingReply, ExpertCoachingReply.Refusal>? {
        guard let held = store.handover(id: id) else { return nil }
        return ExpertCoachingReply.build(for: held, steps: held.coachingDraft ?? [], card: cards.card, now: now())
    }

    struct StagedCoaching {
        let reply: ExpertCoachingReply
        let lease: StagedExportLease
    }

    /// The expert tapped Send Coaching Steps: write the file into protected staging for the share
    /// sheet. Nothing has left yet — the share sheet's own Send is the tap that sends.
    func stageCoaching(for id: String) -> Result<StagedCoaching, Refusal> {
        guard let result = coachingReply(for: id) else { return .failure(Refusal("That handover is no longer on this phone.")) }
        let reply: ExpertCoachingReply
        switch result {
        case .failure(let refusal): return .failure(Refusal(refusal.message))
        case .success(let built): reply = built
        }
        do {
            let data = try ExpertCoachingReplyFile.write(reply)
            let lease = try replies.makeLease(data: data, fileExtension: ExpertHandoverFile.fileExtension,
                                              displayName: ExpertCoachingReplyFile.fileName(reply),
                                              fallbackName: "coaching.ogcase")
            PrivacyLog.transfer(.assistingReply, .exported, count: reply.steps.count)
            return .success(StagedCoaching(reply: reply, lease: lease))
        } catch {
            PrivacyLog.transfer(.assistingReply, .fileFailed, error: SafeErrorSummary(error))
            return .failure(Refusal("The coaching steps couldn't be written on this phone. Try again."))
        }
    }

    func beginShare(_ staged: StagedCoaching) { replies.beginShare(staged.lease) }

    /// The share sheet closed. Only a completed share marks the steps sent.
    func finishShare(_ staged: StagedCoaching, for id: String, completed: Bool) {
        replies.finishShare(staged.lease, outcome: completed ? .completed : .cancelled)
        if completed { store.markCoachingSent(id: id, coachingId: staged.reply.coachingId) }
    }

    // MARK: - Deleting

    func delete(_ id: String) {
        store.remove(id: id)
        if presented?.id == id { presented = nil }
    }
}
