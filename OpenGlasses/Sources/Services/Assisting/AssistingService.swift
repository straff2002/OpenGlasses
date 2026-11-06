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
/// - the **expert card** (`ExpertCardStore`).
///
/// Medical Compliance mode does not close it: holding a handover sent to you is not an egress, the
/// view is read-only, and the only thing that leaves is the expert's own reply by their own share.
@MainActor
final class AssistingService: ObservableObject {

    static let shared = AssistingService()

    let store: AssistingHandoverStore
    let cards: ExpertCardStore
    private let replies: StagedExportCoordinator
    private let now: () -> Date

    /// A handover the app just opened, for the sheet that shows it.
    @Published var presented: Presented?

    struct Presented: Identifiable, Equatable {
        let id: String
        /// What opening it said: "Update 2 replaced the earlier one: 2 new readings."
        let message: String
    }

    init(store: AssistingHandoverStore? = nil, cards: ExpertCardStore = .shared,
         replies: StagedExportCoordinator = .assistingReply, now: @escaping () -> Date = Date.init) {
        self.store = store ?? .shared
        self.cards = cards
        self.replies = replies
        self.now = now
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

    func take(_ id: String) { store.take(id: id); startHeartbeat() }
    func pause(_ id: String) { store.pause(id: id) }
    func resume(_ id: String) { store.resume(id: id); startHeartbeat() }
    func done(_ id: String) { store.done(id: id) }

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
        if completed { store.markReplySent(id: id) }
    }

    // MARK: - Deleting

    func delete(_ id: String) {
        store.remove(id: id)
        if presented?.id == id { presented = nil }
    }
}
