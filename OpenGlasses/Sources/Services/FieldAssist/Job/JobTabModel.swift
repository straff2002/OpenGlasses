import Foundation

/// The slice of `FieldSessionService` the Job tab needs, beyond the work record's own
/// (`WorkRecordHosting`): the past-job list, the vault in use, and the two billing controls.
///
/// A protocol for the same reason `EquipmentHosting` and `WorkRecordHosting` are: every screen the
/// tab draws is then provable without a vault, a session, or SwiftUI.
@MainActor
protocol JobTabHosting: WorkRecordHosting {
    var history: [FieldSession] { get }
    var activeVault: VaultStore? { get }
    func pauseSession() throws -> FieldSession
    func resumeSession() throws -> FieldSession

    // Evidence (Plan FO P2a). On the protocol rather than reached for, so "close job writes the
    // selection before it ends the session" is a spy assertion rather than a reading of the code.
    var jobMedia: [JobMediaItem] { get }
    func evidenceSelection() -> EvidenceSelection
    func setEvidenceSelection(_ selection: EvidenceSelection)
    func photosDirectory(sessionId: String) -> URL
    func media(sessionId: String) -> [JobMediaItem]

    // Customer sign-off (Plan FO P2c). On the protocol for the same reason the evidence seams are:
    // "the close writes the signature before it takes the record" and "sign-off sends nothing" are
    // assertions a spy can make rather than readings of the code.
    var customerSignOffRequired: Bool { get }
    func signOff(sessionId: String) -> CustomerSignOff?
    func signOffIsStillOpen(sessionId: String) -> Bool
    @discardableResult
    func recordSignOff(_ signOff: CustomerSignOff, pngData: Data?, strokeData: Data?,
                       sessionId: String?) -> CustomerSignOff?
    func logSignOffCancelled(sessionId: String?)
    func signatureURL(sessionId: String, imageId: String) -> URL

    // Debriefs (Plan FO P3b). On the protocol for the same reason the sign-off seams are: "the
    // work order a customer already holds is unchanged by an addendum" is an assertion a spy can
    // make about what the page asked for.
    func debriefs(sessionId: String) -> [JobDebrief]
    func reportWasSent(sessionId: String) -> Bool
}

extension FieldSessionService: JobTabHosting {}

/// The slice of `GuidedJobFlow` the Job tab drives (Plan FO P1's named seams).
///
/// The tab never starts, closes, re-scopes or re-threads a job itself — every one of those goes
/// through the flow, which is the app's single chokepoint for a job's conversation. Stating that as
/// a protocol is what lets a test prove the tab *delegates* rather than re-implements: a spy counts
/// the calls, and "close job closes exactly one job" is an assertion rather than a hope.
@MainActor
protocol JobFlowHosting: AnyObject {
    var intakeState: JobIntakeState { get }
    var boundThreadId: String? { get }
    var pendingUnitQuestion: JobUnitChangeQuestion? { get }

    @discardableResult
    func startJob(vaultId: String, assetId: String?, mode: FieldSession.Mode,
                  jobReference: String?) throws -> FieldSession
    @discardableResult
    func closeJob(outcome: FieldSession.Outcome) throws -> FieldSession
    func supplyJobReference(_ text: String)
    func declineJobReference()
    func answerUnitChange(_ answer: JobUnitChangeAnswer) async
    func raiseLeaveJobThreadQuestion(switchingTo threadId: String?) -> JobThreadQuestion?
    func confirmLeaveJobThread()
    @discardableResult
    func requestResume(threadId: String, confirmed: Bool) -> JobThreadQuestion?
}

extension GuidedJobFlow: JobFlowHosting {}

/// What the Job tab draws and what its controls do, decided without SwiftUI (Plan FO P2).
///
/// The tab is a **dashboard and explicit controls**, not a second chat surface: the Voice tab stays
/// the way work is captured, and nothing here duplicates the wake-word row (that lives in Field
/// Assist settings). What it adds is the moments voice fails — a noisy plant room, a customer
/// standing there, a number the recogniser keeps mishearing — where the technician needs a button.
///
/// Everything is derived, nothing is stored: the state, the rows, the button enablement, the intake
/// wording and the question cards all come from `FieldSessionService` and `GuidedJobFlow` on each
/// read, in the same shape `TaskSectionModel` already uses. A struct rather than an observable
/// object, for the same reason: the two services are the observable things, and a model that cached
/// them would be a third copy of the truth.
@MainActor
struct JobTabModel {

    // MARK: - The three states

    enum State: Equatable {
        /// No job is open. The tab offers the vault, Start job, and the past-job list.
        case noJob(NoJob)
        /// A job is open and accepting work.
        case running(Active)
        /// A job is open and paused. **Still the job** — the binding, the intake and a held unit
        /// question all belong to a job that has not ended, and launch-restore pauses every
        /// recovered session on purpose (Plan FO P1).
        case paused(Active)

        /// The open job, whether it is running or paused.
        var active: Active? {
            switch self {
            case .noJob: return nil
            case .running(let job), .paused(let job): return job
            }
        }
    }

    /// The empty state: which vault a new job would use, and whether one can be started at all.
    struct NoJob: Equatable {
        let vaultId: String
        let vaultName: String
        let vaultUnlocked: Bool

        var canStart: Bool { vaultUnlocked }

        /// Why Start job is unavailable, in the vault's own terms. Nil when it is available —
        /// a disabled button with no reason beside it is a dead end.
        var startBlockedReason: String? {
            vaultUnlocked ? nil
                : "\(vaultName) is locked. Unlock it under Settings → Field Assist before starting a job."
        }
    }

    /// The open job, as the tab shows it.
    struct Active: Equatable {
        let sessionId: String
        let vaultName: String
        /// The number as it was given, when one was. Never invented and never reformatted.
        let jobNumber: String?
        let intake: IntakeCopy
        let isPaused: Bool
        let outcomeLabel: String
        let startedAt: Date
        let startedLine: String
        /// Time on the job, in whatever the organisation bills in. **Display only** — the phrase
        /// is the work record's own, so the screen and the PDF cannot disagree.
        let elapsedLine: String
        /// A coarser sentence for VoiceOver, so focusing the row says something useful without
        /// the value churning under the cursor.
        let elapsedSpoken: String
        /// The machine the job is on right now, when one has been recognised.
        let currentUnit: String?
        /// Every unit this job has covered, current one included, in the order they were first
        /// seen. One job may legitimately span several.
        let visitedUnits: [String]
        /// Whether the job owns a conversation that can be opened.
        let hasConversation: Bool
        /// Whether there is a record to read back or send yet.
        let hasRecord: Bool
        /// How many photos the job has collected so far (Plan FO P2a). Shown on the page, and
        /// what decides whether closing puts the evidence review in front of the technician.
        let photoCount: Int

        var pauseButtonTitle: String { isPaused ? "Resume job" : "Pause job" }

        /// What pausing means, said plainly: this is the billing clock, not the microphone.
        var pauseFootnote: String {
            isPaused
                ? "Paused — time on the job has stopped counting."
                : "Time on the job is counting."
        }

        var unitLine: String {
            currentUnit ?? "No machine recorded yet"
        }
    }

    // MARK: - The job number

    /// Where the job number stands, in the words the tab shows — one case of `JobIntakeState` per
    /// line, so a technician always knows whether the app is waiting on them or the other way
    /// round. The number itself is never reformatted (Plan FO P1).
    struct IntakeCopy: Equatable {
        /// The big line: the number, or what is standing in for it.
        let headline: String
        /// The quieter sentence under it, when there is something to explain.
        let detail: String?
        /// Whether the job still owes a number.
        let isOutstanding: Bool
        /// Whether "I don't have one" is still worth offering. Never after it has been answered.
        let offersDecline: Bool
        /// What the text field says before anything is typed.
        let fieldPrompt: String
        /// The whole thing as one sentence, for VoiceOver.
        let spoken: String

        static func make(_ state: JobIntakeState) -> IntakeCopy {
            switch state {
            case .recorded(let reference):
                return IntakeCopy(headline: "Job \(reference)",
                                  detail: nil,
                                  isOutstanding: false,
                                  offersDecline: false,
                                  fieldPrompt: "Change the job number",
                                  spoken: "Job number \(reference). Tap to change it.")
            case .declined:
                return IntakeCopy(headline: "No job number",
                                  detail: "Recorded as \u{201C}no job number\u{201D}. The report still goes out.",
                                  isOutstanding: false,
                                  offersDecline: false,
                                  fieldPrompt: "Change the job number",
                                  spoken: "No job number. It was recorded as not having one, and the report still goes out.")
            case .notRequired:
                return IntakeCopy(headline: "No job number",
                                  detail: "This job was never asked for one. You can type it in.",
                                  isOutstanding: false,
                                  offersDecline: false,
                                  fieldPrompt: "Change the job number",
                                  spoken: "No job number. This job was never asked for one; you can type it in.")
            case .needsReference:
                return IntakeCopy(headline: "Job number not recorded",
                                  detail: "Type it in, or wait — it will be asked for out loud.",
                                  isOutstanding: true,
                                  offersDecline: true,
                                  fieldPrompt: "Type the job number",
                                  spoken: "Job number not recorded. Type it in, or wait to be asked out loud.")
            case .asked:
                return IntakeCopy(headline: "Job number — asked, waiting",
                                  detail: "Say it, or type it here.",
                                  isOutstanding: true,
                                  offersDecline: true,
                                  fieldPrompt: "Type the job number",
                                  spoken: "Job number asked for, waiting for an answer. Say it, or type it here.")
            case .confirming(let candidate, _):
                return IntakeCopy(headline: "Heard \u{201C}\(candidate)\u{201D}",
                                  detail: "Say yes to confirm, or type the right one.",
                                  isOutstanding: true,
                                  offersDecline: true,
                                  fieldPrompt: "Type the job number",
                                  spoken: "Heard job number \(candidate). Say yes to confirm, or type the right one.")
            case .outstanding:
                return IntakeCopy(headline: "Job number still outstanding",
                                  detail: "It wasn't heard clearly. Type it here — you won't be asked again.",
                                  isOutstanding: true,
                                  offersDecline: true,
                                  fieldPrompt: "Type the job number",
                                  spoken: "Job number still outstanding. It wasn't heard clearly; type it here.")
            }
        }
    }

    // MARK: - The two questions, as cards

    /// A question the app has put, rendered so it can be answered by tap.
    ///
    /// The message is **the sentence P1 speaks**, verbatim: a technician who half-heard it through
    /// a respirator should find the same words on the screen, not a paraphrase of them.
    struct QuestionCard: Equatable, Identifiable {
        struct Action: Equatable, Identifiable {
            let id: String
            let title: String
            let answer: JobUnitChangeAnswer
            /// True for the one that ends a job — the view gives it a confirming role.
            var isDestructive: Bool { answer == .jobFinished }
        }

        let id: String
        let title: String
        let message: String
        let actions: [Action]

        static func unitChange(_ question: JobUnitChangeQuestion) -> QuestionCard {
            QuestionCard(
                id: "unit-change." + question.candidate.heading,
                title: "Different unit?",
                message: question.spoken,
                actions: [
                    Action(id: "same", title: "Same job — another unit", answer: .sameJob),
                    Action(id: "finished", title: "That job's finished", answer: .jobFinished),
                    Action(id: "unsure", title: "Not sure", answer: .unsure)
                ])
        }
    }

    /// The other question: leaving the job's conversation. Two answers, both the technician's.
    struct ThreadQuestionCard: Equatable {
        let message: String
        let keepTitle = "Keep it in the job"
        let leaveTitle = "Start a separate chat"

        init(_ question: JobThreadQuestion) { message = question.spoken }
    }

    // MARK: - Past jobs

    /// One finished job, as the list shows it.
    struct PastJobRow: Identifiable, Equatable {
        let id: String
        /// "Job 1005", or "No job number" — **never blank**. A visit with no number is a real
        /// visit, and a row that renders as an empty line is a row nobody can tap with confidence.
        let jobNumber: String
        let hasJobNumber: Bool
        let vaultName: String
        let dateLine: String
        let outcomeLabel: String
        let equipment: String?
        let billingLine: String
        let startedAt: Date
        /// Everything the search box matches against, already lowercased.
        let searchKey: String

        /// What VoiceOver reads for the whole row, in one sentence.
        var spoken: String {
            var parts = [jobNumber, vaultName, dateLine, outcomeLabel]
            if let equipment { parts.append(equipment) }
            parts.append(billingLine)
            return parts.joined(separator: ", ")
        }
    }

    /// A finished job opened from the list: its record, its conversation, and a way to send it
    /// again.
    struct PastJob: Equatable {
        let sessionId: String
        let jobNumber: String
        let hasJobNumber: Bool
        let vaultName: String
        let dateLine: String
        let outcomeLabel: String
        let visitedUnits: [String]
        /// The record exactly as the export renders it — the same lines, in the same order.
        let summaryLines: [String]
        let billingLine: String
        /// The conversation the job owned, when it still exists. Read-only from here: opening it
        /// must never make it the thread the next turn lands in.
        let threadId: String?
        /// The record itself, for the re-send.
        let record: WorkRecord
    }

    /// The blank a past job's value cannot be.
    static let noJobNumber = "No job number"

    // MARK: - Construction

    /// The settings a new job is started from, and the vault vocabulary the rows need. Injected so
    /// a test states them rather than writing preferences and hoping a registry reads them.
    @MainActor
    struct Defaults {
        var vaultId: () -> String = { Config.fieldAssistDefaultVaultId }
        var mode: () -> FieldSession.Mode = {
            FieldSession.Mode(rawValue: UserDefaults.standard.string(forKey: "fieldAssistDefaultMode")
                              ?? FieldSession.Mode.aiOnly.rawValue) ?? .aiOnly
        }
        var vaultName: (String) -> String = { VaultRegistry.shared.manifest(id: $0)?.name ?? $0 }
        var vaultUnlocked: (String) -> Bool = { VaultRegistry.shared.isUnlocked($0) }
    }

    private let host: JobTabHosting
    private let flow: JobFlowHosting
    private let defaults: Defaults

    init(host: JobTabHosting, flow: JobFlowHosting, defaults: Defaults) {
        self.host = host
        self.flow = flow
        self.defaults = defaults
    }

    /// The app's own settings and vault registry. Spelled as a second initialiser rather than a
    /// default argument because a default is evaluated outside the actor, and every one of these
    /// closures reads main-actor state.
    init(host: JobTabHosting, flow: JobFlowHosting) {
        self.init(host: host, flow: flow, defaults: Defaults())
    }

    // MARK: - State

    /// The open job, whether running or paused. **Keyed on `endedAt`, not `isActive`** — a paused
    /// job is still the job, and a cancelled one is not open at all.
    private var openSession: FieldSession? {
        guard let session = host.activeSession,
              session.endedAt == nil, session.outcome != .cancelled else { return nil }
        return session
    }

    var state: State {
        guard let session = openSession else {
            let id = defaults.vaultId()
            return .noJob(NoJob(vaultId: id,
                                vaultName: defaults.vaultName(id),
                                vaultUnlocked: defaults.vaultUnlocked(id)))
        }
        let job = active(for: session)
        return session.pausedAt == nil ? .running(job) : .paused(job)
    }

    private func active(for session: FieldSession) -> Active {
        let record = host.workRecord()
        let units = visitedUnitNames(of: session)
        return Active(
            sessionId: session.id,
            vaultName: host.activeVault?.manifest.name ?? defaults.vaultName(session.vaultId),
            jobNumber: session.jobReference.flatMap { $0.isEmpty ? nil : $0 },
            intake: IntakeCopy.make(flow.intakeState),
            isPaused: session.pausedAt != nil,
            outcomeLabel: session.outcome.displayName,
            startedAt: session.startedAt,
            startedLine: "Started \(session.startedAt.formatted(date: .omitted, time: .shortened))",
            elapsedLine: Self.elapsed(record: record, session: session),
            elapsedSpoken: "Time on the job, \(Self.elapsed(record: record, session: session))",
            currentUnit: session.equipment?.modelToken,
            visitedUnits: units,
            hasConversation: flow.boundThreadId != nil,
            hasRecord: record != nil,
            photoCount: host.jobMedia.count)
    }

    /// Time on the job, from the record's own arithmetic and nothing else.
    ///
    /// Minute-grained on purpose. The record's exact seconds go in the export; a live screen that
    /// re-renders a second counter is a value VoiceOver re-reads under the cursor and a number
    /// nobody was asking for. `billableMinutes` and `billableUnits` are both the record's fields.
    private static func elapsed(record: WorkRecord?, session: FieldSession) -> String {
        guard let record else { return WorkRecord.minutesPhrase(minutes: 0) }
        if session.billingBasis == .units, let units = record.billableUnits {
            return WorkRecord.unitPhrase(units)
        }
        return WorkRecord.minutesPhrase(minutes: record.billableMinutes)
    }

    /// The current machine first, then every other unit the job has been on, without repeats.
    private func visitedUnitNames(of session: FieldSession) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for token in [session.equipment?.modelToken].compactMap({ $0 })
            + session.visitedUnits.map(\.modelToken) where seen.insert(token).inserted {
            names.append(token)
        }
        return names
    }

    // MARK: - Questions

    /// The change-of-unit question, when one is outstanding. Read straight off the flow's published
    /// property — no side effect, so a view body may ask on every pass.
    var unitQuestion: QuestionCard? {
        flow.pendingUnitQuestion.map(QuestionCard.unitChange)
    }

    /// Raise the "leaving the job's conversation" question, or nil when leaving asks nothing.
    ///
    /// **An action, not a query**, despite its shape: it is what puts the question, and the flow
    /// writes that into the audit log. Called from a tap, never from a view body. (P2 worked
    /// around a flow that logged from the *query* as well; P2a split the two, so the query beside
    /// this one is now safe anywhere.)
    func leaveThreadQuestion() -> ThreadQuestionCard? {
        flow.raiseLeaveJobThreadQuestion(switchingTo: nil).map(ThreadQuestionCard.init)
    }

    func confirmLeaveThread() { flow.confirmLeaveJobThread() }

    func answer(_ action: QuestionCard.Action) async {
        await flow.answerUnitChange(action.answer)
    }

    // MARK: - Controls

    /// Start a job on the default vault, with the number the technician typed if they typed one.
    ///
    /// Through the flow, so the Job tab's button and `field_session start` cannot end up doing
    /// different things — and so whether a job starts is never the model's decision.
    @discardableResult
    func startJob(jobReference: String? = nil) throws -> FieldSession {
        let vaultId = defaults.vaultId()
        return try flow.startJob(vaultId: vaultId, assetId: nil, mode: defaults.mode(),
                                 jobReference: JobIntakeState.cleaned(jobReference))
    }

    /// Record a number typed on this screen. Ignored when it is blank, so a stray tap on Done
    /// cannot overwrite a good number with nothing.
    func supplyJobReference(_ text: String) {
        guard JobIntakeState.cleaned(text) != nil else { return }
        flow.supplyJobReference(text)
    }

    func declineJobReference() { flow.declineJobReference() }

    @discardableResult
    func pauseOrResume() throws -> FieldSession? {
        guard let session = openSession else { return nil }
        return session.pausedAt == nil ? try host.pauseSession() : try host.resumeSession()
    }

    /// Finish the job — **through the flow**, which ends the session and lets its conversation go
    /// with it. The export and the delivery that follow are the shipped ones; this does not
    /// re-implement either.
    ///
    /// The record is taken *before* the close, because `workRecord()` reads the active session and
    /// there is no active session afterwards — and the evidence selection is written before *that*,
    /// for the same reason twice over: the record has to carry it, and the session has to be open
    /// to receive it.
    func closeJob(outcome: FieldSession.Outcome = .resolved,
                  evidence: EvidenceSelection? = nil) throws -> (session: FieldSession, record: WorkRecord?) {
        if let evidence { host.setEvidenceSelection(evidence) }
        // The organisation's rule, checked here rather than in the sheet: every route that closes
        // a job comes through this one method, so a screen that forgot to ask cannot close past it
        // (Plan FO P2c).
        if case .blocked(let reason) = SignOffPolicy.decide(signOff: host.activeSession?.signOff,
                                                            required: host.customerSignOffRequired) {
            throw FieldSessionError.customerSignOffRequired(reason)
        }
        let record = host.workRecord()
        let session = try flow.closeJob(outcome: outcome)
        return (session, record)
    }

    // MARK: - Evidence (Plan FO P2a)

    /// The open job's photos, grouped for the grid. Nil when no job is open.
    var evidenceReview: EvidenceReviewModel? {
        guard let session = openSession else { return nil }
        return EvidenceReviewModel(items: host.jobMedia,
                                   taskTitles: session.tasks.map { (id: $0.id, title: $0.title) },
                                   photosDirectory: host.photosDirectory(sessionId: session.id),
                                   faceBlurOn: Config.privacyFilterEnabled)
    }

    /// The decision as it stands, defaults filled in — what the review step opens on.
    func evidenceSelection() -> EvidenceSelection { host.evidenceSelection() }

    /// Record a decision without closing: the Photos section's own edits, made mid-job.
    func applyEvidenceSelection(_ selection: EvidenceSelection) {
        host.setEvidenceSelection(selection)
    }

    /// A finished job's evidence, for its page's Photos section and its share sheet. The selection
    /// is the one that went out, not a fresh proposal — re-sharing a past job hands out the same
    /// files the customer's PDF was made from.
    func pastEvidence(sessionId: String) -> (review: EvidenceReviewModel, selection: EvidenceSelection)? {
        guard let session = host.history.first(where: { $0.id == sessionId }) else { return nil }
        let media = host.media(sessionId: sessionId)
        guard !media.isEmpty else { return nil }
        // **Not** `Config.privacyFilterEnabled`. The job is finished: nothing about these files
        // can change, the blur was applied on the way to disk, and the setting as it stands today
        // answers a question about the next photograph rather than about these ones.
        let review = EvidenceReviewModel(
            items: media,
            taskTitles: session.tasks.map { (id: $0.id, title: $0.title) },
            photosDirectory: host.photosDirectory(sessionId: sessionId),
            faceBlur: .recorded(from: media))
        let selection = (session.evidenceSelection ?? EvidenceSelection.proposed(for: media))
            .reconciled(with: media)
        return (review, selection)
    }

    // MARK: - Customer sign-off (Plan FO P2c)

    /// Whether the organisation asks for a signature before a job can close.
    var signOffRequired: Bool { host.customerSignOffRequired }

    /// What a sign-off sheet is headed with: the job as the customer knows it, and when the visit
    /// was. Built here rather than in the view so the open job and a finished one head the same
    /// way, and so the wording is testable.
    struct SignOffHeading: Equatable {
        let jobNumber: String
        let dateLine: String
    }

    /// The open job's heading, or nil when no job is open.
    var signOffHeading: SignOffHeading? {
        guard let session = openSession else { return nil }
        return Self.heading(for: session)
    }

    /// A finished job's, for a signature taken after the close.
    func signOffHeading(sessionId: String) -> SignOffHeading? {
        guard let session = host.history.first(where: { $0.id == sessionId }) else { return nil }
        return Self.heading(for: session)
    }

    private static func heading(for session: FieldSession) -> SignOffHeading {
        let reference = session.jobReference.flatMap { $0.isEmpty ? nil : $0 }
        return SignOffHeading(
            jobNumber: reference.map { "Job \($0)" } ?? noJobNumber,
            dateLine: session.startedAt.formatted(date: .abbreviated, time: .shortened))
    }

    /// The customer's half of the open job's record, as the hand-over sheet would show it now.
    ///
    /// Nil when no job is open. **Not** `readBackLines`: that is the whole work record, notes and
    /// escalations included, and none of it is something to ask a customer to put their name to.
    var customerSummaryLines: [String]? {
        guard openSession != nil, let record = host.workRecord() else { return nil }
        return record.customerSummaryLines
    }

    /// What the open job has recorded so far, if anything.
    var openJobSignOff: CustomerSignOff? {
        guard let session = openSession else { return nil }
        return session.signOff
    }

    /// Write the customer's answer onto the open job, before it is closed.
    @discardableResult
    func recordSignOff(_ signOff: CustomerSignOff, pngData: Data? = nil,
                       strokeData: Data? = nil) -> CustomerSignOff? {
        guard let session = openSession else { return nil }
        return host.recordSignOff(signOff, pngData: pngData, strokeData: strokeData,
                                  sessionId: session.id)
    }

    /// …or onto a finished one, from its page.
    @discardableResult
    func recordSignOff(sessionId: String, _ signOff: CustomerSignOff, pngData: Data? = nil,
                       strokeData: Data? = nil) -> CustomerSignOff? {
        host.recordSignOff(signOff, pngData: pngData, strokeData: strokeData, sessionId: sessionId)
    }

    func signOff(sessionId: String) -> CustomerSignOff? { host.signOff(sessionId: sessionId) }

    /// Whether a finished job can still be signed — until its report has gone.
    func signOffIsStillOpen(sessionId: String) -> Bool { host.signOffIsStillOpen(sessionId: sessionId) }

    func signOffCancelled(sessionId: String?) { host.logSignOffCancelled(sessionId: sessionId) }

    func signatureURL(sessionId: String, imageId: String) -> URL {
        host.signatureURL(sessionId: sessionId, imageId: imageId)
    }

    /// A finished job's customer summary as it stands, for a sign-off recorded after the close.
    func customerSummaryLines(sessionId: String) -> [String]? {
        guard let job = pastJob(id: sessionId) else { return nil }
        return job.record.customerSummaryLines
    }

    // MARK: - Clips on the way out (Plan FO P2b)

    /// What will happen to a finished job's clips on the channel the report would go by.
    ///
    /// Shown on the past job's page *before* Send, because "this one is too large" is a fact the
    /// technician needs while they still have the phone in their hand and the share sheet a tap
    /// away — not a line they read afterwards in a body they have already sent.
    struct ClipDelivery: Equatable {
        /// The channel's name in a sentence ("email", "a message", "the share sheet"), because
        /// the *label* is a button's caption — "Share…", ellipsis and all — and reads as nonsense
        /// mid-sentence.
        let channelName: String
        let channelLabel: String
        let plan: ClipDeliveryPlan
        /// Every included clip, attached or not, in the order the report names them.
        let clips: [JobMediaItem]

        var attachedCount: Int { plan.attached.count }
        var overBudgetCount: Int { plan.overBudget.count }

        /// The sentence above the list.
        var summary: String {
            switch (attachedCount, overBudgetCount) {
            case (0, 0): return "No clips go with this report."
            case (let sent, 0):
                return sent == 1
                    ? "One clip goes with the report by \(channelName)."
                    : "\(sent) clips go with the report by \(channelName)."
            case (0, let over):
                return over == 1
                    ? "The clip is too large for \(channelLabel) — share it separately."
                    : "\(over) clips are too large for \(channelLabel) — share them separately."
            case (let sent, let over):
                return "\(sent) clip\(sent == 1 ? "" : "s") go\(sent == 1 ? "es" : "") with the "
                    + "report; \(over) \(over == 1 ? "is" : "are") too large for "
                    + "\(channelLabel) and must be shared separately."
            }
        }

        /// What one clip's row says about how it travels.
        func line(for clip: JobMediaItem) -> String {
            var parts: [String] = [clip.caption?.isEmpty == false ? clip.caption! : "No caption"]
            if let length = clip.durationLabel { parts.append(length) }
            if let size = clip.sizeLabel { parts.append(size) }
            return parts.joined(separator: " · ")
        }
    }

    /// The clip partition for a finished job, against the channel the report would actually go by.
    /// Nil when the job has no included clips, or no channel is allowed at all.
    func clipDelivery(sessionId: String) -> ClipDelivery? {
        guard let session = host.history.first(where: { $0.id == sessionId }) else { return nil }
        let clipVaultName = defaults.vaultName(session.vaultId)
        let record = WorkRecord(session: session, vaultName: clipVaultName,
                                vaultSourceNote: VaultSourceBadge.forInstalledVault(id: session.vaultId)?
                                    .recordLine(vaultName: clipVaultName))
        let clips = record.includedClips
        guard !clips.isEmpty else { return nil }
        guard let channel = DeliveryPolicy(settings: Config.deliverySettings).defaultChannel else {
            return nil
        }
        let budget = AttachmentBudget.standard(
            for: channel,
            canSendAttachments: channel == .messages ? ReportComposerAvailability.messagesCanAttach
                                                     : true)
        let partition = budget.partition(clips: clips,
                                         reservedBytes: FieldSessionService.reportFileReserveBytes)
        return ClipDelivery(channelName: channel.spokenName, channelLabel: channel.label,
                            plan: ClipDeliveryPlan(channel: channel, partition: partition),
                            clips: clips)
    }

    /// Where a finished job's clip file lives, for the share sheet.
    func clipURL(sessionId: String, itemId: String) -> URL {
        host.photosDirectory(sessionId: sessionId).appendingPathComponent(itemId)
    }

    /// What "Read back" speaks and shows. The record's own lines, in the record's own order.
    var readBackLines: [String]? { host.workRecord()?.summaryLines }
    var readBackSpeech: String? { host.workRecord()?.summary }

    // MARK: - Debriefs (Plan FO P3b)

    /// A job's saved debriefs, newest first. Empty for a job nobody talked over, which is every
    /// job before this existed.
    func debriefs(sessionId: String) -> [JobDebrief] { host.debriefs(sessionId: sessionId) }

    /// Whether this job has anything an addendum would carry.
    ///
    /// Only a job whose report has **already gone**: before that, a debrief prints in the work
    /// order itself and a second document would be a second copy of the same words.
    func hasAddendum(sessionId: String) -> Bool {
        !DebriefDocumentPolicy.placement(debriefs: host.debriefs(sessionId: sessionId),
                                         reportAlreadySent: host.reportWasSent(sessionId: sessionId))
            .addendumDebriefs.isEmpty
    }

    /// The job as the debrief flow names it, for a debrief started from the phone.
    func debriefCandidate(sessionId: String) -> DebriefJobResolver.Candidate? {
        guard let session = host.history.first(where: { $0.id == sessionId }) else { return nil }
        return DebriefJobResolver.Candidate(
            sessionId: session.id,
            jobReference: session.jobReference.flatMap { $0.isEmpty ? nil : $0 },
            startedAt: session.startedAt,
            outcomeLabel: session.outcome.displayName,
            isActive: session.endedAt == nil && session.outcome != .cancelled)
    }

    // MARK: - The job's conversation

    enum OpenConversation: Equatable {
        /// Go to the Chat tab and open this thread.
        case open(threadId: String)
        /// The job has no conversation yet — nothing has been said on it.
        case none
        /// Opening it would take the technician out of another job thread first.
        case asks(ThreadQuestionCard)
    }

    /// Open the job's conversation, **through the P1 chokepoint**.
    ///
    /// Never by assigning `activeThreadId`: that is the id without the history, which is what left
    /// CarPlay and the watch resuming a conversation the model had never seen. `requestResume`
    /// does both halves and is the only thing allowed to.
    func openConversation() -> OpenConversation {
        guard let threadId = flow.boundThreadId else { return .none }
        if let question = flow.requestResume(threadId: threadId, confirmed: false) {
            return .asks(ThreadQuestionCard(question))
        }
        return .open(threadId: threadId)
    }

    // MARK: - Past jobs

    /// Finished jobs, newest first. The open one is not among them — it is the job, not a past job.
    var pastJobs: [PastJobRow] {
        host.history
            .filter { $0.endedAt != nil }
            .sorted { $0.startedAt > $1.startedAt }
            .map(row(for:))
    }

    /// The list filtered by what was typed in the search field. An empty query is every row.
    ///
    /// Matching is by job number first — that is the index a technician thinks in — and then by the
    /// machine and the vault, because "the Lennox one last Tuesday" is the other way people look.
    func pastJobs(matching query: String) -> [PastJobRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return pastJobs }
        return pastJobs.filter { $0.searchKey.contains(needle) }
    }

    var hasPastJobs: Bool { host.history.contains { $0.endedAt != nil } }

    /// How many days "Export a day's transcripts" offers. Two working weeks: support asks about
    /// the visit a customer just complained about, not one from last quarter, which is still one
    /// tap away on its own page.
    static let transcriptDayLimit = 14

    /// Days with at least one job, newest first, with how many jobs each has.
    var transcriptDays: [JobTranscriptExport.Day] {
        Array(JobTranscriptExport.days(in: host.history, calendar: .current)
            .prefix(Self.transcriptDayLimit))
    }

    private func row(for session: FieldSession) -> PastJobRow {
        let reference = session.jobReference.flatMap { $0.isEmpty ? nil : $0 }
        let vaultName = defaults.vaultName(session.vaultId)
        let equipment = session.equipment?.modelToken
        return PastJobRow(
            id: session.id,
            jobNumber: reference.map { "Job \($0)" } ?? Self.noJobNumber,
            hasJobNumber: reference != nil,
            vaultName: vaultName,
            dateLine: session.startedAt.formatted(date: .abbreviated, time: .shortened),
            outcomeLabel: session.outcome.displayName,
            equipment: equipment,
            billingLine: WorkRecord.billingSummary(seconds: session.billableSeconds,
                                                   basis: session.billingBasis,
                                                   minutesPerUnit: session.minutesPerBillingUnit),
            startedAt: session.startedAt,
            searchKey: [reference, vaultName, equipment]
                .compactMap { $0 }.joined(separator: " ").lowercased())
    }

    /// One past job in full, for its own page.
    func pastJob(id: String) -> PastJob? {
        guard let session = host.history.first(where: { $0.id == id }), session.endedAt != nil else {
            return nil
        }
        let vaultName = defaults.vaultName(session.vaultId)
        let record = WorkRecord(session: session, vaultName: vaultName,
                                vaultSourceNote: VaultSourceBadge.forInstalledVault(id: session.vaultId)?
                                    .recordLine(vaultName: vaultName))
        let reference = session.jobReference.flatMap { $0.isEmpty ? nil : $0 }
        return PastJob(
            sessionId: session.id,
            jobNumber: reference.map { "Job \($0)" } ?? Self.noJobNumber,
            hasJobNumber: reference != nil,
            vaultName: vaultName,
            dateLine: session.startedAt.formatted(date: .abbreviated, time: .shortened),
            outcomeLabel: session.outcome.displayName,
            visitedUnits: visitedUnitNames(of: session),
            summaryLines: record.summaryLines,
            billingLine: record.billingSummary,
            threadId: session.conversationThreadId,
            record: record)
    }
}
