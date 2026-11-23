import Foundation

/// One meeting to write notes for.
struct MeetingNotesRequest: Sendable {
    /// The saved note's meeting id, and the owed record's.
    let id: UUID
    /// Oldest first; a diarized line starts with its speaker's name.
    let lines: [OwedMeetingNotes.Line]
    let startedAt: Date
    let endedAt: Date
    /// Lines the session no longer held when the summary was made.
    var droppedLines: Int = 0
    /// Whether the summary is saved as a note — the only case notes may be owed for.
    let saving: Bool
}

/// What became of a request, or of a write.
enum MeetingNotesOutcome: Equatable, Sendable {
    /// The model wrote them (a write's result; a summary inside a turn never waits for one).
    case written(MeetingNotes)
    /// To be written by the model as soon as the turn that asked is over; the phone's notes stand
    /// until then.
    case queued
    /// Held for later (`MeetingNotesOwedStore`); the phone's notes stand meanwhile.
    case owed(MeetingNotesOweReason)
    /// The phone's notes, and nothing owed.
    case fallback(MeetingNotesFallbackReason)

    /// Fuller notes from the model are still to come.
    var isPending: Bool {
        switch self {
        case .queued, .owed: return true
        case .written, .fallback: return false
        }
    }
}

/// Writes meeting notes with the model, after the turn that asked for them, and writes owed ones
/// when it can (Plan MX P4–P6).
///
/// The model call is the app's (`configure`): the same stateless, tool-free completion the meeting
/// assistant's rounds go through, so HIPAA mode, Medical Local Only and the active model apply
/// exactly as they do there. Until it is configured — and in tests that do not configure it —
/// every request takes the phone's notes.
///
/// **Never inside a turn.** A summary is asked for by a tool call while its turn waits, and a
/// model pass over a whole meeting can take minutes, so `queue` decides and queues, and never
/// calls the model: the turn answers at once with the phone's notes and the transcript excerpt.
/// (The stateless call runs in a history of its own, so a turn beside it is safe; holding the
/// write back keeps the model, and an on-device model's memory, free for the wearer's turn.) The write runs once no turn is
/// in flight (`writeOwed`), one meeting and one model step at a time; before every step it checks
/// again, and a turn that has started meanwhile stops the write after the step already running
/// (which is always awaited to its end, never abandoned), leaving the meeting queued or owed to
/// resume from that step once the turn is over.
///
/// A queued write is held in memory always, and in the owed store exactly when it may be
/// (`MeetingNotesOwedPolicy`), so a kill or a stop before it is written is recovered at the next
/// foreground. Owed notes are also written when the app comes to the front.
@MainActor
final class MeetingNotesService {

    static let shared = MeetingNotesService()

    struct Environment {
        /// The model: system and user prompt in, reply out.
        var complete: MeetingNotesWriter.Complete
        /// Where the call would go now.
        var route: @MainActor () -> MeetingNotesRoutePolicy.Inputs
        var keepCaptionSessions: @MainActor () -> Bool = { Config.keepCaptionSessions }
        var medicalCompliance: @MainActor () -> Bool = { Config.hipaaMode }
        /// A conversation turn is running.
        var turnInFlight: @MainActor () -> Bool = { false }
        /// Notes were written: complete the saved note, its action items and the latest summary
        /// with them.
        var completeNote: @MainActor (OwedMeetingNotes, MeetingNotes) -> Void = { _, _ in }
    }

    /// One meeting queued in this process to be written once the turn is over.
    private struct Queued {
        var record: OwedMeetingNotes
        /// Also held in the owed store; gone from there means erased or pruned, and it goes.
        let held: Bool
    }

    private(set) var environment: Environment?
    private let injectedStore: MeetingNotesOwedStore?
    private lazy var store: MeetingNotesOwedStore = injectedStore ?? .shared
    private var waiting: [Queued] = []
    /// How far a stopped write got, by meeting, to resume from (in memory only).
    private var progress: [UUID: MeetingNotesWriter.Progress] = [:]
    private var draining = false

    /// How long a write waits for a turn to end before it gives up for now, in steps.
    var turnWaitStep: Double = 2
    var turnWaitSteps = 300

    init(store: MeetingNotesOwedStore? = nil) {
        injectedStore = store
    }

    func configure(_ environment: Environment) {
        self.environment = environment
    }

    var isConfigured: Bool { environment != nil }

    /// The meetings queued to be written after the turn, oldest first.
    var queuedIDs: [UUID] { waiting.map(\.record.id) }

    // MARK: - Inside a turn

    /// What becomes of `request`'s notes, decided without calling the model. A `.queued` meeting
    /// is written once `startQueuedWrites` is called and the turn is over; the caller saves its
    /// note first, so the write has a note to complete.
    func queue(_ request: MeetingNotesRequest) -> MeetingNotesOutcome {
        guard let environment else { return fallback(.notConfigured, request) }
        guard !request.lines.isEmpty else { return fallback(.emptyReply, request) }
        let mayHold = MeetingNotesOwedPolicy.mayHold(saving: request.saving,
                                                     keepCaptionSessions: environment.keepCaptionSessions(),
                                                     medicalCompliance: environment.medicalCompliance())
        switch MeetingNotesRoutePolicy.decide(environment.route()) {
        case .fallback(let reason):
            return fallback(reason, request)
        case .owe(let reason):
            guard mayHold, store.hold(record(request, state: .owed, reason: reason)) else {
                return fallback(.cannotRunNow, request)
            }
            PrivacyLog.store(.meetingNotes, .saved, count: request.lines.count, detail: PrivacyToken(reason.rawValue))
            return .owed(reason)
        case .writeNow:
            let owed = record(request, state: .owed, reason: .afterTurn)
            let held = mayHold && store.hold(owed)
            waiting.removeAll { $0.record.id == request.id }
            waiting.append(Queued(record: owed, held: held))
            PrivacyLog.store(.meetingNotes, .saved, count: request.lines.count,
                             detail: PrivacyToken(MeetingNotesOweReason.afterTurn.rawValue))
            return .queued
        }
    }

    /// Start writing what is queued, without waiting for it: the write waits for the turn that
    /// asked to be over, and the turn must not wait for the write.
    func startQueuedWrites() {
        guard !waiting.isEmpty else { return }
        Task { @MainActor [weak self] in await self?.writeOwed(trigger: "afterTurn") }
    }

    // MARK: - After the turn

    /// Write every queued and owed meeting the model can write now: this process's queue first,
    /// then the store's, oldest first. Returns how many were written. Waits (boundedly) for a turn
    /// in flight to end before each meeting; stops when the route will not take a call now, or
    /// when a turn outlasts the wait, leaving the rest queued or owed.
    @discardableResult
    func writeOwed(trigger: String) async -> Int {
        guard environment != nil, !draining else { return 0 }
        draining = true
        defer { draining = false }
        var written = 0
        var tried: Set<UUID> = []
        while let next = nextToWrite(excluding: tried) {
            guard let environment, MeetingNotesRoutePolicy.decide(environment.route()) == .writeNow else { break }
            guard await waitForNoTurn() else { break }
            // Still to be written after the wait (an erasure, the switch or a settle may have taken it).
            guard let target = current(next.record.id, held: next.held) else {
                tried.insert(next.record.id)
                continue
            }
            switch await write(target, trigger: trigger) {
            case .written:
                written += 1
                tried.insert(target.record.id)
            case .failed:
                tried.insert(target.record.id)
            case .stopped:
                // A turn started, or the route changed: resume from the same step once it allows.
                continue
            }
        }
        store.prune()
        return written
    }

    // MARK: - One write

    private enum WriteResult { case written, stopped, failed }

    private func write(_ target: Queued, trigger: String) async -> WriteResult {
        guard let environment else { return .stopped }
        let record = target.record
        let id = record.id
        if target.held { store.update(id: id) { $0.state = .writing; $0.attempts += 1 } }
        let lines = record.lines.map(\.text)
        let inputs = environment.route()
        let script = MeetingNotesBudget.script(of: lines.prefix(200).joined(separator: "\n"))
        let budget = MeetingNotesBudget.characters(contextTokens: inputs.contextTokens, script: script)
        let writer = MeetingNotesWriter(complete: environment.complete)
        do {
            let written = try await writer.write(lines: lines, budget: budget, resuming: progress[id],
                                                 mayStep: { [weak self] in await self?.mayStep() ?? false })
            progress[id] = nil
            dequeue(id)
            environment.completeNote(record, written.notes)
            if target.held { store.settle(id: id) }
            log(written, lines: lines, detail: trigger == "afterTurn" ? "writtenAfterTurn" : "writtenLater")
            return .written
        } catch let stopped as MeetingNotesWriter.Stopped {
            progress[id] = stopped.progress
            // A stop is not a failed attempt.
            if target.held { store.update(id: id) { $0.state = .owed; $0.attempts = max(0, $0.attempts - 1) } }
            PrivacyLog.store(.meetingNotes, .saved, count: stopped.progress.calls, detail: PrivacyToken("stopped"))
            return .stopped
        } catch {
            progress[id] = nil
            dequeue(id)
            if target.held { store.update(id: id) { $0.state = .owed } }
            PrivacyLog.store(.meetingNotes, .writeFailed, detail: PrivacyToken(trigger),
                             error: SafeErrorSummary(error))
            return .failed
        }
    }

    /// Asked before every model step: no turn in flight, and the route still writes now.
    private func mayStep() -> Bool {
        guard let environment else { return false }
        return !environment.turnInFlight() && MeetingNotesRoutePolicy.decide(environment.route()) == .writeNow
    }

    /// Wait for a turn in flight to end, at most `turnWaitSteps` steps. False when it did not.
    private func waitForNoTurn() async -> Bool {
        var waited = 0
        while environment?.turnInFlight() ?? false {
            guard waited < turnWaitSteps else { return false }
            try? await Task.sleep(nanoseconds: UInt64(turnWaitStep * 1_000_000_000))
            waited += 1
        }
        return environment != nil
    }

    // MARK: - Helpers

    private func nextToWrite(excluding tried: Set<UUID>) -> Queued? {
        if let queued = waiting.first(where: { !tried.contains($0.record.id) }) { return queued }
        let inMemory = Set(queuedIDs)
        return store.pending
            .first { !tried.contains($0.id) && !inMemory.contains($0.id) }
            .map { Queued(record: $0, held: true) }
    }

    /// The meeting as it stands now: a held one only while the store still has it.
    private func current(_ id: UUID, held: Bool) -> Queued? {
        guard held else { return waiting.first { $0.record.id == id } }
        guard let stored = store.record(id: id) else {
            dequeue(id)
            progress[id] = nil
            return nil
        }
        return Queued(record: stored, held: true)
    }

    private func dequeue(_ id: UUID) {
        waiting.removeAll { $0.record.id == id }
    }

    private func record(_ request: MeetingNotesRequest, state: OwedMeetingNotes.State,
                        reason: MeetingNotesOweReason) -> OwedMeetingNotes {
        OwedMeetingNotes(id: request.id, startedAt: request.startedAt, endedAt: request.endedAt,
                         lines: request.lines, droppedLines: request.droppedLines, state: state, reason: reason)
    }

    private func fallback(_ reason: MeetingNotesFallbackReason, _ request: MeetingNotesRequest,
                          error: Error? = nil) -> MeetingNotesOutcome {
        PrivacyLog.store(.meetingNotes, .saveSkipped, count: request.lines.count,
                         detail: PrivacyToken(reason.rawValue), error: error.map { SafeErrorSummary($0) })
        return .fallback(reason)
    }

    /// Counts only: how many action items and decisions, how many calls, how long the transcript.
    private func log(_ written: MeetingNotesWriter.Written, lines: [String], detail: String) {
        PrivacyLog.store(.meetingNotes, .recordWritten, count: written.notes.actionItems.count,
                         total: written.calls,
                         characters: lines.reduce(0) { $0 + $1.count },
                         detail: PrivacyToken(detail))
    }
}

extension MeetingNotesService {
    /// The context window of `config`, where the app knows it (`ModelContextWindow`), as the
    /// meeting summary's excerpt budget reads it.
    static func contextTokens(for config: ModelConfig) -> Int? {
        let catalogContext = config.llmProvider == .chatgpt
            ? ChatGPTContextCatalog.context(model: config.model, accountID: ChatGPTOAuthService.shared.accountID)
            : nil
        return ModelContextWindow.resolve(provider: config.llmProvider, model: config.model,
                                          baseURL: config.baseURL, chatGPTCatalogContext: catalogContext)?.tokens
    }
}
