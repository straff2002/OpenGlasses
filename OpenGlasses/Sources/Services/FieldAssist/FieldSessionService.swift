import Foundation
import CoreLocation

/// Coordinates the active Field Assist session for the app.
///
/// Responsibilities:
///   - Owns the currently active `FieldSession` (or none).
///   - Loads the vault associated with the active session and produces system-prompt context
///     for `LLMService.buildSystemPrompt` to inject (mirroring `VoiceSkillStore.promptContext()`).
///   - Persists session metadata + audit log via `SessionLogger`.
///   - Tracks pause/resume billable time accurately.
///   - Lists historical sessions for review/export.
///
/// Threading: `@MainActor` to match the rest of the app's UI-tier services.
@MainActor
final class FieldSessionService: ObservableObject {
    static let shared = FieldSessionService()

    /// The active session (nil when no session is in progress).
    @Published private(set) var activeSession: FieldSession?
    /// The vault store associated with the active session.
    @Published private(set) var activeVault: VaultStore?
    /// All sessions ever created (most recent first).
    @Published private(set) var history: [FieldSession] = []

    private var logger: SessionLogger?
    private var lastResumeAt: Date?

    /// Procedures available in the active session's vault.
    private var library: ProcedureLibrary?
    /// The currently running procedure, if any.
    private var runner: ProcedureRunner?

    /// Id of the procedure currently running (nil when none). Published for UI.
    @Published private(set) var activeProcedureId: String?

    /// The drawing this turn points at, or nil when it points at none (Plan EK P2). Published so
    /// the phone can put the page in front of the technician while the model is still answering.
    @Published private(set) var stagedFigure: StagedFigure?

    /// The last figure this session staged. Kept after `stagedFigure` clears so "show me that
    /// figure again" has something to reopen.
    private(set) var lastShownFigure: StagedFigure?

    /// The machine the session believes is in front of the technician (Plan EL). Published so the
    /// phone and the lens can say which model the answers are for.
    @Published private(set) var activeEquipment: EquipmentIdentity?

    /// The active vault's model index, derived once per session from its core headings. Empty for a
    /// vault that names no models, which makes every identity feature a no-op there.
    private(set) var modelIndex = VaultModelIndex(vaultName: "", files: [])

    private let sessionsRoot: URL

    init(sessionsRoot: URL? = nil) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.sessionsRoot = sessionsRoot ?? documents.appendingPathComponent("FieldSessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.sessionsRoot, withIntermediateDirectories: true)
        loadHistory()
        restoreInProgressSessionIfAny()
    }

    // MARK: - Lifecycle

    /// Start a new session against a vault. Returns the created session, or throws if the vault
    /// isn't unlocked or another session is already active.
    @discardableResult
    func startSession(
        vaultId: String,
        assetId: String?,
        mode: FieldSession.Mode = .aiOnly,
        startLocation: CLLocation? = nil,
        jobReference: String? = nil
    ) throws -> FieldSession {
        guard activeSession == nil else {
            throw FieldSessionError.alreadyActive
        }
        guard let manifest = VaultRegistry.shared.manifest(id: vaultId) else {
            throw FieldSessionError.unknownVault(vaultId)
        }
        guard VaultRegistry.shared.isUnlocked(manifest) else {
            throw FieldSessionError.vaultLocked(vaultId)
        }

        let store = VaultRegistry.shared.store(for: manifest)
        var session = FieldSession(
            id: UUID().uuidString,
            vaultId: vaultId,
            assetId: assetId,
            mode: mode,
            startedAt: Date(),
            endedAt: nil,
            pausedAt: nil,
            resumedAt: nil,
            outcome: .inProgress,
            startLocation: startLocation.map(FieldSession.GeoPoint.init),
            endLocation: nil,
            escalations: [],
            billableSeconds: 0
        )
        if let reference = jobReference?.trimmingCharacters(in: .whitespacesAndNewlines),
           !reference.isEmpty {
            session.jobReference = reference
        }

        activeSession = session
        activeVault = store
        modelIndex = VaultModelIndex(store: store)
        partsIndex = VaultPartsIndex(store: store)
        activeEquipment = nil
        stagedDelivery = nil
        lastDeliveryCancelled = false
        taskCue = nil
        deliveryLogger = nil
        library = ProcedureLibrary(store: store)
        let newLogger = SessionLogger(session: session, root: sessionsRoot.appendingPathComponent(session.id, isDirectory: true))
        logger = newLogger
        // The audit record says what entitled the session — a pilot export must read as a pilot.
        let entitlement = FieldAssistEntitlement.shared.decision().auditLabel
        var note = "vault=\(vaultId), mode=\(mode.rawValue), asset=\(assetId ?? "-"), entitlement=\(entitlement)"
        if let pack = VaultImporter.installedPack(for: vaultId) {
            // An exported record says whose knowledge it drew on (Plan EG).
            note += ", pack=\(pack.id)@\(pack.version), author=\(pack.author ?? "-")"
        }
        newLogger.appendLifecycle(.sessionStarted, note: note)
        EscalationCoordinator.shared.reset()
        lastResumeAt = Date()
        history.insert(session, at: 0)
        // A work order that names the machine has already done the recognition. One model and one
        // only: an asset id that matches several is not an identification.
        if let assetId, case let matches = modelIndex.match(text: assetId), matches.count == 1 {
            setEquipment(EquipmentIdentity(model: matches[0], token: matches[0].name, source: .asset))
        }
        return activeSession ?? session
    }

    /// Pause the active session (stops billable-time accumulation).
    @discardableResult
    func pauseSession() throws -> FieldSession {
        guard var session = activeSession, let logger else {
            throw FieldSessionError.noActiveSession
        }
        if session.pausedAt != nil { return session }
        accumulateBillableTime(into: &session)
        session.pausedAt = Date()
        session.outcome = .paused
        activeSession = session
        history = history.replacingFirst(matching: session.id, with: session)
        logger.updateSession { $0 = session }
        logger.appendLifecycle(.sessionPaused)
        lastResumeAt = nil
        return session
    }

    /// Resume a previously paused session.
    @discardableResult
    func resumeSession() throws -> FieldSession {
        guard var session = activeSession, let logger else {
            throw FieldSessionError.noActiveSession
        }
        guard session.pausedAt != nil else { return session }
        session.pausedAt = nil
        session.resumedAt = Date()
        session.outcome = .inProgress
        activeSession = session
        history = history.replacingFirst(matching: session.id, with: session)
        logger.updateSession { $0 = session }
        logger.appendLifecycle(.sessionResumed)
        lastResumeAt = Date()
        return session
    }

    /// End the active session with an outcome.
    @discardableResult
    func endSession(outcome: FieldSession.Outcome = .resolved, endLocation: CLLocation? = nil) throws -> FieldSession {
        guard var session = activeSession, let logger else {
            throw FieldSessionError.noActiveSession
        }
        accumulateBillableTime(into: &session)
        session.endedAt = Date()
        session.endLocation = endLocation.map(FieldSession.GeoPoint.init)
        session.outcome = outcome
        history = history.replacingFirst(matching: session.id, with: session)
        logger.updateSession { $0 = session }
        logger.appendLifecycle(.sessionEnded, note: "outcome=\(outcome.rawValue), billable_seconds=\(Int(session.billableSeconds))")
        // The visit's record leaves as its own queued operation, whatever else the session does
        // with it (Plan EM). The queue's sink is unchanged — this is a durable local tombstone
        // until a configured endpoint exists.
        let record = WorkRecord(session: session,
                                vaultName: activeVault?.manifest.name ?? session.vaultId)
        offlineQueue?.enqueue(QueuedOp.make(workRecord: record))
        activeSession = nil
        activeVault = nil
        activeEquipment = nil
        modelIndex = VaultModelIndex(vaultName: "", files: [])
        partsIndex = VaultPartsIndex(files: [])
        stagedFigure = nil
        lastShownFigure = nil
        stagedDelivery = nil
        taskCue = nil
        deliveryLogger = logger
        self.logger = nil
        lastResumeAt = nil
        runner = nil
        library = nil
        activeProcedureId = nil
        return session
    }

    /// Record an escalation request on the active session.
    func recordEscalation(reason: String) {
        guard var session = activeSession, let logger else { return }
        session.escalations.append(.init(timestamp: Date(), reason: reason, resolvedAt: nil))
        activeSession = session
        history = history.replacingFirst(matching: session.id, with: session)
        logger.updateSession { $0 = session }
        logger.append(.init(timestamp: Date(), kind: .escalationRequested, text: reason, payload: nil))
    }

    /// Mark the most recent unresolved escalation as resolved and log it.
    func resolveLastEscalation(note: String? = nil) {
        guard var session = activeSession, let logger else { return }
        guard let idx = session.escalations.lastIndex(where: { $0.resolvedAt == nil }) else { return }
        session.escalations[idx].resolvedAt = Date()
        activeSession = session
        history = history.replacingFirst(matching: session.id, with: session)
        logger.updateSession { $0 = session }
        logger.append(.init(timestamp: Date(), kind: .escalationResolved, text: note, payload: nil))
    }

    // MARK: - Equipment identity (Plan EL)

    /// Record the machine in front of the technician. Persists through the session's own update
    /// path, so the audit record and a crash-restored session both carry it.
    func setEquipment(_ identity: EquipmentIdentity) {
        guard var session = activeSession else { return }
        session.equipment = identity
        activeSession = session
        activeEquipment = identity
        history = history.replacingFirst(matching: session.id, with: session)
        logger?.updateSession { $0 = session }
        var payload: [String: AnyCodable] = ["model": AnyCodable(identity.modelToken),
                                             "heading": AnyCodable(identity.heading),
                                             "file": AnyCodable(identity.file),
                                             "source": AnyCodable(identity.source.rawValue)]
        // The nameplate's own text is audit material — it is what the recognition was based on —
        // and it never goes anywhere near a prompt.
        if let nameplate = identity.nameplateText { payload["nameplate_text"] = AnyCodable(nameplate) }
        logger?.append(.init(timestamp: Date(), kind: .equipmentRecognised,
                             text: identity.heading, payload: payload))
    }

    /// Forget it — a wrong read, or the technician has moved to another unit.
    func clearEquipment() {
        guard var session = activeSession else { return }
        let previous = session.equipment
        session.equipment = nil
        activeSession = session
        activeEquipment = nil
        history = history.replacingFirst(matching: session.id, with: session)
        logger?.updateSession { $0 = session }
        logger?.append(.init(timestamp: Date(), kind: .equipmentCleared, text: previous?.heading,
                             payload: previous.map { ["model": AnyCodable($0.modelToken),
                                                      "heading": AnyCodable($0.heading)] }))
    }

    /// Is this turn about a machine these manuals are for? Runs before retrieval everywhere, so a
    /// question about another manufacturer's unit is answered with the scope sentence rather than
    /// with passages that are genuinely about the subject and genuinely about the wrong machine.
    func equipmentScope(turn: String?, nameplateText: String? = nil) -> EquipmentScopeCheck.Outcome {
        EquipmentScopeCheck.check(text: turn, nameplateText: nameplateText,
                                  index: modelIndex, active: activeEquipment)
    }

    /// The retriever's view of the active machine: every spelling of it, and every spelling of
    /// every other model the vault names. Nil when nothing is active or the vault names no models.
    var retrievalModelScope: VaultRetriever.ModelScope? {
        guard let active = activeEquipment, !modelIndex.isEmpty else { return nil }
        guard let model = modelIndex.models.first(where: { $0.heading == active.heading }) else { return nil }
        return VaultRetriever.ModelScope(activeTokens: Set(model.tokens),
                                         otherTokens: modelIndex.knownModelTokens)
    }

    // MARK: - Work record: tasks, parts, identity (Plan EM)

    /// The active vault's parts table, derived once per session from its core files. Empty for a
    /// vault that lists no parts, which leaves the manuals as the only route to a verification.
    private(set) var partsIndex = VaultPartsIndex(files: [])

    /// Verification of a part number against the vault's parts table first, then its manuals.
    var partsVerifier: PartsVerifier {
        let store = activeVault
        let documentStore = self.documentStore
        return PartsVerifier(index: partsIndex) { token in
            guard let store, store.manifest.hasDocuments, let documentStore else { return [] }
            return documentStore.passages(containingToken: token,
                                          namespace: DocumentStore.vaultNamespace(store.manifest.id),
                                          limit: 3)
        }
    }

    /// Verify one part number the way everything else does, so nothing can be written down by a
    /// route that skips the book.
    func verifyPart(_ number: String) -> TaskPart { partsVerifier.verify(number) }

    /// Apply a change to the active session and persist it through the one update path, so the
    /// audit record, the history list and a crash-restored session cannot disagree.
    @discardableResult
    private func mutateSession<T>(_ body: (inout FieldSession) -> T) -> T? {
        guard var session = activeSession else { return nil }
        let result = body(&session)
        activeSession = session
        history = history.replacingFirst(matching: session.id, with: session)
        logger?.updateSession { $0 = session }
        return result
    }

    /// The job this visit belongs to.
    func setJobReference(_ reference: String) {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, activeSession != nil else { return }
        mutateSession { $0.jobReference = trimmed }
        logger?.append(.init(timestamp: Date(), kind: .jobReferenceSet, text: trimmed, payload: nil))
    }

    /// Write down a field read off the machine — model, serial, board part number, firmware,
    /// refrigerant — with where it came from, because digits are where recognition fails quietly.
    @discardableResult
    func recordIdentityField(name: String, value: String,
                             source: DeviceIdentityField.Source) -> DeviceIdentityField? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !value.isEmpty, activeSession != nil else { return nil }
        let field = DeviceIdentityField(name: name, value: value, source: source)
        mutateSession { session in
            // A field read a second time replaces the first — the later reading is the one the
            // technician is standing in front of.
            session.identityFields.removeAll { $0.name.lowercased() == name.lowercased() }
            session.identityFields.append(field)
        }
        logger?.append(.init(timestamp: Date(), kind: .identityFieldRecorded, text: field.summary,
                             payload: ["field": AnyCodable(name), "value": AnyCodable(value),
                                       "source": AnyCodable(source.rawValue)]))
        return field
    }

    // MARK: Tasks

    func task(id: String) -> FieldSession.Task? { activeSession?.tasks.first { $0.id == id } }
    /// The task work is being recorded against, if any.
    var activeTask: FieldSession.Task? { activeSession?.activeTask }
    /// The recommendation "do it" / "skip that" / "later" resolve to when no task is named.
    var latestRecommendation: FieldSession.Task? { activeSession?.latestRecommendation }

    /// Record a recommendation. It is a proposal and nothing else until the technician decides.
    ///
    /// Refused without a citation: the model may only recommend what it can point at in the book.
    /// Refused with a procedure the vault does not have: a task cannot promise to run something
    /// that is not there.
    @discardableResult
    func proposeTask(title: String, why: String? = nil, procedureId: String? = nil,
                     parts: [TaskPart] = [], safetyNote: String? = nil,
                     citation: String) throws -> FieldSession.Task {
        guard activeSession != nil else { throw FieldSessionError.noActiveSession }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw FieldSessionError.taskNeedsTitle }
        let citation = citation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !citation.isEmpty else { throw FieldSessionError.recommendationNeedsCitation }
        if let procedureId, !procedureId.isEmpty, library?.procedure(id: procedureId) == nil {
            throw FieldSessionError.unknownProcedure(procedureId)
        }
        let task = FieldSession.Task(
            title: title, why: why, origin: .recommended, status: .recommended,
            procedureId: (procedureId?.isEmpty == true) ? nil : procedureId,
            citation: citation, safetyNote: safetyNote, parts: parts)
        mutateSession { $0.tasks.append(task) }
        logger?.append(.init(timestamp: Date(), kind: .taskProposed, text: title, payload: [
            "task_id": AnyCodable(task.id),
            "citation": AnyCodable(citation),
            "procedure_id": AnyCodable(task.procedureId ?? ""),
            "parts": AnyCodable(task.parts.map { ["number": $0.number, "verified": $0.verified] as [String: Any] })
        ]))
        return task
    }

    /// "Add a task: cleaned the condensate trap." Work the technician did without anybody
    /// suggesting it — already in progress, because they are telling you while doing it.
    @discardableResult
    func addOperatorTask(title: String, why: String? = nil) throws -> FieldSession.Task {
        guard activeSession != nil else { throw FieldSessionError.noActiveSession }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw FieldSessionError.taskNeedsTitle }
        let now = Date()
        let task = FieldSession.Task(title: title, why: why, origin: .operatorAdded,
                                     status: .inProgress, createdAt: now, acceptedAt: now)
        mutateSession { $0.tasks.append(task) }
        logger?.append(.init(timestamp: now, kind: .taskStarted, text: title,
                             payload: ["task_id": AnyCodable(task.id),
                                       "origin": AnyCodable(task.origin.rawValue)]))
        raiseTaskCue(task, phase: .started)
        return task
    }

    /// What "do it" / "skip that" / "later" did, including the procedure an acceptance started.
    struct TaskDecisionResult {
        let task: FieldSession.Task
        /// The step the technician is now on, when accepting started a procedure.
        let procedureStep: Procedure.Step?
        /// Why a procedure named by the task could not be started, when it could not.
        let procedureProblem: String?
    }

    enum TaskDecision: String {
        case accept
        case decline
        case defer_ = "defer"
    }

    /// Accept, decline or defer a task.
    ///
    /// Accepting starts the task's procedure when it names one, and makes the task the active one
    /// so readings, photos and verified pages attach to it — unless something else is already
    /// running, in which case it rests at `accepted` and `start` picks it up later.
    @discardableResult
    func decideTask(id: String, decision: TaskDecision) throws -> TaskDecisionResult {
        guard activeSession != nil else { throw FieldSessionError.noActiveSession }
        guard let existing = task(id: id) else { throw FieldSessionError.unknownTask(id) }
        guard existing.status.isOpen else {
            throw FieldSessionError.taskAlreadyClosed(existing.title, existing.status.rawValue)
        }

        var step: Procedure.Step?
        var problem: String?
        let now = Date()

        switch decision {
        case .decline, .defer_:
            mutateSession { session in
                guard let idx = session.tasks.firstIndex(where: { $0.id == id }) else { return }
                session.tasks[idx].status = (decision == .decline) ? .declined : .deferred
            }
        case .accept:
            if let procedureId = existing.procedureId {
                do {
                    step = try startProcedure(id: procedureId)
                } catch {
                    problem = error.localizedDescription
                }
            }
            let busy = (step == nil) && (activeTask != nil)
            mutateSession { session in
                guard let idx = session.tasks.firstIndex(where: { $0.id == id }) else { return }
                session.tasks[idx].acceptedAt = session.tasks[idx].acceptedAt ?? now
                session.tasks[idx].status = busy ? .accepted : .inProgress
            }
        }

        let updated = task(id: id) ?? existing
        if updated.status == .inProgress { raiseTaskCue(updated, phase: .started) }
        logger?.append(.init(timestamp: now, kind: .taskDecision, text: updated.title, payload: [
            "task_id": AnyCodable(id),
            "decision": AnyCodable(decision.rawValue),
            "status": AnyCodable(updated.status.rawValue)
        ]))
        return TaskDecisionResult(task: updated, procedureStep: step, procedureProblem: problem)
    }

    /// Pick up a task that was accepted or put off earlier.
    @discardableResult
    func startTask(id: String) throws -> FieldSession.Task {
        guard activeSession != nil else { throw FieldSessionError.noActiveSession }
        guard let existing = task(id: id) else { throw FieldSessionError.unknownTask(id) }
        guard existing.status.isOpen || existing.status == .deferred else {
            throw FieldSessionError.taskAlreadyClosed(existing.title, existing.status.rawValue)
        }
        let now = Date()
        mutateSession { session in
            guard let idx = session.tasks.firstIndex(where: { $0.id == id }) else { return }
            session.tasks[idx].acceptedAt = session.tasks[idx].acceptedAt ?? now
            session.tasks[idx].status = .inProgress
        }
        let updated = task(id: id) ?? existing
        logger?.append(.init(timestamp: now, kind: .taskStarted, text: updated.title,
                             payload: ["task_id": AnyCodable(id)]))
        raiseTaskCue(updated, phase: .started)
        return updated
    }

    /// Close a task, with what the technician said they did.
    @discardableResult
    func completeTask(id: String, note: String? = nil, outcome: String? = nil) throws -> FieldSession.Task {
        try closeTask(id: id, status: .done, note: note, outcome: outcome)
    }

    /// Give a task up. Kept on the record — started and not finished is information.
    @discardableResult
    func abandonTask(id: String, note: String? = nil) throws -> FieldSession.Task {
        try closeTask(id: id, status: .abandoned, note: note, outcome: nil)
    }

    @discardableResult
    private func closeTask(id: String, status: FieldSession.Task.Status,
                           note: String?, outcome: String?) throws -> FieldSession.Task {
        guard activeSession != nil else { throw FieldSessionError.noActiveSession }
        guard let existing = task(id: id) else { throw FieldSessionError.unknownTask(id) }
        guard existing.status.isOpen else {
            throw FieldSessionError.taskAlreadyClosed(existing.title, existing.status.rawValue)
        }
        let now = Date()
        mutateSession { session in
            guard let idx = session.tasks.firstIndex(where: { $0.id == id }) else { return }
            session.tasks[idx].status = status
            session.tasks[idx].completedAt = now
            session.tasks[idx].acceptedAt = session.tasks[idx].acceptedAt ?? session.tasks[idx].createdAt
            if let note, !note.isEmpty { session.tasks[idx].completionNote = note }
            if let outcome, !outcome.isEmpty { session.tasks[idx].procedureOutcome = outcome }
        }
        let updated = task(id: id) ?? existing
        logger?.append(.init(timestamp: now, kind: .taskCompleted, text: updated.title, payload: [
            "task_id": AnyCodable(id),
            "status": AnyCodable(status.rawValue),
            "note": AnyCodable(note ?? ""),
            "outcome": AnyCodable(updated.procedureOutcome ?? "")
        ]))
        raiseTaskCue(updated, phase: status == .done ? .done : .abandoned)
        return updated
    }

    /// A procedure a task started has reached its end: the outcome closes the task, so nobody has
    /// to remember to say "done" twice.
    private func closeTaskForProcedure(id procedureId: String?, outcome: String) {
        guard let procedureId,
              let task = activeSession?.tasks.last(where: {
                  $0.procedureId == procedureId && $0.status.isOpen
              }) else { return }
        _ = try? closeTask(id: task.id, status: .done, note: nil, outcome: outcome)
    }

    // MARK: Evidence attachment

    /// Attach evidence to the active task, or to the job when none is running. Called from the
    /// existing logging paths so nothing has to be recorded twice.
    private func attachEvidence(_ body: (inout FieldSession.Evidence) -> Void) {
        mutateSession { session in
            if let idx = session.tasks.lastIndex(where: { $0.status == .inProgress }) {
                body(&session.tasks[idx].evidence)
            } else {
                body(&session.jobEvidence)
            }
        }
    }

    // MARK: Parts requests

    /// Ask base for a part. May stand without a task — a stock check goes out before anybody knows
    /// whether the repair is happening — and leaves as its own queued operation.
    @discardableResult
    func requestPart(_ part: TaskPart, quantity: Int = 1, taskId: String? = nil,
                     urgency: PartsRequest.Urgency = .routine, onVan: Bool = false) -> PartsRequest? {
        guard let session = activeSession else { return nil }
        let request = PartsRequest(part: part, quantity: max(quantity, 1), taskId: taskId,
                                   modelToken: activeEquipment?.modelToken, urgency: urgency,
                                   onVan: onVan)
        mutateSession { $0.partsRequests.append(request) }
        logger?.append(.init(timestamp: request.createdAt, kind: .partsRequested,
                             text: request.summary, payload: [
                                "request_id": AnyCodable(request.id),
                                "part": AnyCodable(part.number),
                                "quantity": AnyCodable(request.quantity),
                                "verified": AnyCodable(part.verified),
                                "page": AnyCodable(part.page ?? ""),
                                "task_id": AnyCodable(taskId ?? ""),
                                "urgency": AnyCodable(urgency.rawValue),
                                "on_van": AnyCodable(onVan)]))
        offlineQueue?.enqueue(QueuedOp.make(partsRequest: request, sessionId: session.id))
        return request
    }

    /// Record what base said. **Reported, never acted on**: it is attached to the request and
    /// spoken to the technician, and it changes no task and no recommendation by itself.
    @discardableResult
    func answerPartsRequest(id: String? = nil, part: String? = nil, answer: String) -> PartsRequest? {
        guard let session = activeSession else { return nil }
        let wantedPart = part.map(PartsVerifier.normalise)
        let match = session.partsRequests.last { request in
            if let id { return request.id == id }
            if let wantedPart, !wantedPart.isEmpty { return request.part.number == wantedPart }
            return true
        }
        guard let match else { return nil }
        let now = Date()
        mutateSession { session in
            guard let idx = session.partsRequests.firstIndex(where: { $0.id == match.id }) else { return }
            session.partsRequests[idx].baseAnswer = answer
            session.partsRequests[idx].status = .answered
            session.partsRequests[idx].answeredAt = now
        }
        logger?.append(.init(timestamp: now, kind: .partsAnswered, text: answer, payload: [
            "request_id": AnyCodable(match.id),
            "part": AnyCodable(match.part.number)
        ]))
        return activeSession?.partsRequests.first { $0.id == match.id }
    }

    // MARK: The record

    /// The visit's record as it stands — what "read back the job" speaks, and what leaves at the
    /// end. Deterministic: no model is asked to summarise anything.
    func workRecord() -> WorkRecord? {
        guard let session = activeSession else { return nil }
        var snapshot = session
        // Time on site as it is right now, without disturbing the session's own accounting.
        if let lastResumeAt { snapshot.billableSeconds += Date().timeIntervalSince(lastResumeAt) }
        return WorkRecord(session: snapshot, vaultName: activeVault?.manifest.name ?? session.vaultId)
    }

    // MARK: Delivery (Plan EM P2)

    /// The report waiting for the operator's thumb, or nil when none is.
    ///
    /// Published, and staged rather than sent: the app root subscribes and opens the composer, the
    /// same way a staged figure reaches the phone. `deliver_report` never presents anything itself,
    /// so it behaves identically with no app around it.
    @Published private(set) var stagedDelivery: DeliveryRequest?

    /// True once a composer was dismissed without sending. The session card says so, because a
    /// record nobody sent is the one thing a technician must not discover a week later.
    @Published private(set) var lastDeliveryCancelled = false

    /// The line the lens flashes when a task starts or closes, or nil when nothing has happened.
    @Published private(set) var taskCue: TaskHUDCue.Cue?

    /// The logger of the session a report belongs to, kept alive past `endSession` so a composer
    /// still open when the session closes can still write its outcome into that session's log.
    /// Appending is all it is used for — the session metadata is already final.
    private var deliveryLogger: SessionLogger?

    /// Where a report's files come from. Overridable so a headless test can stage a delivery
    /// without rendering a PDF, and so a caller that has already exported does not export twice.
    var reportAttachmentsProvider: (() -> [DeliveryRequest.Attachment])?

    /// The work order PDF and the JSON record for the active session, exported now.
    ///
    /// Empty when the export refuses — a device without the team entitlement still gets the spoken
    /// summary and a message body, and is told the files are not attached rather than being handed
    /// an empty PDF.
    func reportAttachments() -> [DeliveryRequest.Attachment] {
        if let reportAttachmentsProvider { return reportAttachmentsProvider() }
        guard let record = workRecord(), let leases = try? exportSession(formats: [.json, .pdf]) else {
            return []
        }
        // The attachments point at staged files. Their leases stay held by the coordinator until
        // the composer is done with them and the app backgrounds, or the TTL sweeps them — the
        // filename the recipient sees is the report stem, never the on-disk UUID.
        return leases.compactMap { lease in
            switch lease.fileURL.pathExtension.lowercased() {
            case "pdf": return DeliveryRequest.Attachment(url: lease.fileURL, kind: .pdf,
                                                          filename: record.reportFileStem + ".pdf")
            case "json": return DeliveryRequest.Attachment(url: lease.fileURL, kind: .json,
                                                           filename: record.reportFileStem + ".json")
            default: return nil
            }
        }
    }

    /// Put a report in front of the operator. Publishing it is what opens the composer; nothing
    /// has been sent when this returns.
    func stageDelivery(_ request: DeliveryRequest) {
        lastDeliveryCancelled = false
        stagedDelivery = request
    }

    func clearStagedDelivery() {
        stagedDelivery = nil
    }

    /// The composer closed. Write what happened to the audit log, move the stock checks this report
    /// carried to `sent` when it was actually sent, and clear the staging either way.
    ///
    /// A cancelled report changes nothing else: the queued record stays `pending`, which is what
    /// makes "nothing is silently lost" true rather than aspirational.
    func completeDelivery(_ request: DeliveryRequest, outcome: DeliveryOutcome) {
        if stagedDelivery?.id == request.id { stagedDelivery = nil }
        lastDeliveryCancelled = !outcome.isSent

        if outcome.isSent, !request.partsRequestIds.isEmpty {
            let ids = Set(request.partsRequestIds)
            mutateSession { session in
                for idx in session.partsRequests.indices
                where ids.contains(session.partsRequests[idx].id)
                    && session.partsRequests[idx].status == .requested {
                    session.partsRequests[idx].status = .sent
                }
            }
        }

        let kind: SessionLogger.Event.Kind
        switch outcome {
        case .sent: kind = .reportSent
        case .saved, .handedOff, .cancelled: kind = .reportCancelled
        case .failed: kind = .reportFailed
        }
        var payload: [String: AnyCodable] = [
            "channel": AnyCodable(request.channel.rawValue),
            "outcome": AnyCodable(outcome.auditLabel),
            "recipients": AnyCodable(request.recipients.count),
            "attachments": AnyCodable(request.attachments.map(\.kind.rawValue)),
            "parts_requests": AnyCodable(request.partsRequestIds.count)
        ]
        // The addresses themselves are not written down — how many there were is what an audit
        // needs, and a work order that leaks a customer's inbox is a different problem.
        if case .failed(let reason) = outcome { payload["error"] = AnyCodable(reason) }
        // The active session's log when this report belongs to it; the log of the session that
        // just ended when a composer outlived it. Never somebody else's log.
        let target = activeSession?.id == request.sessionId ? logger
            : (deliveryLogger?.session.id == request.sessionId ? deliveryLogger : nil)
        target?.append(.init(timestamp: Date(), kind: kind, text: request.subject, payload: payload))
    }

    /// Flash a task on the lens. Set by the task mutators; cleared by whoever showed it.
    private func raiseTaskCue(_ task: FieldSession.Task, phase: TaskHUDCue.Cue.Phase) {
        taskCue = TaskHUDCue.Cue(taskId: task.id, title: task.title, phase: phase)
    }

    // MARK: - Prompt context

    /// Where a vault's reference-tier documents live. Injected by `AppState`; nil in headless
    /// contexts, in which case the manual block is simply absent.
    /// Setting a store adopts that store's embedding backend's measured gate defaults — similarity
    /// means something different on each backend, so the gate cannot be one constant. Assign
    /// `retrievalPolicy` after the store to override (tests pin a floor of 0 or 1.01 this way).
    var documentStore: DocumentStore? {
        didSet {
            guard let documentStore else { return }
            retrievalPolicy = .default(for: documentStore.embeddingModelId)
        }
    }
    /// The evidence gate for per-turn manual retrieval. Injectable so tests can pin the floor.
    var retrievalPolicy = RetrievalEvidencePolicy()
    /// How many manual passages a turn may carry.
    var manualPassageLimit = 4

    /// System-prompt addendum for the active session, or nil when no session is active.
    /// Hooked into `LLMService.buildSystemPrompt`. When the vault declares a reference tier and
    /// `turn` is given, the passages retrieved for that turn ride along — or an explicit statement
    /// that nothing did, so the model cannot fall back to general knowledge silently.
    func promptContext(turn: String? = nil) -> String? {
        guard let store = activeVault else { return nil }
        var context = VaultPromptBuilder.promptContext(for: store)
        if let equipment = activeEquipment {
            context = (context.map { $0 + "\n\n" } ?? "") + equipment.promptBlock
        }
        if let runner {
            let procedureContext = runner.promptContext()
            if !procedureContext.isEmpty {
                context = (context.map { $0 + "\n\n" } ?? "") + procedureContext
            }
        }
        if let manuals = manualPassagesContext(turn: turn, store: store) {
            context = (context.map { $0 + "\n\n" } ?? "") + manuals
        }
        return context
    }

    /// The `MANUAL PASSAGES` block for a turn, or nil when the vault has no reference tier, nothing
    /// has been ingested for it, or there is no turn to retrieve against.
    func manualPassagesContext(turn: String?, store: VaultStore) -> String? {
        guard store.manifest.hasDocuments, let documentStore,
              let turn = turn?.trimmingCharacters(in: .whitespacesAndNewlines), !turn.isEmpty else { return nil }
        let namespace = DocumentStore.vaultNamespace(store.manifest.id)
        guard documentStore.documentCount(namespace: namespace) > 0 else { return nil }
        // Equipment before evidence. A question about a machine this vault is not for cannot be
        // answered by any passage in it, however well the words line up (Plan EL §3), so the block
        // becomes the scope sentence and the vault's rules relay it verbatim.
        var scopeNote: String?
        switch equipmentScope(turn: turn) {
        case .unknownEquipment(_, let sentence):
            stageFigure(nil)
            return VaultRetriever.promptBlock(.insufficient(reason: sentence))
        case .otherKnownModel(let token, let model):
            if let active = activeEquipment {
                scopeNote = EquipmentScopeCheck.otherModelNote(token: token, model: model, active: active)
            }
        case .inScope:
            break
        }
        let outcome = manualRetriever(store: store).retrieve(
            .init(turn: turn, procedureStep: runner?.currentStep?.title, limit: manualPassageLimit))
        // The turn's drawing, if its evidence points at one. Staged here and nowhere else for the
        // automatic path, so a figure never outlives the question that found it: a turn whose
        // evidence has no drawing in it clears the last one rather than leaving a wiring diagram
        // attached to a question about condensate.
        stageFigure(makeStagedFigure(for: Self.bestFigure(in: outcome.passages), vaultId: store.manifest.id))
        let block = VaultRetriever.promptBlock(outcome)
        return scopeNote.map { block + "\n\n" + $0 } ?? block
    }

    /// A retriever scoped to the active vault's namespace, or nil when there is no store.
    func manualRetriever(store: VaultStore) -> VaultRetriever {
        let namespace = DocumentStore.vaultNamespace(store.manifest.id)
        let documentStore = self.documentStore
        return VaultRetriever(query: { query, limit in
            documentStore?.query(query, limit: limit, namespace: namespace) ?? []
        }, tokenSearch: { token, limit in
            documentStore?.passages(containingToken: token, namespace: namespace, limit: limit) ?? []
        }, provenance: { documentId in
            documentStore?.list(namespace: namespace).first { $0.id == documentId }?.sourceType == VaultImporter.recognisedSourceType
        }, policy: retrievalPolicy, modelScope: retrievalModelScope)
    }

    /// Whether the active vault has manuals available to search.
    var activeVaultHasManuals: Bool {
        guard let store = activeVault, store.manifest.hasDocuments, let documentStore else { return false }
        return documentStore.documentCount(namespace: DocumentStore.vaultNamespace(store.manifest.id)) > 0
    }

    /// Whether a session is currently active and accepting input.
    var isSessionActive: Bool { activeSession?.isActive == true }

    // MARK: - Figures (Plan EK)

    /// The drawing a turn points at: what a technician would turn to in the book, what the phone
    /// puts on screen, and what the model is handed as a picture when the turn has no camera frame.
    ///
    /// A value type carrying only what naming and rendering the page need — the page itself is
    /// resolved from the vault's baseline on demand (`sourcePDFURL(for:)`), because a staged figure
    /// may outlive an uninstall and must then simply fail to resolve.
    struct StagedFigure: Equatable {
        let documentId: String
        /// The manual's title, as the citation says it.
        let documentTitle: String
        /// The printed page the drawing is on — the number in the citation, and the page the
        /// renderer opens. Plan EK P1 measured the printed and physical page in agreement on
        /// every page of the example pair; a document where they disagree renders the wrong page,
        /// which is why the extractor warns on a mismatch at import.
        let page: Int
        /// "Figure 58" / "Table 16", when the page printed a caption.
        let figure: String?
        /// The vault file the document was ingested from ("SLP99UHVK-Install.pdf"), when the
        /// ledger still knows it. Nil once the ledger entry has gone, and for a document the
        /// manifest lists as something other than a PDF.
        let sourceFile: String?

        init(documentId: String, documentTitle: String, page: Int, figure: String? = nil,
             sourceFile: String? = nil) {
            self.documentId = documentId
            self.documentTitle = documentTitle
            self.page = page
            self.figure = figure
            self.sourceFile = sourceFile
        }

        /// The same citation the passage carried, so what is said, shown and logged agree.
        var citation: String {
            var parts = [documentTitle, "page \(page)"]
            if let figure, !figure.isEmpty { parts.append(figure) }
            return parts.joined(separator: ", ")
        }

        /// How the figure is named in a sentence: its caption when it has one, else its page.
        var name: String {
            figure.flatMap { $0.isEmpty ? nil : $0 } ?? "the drawing on page \(page)"
        }

        /// The staged figure as a citation, so what is logged when a figure is asked for by voice
        /// keys the same way as a citation tapped under an answer (Plan EK P3).
        var asCitation: Citation {
            Citation(kind: .manual, title: documentTitle, page: page, figure: figure)
        }

        /// Whether the vault holds a page that can be rendered at all. The Markdown route holds
        /// extracted text and has none — the honest limit the vault guide names.
        var hasSourcePage: Bool { sourceFile?.lowercased().hasSuffix(".pdf") == true }
    }

    /// The best drawing among a turn's evidence: a drawing outright, else prose that names one.
    /// Ranked order is the retriever's, so "best" is "highest ranked" and nothing re-scores here.
    static func bestFigure(in passages: [VaultRetriever.Passage]) -> VaultRetriever.Passage? {
        passages.first { $0.kind == .diagram && $0.page != nil }
            ?? passages.first { $0.figure?.isEmpty == false && $0.page != nil }
    }

    /// Stage a figure for this turn, or clear the staging when there is none. Whatever is staged
    /// stays reachable as `lastShownFigure` for the rest of the session.
    func stageFigure(_ figure: StagedFigure?) {
        stagedFigure = figure
        if let figure { lastShownFigure = figure }
    }

    /// Put the session's last figure back on the turn ("show me that figure again").
    @discardableResult
    func restageLastFigure() -> StagedFigure? {
        guard let last = lastShownFigure else { return nil }
        stagedFigure = last
        return last
    }

    /// Build a staged figure from a retrieved passage, filling in the source file from the vault's
    /// document ledger so the page can be found again. Nil when the passage names no page.
    func makeStagedFigure(for passage: VaultRetriever.Passage?, vaultId: String) -> StagedFigure? {
        guard let passage, let page = passage.page else { return nil }
        let file = VaultImporter.documentLedger(for: vaultId)
            .entries.first { $0.documentId == passage.documentId }?.file
        return StagedFigure(documentId: passage.documentId, documentTitle: passage.documentName,
                            page: page, figure: passage.figure, sourceFile: file)
    }

    /// The PDF in the vault's read-only baseline that a staged figure's page comes from, or nil
    /// when the document was imported as text (or is no longer installed).
    func sourcePDFURL(for figure: StagedFigure) -> URL? {
        guard figure.hasSourcePage, let file = figure.sourceFile, let store = activeVault else { return nil }
        let manifest = store.manifest
        guard let document = manifest.documents.first(where: { $0.file == file }) else { return nil }
        let url = VaultImporter.baselineDirectory(for: manifest.id)
            .appendingPathComponent(manifest.documentRelativePath(document))
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Citations as doors (Plan EK P3)

    /// Where an opened citation came from. A tap and a spoken request are different evidence in an
    /// audit: one is a technician reading the page, the other is a technician asking to be shown it.
    enum CitationOrigin: String, Equatable {
        case chip
        case voice
    }

    /// The ledger entry a staged figure's document was ingested as, when the vault still knows it.
    func ledgerEntry(for figure: StagedFigure) -> VaultDocumentLedger.Entry? {
        guard let store = activeVault else { return nil }
        let ledger = VaultImporter.documentLedger(for: store.manifest.id)
        return ledger.entries.first { $0.documentId == figure.documentId }
            ?? ledger.entries.first { $0.file == figure.sourceFile }
    }

    /// The manifest entry for a staged figure's file.
    func manifestDocument(for figure: StagedFigure) -> VaultDocument? {
        guard let file = figure.sourceFile, let store = activeVault else { return nil }
        return store.manifest.documents.first { $0.file == file }
    }

    /// The manufacturer's own PDF for a staged figure: the imported document when that is a PDF,
    /// otherwise the original bundled beside the extracted text (`source`). Nil when the vault
    /// holds neither — which is what "Original not bundled in this vault" is telling the reader.
    func manufacturerPDFURL(for figure: StagedFigure) -> URL? {
        if let direct = sourcePDFURL(for: figure) { return direct }
        guard let store = activeVault, let document = manifestDocument(for: figure),
              let relative = store.manifest.documentSourceRelativePath(document) else { return nil }
        let url = VaultImporter.baselineDirectory(for: store.manifest.id).appendingPathComponent(relative)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Turn a citation parsed out of an answer back into the page it names, or nil when no manual
    /// in this vault answers to that title. Matching is by the title the ledger recorded, which is
    /// the title the citation was built from, so a chip can only ever open the document it names.
    func stagedFigure(for citation: Citation) -> StagedFigure? {
        guard citation.kind == .manual, let store = activeVault else { return nil }
        let wanted = citation.title.lowercased()
        let entries = VaultImporter.documentLedger(for: store.manifest.id).entries
        guard let entry = entries.first(where: { $0.title.lowercased() == wanted })
                ?? entries.first(where: { $0.title.lowercased().contains(wanted) }) else { return nil }
        return StagedFigure(documentId: entry.documentId, documentTitle: entry.title,
                            page: max(citation.page ?? 1, 1), figure: citation.figure,
                            sourceFile: entry.file)
    }

    /// Everything the figure sheet needs for one staged figure: which document it can show, the
    /// pages it can turn to, the hash the manufacturer's file is checked against, and the
    /// manufacturer's published copy when the manifest names one.
    func manualPageSheet(for figure: StagedFigure) -> ManualPageSheetModel {
        let pdf = manufacturerPDFURL(for: figure)
        let document = manifestDocument(for: figure)
        let entry = ledgerEntry(for: figure)
        let isPDF = document?.isPDF ?? (figure.sourceFile?.lowercased().hasSuffix(".pdf") == true)
        let pages: [ManualPageSheetModel.Page] = isPDF ? [] :
            (documentStore?.pageTexts(documentId: figure.documentId) ?? [])
                .map { .init(number: $0.page, text: $0.text) }
        let published = document?.sourceUrl
            .flatMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }
        return ManualPageSheetModel(
            citation: figure.citation,
            documentTitle: figure.documentTitle,
            citedPage: figure.page,
            manufacturerPDF: pdf,
            pdfPageCount: pdf.map(ManualPageSheetModel.pageCount(ofPDF:)) ?? 0,
            extractedPages: pages,
            publishedURL: published,
            // The document's own hash when the document is the PDF; the original's hash when the
            // PDF is bundled beside extracted text. Comparing the wrong one would report a
            // faithfully imported manual as changed.
            ledgerHash: isPDF ? entry?.contentHash : entry?.sourceContentHash,
            documentIsPDF: isPDF)
    }

    /// Audit: a technician opened a citation — from a chip under the answer, or by asking.
    func logCitationOpened(_ citation: Citation, origin: CitationOrigin) {
        logger?.append(SessionLogger.Event(
            timestamp: Date(), kind: .citationOpened, text: citation.label,
            payload: ["document": AnyCodable(citation.title),
                      "page": AnyCodable(citation.page ?? 0),
                      "origin": AnyCodable(origin.rawValue),
                      "kind": AnyCodable(citation.kind.rawValue)]))
        let label = citation.label
        attachEvidence { evidence in
            if !evidence.citationsOpened.contains(label) { evidence.citationsOpened.append(label) }
        }
    }

    /// Audit: the page behind a citation was actually put on screen, and against what.
    func logPageVerified(title: String, page: Int, source: ManualPageRoute) {
        logger?.append(SessionLogger.Event(
            timestamp: Date(), kind: .pageVerified, text: "\(title), page \(page)",
            payload: ["document": AnyCodable(title),
                      "page": AnyCodable(page),
                      "source": AnyCodable(source.rawValue)]))
        let label = "\(title), page \(page)"
        attachEvidence { evidence in
            if !evidence.pagesVerified.contains(label) { evidence.pagesVerified.append(label) }
        }
    }

    /// Audit: a page was turned to.
    func logPageViewed(title: String, page: Int) {
        logger?.append(SessionLogger.Event(
            timestamp: Date(), kind: .pageViewed, text: "\(title), page \(page)",
            payload: ["document": AnyCodable(title), "page": AnyCodable(page)]))
    }

    /// Audit: a manual page went to the model as this turn's image.
    func logFigureSent(_ figure: StagedFigure) {
        logger?.append(SessionLogger.Event(
            timestamp: Date(), kind: .figureSent, text: figure.citation,
            payload: ["document": AnyCodable(figure.documentTitle),
                      "page": AnyCodable(figure.page),
                      "figure": AnyCodable(figure.figure ?? "")]))
    }

    /// Audit: a manual figure was put in front of the technician (or could not be).
    func logFigureShown(_ figure: StagedFigure, asPicture: Bool) {
        logger?.append(SessionLogger.Event(
            timestamp: Date(), kind: .figureShown, text: figure.citation,
            payload: ["document": AnyCodable(figure.documentTitle),
                      "page": AnyCodable(figure.page),
                      "figure": AnyCodable(figure.figure ?? ""),
                      "as_picture": AnyCodable(asPicture)]))
    }

    // MARK: - Audit-log convenience

    func logUserMessage(_ text: String) {
        logger?.appendUserMessage(text)
    }

    func logAssistantMessage(_ text: String, citations: [String]? = nil) {
        logger?.appendAssistantMessage(text, citations: citations)
    }

    /// Append a finished capture-flow record to the audit log so `SessionExporter` folds it into
    /// the consolidated export (no-op if no session).
    func logCaptureRecord(_ record: CaptureRecord) {
        logger?.append(record.auditEvent)
        // A reading taken while a task is running belongs to that task; with none running it
        // belongs to the job (Plan EM).
        attachEvidence { evidence in
            if !evidence.readings.contains(record.id) { evidence.readings.append(record.id) }
        }
    }

    /// Append a HECA safety-assessment event to the active session's audit log (no-op if no session).
    func logSafetyAssessment(summary: String, score: Double?) {
        logger?.append(SessionLogger.Event(
            timestamp: Date(), kind: .safetyAssessment, text: summary,
            payload: score.map { ["heca_score": AnyCodable($0)] }))
    }

    /// Offline store-and-forward queue (Plan T). Set by AppState. Photo captures are written to
    /// disk durably by the logger; we additionally enqueue an upload op so the evidence syncs to a
    /// backend when one exists — best-effort, never blocking the capture.
    var offlineQueue: OfflineQueue?

    func attachPhoto(_ data: Data, caption: String? = nil) -> URL? {
        let url = logger?.attachPhoto(data, caption: caption)
        if let url {
            let name = url.lastPathComponent
            attachEvidence { evidence in
                if !evidence.photos.contains(name) { evidence.photos.append(name) }
            }
        }
        if let url, let sessionId = activeSession?.id {
            offlineQueue?.enqueue(QueuedOp.make(
                kind: .photoUpload, sessionId: sessionId,
                json: ["path": url.path, "caption": caption ?? ""]))
        }
        return url
    }

    // MARK: - Procedures

    /// "id — title" summaries of procedures available in the active session's vault.
    func availableProcedures() -> [String] {
        library?.summaries() ?? []
    }

    /// Structured procedure definitions available in the active session's vault (empty when
    /// no session is active). Backs the HUD launcher's SOPs branch (Display Phase 4 / Plan Y).
    func availableProcedureDefinitions() -> [Procedure] {
        library?.all ?? []
    }

    /// The step the active procedure is currently on, if a procedure is running.
    var activeProcedureStep: Procedure.Step? { runner?.currentStep }

    /// Title of the active procedure, if any.
    var activeProcedureTitle: String? { runner?.procedure.title }

    /// Begin a procedure by id. Requires an active session and no procedure already running.
    @discardableResult
    func startProcedure(id: String) throws -> Procedure.Step {
        guard activeSession != nil, let logger else { throw FieldSessionError.noActiveSession }
        guard runner == nil else { throw FieldSessionError.procedureAlreadyRunning }
        guard let procedure = library?.procedure(id: id) else { throw FieldSessionError.unknownProcedure(id) }
        let newRunner = try ProcedureRunner(starting: procedure, logger: logger)
        runner = newRunner
        activeProcedureId = procedure.id
        guard let entry = newRunner.currentStep else { throw FieldSessionError.unknownProcedure(id) }
        return entry
    }

    @discardableResult
    func advanceProcedure(choice: String?) throws -> ProcedureRunner.Transition {
        guard let runner else { throw FieldSessionError.noProcedureRunning }
        let transition = try runner.advance(choice: choice)
        if case .completed(let outcome) = transition {
            closeTaskForProcedure(id: activeProcedureId, outcome: outcome)
            clearRunner()
        }
        return transition
    }

    @discardableResult
    func procedureBack() throws -> Procedure.Step {
        guard let runner else { throw FieldSessionError.noProcedureRunning }
        return try runner.goBack()
    }

    @discardableResult
    func procedureRepeat() throws -> Procedure.Step {
        guard let runner else { throw FieldSessionError.noProcedureRunning }
        return try runner.repeatStep()
    }

    func completeProcedure(outcome: String) throws {
        guard let runner else { throw FieldSessionError.noProcedureRunning }
        _ = runner.complete(outcome: outcome)
        closeTaskForProcedure(id: activeProcedureId, outcome: outcome)
        clearRunner()
    }

    private func clearRunner() {
        runner = nil
        activeProcedureId = nil
    }

    // MARK: - Export

    /// Export a session's compliance artifacts (consolidated JSON audit and/or PDF work order).
    /// Defaults to the active session, falling back to the most recent. Returns one protected
    /// staging lease per artifact; holding a lease is what keeps its file.
    @discardableResult
    func exportSession(id: String? = nil,
                       formats: Set<SessionExporter.Format> = [.json, .pdf]) throws -> [StagedExportLease] {
        guard let sessionId = id ?? activeSession?.id ?? history.first?.id else {
            throw FieldSessionError.noActiveSession
        }
        let dir = sessionsRoot.appendingPathComponent(sessionId, isDirectory: true)
        let leases = try SessionExporter.export(sessionDir: dir, formats: formats)
        // Plan T: store-and-forward the audit — enqueue an op so the export syncs to a backend
        // when one exists (no-op locally beyond a queued tombstone until a networked sink lands).
        // The op records which formats were produced, never their paths: a staged artifact's path
        // is a lease that outlives neither the share nor the TTL, and the queue is durable.
        offlineQueue?.enqueue(QueuedOp.make(
            kind: .auditExport, sessionId: sessionId,
            json: ["formats": formats.map(\.rawValue).sorted(),
                   "exportedAt": Date().timeIntervalSince1970]))
        return leases
    }

    // MARK: - History

    private func loadHistory() {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: sessionsRoot, includingPropertiesForKeys: nil) else {
            history = []
            return
        }
        var loaded: [FieldSession] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for dir in entries where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let meta = dir.appendingPathComponent("session.json")
            if let data = try? Data(contentsOf: meta), let session = try? decoder.decode(FieldSession.self, from: data) {
                loaded.append(session)
            }
        }
        history = loaded.sorted { $0.startedAt > $1.startedAt }
    }

    /// If the previous app run was interrupted (in_progress session left behind), pick it up.
    private func restoreInProgressSessionIfAny() {
        guard let inProgress = history.first(where: { $0.endedAt == nil && $0.outcome != .cancelled }) else { return }
        guard let manifest = VaultRegistry.shared.manifest(id: inProgress.vaultId) else { return }
        let store = VaultRegistry.shared.store(for: manifest)
        activeSession = inProgress
        activeVault = store
        modelIndex = VaultModelIndex(store: store)
        partsIndex = VaultPartsIndex(store: store)
        // The machine is part of the session record, so a crash-restored session still knows what
        // it is standing in front of.
        activeEquipment = inProgress.equipment
        library = ProcedureLibrary(store: store)
        let restoredLogger = SessionLogger(session: inProgress, root: sessionsRoot.appendingPathComponent(inProgress.id, isDirectory: true))
        logger = restoredLogger
        reconstructRunner(from: restoredLogger.readEvents(), logger: restoredLogger)
        // On crash recovery, treat the session as paused so the user must explicitly resume.
        if inProgress.pausedAt == nil {
            _ = try? pauseSession()
        } else {
            lastResumeAt = nil
        }
    }

    /// Rebuild the active `ProcedureRunner` from the audit log, if a procedure was in progress
    /// when the app was interrupted. Replays procedure events, using the visited-stack snapshot
    /// carried in the last `procedureStep` event to restore position.
    private func reconstructRunner(from events: [SessionLogger.Event], logger: SessionLogger) {
        var activeProcId: String?
        var stack: [String] = []
        for event in events {
            switch event.kind {
            case .procedureStarted:
                activeProcId = event.payload?["procedure_id"]?.value as? String
                stack = (event.payload?["entry_step"]?.value as? String).map { [$0] } ?? []
            case .procedureStep:
                if let snapshot = event.payload?["stack"]?.value as? [Any] {
                    stack = snapshot.compactMap { $0 as? String }
                }
            case .procedureCompleted:
                activeProcId = nil
                stack = []
            default:
                break
            }
        }
        guard let procId = activeProcId, let procedure = library?.procedure(id: procId) else { return }
        runner = ProcedureRunner(restoring: procedure, visited: stack, logger: logger)
        activeProcedureId = procId
    }

    /// Accumulate billable seconds since the last resume.
    private func accumulateBillableTime(into session: inout FieldSession) {
        if let lastResumeAt {
            session.billableSeconds += Date().timeIntervalSince(lastResumeAt)
        }
        self.lastResumeAt = nil
    }
}

// MARK: - Errors

enum FieldSessionError: LocalizedError {
    case alreadyActive
    case noActiveSession
    case unknownVault(String)
    case vaultLocked(String)
    case procedureAlreadyRunning
    case noProcedureRunning
    case unknownProcedure(String)
    case unknownTask(String)
    case taskNeedsTitle
    case taskAlreadyClosed(String, String)
    case recommendationNeedsCitation

    var errorDescription: String? {
        switch self {
        case .alreadyActive: return "A Field Assist session is already active. End it before starting another."
        case .noActiveSession: return "No active Field Assist session."
        case .unknownVault(let id): return "Unknown vault: \(id)"
        case .vaultLocked(let id): return "The '\(id)' vault is locked. Unlock the corresponding pack to use it."
        case .procedureAlreadyRunning: return "A procedure is already running. Complete it before starting another."
        case .noProcedureRunning: return "No procedure is currently running. Start one first."
        case .unknownProcedure(let id): return "Unknown procedure: \(id)"
        case .unknownTask(let id): return "No task with id \(id) on this job."
        case .taskNeedsTitle: return "A task needs a title — say what is to be done."
        case .taskAlreadyClosed(let title, let status):
            return "'\(title)' is already \(status.replacingOccurrences(of: "_", with: " "))."
        case .recommendationNeedsCitation:
            return "A recommendation needs a citation. Look the answer up in the manuals first, then recommend it with the source you found."
        }
    }
}

// MARK: - Array helpers

private extension Array where Element == FieldSession {
    /// Return a new array with the first session matching id replaced.
    func replacingFirst(matching id: String, with replacement: FieldSession) -> [FieldSession] {
        var copy = self
        if let idx = copy.firstIndex(where: { $0.id == id }) {
            copy[idx] = replacement
        }
        return copy
    }
}
