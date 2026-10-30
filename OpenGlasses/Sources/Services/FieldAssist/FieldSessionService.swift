import Foundation
import CoreLocation
import UIKit

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

    private var logger: SessionLogger? {
        didSet {
            conversationSourceIDs = nil
            // A filing on one job never withholds a line on the next.
            recentTechnicianTurns = []
            pendingTurnWithhold = nil
            // …and an answer on one job is never logged, or prefaced, on the next.
            loggedLearningAnswers = []
            pendingDisclosure = nil
        }
    }
    private var conversationSourceIDs: Set<String>?
    private var lastResumeAt: Date?
    private var accessExpiryTask: Task<Void, Never>?
    /// App teardown and delivery after an access loss has durably closed the job.
    var onAccessClosed: ((FieldSession) -> Void)?
    /// The open job's number or unit just changed, by whichever route: the Job tab, `field_session`,
    /// the intake, `equipment_lookup`, a tap on the phone's model list. What the job's conversation
    /// is called follows it (Plan KE).
    var onJobIdentityChanged: (() -> Void)?
    private var lockedSessionIDs: Set<String> = {
        guard let departure = OrgDepartureService.loadStored(), departure.reason != .lapsed else { return [] }
        return Set(departure.sessionIds)
    }()
    var lockedManagedRecordIDs: Set<String> { lockedSessionIDs }

    func managedRecordIDs(since enrolledAt: Date) -> [String] {
        let held = history + lockedSessionIDs.compactMap { storedSession(id: $0) }
        return Array(Set(held.filter { $0.startedAt >= enrolledAt }.map(\.id))).sorted()
    }

    func restoreRecordsAfterRenewal() {
        guard OrgProfileManager.shared.lease?.isInForce == true else { return }
        if let departure = OrgDepartureService.loadStored(), departure.reason != .lapsed {
            lockedSessionIDs = Set(departure.sessionIds)
        } else {
            lockedSessionIDs = []
        }
        loadHistory()
    }

    private var hasCurrentWorkAccess: Bool {
        FieldAssistEntitlement.shared.has(.fieldWork) && !OrgProfileManager.shared.contentLocked
    }

    /// Procedures available in the active session's vault.
    private var library: ProcedureLibrary?
    /// The currently running procedure, if any.
    private var runner: ProcedureRunner?

    /// Id of the procedure currently running (nil when none). Published for UI.
    @Published private(set) var activeProcedureId: String?

    /// The rule chain running on this job, if any (Plan JJ P2). Read through `activeChain`, which
    /// holds it to the session it was started in.
    var chainRun: ActiveChainRun?
    /// The chain the model proposed on this job and read back, waiting for the technician's go
    /// (Plan JJ P3). Read through `pendingProposal`, which holds it to its session.
    var chainProposal: PendingChainProposal?
    /// The last proposed chain that ran to a result on this job: what "keep that chain" keeps.
    var lastProposedResult: PendingChainProposal?
    /// Whether the organisation's office is this phone's destination. A kept chain also goes to
    /// its review through the team-learning bundle then; without it, keeping and sharing work on
    /// the phone alone (Plan JJ P3). Injectable for tests.
    var chainOfficeConfigured: () -> Bool = { AppState.officeIsReportDestination }
    /// Where a kept chain is filed for the office's review. Nil is the shared service.
    var chainReviewCandidates: LearningCandidateService?

    /// The drawing this turn points at, or nil when it points at none (Plan EK P2). Published so
    /// the phone can put the page in front of the technician while the model is still answering.
    @Published private(set) var stagedFigure: StagedFigure?
    /// The last answer's sources and the "show me" pages (Plan IN P2). Injectable for tests.
    var sourceCenter: ShowSourceCenter = .shared

    /// The last figure this session put on the phone. Kept after `stagedFigure` clears so "show me
    /// that figure again" has something to reopen. A page staged for the model only was never
    /// shown, so it never becomes this (Plan KD P3).
    private(set) var lastShownFigure: StagedFigure?

    /// The label of the table `table_lookup` last read this session ("Table 98"): a retrieved
    /// table under this label may go to the model as the turn's picture (Plan KD P3).
    private(set) var lookedUpTableLabel: String?

    /// The machine the session believes is in front of the technician (Plan EL). Published so the
    /// phone and the lens can say which model the answers are for.
    @Published private(set) var activeEquipment: EquipmentIdentity?

    /// The active vault's model index, derived once per session from its core headings. Empty for a
    /// vault that names no models, which makes every identity feature a no-op there.
    private(set) var modelIndex = VaultModelIndex(vaultName: "", files: [])

    private let sessionsRoot: URL

    /// Where a job's model usage is read from (Plan GD1). The app's one tracker; a test points it
    /// at a tracker over a temporary store and states the figures.
    var usageTracker: UsageTracker

    init(sessionsRoot: URL? = nil) {
        usageTracker = UsageTracker.shared
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.sessionsRoot = sessionsRoot ?? documents.appendingPathComponent("FieldSessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.sessionsRoot, withIntermediateDirectories: true)
        loadHistory()
        restoreInProgressSessionIfAny()
        // Fold the running clock into the saved total whenever the app leaves the foreground, so a
        // kill in the background loses nothing already worked (Plan GB P3).
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkpointBillableTime() }
        }
    }

    private var backgroundObserver: NSObjectProtocol?

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
        guard hasCurrentWorkAccess, VaultRegistry.shared.isUnlocked(manifest) else {
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
            billableSeconds: 0,
            billingBasis: Config.fieldAssistBillingBasis,
            minutesPerBillingUnit: Config.fieldAssistMinutesPerBillingUnit
        )
        // "Start job 1005" is one step; starting without a number leaves the intake owing one, and
        // the app — not the model — asks for it (Plan FO P1).
        let intake = JobIntakeState.needsReference.advance(.jobStarted(reference: jobReference))
        session.reportedBy = Config.reportIdentity
        session.jobReference = intake.recordedReference
        session.jobIntake = intake.state
        session.vaultOnly = manifest.isVaultOnly ? true : nil

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
        scheduleAccessCheck()
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
        guard hasCurrentWorkAccess, VaultRegistry.shared.isUnlocked(session.vaultId) else {
            reconcileAccess()
            throw FieldSessionError.vaultLocked(session.vaultId)
        }
        guard session.pausedAt != nil else { return session }
        session.pausedAt = nil
        session.appClosedPause = nil
        session.resumedAt = Date()
        session.outcome = .inProgress
        activeSession = session
        history = history.replacingFirst(matching: session.id, with: session)
        logger.updateSession { $0 = session }
        logger.appendLifecycle(.sessionResumed)
        lastResumeAt = Date()
        scheduleAccessCheck()
        return session
    }

    /// Check verified access, never the fact that a job happened to be left open. A receipt
    /// still being restored is unknown; it must not close a legitimate subscriber's job.
    func reconcileAccess() {
        for id in lockedSessionIDs {
            if let closed = storedSession(id: id), closed.accessClosureReason != nil {
                try? ensureHandoverQueued(closed)
            }
        }
        for closed in history where closed.accessClosureReason != nil && closed.endedAt != nil {
            try? ensureHandoverQueued(closed)
        }
        guard let session = activeSession else { return }
        let decision = FieldAssistEntitlement.shared.decision()
        let expired: Bool
        if case .expired = decision.denial { expired = true } else { expired = false }
        guard decision.isGranted || expired || StoreKitService.shared.hasCheckedEntitlements else { return }
        if !hasCurrentWorkAccess || !VaultRegistry.shared.isUnlocked(session.vaultId) {
            _ = try? closeForAccessLoss(reason: "Field Assist access ended. The job was automatically closed for handover.")
        } else {
            if activeVault == nil, let manifest = VaultRegistry.shared.manifest(id: session.vaultId) {
                let store = VaultRegistry.shared.store(for: manifest)
                activeVault = store
                modelIndex = VaultModelIndex(store: store)
                partsIndex = VaultPartsIndex(store: store)
                activeEquipment = session.equipment
                library = ProcedureLibrary(store: store)
                if let logger { reconstructRunner(from: logger.readEvents(), logger: logger) }
            }
            scheduleAccessCheck()
        }
    }

    /// Security closure is not a claim that the work passed inspection or that a customer
    /// signed it. Preserve open tasks and evidence, record the reason and queue a deferred record.
    @discardableResult
    func closeForAccessLoss(reason: String) throws -> FieldSession {
        guard activeSession != nil else { throw FieldSessionError.noActiveSession }
        mutateSession { $0.accessClosureReason = reason; return () }
        recordEscalation(reason: reason)
        let ended = try endSession(outcome: .deferred)
        onAccessClosed?(ended)
        return ended
    }

    /// The departure can restart before this service restores a job. Close directly from its
    /// saved metadata in that case, without loading the withdrawn vault or exposing its history.
    func closeManagedRecordForDeparture(id: String, reason: String) throws {
        if activeSession?.id == id {
            let ended = try closeForAccessLoss(reason: reason)
            try ensureHandoverQueued(ended)
            return
        }
        guard var session = storedSession(id: id) else { return }
        if session.endedAt != nil {
            if session.accessClosureReason != nil { try ensureHandoverQueued(session) }
            return
        }
        let directory = sessionDirectory(sessionId: id)
        let log = SessionLogger(session: session, root: directory)
        let recovery = BillableClock.recover(session: session,
            lastEvidenceOfLife: log.readEvents().map(\.timestamp).max(), now: Date())
        session.billableSeconds += recovery.creditedSeconds
        session.endedAt = Date()
        session.outcome = .deferred
        session.accessClosureReason = reason
        session.escalations.append(.init(timestamp: Date(), reason: reason, resolvedAt: nil))
        session.dropOfficeSuppliedContext()
        log.updateSession { $0 = session }
        log.appendLifecycle(.sessionEnded, note: reason)
        try ensureHandoverQueued(session)
    }

    private func ensureHandoverQueued(_ session: FieldSession) throws {
        guard let offlineQueue else { throw CocoaError(.fileWriteUnknown) }
        guard !offlineQueue.containsWorkRecord(sessionId: session.id) else { return }
        let record = WorkRecord(session: session, vaultName: session.vaultId,
                                usage: jobUsage(sessionId: session.id),
                                capturedManuals: capturedManualReferences(for: session))
        offlineQueue.enqueue(QueuedOp.make(workRecord: record))
        guard offlineQueue.containsWorkRecord(sessionId: session.id) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Delivery retains the original files; interactive job/history/export paths lose access.
    func lockManagedRecords(ids: Set<String>) {
        lockedSessionIDs.formUnion(ids)
        history.removeAll { ids.contains($0.id) }
    }

    private func storedSession(id: String) -> FieldSession? {
        guard UUID(uuidString: id) != nil else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: sessionDirectory(sessionId: id).appendingPathComponent("session.json")) else { return nil }
        return try? decoder.decode(FieldSession.self, from: data)
    }

    /// Narrow delivery-only read for the already queued report; never a model or UI history read.
    func handoverWorkRecord(sessionId: String) -> WorkRecord? {
        guard let session = storedSession(id: sessionId) else { return nil }
        return WorkRecord(session: session, vaultName: session.vaultId,
                          usage: jobUsage(sessionId: sessionId),
                          capturedManuals: capturedManualReferences(for: session))
    }

    func departureThreadID(sessionId: String) -> String? {
        storedSession(id: sessionId)?.conversationThreadId
    }

    private func scheduleAccessCheck() {
        accessExpiryTask?.cancel()
        guard let expiry = FieldAssistEntitlement.shared.nextExpiration else {
            // The last grant may have expired while the vault was being loaded. Do not lose
            // the deadline just because it is no longer in the future when scheduling finishes.
            if let session = activeSession,
               !hasCurrentWorkAccess || !VaultRegistry.shared.isUnlocked(session.vaultId) {
                accessExpiryTask = Task { @MainActor [weak self] in self?.reconcileAccess() }
            }
            return
        }
        let delay = max(0, expiry.timeIntervalSince(FieldAssistEntitlement.shared.clock()))
        accessExpiryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.reconcileAccess()
        }
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
        // The office's history and site requirements were for the visit, not for the phone to
        // keep: the finished job holds only how much there was (Plan HU).
        session.dropOfficeSuppliedContext()
        history = history.replacingFirst(matching: session.id, with: session)
        logger.updateSession { $0 = session }
        logger.appendLifecycle(.sessionEnded, note: "outcome=\(outcome.rawValue), billable_seconds=\(Int(session.billableSeconds))")
        // The visit's record leaves as its own queued operation, whatever else the session does
        // with it (Plan EM). The queue's sink is unchanged — this is a durable local tombstone
        // until a configured endpoint exists.
        let endedVaultName = activeVault?.manifest.name ?? session.vaultId
        let record = WorkRecord(session: session, vaultName: endedVaultName,
                                vaultSourceNote: VaultSourceBadge.forInstalledVault(id: session.vaultId)?
                                    .recordLine(vaultName: endedVaultName),
                                usage: jobUsage(sessionId: session.id),capturedManuals:capturedManualReferences(for:session))
        offlineQueue?.enqueue(QueuedOp.make(workRecord: record))
        activeSession = nil
        accessExpiryTask?.cancel()
        accessExpiryTask = nil
        activeVault = nil
        activeEquipment = nil
        modelIndex = VaultModelIndex(vaultName: "", files: [])
        partsIndex = VaultPartsIndex(files: [])
        stagedFigure = nil
        lastShownFigure = nil
        lookedUpTableLabel = nil
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
        // A different unit: another vault section, or — for a unit the vault does not cover —
        // another statement (Plan GB P2).
        if let previous = session.equipment, previous.heading != identity.heading,
           previous.unitKey != identity.unitKey {
            session.continuityScope = UUID().uuidString
            runner = nil
            activeProcedureId = nil
            // The job has moved off the unit the earlier work was attached to (Plan GD2).
            session.earlierWorkAttachedAt = nil
        }
        // The job's first identification, arriving after work was already recorded (Plan GD2): the
        // work stays on this unit — usually right — and the marker lets the tool say so and offer
        // `separate_earlier_work` when it was another machine. Nothing is guessed either way.
        if session.equipment == nil, session.hasWorkInCurrentScope {
            session.earlierWorkAttachedAt = Date()
        }
        session.equipment = identity
        // Every unit the job has been on, in the order they were first seen (Plan FO P1). Recorded
        // here rather than in the guided flow, because a job also reaches this by a spoken
        // correction, a tap on the phone's model list and a work order's asset id — a list that is
        // only filled by one of the four routes is not a record of the job. One entry per scope
        // (Plan GB P2): two identical machines are two units, and re-identifying the one in front
        // of the technician is not a second one.
        if !session.visitedUnits.contains(where: { $0.continuityScope == session.continuityScope }) {
            session.visitedUnits.append(VisitedUnit(identity: identity, serial: nil,
                                                    continuityScope: session.continuityScope))
        }
        activeSession = session
        activeEquipment = identity
        history = history.replacingFirst(matching: session.id, with: session)
        logger?.updateSession { $0 = session }
        var payload: [String: AnyCodable] = ["model": AnyCodable(identity.modelToken),
                                             "heading": AnyCodable(identity.heading),
                                             "file": AnyCodable(identity.file),
                                             "source": AnyCodable(identity.source.rawValue)]
        if let stated = identity.statedModel { payload["stated_model"] = AnyCodable(stated) }
        payload["vault_match"] = AnyCodable(identity.vaultMatch?.kind.rawValue ?? "none")
        // The nameplate's own text is audit material — it is what the recognition was based on —
        // and it never goes anywhere near a prompt.
        if let nameplate = identity.nameplateText { payload["nameplate_text"] = AnyCodable(nameplate) }
        logger?.append(.init(timestamp: Date(), kind: .equipmentRecognised,
                             text: identity.heading, payload: payload))
        refreshSiteSystem()
        onJobIdentityChanged?()
    }

    /// The technician restated the model of the unit they are on (Plan GB P2) — "no, the model is
    /// SLP99UH090XV48C". The same unit, restated: the scope, the work and when the unit was first
    /// recognised all stay; what was said and what it matched are replaced, and the change is
    /// logged as a correction. With no unit yet, it is simply the first identification.
    @discardableResult
    func correctEquipment(_ replacement: EquipmentIdentity) -> EquipmentIdentity {
        guard var session = activeSession, let current = session.equipment else {
            setEquipment(replacement)
            return replacement
        }
        let corrected = current.corrected(to: replacement)
        session.equipment = corrected
        let unit = VisitedUnit(identity: corrected, continuityScope: session.continuityScope,
                               firstSeenAt: current.recognisedAt)
        if let index = session.visitedUnits.lastIndex(where: { $0.continuityScope == session.continuityScope }) {
            let serial = session.visitedUnits[index].serial
            session.visitedUnits[index] = serial.map(unit.withSerial) ?? unit
        } else {
            session.visitedUnits.append(unit)
        }
        activeSession = session
        activeEquipment = corrected
        history = history.replacingFirst(matching: session.id, with: session)
        logger?.updateSession { $0 = session }
        logger?.append(.init(timestamp: Date(), kind: .equipmentCorrected, text: corrected.stated,
                             payload: ["from": AnyCodable(current.stated),
                                       "to": AnyCodable(corrected.stated),
                                       "heading": AnyCodable(corrected.heading),
                                       "vault_match": AnyCodable(corrected.vaultMatch?.kind.rawValue ?? "none")]))
        refreshSiteSystem()
        onJobIdentityChanged?()
        return corrected
    }

    /// "Next unit": the technician moves to another machine on the same job (Plan GB P2), with or
    /// without its model. Work from here on is recorded against the new unit; the one before keeps
    /// its own.
    func startNextUnit(_ identity: EquipmentIdentity?) {
        guard var session = activeSession else { return }
        session.continuityScope = UUID().uuidString
        runner = nil
        activeProcedureId = nil
        session.earlierWorkAttachedAt = nil
        session.equipment = identity
        if let identity {
            session.visitedUnits.append(VisitedUnit(identity: identity, continuityScope: session.continuityScope))
        }
        activeSession = session
        activeEquipment = identity
        history = history.replacingFirst(matching: session.id, with: session)
        logger?.updateSession { $0 = session }
        logger?.append(.init(timestamp: Date(), kind: .unitStarted, text: identity?.stated,
                             payload: ["scope": AnyCodable(session.continuityScope),
                                       "stated_model": AnyCodable(identity?.stated ?? ""),
                                       "vault_match": AnyCodable(identity?.vaultMatch?.kind.rawValue ?? "none")]))
        if identity != nil { refreshSiteSystem() }
        onJobIdentityChanged?()
    }

    /// Whether the job's first identification landed on work already recorded (Plan GD2) — what
    /// the identification reply adds its sentence for, and what `separateEarlierWork` needs.
    var earlierWorkAttached: Bool { activeSession?.earlierWorkAttachedAt != nil }

    /// "That was a different unit" (Plan GD2): the work recorded before the first identification
    /// belongs to another machine. The earlier work keeps its scope — `UnitLedger` then prints it as
    /// an unidentified unit — and the identified machine moves to a scope of its own, keeping when
    /// it was first seen. Nothing is inferred: this runs only because the technician said so, and
    /// only when the first identification attached earlier work. Returns false otherwise.
    @discardableResult
    func separateEarlierWork() -> Bool {
        guard var session = activeSession, session.earlierWorkAttachedAt != nil else { return false }
        let earlierScope = session.continuityScope
        let unitScope = UUID().uuidString
        session.continuityScope = unitScope
        runner = nil
        activeProcedureId = nil
        if let index = session.visitedUnits.lastIndex(where: { $0.continuityScope == earlierScope }) {
            session.visitedUnits[index] = session.visitedUnits[index].rescoped(to: unitScope)
        } else if let equipment = session.equipment {
            session.visitedUnits.append(VisitedUnit(identity: equipment, continuityScope: unitScope,
                                                    firstSeenAt: equipment.recognisedAt))
        }
        // Only the earlier work stays behind. Anything recorded since the identification — a
        // nameplate field, a task, a reading — was recorded on the machine just identified and moves
        // with it; what was recorded before it is the earlier work, and keeps its scope untouched.
        if let identifiedAt = session.equipment?.recognisedAt {
            for field in session.identityFields where field.recordedAt >= identifiedAt {
                let key = field.name.lowercased()
                if (session.identityEquipmentScopes[key] ?? "initial") == earlierScope {
                    session.identityEquipmentScopes[key] = unitScope
                }
            }
            for task in session.tasks where task.createdAt >= identifiedAt
                && (session.taskEquipmentScopes[task.id] ?? "initial") == earlierScope {
                session.taskEquipmentScopes[task.id] = unitScope
            }
            session.spokenReadings = session.spokenReadings.map { reading in
                guard reading.at >= identifiedAt, reading.unitScope == earlierScope else { return reading }
                return reading.movedToScope(unitScope)
            }
        }
        session.earlierWorkAttachedAt = nil
        activeSession = session
        history = history.replacingFirst(matching: session.id, with: session)
        logger?.updateSession { $0 = session }
        logger?.append(.init(timestamp: Date(), kind: .unitSplit, text: session.equipment?.stated,
                             payload: ["earlier_scope": AnyCodable(earlierScope),
                                       "unit_scope": AnyCodable(unitScope),
                                       "stated_model": AnyCodable(session.equipment?.stated ?? "")]))
        return true
    }

    /// The machines this job covered and the work done on each (Plan GB P2).
    var unitLedger: UnitLedger {
        activeSession.map(UnitLedger.init(session:)) ?? UnitLedger(units: [])
    }

    /// Units the technician named that the vault does not cover, by unit key — in scope because
    /// the technician said so.
    private var assertedUnitKeys: Set<String> {
        guard let session = activeSession else { return [] }
        var keys = Set(session.visitedUnits
            .filter { $0.statedModel != nil && $0.vaultMatchKind == nil }
            .map { EquipmentRecognition.normalised($0.stated) })
        if let active = session.equipment, active.isOutOfVault { keys.insert(active.unitKey) }
        return keys
    }

    /// Forget it — a wrong read, or the technician has moved to another unit.
    func clearEquipment() {
        guard var session = activeSession else { return }
        let previous = session.equipment
        session.continuityScope = UUID().uuidString
        runner = nil
        activeProcedureId = nil
        session.equipment = nil
        session.earlierWorkAttachedAt = nil
        activeSession = session
        activeEquipment = nil
        history = history.replacingFirst(matching: session.id, with: session)
        logger?.updateSession { $0 = session }
        logger?.append(.init(timestamp: Date(), kind: .equipmentCleared, text: previous?.heading,
                             payload: previous.map { ["model": AnyCodable($0.modelToken),
                                                      "heading": AnyCodable($0.heading)] }))
        onJobIdentityChanged?()
    }

    /// Is this turn about a machine these manuals are for? Runs before retrieval everywhere, so a
    /// question about another manufacturer's unit is answered with the scope sentence rather than
    /// with passages that are genuinely about the subject and genuinely about the wrong machine.
    func equipmentScope(turn: String?, nameplateText: String? = nil) -> EquipmentScopeCheck.Outcome {
        EquipmentScopeCheck.check(text: turn, nameplateText: nameplateText,
                                  index: modelIndex, active: activeEquipment,
                                  asserted: assertedUnitKeys)
    }

    /// The retriever's view of the active machine: every spelling of it, every spelling of every
    /// other model the vault names, and the documents the vault assigns it. A series member has no
    /// section, so it has no spellings to score text by, only its series' documents. Nil when
    /// nothing is active, the vault names no models, or a series member has no documents named.
    var retrievalModelScope: VaultRetriever.ModelScope? {
        guard let active = activeEquipment, !modelIndex.isEmpty else { return nil }
        let assigned = Set(assignedDocuments.map(\.id))
        guard let model = modelIndex.models.first(where: { $0.heading == active.heading }) else {
            guard active.isSeriesMember, !assigned.isEmpty else { return nil }
            return VaultRetriever.ModelScope(activeTokens: [], otherTokens: [], assignedDocumentIds: assigned)
        }
        return VaultRetriever.ModelScope(activeTokens: Set(model.tokens), otherTokens: modelIndex.knownModelTokens,
                                         assignedDocumentIds: assigned)
    }

    /// The vault's manuals the active unit's section names, by title so the prompt reads the same
    /// each turn (Plan KE P1): empty for a vault whose sections name none, and with no unit.
    var assignedDocuments: [(id: String, title: String)] {
        guard let active = activeEquipment, let store = activeVault, let documentStore else { return [] }
        let sections = active.isSeriesMember ? modelIndex.seriesModels
            : modelIndex.models.filter { $0.heading == active.heading }
        guard sections.contains(where: { !$0.body.isEmpty }) else { return [] }
        let documents = documentStore.list(namespace: DocumentStore.vaultNamespace(store.manifest.id))
            .map { (id: $0.id, title: $0.name) }
        let assigned = sections.reduce(into: Set<String>()) { $0.formUnion($1.assignedDocumentIds(among: documents)) }
        return documents.filter { assigned.contains($0.id) }.sorted { $0.title < $1.title }
    }

    /// The sentence naming the assigned documents, or nil when there is no set. Short: it goes out
    /// on every turn of the job.
    func assignedDocumentsNote() -> String? {
        let titles = assignedDocuments.map(\.title)
        guard let stated = activeEquipment?.stated, !titles.isEmpty else { return nil }
        let named = titles.prefix(Self.assignedTitlesNamed).joined(separator: "; ")
            + (titles.count > Self.assignedTitlesNamed ? " and \(titles.count - Self.assignedTitlesNamed) more" : "")
        return "DOCUMENTS FOR \(stated): \(named). Passages from any other document are not assigned to this model; say so if you use one."
    }

    private static let assignedTitlesNamed = 6

    /// Whether `text` names the active unit and nothing that could change it (`ToolRepeatGuard`).
    func namesOnlyActiveUnit(_ text: String) -> Bool {
        activeEquipment.map { EquipmentRecognition.restates($0, in: text) } ?? false
    }

    /// What the technician said to open the turn in flight, as `TechnicianWords` documents it: nil
    /// for a turn with no captured words, so an agent's or a live session's turn records nothing and
    /// adds nothing. A seam so a test states the words.
    var technicianWords: @MainActor () -> String? = { TechnicianWords.current() }

    /// The last words read for a model, per job: `promptContext` runs again after every tool round
    /// on some routes, and a turn that said "forget the QX100" must not bring it back after the
    /// tool forgot it.
    private var modelReadFrom: (session: String, words: String)?

    /// A turn naming one of the vault's models records it, before anything is retrieved for that
    /// turn (Plan KE P1): when there is no unit yet, or when it spells the active one more fully.
    /// The same identity `equipment_lookup` records, so the job log, the Unit card and the title
    /// follow. Says nothing: the model reads the unit in the turn's own prompt.
    private func recordModelSaid() {
        guard let session = activeSession, session.pausedAt == nil, let said = technicianWords(),
              modelReadFrom?.session != session.id || modelReadFrom?.words != said else { return }
        modelReadFrom = (session.id, said)
        guard let unit = EquipmentRecognition.unitSaid(in: said, active: activeEquipment, index: modelIndex) else { return }
        switch unit.change {
        case .firstUnit: setEquipment(unit.identity)
        case .fullerSpelling: correctEquipment(unit.identity)
        case .sameUnit, .anotherUnit: break
        }
    }

    // MARK: - Work record: tasks, parts, identity (Plan EM)

    /// The active vault's parts table, derived once per session from its core files. Empty for a
    /// vault that lists no parts, which leaves the manuals as the only route to a verification.
    private(set) var partsIndex = VaultPartsIndex(files: [])

    /// Verification of a part number against the vault's parts table first, then its manuals.
    var partsVerifier: PartsVerifier {
        let store = activeVault
        let documentStore = self.documentStore
        return PartsVerifier(index: partsIndex) { [weak self] token in
            guard let self, let store, let documentStore else { return [] }
            // The same availability check the retriever runs. A part number is written into a task
            // and ordered from it, so a citation to a manual that has gone is the last thing this
            // route may produce — verified-from-the-book has to mean a book that is still here.
            let isAvailable = VaultManualRemoval.availabilityCheck(forVault: store.manifest.id,
                                                                   documentStore: documentStore, capturedCatalog:capturedManuals)
            return self.retrievalNamespaces(vaultId: store.manifest.id)
                .filter { $0.source.isReference }
                .flatMap { space in
                    documentStore.passages(containingToken: token, namespace: space.namespace, limit: 3)
                        .filter { passage in
                            space.source == .capturedManual
                                ? self.capturedManuals.available(passage.documentId, session: self.activeSession, vaultID: store.manifest.id)
                                : isAvailable(passage.documentId)
                        }
                }
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
        mutateSession {
            $0.jobReference = trimmed
            $0.jobIntake = .recorded(reference: trimmed)
            return ()
        }
        logger?.append(.init(timestamp: Date(), kind: .jobReferenceSet, text: trimmed, payload: nil))
        onJobIdentityChanged?()
    }

    /// Name or rename the open job (Plan KD P0), in place: the job stays open with everything on
    /// it. Returns false when there is no job or it already has that name — nothing is logged
    /// then, so a name said twice is one line in the job log.
    @discardableResult
    func setJobName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let previous = activeSession, previous.assetId != trimmed else { return false }
        mutateSession {
            $0.assetId = trimmed
            return ()
        }
        logger?.append(.init(timestamp: Date(), kind: .jobNameSet, text: trimmed,
                             payload: previous.assetId.map { ["previous": AnyCodable($0)] }))
        return true
    }

    // MARK: - Guided job flow (Plan FO P1)

    /// Carry what was known before the visit onto the job just started from it (Plan FO P3c):
    /// the site, the fault report as it was given, the brief the technician heard, and the job
    /// file's provenance. **Not** the equipment — a job ahead names machines the office believes
    /// are there, and the machine in front of the technician is recognised on site, as always.
    func applyJobAhead(_ job: UpcomingJob) {
        guard activeSession != nil else { return }
        mutateSession { session in
            session.site = job.site.isEmpty ? nil : job.site
            session.faultReport = job.faultReport
            session.connectorNotes = job.origin == .connector ? job.notes : nil
            session.brief = job.brief
            session.jobFile = job.provenance
            session.jobNeeds = job.needs
            session.officeHistory = job.officeHistory
            session.officeSiteRequirements = job.siteRequirements
            session.officeEquipment = job.officeHistory != nil && !job.equipment.isEmpty ? job.equipment : nil
            session.siteSystem = job.siteSystem
        }
        var payload: [String: AnyCodable] = [
            "origin": AnyCodable(job.origin.rawValue),
            "has_site": AnyCodable(!job.site.isEmpty),
            "has_fault_report": AnyCodable(job.faultReport != nil),
            "has_brief": AnyCodable(job.brief != nil),
        ]
        if let provenance = job.provenance {
            payload["job_file"] = AnyCodable(provenance.fileName)
            payload["signature"] = AnyCodable(provenance.signature.rawValue)
            payload["signer"] = AnyCodable(provenance.signer ?? "")
            payload["received_at"] = AnyCodable(ISO8601DateFormatter().string(from: provenance.receivedAt))
            payload["digest"] = AnyCodable(provenance.digest)
            if let identity = provenance.identity {
                payload["job_id"] = AnyCodable(identity.jobID)
                payload["revision"] = AnyCodable(Int(identity.revision))
            }
        }
        // Counts only: the office's text never reaches the log (Plan HU §2).
        if let history = job.officeHistory {
            payload["office_history_units"] = AnyCodable(history.units.count)
            payload["office_flags"] = AnyCodable(history.flags.count)
        }
        if let requirements = job.siteRequirements {
            payload["office_site_requirements"] = AnyCodable(requirements.items.count)
        }
        logger?.append(.init(timestamp: Date(), kind: .jobAheadStarted,
                             text: job.provenance?.recordLine ?? job.title, payload: payload))
        // The site system the brief matched, then weighed again with what the job ahead says
        // against this vault — a job started without a brief is matched here (Plan HV §3).
        if let match = job.siteSystem { logSiteSystem(match, previous: nil) }
        refreshSiteSystem(adding: SiteSystemEvidence(job: job))
    }

    // MARK: - Site systems (Plan HV)

    /// The open job's matched site document, when the match is about this session's vault.
    var siteSystemDocument: SiteSystemDocument? {
        guard let session = activeSession, let match = session.siteSystem,
              match.applies(toVault: session.vaultId), let siteId = match.siteId else { return nil }
        return activeVault?.siteDocument(id: siteId)
    }

    /// The matched site's unit that is the one in front of the technician, when it can be told.
    var siteSystemActiveUnit: SiteSystemDocument.Unit? {
        guard let session = activeSession, let document = siteSystemDocument else { return nil }
        return SiteSystemMatcher.unit(in: document, model: session.equipment?.modelToken,
                                      serial: activeSerial, modelKey: SiteSystemMatcher.modelKey(index: modelIndex))
    }

    /// The model's block for the matched site, or nothing.
    func siteSystemLines(limit: Int = SiteSystemContract.characterLimit) -> [String] {
        guard let session = activeSession else { return [] }
        return SiteSystemContract.lines(match: session.siteSystem, document: siteSystemDocument,
                                        vaultId: session.vaultId, activeUnitID: siteSystemActiveUnit?.id,
                                        sourceFormat: activeVault?.manifest.sourceAttributionFormat, limit: limit)
    }

    /// Work the match out again from everything the job knows: what was kept with the last match,
    /// anything handed in, and what this visit has learned on site — a unit recognised, a serial
    /// written down. A change is logged; the same answer is not. A vault without site documents
    /// does nothing at all.
    func refreshSiteSystem(adding extra: SiteSystemEvidence? = nil) {
        guard let session = activeSession, let store = activeVault else { return }
        let documents = store.siteDocuments()
        guard !documents.isEmpty else { return }
        var evidence = SiteSystemEvidence(session: session)
        if let kept = session.siteSystem, kept.vaultId == session.vaultId { evidence = kept.evidence.merged(with: evidence) }
        if let extra { evidence = evidence.merged(with: extra) }
        let match = SiteSystemMatcher.match(evidence: evidence, documents: documents, vaultId: session.vaultId,
                                            modelKey: SiteSystemMatcher.modelKey(index: modelIndex))
        guard match != session.siteSystem else { return }
        let previous = session.siteSystem
        mutateSession { $0.siteSystem = match }
        // Only a change in what is known is an event; more evidence for the same answer is not.
        if let match, match.strength != previous?.strength || match.siteId != previous?.siteId
            || match.matchedUnitIDs != previous?.matchedUnitIDs {
            logSiteSystem(match, previous: previous)
        }
    }

    /// Identifiers, strength and counts only: never the site's name or any of its text.
    private func logSiteSystem(_ match: SiteSystemMatch, previous: SiteSystemMatch?) {
        var payload: [String: AnyCodable] = [
            "strength": AnyCodable(match.strength.rawValue),
            "candidates": AnyCodable(match.candidateCount),
            "matched_units": AnyCodable(match.matchedUnitIDs.count),
        ]
        if let site = match.siteId { payload["site_id"] = AnyCodable(site) }
        if let basis = match.basis { payload["basis"] = AnyCodable(basis.rawValue) }
        if let previous { payload["previous_strength"] = AnyCodable(previous.strength.rawValue) }
        if let site = previous?.siteId { payload["previous_site_id"] = AnyCodable(site) }
        logger?.append(.init(timestamp: Date(), kind: .siteSystemMatched,
                             text: "site system \(match.strength.rawValue)", payload: payload))
    }

    /// What `equipment_lookup` adds when it records a unit the matched site lists, the first time
    /// that unit is recorded on this job; nil every other time (Plan HV §5).
    func siteSystemAnnouncement() -> String? {
        guard let session = activeSession, let match = session.siteSystem,
              match.applies(toVault: session.vaultId), let siteId = match.siteId,
              let unit = siteSystemActiveUnit,
              let line = SiteSystemContract.announcement(match) else { return nil }
        let already = (logger?.readEvents() ?? []).contains {
            $0.kind == .siteSystemAnnounced && $0.payload?["site_id"]?.value as? String == siteId
                && $0.payload?["unit_id"]?.value as? String == unit.id
        }
        guard !already else { return nil }
        logger?.append(.init(timestamp: Date(), kind: .siteSystemAnnounced, text: "site system announced",
                             payload: ["site_id": AnyCodable(siteId), "unit_id": AnyCodable(unit.id)]))
        return line
    }

    /// The phone has left the organisation: what its office said about the open job's units and
    /// site goes now, not at close (Plan HU, decided 2026-10-20). The jobs ahead, which carry the
    /// rest of it, are erased with the organisation's content.
    func eraseOfficeSuppliedContext() {
        guard let session = activeSession,
              session.officeHistory != nil || session.officeSiteRequirements != nil
                || session.brief?.hasOfficeContent == true else { return }
        mutateSession { $0.dropOfficeSuppliedContext() }
    }

    /// Record that the office's warnings were said as the job started (Plan HU P3), so they are
    /// said once: `officeSiteRequirementsSpoken` and `officeFlagsSpoken`, counts only, never the
    /// text. Returns false — and records nothing — when there is no open job, nothing to say, or
    /// they were already said on this job; resuming it, on this launch or the next, says nothing
    /// more.
    @discardableResult
    func recordOfficeWarningsSpoken(_ warnings: JobStartWarnings) -> Bool {
        guard activeSession != nil, !warnings.isEmpty, !officeWarningsAlreadySpoken else { return false }
        if !warnings.requirements.isEmpty {
            logger?.append(.init(timestamp: Date(), kind: .officeSiteRequirementsSpoken,
                                 text: "\(warnings.requirements.count) office site requirements said at the start",
                                 payload: ["count": AnyCodable(warnings.requirements.count)]))
        }
        if !warnings.flags.isEmpty {
            logger?.append(.init(timestamp: Date(), kind: .officeFlagsSpoken,
                                 text: "\(warnings.flags.count) office flags said at the start",
                                 payload: ["count": AnyCodable(warnings.flags.count),
                                           "read": AnyCodable(min(warnings.flags.count, OfficeWarningSpeech.flagsRead))]))
        }
        return true
    }

    /// Whether the open job's log already says the office's warnings were said.
    var officeWarningsAlreadySpoken: Bool {
        (logger?.readEvents() ?? []).contains { $0.kind == .officeFlagsSpoken || $0.kind == .officeSiteRequirementsSpoken }
    }

    /// Bind the job to a saved conversation, or let go of one.
    ///
    /// Everything the technician says on a job belongs in one thread. This is where the job
    /// records which; `JobThreadCoordinator` is the only thing that decides *what* to pass.
    func bindConversationThread(_ threadId: String?, reason: JobThreadPolicy.BindReason? = nil) {
        guard let session = activeSession, session.conversationThreadId != threadId else { return }
        mutateSession {
            $0.conversationThreadId = threadId
            $0.conversationThreadDetached = false
            return ()
        }
        logger?.append(.init(timestamp: Date(), kind: .jobThreadBound, text: reason?.rawValue,
                             payload: ["thread": AnyCodable(threadId ?? ""),
                                       "reason": AnyCodable(reason?.rawValue ?? "")]))
    }

    /// The technician chose to carry on in a separate chat. The job keeps the thread it owned so
    /// it can still be reviewed; new turns stop landing in it.
    func detachConversationThread() {
        guard activeSession?.conversationThreadDetached == false else { return }
        mutateSession { $0.conversationThreadDetached = true; return () }
        logger?.append(.init(timestamp: Date(), kind: .jobThreadBound, text: "detached",
                             payload: ["detached": AnyCodable(true)]))
    }

    /// Where the job number stands.
    func updateJobIntake(_ state: JobIntakeState) {
        guard let session = activeSession, session.jobIntake != state else { return }
        mutateSession { $0.jobIntake = state; return () }
    }

    /// Record what the app asked and what came back. Both are evidence: an unanswered question
    /// and a declined job number are facts about the visit.
    func logJobQuestion(_ question: String, asked: Bool, answer: String? = nil,
                        detail: [String: AnyCodable] = [:]) {
        var payload = detail
        payload["question"] = AnyCodable(question)
        if let answer { payload["answer"] = AnyCodable(answer) }
        logger?.append(.init(timestamp: Date(),
                             kind: asked ? .jobQuestionAsked : .jobQuestionAnswered,
                             text: answer ?? question, payload: payload))
    }

    /// Hold (or release) a change-of-unit question. Held on the session so an app restart in the
    /// middle of one does not silently drop it.
    func setPendingUnitChange(_ pending: PendingUnitChange?) {
        guard activeSession?.pendingUnitChange != pending else { return }
        mutateSession { $0.pendingUnitChange = pending; return () }
    }

    /// Write the serial onto the unit the job is currently on, so two identical machines on one
    /// site can be told apart in the record. No-op when the serial is already there.
    func recordSerialForActiveUnit(_ serial: String?) {
        guard let serial, !serial.isEmpty else { return }
        mutateSession { session in
            guard let idx = session.visitedUnits.lastIndex(where: {
                $0.continuityScope == session.continuityScope
            }), session.visitedUnits[idx].serial != serial else { return }
            session.visitedUnits[idx] = session.visitedUnits[idx].withSerial(serial)
        }
        refreshSiteSystem()
    }

    /// The serial the session has written down for the machine it is on, if any. `recordIdentityField`
    /// is where serials land, and it is the only thing that tells two identical units apart.
    var activeSerial: String? {
        guard let session = activeSession else { return nil }
        return session.identityFields.last {
            $0.name.lowercased().contains("serial")
                && (session.identityEquipmentScopes[$0.name.lowercased()] ?? "initial") == session.continuityScope
        }?.value
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
            session.identityEquipmentScopes[name.lowercased()] = session.continuityScope
        }
        logger?.append(.init(timestamp: Date(), kind: .identityFieldRecorded, text: field.summary,
                             payload: ["field": AnyCodable(name), "value": AnyCodable(value),
                                       "source": AnyCodable(source.rawValue)]))
        if name.lowercased().contains("serial") { refreshSiteSystem() }
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
        mutateSession {
            $0.tasks.append(task)
            $0.taskEquipmentScopes[task.id] = $0.continuityScope
        }
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
        mutateSession {
            $0.tasks.append(task)
            $0.taskEquipmentScopes[task.id] = $0.continuityScope
        }
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
    ///
    /// `confirmed` is the technician saying the check a fix waits on passed (Plan GB P3). Without
    /// it, a fix that needs a retest closes and leaves an open "Verify: …" task behind, and the
    /// check itself cannot be closed as done at all.
    @discardableResult
    func completeTask(id: String, note: String? = nil, outcome: String? = nil,
                      confirmed: Bool = false) throws -> FieldSession.Task {
        try closeTask(id: id, status: .done, note: note, outcome: outcome, confirmed: confirmed)
    }

    /// Give a task up. Kept on the record — started and not finished is information.
    @discardableResult
    func abandonTask(id: String, note: String? = nil) throws -> FieldSession.Task {
        try closeTask(id: id, status: .abandoned, note: note, outcome: nil)
    }

    @discardableResult
    private func closeTask(id: String, status: FieldSession.Task.Status,
                           note: String?, outcome: String?,
                           confirmed: Bool = false) throws -> FieldSession.Task {
        guard activeSession != nil else { throw FieldSessionError.noActiveSession }
        guard let existing = task(id: id) else { throw FieldSessionError.unknownTask(id) }
        guard existing.status.isOpen else {
            throw FieldSessionError.taskAlreadyClosed(existing.title, existing.status.rawValue)
        }
        let decision = TaskClosePolicy.decide(task: existing, status: status, confirmed: confirmed)
        if case .refuse(let reason) = decision { throw FieldSessionError.verificationOwed(reason) }
        let now = Date()
        mutateSession { session in
            guard let idx = session.tasks.firstIndex(where: { $0.id == id }) else { return }
            session.tasks[idx].status = status
            session.tasks[idx].completedAt = now
            session.tasks[idx].acceptedAt = session.tasks[idx].acceptedAt ?? session.tasks[idx].createdAt
            if let note, !note.isEmpty { session.tasks[idx].completionNote = note }
            if let outcome, !outcome.isEmpty { session.tasks[idx].procedureOutcome = outcome }
            if confirmed, status == .done, session.tasks[idx].verification != nil {
                session.tasks[idx].verification?.verifiedAt = now
            }
            // The fix is done; the check it waits on stays open, on the same unit (Plan GB P3).
            if case .closeSpawningVerification(let title) = decision,
               let requirement = session.tasks[idx].verification {
                let check = FieldSession.Task(
                    title: title, why: requirement.instruction, origin: session.tasks[idx].origin,
                    status: .accepted, createdAt: now, acceptedAt: now, verification: requirement)
                session.tasks.append(check)
                session.taskEquipmentScopes[check.id] = session.taskEquipmentScopes[id] ?? session.continuityScope
            }
        }
        if case .closeSpawningVerification(let title) = decision {
            logger?.append(.init(timestamp: now, kind: .taskProposed, text: title,
                                 payload: ["origin": AnyCodable("verification"),
                                           "for_task_id": AnyCodable(id)]))
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

    /// The technician said the final check passed — "the test run was fine, the furnace is
    /// working" — as the job closes. Recorded where the report can show it.
    ///
    /// A check already owed closes on it, confirmed. Otherwise, once a repair is done and nothing
    /// has verified it, the check goes on the job as a done "Verify: …" task with their words: a
    /// tester's report listed two ignitor replacements and not the test run that proved them.
    /// Nothing is recorded when no work was done, or a check already passed.
    @discardableResult
    func recordPassedFinalCheck(note: String, now: Date = Date()) -> FieldSession.Task? {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let job = activeSession, !note.isEmpty else { return nil }
        if let owed = job.openVerifications.last {
            return try? completeTask(id: owed.id, note: note, confirmed: true)
        }
        let repaired = job.tasks.contains { $0.status == .done && !$0.isVerificationTask }
        let alreadyVerified = job.tasks.contains { $0.verification?.isVerified == true }
        guard repaired, !alreadyVerified else { return nil }
        let check = FieldSession.Task(
            title: Self.finalCheckTitle, origin: .operatorAdded, status: .done,
            completionNote: note, createdAt: now, acceptedAt: now, completedAt: now,
            verification: VerificationRequirement(instruction: "Operational test after the repair",
                                                  verifiedAt: now))
        mutateSession {
            $0.tasks.append(check)
            $0.taskEquipmentScopes[check.id] = $0.continuityScope
        }
        logger?.append(.init(timestamp: now, kind: .taskCompleted, text: check.title, payload: [
            "task_id": AnyCodable(check.id),
            "status": AnyCodable(FieldSession.Task.Status.done.rawValue),
            "note": AnyCodable(note),
            "origin": AnyCodable("final_check")
        ]))
        return check
    }

    static let finalCheckTitle = "Verify: operational test"

    /// A procedure a task started has reached its end: the outcome closes the task, so nobody has
    /// to remember to say "done" twice.
    private func closeTaskForProcedure(id procedureId: String?, outcome: String, confirmed: Bool = true) {
        guard let procedureId,
              let task = activeSession?.tasks.last(where: {
                  $0.procedureId == procedureId && $0.status.isOpen
              }) else { return }
        _ = try? closeTask(id: task.id, status: .done, note: nil, outcome: outcome, confirmed: confirmed)
    }

    /// The running procedure's task, when it has one.
    private func procedureTaskIndex(in session: FieldSession) -> Int? {
        guard let procedureId = activeProcedureId else { return nil }
        return session.tasks.lastIndex { $0.procedureId == procedureId && $0.status.isOpen }
    }

    /// A check owed on a task (Plan GB P3). Set by a procedure's last step when it asks for one;
    /// callable directly for work whose fix waits on a check the vault does not script.
    func requireVerification(taskId: String, _ requirement: VerificationRequirement) throws {
        guard task(id: taskId) != nil else { throw FieldSessionError.unknownTask(taskId) }
        mutateSession { session in
            guard let idx = session.tasks.firstIndex(where: { $0.id == taskId }) else { return }
            session.tasks[idx].verification = requirement
        }
    }

    /// The procedure's last step asks for a check: the task it runs under now waits on it.
    private func requireVerification(for step: Procedure.Step) {
        guard step.needsConfirmation else { return }
        mutateSession { session in
            guard let idx = procedureTaskIndex(in: session),
                  session.tasks[idx].verification == nil else { return }
            session.tasks[idx].verification = VerificationRequirement(instruction: step.instruction,
                                                                      procedureStepId: step.id)
        }
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

    /// The order for a job's parts requests still waiting to go — the open job's by default, or a
    /// finished one's by id. Nil when nothing on it is waiting (every request sent or answered),
    /// or when this phone does not hold the job.
    func partsOrder(sessionId: String? = nil, requestId: String? = nil, note: String? = nil) -> PartsOrder? {
        let session: FieldSession
        let vaultName: String
        if let active = activeSession, sessionId == nil || sessionId == active.id {
            session = active
            vaultName = activeVault?.manifest.name ?? active.vaultId
        } else if let sessionId, let stored = history.first(where: { $0.id == sessionId }) {
            session = stored
            vaultName = VaultRegistry.shared.manifest(id: stored.vaultId)?.name ?? stored.vaultId
        } else {
            return nil
        }
        return PartsOrder(sessionId: session.id, jobReference: session.jobReference,
                          vaultName: vaultName, equipmentModel: session.equipment?.modelToken,
                          partsRequests: session.partsRequests, requestId: requestId, note: note)
    }

    // MARK: Van stock (Plan IH P4)

    /// Whether the technician keeps van stock at all. The close only asks about parts with no
    /// stock entry when they do: a phone whose van list is empty has nothing to reconcile, and a
    /// question about it would be noise on every job. Injectable for tests.
    var vanStockInUse: () -> Bool = {
        !Config.organizationForbidsVanStock && !VanStockStore.shared.log.isEmpty
    }

    /// A part recorded as used from the van on the open job.
    func recordVanStockUse(_ use: VanStockUse) {
        guard activeSession != nil else { return }
        mutateSession { $0.vanStockUses = ($0.vanStockUses ?? []) + [use] }
    }

    /// An undo in the van's log took these uses back, so they come off the job too.
    func removeVanStockUses(movementIDs: Set<String>) {
        guard let uses = activeSession?.vanStockUses, uses.contains(where: { movementIDs.contains($0.id) }) else { return }
        mutateSession { session in
            let kept = uses.filter { !movementIDs.contains($0.id) }
            session.vanStockUses = kept.isEmpty ? nil : kept
        }
    }

    /// The technician said a part on this job did not come off the van. False with no job open.
    @discardableResult
    func markNotFromVan(part number: String) -> Bool {
        let cleaned = VaultPartsIndex.normalise(number)
        guard activeSession != nil, !cleaned.isEmpty else { return false }
        mutateSession { session in
            if !(session.vanStockNotFromVan ?? []).contains(cleaned) {
                session.vanStockNotFromVan = (session.vanStockNotFromVan ?? []) + [cleaned]
            }
        }
        return true
    }

    /// Parts on the open job's finished tasks with no stock entry. Empty when the technician
    /// keeps no van stock.
    var unrecordedVanParts: [TaskPart] {
        guard let session = activeSession, vanStockInUse() else { return [] }
        var seen = Set<String>()
        let partsUsed = session.tasks.filter { $0.status == .done }.flatMap(\.parts)
            .filter { seen.insert($0.number).inserted }
        return VanStockReconciler.unrecorded(partsUsed: partsUsed, uses: session.vanStockUses ?? [],
                                             notFromVan: session.vanStockNotFromVan ?? [])
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
    private func activeSessionSnapshot() -> FieldSession? {
        guard var snapshot = activeSession else { return nil }
        // Time on site as it is right now, without disturbing the session's own accounting.
        if let lastResumeAt { snapshot.billableSeconds += Date().timeIntervalSince(lastResumeAt) }
        return snapshot
    }

    func workRecord() -> WorkRecord? {
        guard let session = activeSessionSnapshot() else { return nil }
        let name = activeVault?.manifest.name ?? session.vaultId
        return WorkRecord(session: session, vaultName: name,
                          vaultSourceNote: VaultSourceBadge.forInstalledVault(id: session.vaultId)?
                              .recordLine(vaultName: name),
                          usage: jobUsage(sessionId: session.id),capturedManuals:capturedManualReferences(for:session))
    }

    /// What a job has cost in model usage so far (Plan GD1) — every request the usage store tagged
    /// with its id. Empty for a job that made none, which the record then leaves out.
    func jobUsage(sessionId: String) -> JobUsageSummary {
        usageTracker.jobUsage(fieldSessionId: sessionId)
    }

    /// A finished job's record, built from the session as it was saved. Nil for an id this phone
    /// does not hold. The open job's record is `workRecord()`, which counts its running clock.
    func workRecord(sessionId: String) -> WorkRecord? {
        guard let session = history.first(where: { $0.id == sessionId }) else { return nil }
        let name = VaultRegistry.shared.manifest(id: session.vaultId)?.name ?? session.vaultId
        return WorkRecord(session: session, vaultName: name,
                          vaultSourceNote: VaultSourceBadge.forInstalledVault(id: session.vaultId)?
                              .recordLine(vaultName: name),
                          usage: jobUsage(sessionId: session.id),capturedManuals:capturedManualReferences(for:session))
    }

    func capturedManualReferences(for session: FieldSession) -> [WorkRecord.CapturedManualReference] {
        capturedManuals.eligible(for:session,vaultID:session.vaultId).compactMap { m in
            guard let bytes = try? CapturedManualContract.canonicalBytes(m) else {return nil}
            return .init(captureID:m.captureID,captureRevision:m.captureRevision,
                bundleSHA256:CapturedManualContract.digest(bytes),title:m.title,originalJob:m.jobReference,
                capturedAt:m.capturedAt,pageCount:m.pageCount,lowConfidencePages:m.lowConfidencePages,
                standing:CapturedManualOutbox.shared.standing(m))
        }
    }

    /// Jobs that ended within `window` of `now`, as `ReportTargetResolver` needs them (Plan GB P0).
    /// Only recent ones are read, because whether a report went is read off each job's own log.
    /// A cancelled job has no report to send.
    func recentlyEndedJobs(now: Date = Date(),
                           window: TimeInterval = ReportTargetResolver.recentWindow)
        -> [ReportTargetResolver.EndedJob] {
        history.compactMap { session in
            guard let endedAt = session.endedAt, session.outcome != .cancelled,
                  now.timeIntervalSince(endedAt) <= window else { return nil }
            return ReportTargetResolver.EndedJob(
                sessionId: session.id, threadId: session.conversationThreadId,
                endedAt: endedAt, reportSent: reportWasSent(sessionId: session.id))
        }
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

    /// What the device and the organisation have set up for transcripts (Plan HD). Read through
    /// `Config` in the app; a test hands in its own.
    var reportTranscriptContext: () -> ReportTranscriptPolicy.Context = { .current() }

    /// Everything a report needs to be staged on one channel: its files, its clip partition, and
    /// the clips themselves (Plan FO P2b).
    struct ReportDelivery {
        var attachments: [DeliveryRequest.Attachment] = []
        var clipPlan: ClipDeliveryPlan = .undecided
        /// Every clip the technician included, attached or not — the share-sheet fallback needs
        /// the ones that did not fit, and the report names all of them.
        var clipItems: [JobMediaItem] = []
        /// Who the report is for and what of the conversation it carries (Plan HD).
        var transcript: ReportTranscriptPolicy.Decision?
    }

    /// The report's files for a chosen channel, with the clips partitioned before anything opens.
    ///
    /// The order matters and is the design. The clips are partitioned **first**, against a fixed
    /// allowance for the work order and the JSON, and only then is the PDF rendered — because the
    /// PDF prints which clips travelled and which did not, so a partition that depended on the
    /// PDF's own size would depend on a file it is printed into. The allowance is stated rather
    /// than measured for the same reason the image budget is: the same job on the same channel has
    /// to produce the same report twice, or a re-send is not a re-send.
    ///
    /// Who the report is for is decided here too (Plan HD), from the recipients it is prepared
    /// for and what the technician chose on the send sheet: whether the JSON keeps the transcript,
    /// and whether the separate transcript PDF goes. That PDF is a report file, so its stated
    /// allowance is reserved before any clip — the same job, channel and choice partition the same
    /// way every time.
    func reportDelivery(for channel: DeliveryChannel,
                        canSendAttachments: Bool = true,
                        sessionId: String? = nil,
                        recipients: [String] = [],
                        transcriptChoice: ReportTranscriptPolicy.Choice = .standard) -> ReportDelivery {
        let record: WorkRecord?
        if let sessionId, activeSession?.id != sessionId {
            record = workRecord(sessionId: sessionId)
        } else {
            record = workRecord()
        }
        guard let record else { return ReportDelivery() }

        let clips = record.includedClips
        let budget = AttachmentBudget.standard(for: channel, canSendAttachments: canSendAttachments)
        let transcript = ReportTranscriptPolicy.decide(
            channel: channel, recipients: recipients, carriesFiles: budget.carriesFiles,
            context: reportTranscriptContext(), choice: transcriptChoice)
        let reserved = Self.reportFileReserveBytes
            + (transcript.attachesTranscriptPDF ? Self.transcriptFileReserveBytes : 0)
        let partition = budget.partition(clips: clips, reservedBytes: reserved)
        let plan = ClipDeliveryPlan(channel: channel, partition: partition)

        var delivery = ReportDelivery(clipPlan: plan, clipItems: clips, transcript: transcript)
        if let reportAttachmentsProvider {
            delivery.attachments = reportAttachmentsProvider()
        } else if let leases = try? exportSession(id: sessionId, formats: [.json, .pdf],
                                                  clipPlan: plan, transcript: transcript) {
            delivery.attachments = leases.compactMap { lease in
                switch lease.fileURL.pathExtension.lowercased() {
                case "pdf": return DeliveryRequest.Attachment(url: lease.fileURL, kind: .pdf,
                                                              filename: record.reportFileStem + ".pdf")
                case "json": return DeliveryRequest.Attachment(url: lease.fileURL, kind: .json,
                                                               filename: record.reportFileStem + ".json")
                default: return nil
                }
            }
            if transcript.attachesTranscriptPDF,
               let lease = try? SessionExporter.exportTranscriptPDF(
                   sessionDir: sessionDirectory(sessionId: sessionId ?? record.sessionId),
                   record: record) {
                delivery.attachments.append(DeliveryRequest.Attachment(
                    url: lease.fileURL, kind: .transcriptPDF,
                    filename: record.reportFileStem + "-transcript.pdf"))
            }
        }
        let directory = photosDirectory(sessionId: sessionId ?? record.sessionId)
        delivery.attachments += partition.attached.compactMap { id in
            guard let clip = clips.first(where: { $0.id == id }) else { return nil }
            let url = directory.appendingPathComponent(id)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return DeliveryRequest.Attachment(url: url, kind: .video,
                                              filename: Self.clipFilename(record: record,
                                                                          clip: clip,
                                                                          index: partition.attached.firstIndex(of: id) ?? 0))
        }
        // Existing report files and clips get their measured room first. Customer reports never
        // acquire a book just because their channel happens to support attachments.
        if transcript.audience == .office, capturedManuals.accessAllowed(),let source = capturedManuals.source {
            var used = delivery.attachments.reduce(0) { total,file in
                guard let size = try? file.url.resourceValues(forKeys:[.fileSizeKey]).fileSize else {return Int.max}
                let (next,overflow) = total.addingReportingOverflow(size);return overflow ? Int.max : next
            }
            for m in ((try? source.manifests()) ?? []) where m.sessionID == record.sessionId
                && m.scope == capturedManuals.scopeForVault(m.vaultID) {
                guard let pdf = try? source.file(m,name:"pages.pdf"),let text = try? source.file(m,name:"text.md") else {continue}
                let manual = budget.partitionManual(pdfBytes:m.pdfBytes,textBytes:m.textBytes,reservedBytes:used,officeAudience:true)
                for file in manual.attached {
                    let isPDF = file == .pdf
                    delivery.attachments.append(.init(url:isPDF ? pdf : text,kind:isPDF ? .capturedManualPDF : .capturedManualText,
                        filename:"manual-\(m.captureID)-\(m.captureRevision)." + (isPDF ? "pdf" : "md")))
                    let (next,overflow) = used.addingReportingOverflow(isPDF ? m.pdfBytes : m.textBytes)
                    used = overflow ? Int.max : next
                }
            }
        }
        return delivery
    }

    /// The room the work order PDF and the JSON record are given before any clip is considered.
    /// Generous on purpose: a twenty-photo work order is the large case, and a clip pushed out by
    /// an over-tight reserve is merely shared separately, while one squeezed in past a real limit
    /// is a report that silently fails to arrive.
    static let reportFileReserveBytes = 3_000_000

    /// The room the internal transcript PDF is given, on top of the report's own, when it goes
    /// (Plan HD). Stated rather than measured for the reason the reserve above is: a text-only PDF
    /// of a long day is well under it, and a stated figure is what makes a re-send reproduce the
    /// partition.
    static let transcriptFileReserveBytes = 500_000

    /// What a clip is called when it arrives: the job, not the device's uuid.
    static func clipFilename(record: WorkRecord, clip: JobMediaItem, index: Int) -> String {
        record.reportFileStem + "-clip-\(index + 1).mp4"
    }

    /// Put a report in front of the operator. Publishing it is what opens the composer; nothing
    /// has been sent when this returns.
    func stageDelivery(_ request: DeliveryRequest) {
        // A parts order is not the report: staging one says nothing about whether the report went.
        // Nor do kept rule chains, which belong to no job (Plan JJ P3).
        if request.payload.partsOrder == nil, request.payload.ruleChains == nil { lastDeliveryCancelled = false }
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
        let order = request.payload.partsOrder
        if order == nil { lastDeliveryCancelled = !outcome.isSent }

        // A report sent after its job closed belongs to a finished session (Plan GB P0): its log is
        // opened on its own directory — the route `recordSignOff` takes — so the send is recorded
        // where `reportWasSent` reads it, and a second "send the report" knows it went.
        let finishedLogger: SessionLogger?
        if activeSession?.id == request.sessionId || deliveryLogger?.session.id == request.sessionId {
            finishedLogger = nil
        } else if let stored = history.first(where: { $0.id == request.sessionId }) {
            finishedLogger = SessionLogger(session: stored,
                                           root: sessionsRoot.appendingPathComponent(stored.id,
                                                                                     isDirectory: true))
        } else {
            finishedLogger = nil
        }

        if outcome.isSent, !request.partsRequestIds.isEmpty {
            let ids = Set(request.partsRequestIds)
            let markSent: (inout FieldSession) -> Void = { session in
                for idx in session.partsRequests.indices
                where ids.contains(session.partsRequests[idx].id)
                    && session.partsRequests[idx].status == .requested {
                    session.partsRequests[idx].status = .sent
                }
            }
            if activeSession?.id == request.sessionId {
                mutateSession(markSent)
            } else if let stored = history.first(where: { $0.id == request.sessionId }) {
                let owner = finishedLogger ?? deliveryLogger
                    ?? SessionLogger(session: stored,
                                     root: sessionsRoot.appendingPathComponent(stored.id, isDirectory: true))
                // From the stored record, whichever logger writes it: the job as it ended — its
                // number, outcome, end time and conversation — with only the parts marked sent.
                var updated = stored
                markSent(&updated)
                owner.updateSession { $0 = updated }
                history = history.replacingFirst(matching: stored.id, with: updated)
            }
        }

        // A parts order is logged as one, under kinds of its own: `reportWasSent` reads
        // `reportSent`, and an order that went must never make the job's report look sent.
        let kind: SessionLogger.Event.Kind
        switch (outcome, order != nil) {
        case (.sent, false): kind = .reportSent
        case (.saved, false), (.handedOff, false), (.cancelled, false): kind = .reportCancelled
        case (.failed, false): kind = .reportFailed
        case (.sent, true): kind = .partsOrderSent
        case (.saved, true), (.handedOff, true), (.cancelled, true): kind = .partsOrderNotSent
        case (.failed, true): kind = .partsOrderFailed
        }
        var payload: [String: AnyCodable] = [
            "channel": AnyCodable(request.channel.rawValue),
            "outcome": AnyCodable(outcome.auditLabel),
            "recipients": AnyCodable(request.recipients.count),
            "attachments": AnyCodable(request.attachments.map(\.kind.rawValue)),
            "parts_requests": AnyCodable(request.partsRequestIds.count)
        ]
        // Who the report was for, and which files carried what was said (Plan HD) — the fact an
        // audit needs when a customer asks whether they were sent the conversation.
        if let transcript = request.transcript {
            payload["audience"] = AnyCodable(transcript.audience.rawValue)
            payload["transcript"] = AnyCodable(transcript.auditTranscript)
        }
        // The addresses themselves are not written down — how many there were is what an audit
        // needs, and a work order that leaks a customer's inbox is a different problem.
        if case .failed(let reason) = outcome { payload["error"] = AnyCodable(reason) }
        // The active session's log when this report belongs to it; the log of the session that
        // just ended when a composer outlived it. Never somebody else's log.
        let target = activeSession?.id == request.sessionId ? logger
            : (deliveryLogger?.session.id == request.sessionId ? deliveryLogger : finishedLogger)
        // The order's line reads as what happened to it: "Parts order sent — 1 × 70W16".
        let text = order.map { order in
            let what: String
            switch outcome {
            case .sent: what = "Parts order sent"
            case .failed: what = "Parts order failed"
            case .saved, .handedOff, .cancelled: what = "Parts order not sent"
            }
            return "\(what) — \(order.spokenList)"
        } ?? request.subject
        target?.append(.init(timestamp: Date(), kind: kind, text: text, payload: payload))
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
    var capturedManuals = CapturedManualCatalog.shared
    var documentStore: DocumentStore? {
        didSet {
            guard let documentStore else { return }
            capturedManuals.documents = documentStore
            documentStore.capturedNamespaceAllowed = { [weak self] namespace in
                if PersonalManualLibrary.shared.canReadCapturedNamespace(namespace) { return true }
                guard let self, let session = self.activeSession else { return false }
                return self.capturedManuals.available(namespace, session: session, vaultID: session.vaultId)
            }
        }
    }
    /// The evidence gate for per-turn manual retrieval: the measured default for the model that
    /// answers for the store, unless a test pins one (assigning pins it).
    var retrievalPolicy: RetrievalEvidencePolicy {
        get { pinnedRetrievalPolicy ?? .default(for: documentStore?.embeddingModelId ?? "") }
        set { pinnedRetrievalPolicy = newValue }
    }
    private var pinnedRetrievalPolicy: RetrievalEvidencePolicy?

    /// The gate for one vault: the measured default for the model its manuals are indexed with
    /// now (Plan IV P4) — the contextual model's once a vault is on it, the standard model's while
    /// it isn't — unless a test pins one.
    func retrievalPolicy(forVault vaultId: String) -> RetrievalEvidencePolicy {
        if let pinnedRetrievalPolicy { return pinnedRetrievalPolicy }
        guard let documentStore else { return RetrievalEvidencePolicy() }
        return .default(for: documentStore.servingModelId(namespace: DocumentStore.vaultNamespace(vaultId)))
    }
    /// How many manual passages a turn or a lookup carries: four, or six when the best passage is
    /// from a clause-numbered document (Plan IV P6), a CJK or Arabic-script one (Plan JY P4), or is
    /// a table row (Plan JJ P1).
    var passageLimit = ManualPassageLimit()

    /// Retrieve manual passages with the shape-dependent limit (Plan IV P6). The larger number is
    /// asked for only when a manual this retrieval may search (`documentIds`, or the whole vault)
    /// is clause-numbered or has table rows, so a vault of prose manuals retrieves exactly as before.
    func retrieveManualPassages(_ request: VaultRetriever.Request, with retriever: VaultRetriever,
                                store: VaultStore, documentIds: [String]? = nil) -> RetrievalOutcome {
        guard let documentStore else { return retriever.retrieve(request) }
        let searched = documentStore.list(namespace: DocumentStore.vaultNamespace(store.manifest.id))
            .filter { documentIds?.contains($0.id) ?? true }
        // A CJK or Arabic-script manual takes the clause budget too (Plan JY P4).
        let searchesClauseNumbered = searched.contains { documentStore.usesClausePassageBudget(documentId: $0.id) }
        return passageLimit.retrieve(request, with: retriever, searchesClauseNumbered: searchesClauseNumbered,
                                     searchesTableRows: documentStore.hasTableRows(documentIds: searched.map(\.id)),
                                     isClauseNumbered: { documentStore.usesClausePassageBudget(documentId: $0) })
    }

    /// System-prompt addendum for the active session, or nil when no session is active.
    /// Hooked into `LLMService.buildSystemPrompt`. When the vault declares a reference tier and
    /// `turn` is given, the passages retrieved for that turn ride along — or an explicit statement
    /// that nothing did, so the model cannot fall back to general knowledge silently.
    /// The request context FM resolves for the active ChatGPT model, or nil off that route. The
    /// same resolution the send path uses, so the vault bound and the request budget agree.
    static func chatGPTRequestContext(for model: ModelConfig?) -> Int? {
        guard let model, model.llmProvider == .chatgpt else { return nil }
        let endpoint = model.baseURL.isEmpty ? ChatGPTOAuth.backendResponsesURL : model.baseURL
        return RequestContextBudget.resolve(
            model: model.model, endpoint: endpoint,
            catalogContext: ChatGPTContextCatalog.context(model: model.model,
                                                          accountID: ChatGPTOAuthService.shared.accountID)).context
    }

    func promptContext(turn: String? = nil) -> String? {
        guard let store = activeVault, hasCurrentWorkAccess,
              VaultRegistry.shared.isUnlocked(store.manifest) else { return nil }
        // What this turn is, for the page rules below and for `manual_figure` later in the turn.
        // Set on every turn, so a kind never outlives the turn it was read from (Plan GB P1).
        lastTurnKind = turn.map(ManualTurnClassifier.classify)
        // Everything below reads the unit, so the turn that first names it is already scoped to it.
        recordModelSaid()
        // Plan GB P5: the vault core is bounded on every provider, not just ChatGPT — an
        // unbounded core rode along on every API request and every tool round-trip. The bound is
        // the validator's budget wherever the request context allows it (Decision 6).
        let model = Config.activeModel
        var context = VaultPromptBuilder.promptContext(for: store,
            referenceByteLimit: VaultPromptBuilder.referenceByteLimit(
                for: model?.llmProvider, requestContext: Self.chatGPTRequestContext(for: model)),
            turn: turn,
            teamLearningsPublished: retrievableCorpus(store: store, documentStore: documentStore).learnings,
            manualLanguages: manualLanguagesPromptLine(store: store))
        if let equipment = activeEquipment {
            context = (context.map { $0 + "\n\n" } ?? "") + equipment.promptBlock
        }
        if let runner {
            let procedureContext = runner.promptContext()
            if !procedureContext.isEmpty {
                context = (context.map { $0 + "\n\n" } ?? "") + procedureContext
            }
        }
        // The rule chain's current step, or the chains the vault offers (Plan JJ P2).
        if let chains = chainPromptContext() {
            context = (context.map { $0 + "\n\n" } ?? "") + chains
        }
        if let continuity = continuityContext(turn: turn) {
            context = (context.map { $0 + "\n\n" } ?? "") + continuity
        }
        if let manuals = manualPassagesContext(turn: turn, store: store) {
            context = (context.map { $0 + "\n\n" } ?? "") + manuals
        }
        // A paused job claims no conversation, and the model has to know that too: shown a job
        // with nothing saying it was paused, it read "you can end" in a chat about the weather as
        // "end the job" and closed it.
        if activeSession?.pausedAt != nil {
            context = (context.map { $0 + "\n\n" } ?? "") + Self.pausedJobPromptNote
        }
        return context
    }

    /// What the model is told while the open job is paused.
    static let pausedJobPromptNote = """
        This job is PAUSED. The technician may be talking about something unrelated: answer \
        normally and do not treat the conversation as work on the job. Do not start, end or \
        change the job unless they name the job or ask for that. "End", "stop" or "that's all" \
        on their own end the conversation, not the job. If they ask to carry on with the job, \
        call field_session with action 'resume'.
        """

    /// The `MANUAL PASSAGES` block for a turn, or nil when the vault has neither manuals nor
    /// published team learnings to retrieve from, or there is no turn to retrieve against.
    func manualPassagesContext(turn: String?, store: VaultStore) -> String? {
        guard let documentStore,
              let turn = turn?.trimmingCharacters(in: .whitespacesAndNewlines), !turn.isEmpty else { return nil }
        guard retrievableCorpus(store: store, documentStore: documentStore).any else { return nil }
        // The job number is not evidence. "Open a new job 108" handed 108 to the exact-token search,
        // and a vent-length table with 108 in a cell opened on the phone (field report, build 420).
        let searchTurn = ManualTurnScope.removingJobReferences(from: turn)
        // Equipment before evidence. A question about a machine this vault is not for cannot be
        // answered by any passage in it, however well the words line up (Plan EL §3), so the block
        // becomes the scope sentence and the vault's rules relay it verbatim.
        var scopeNote: String?
        switch equipmentScope(turn: searchTurn) {
        case .unknownEquipment(_, let sentence):
            stageFigure(nil)
            TurnRecorder.noteManualPassages([], refused: true)
            return VaultRetriever.promptBlock(.insufficient(reason: sentence))
        case .otherKnownModel(let token, let model):
            if let active = activeEquipment {
                scopeNote = EquipmentScopeCheck.otherModelNote(token: token, model: model, active: active)
            }
        case .inScope:
            break
        }
        let editionRequest = EditionRequest.parse(searchTurn, editions: documentEditions(of: store))
        let retriever = manualRetriever(store: store, editionRequest: editionRequest)
        // Manuals in more than one language are searched once per language and merged by rank
        // (Plan JY P2); a library in one language is searched exactly as before.
        let ownOutcome = retrieveByLanguage(.init(turn: searchTurn, procedureStep: runner?.currentStep?.title),
                                            with: retriever, store: store, editionRequest: editionRequest).outcome
        // A follow-up rarely says what it follows (Plan KE P1). A second search, with the job's
        // subject beside the turn, can only add to what the turn found.
        let kind = ManualTurnClassifier.classify(turn)
        var outcome = ownOutcome
        let assigned = Set(assignedDocuments.map(\.id))
        if scopeNote == nil, kind != .jobBookkeeping, activeSession?.pausedAt == nil,
           JobSearchContext.searchesAgain(after: ownOutcome, assigned: assigned), let said = technicianWords(),
           let context = JobSearchContext.context(unit: activeEquipment?.stated, earlierTurns: heldJobTurns,
                                                  current: said, otherModels: otherModelTokens) {
            let widened = retrieveByLanguage(.init(turn: searchTurn, procedureStep: runner?.currentStep?.title,
                                                   jobContext: context),
                                             with: retriever, store: store, editionRequest: editionRequest).outcome
            outcome = JobSearchContext.merged(own: ownOutcome, context: widened, assigned: assigned)
        }
        noteJobTurn()
        // Support trace: which pages went to the model, by citation — or that the gate refused.
        TurnRecorder.noteManualPassages(outcome.passages.map(\.citation), refused: !outcome.answers)
        let disclosure = noteRetrieval(outcome)
        // The turn's drawing, if its evidence points at one. Staged here and nowhere else for the
        // automatic path, so a figure never outlives the question that found it: a turn whose
        // evidence has no drawing in it clears the last one rather than leaving a wiring diagram
        // attached to a question about condensate. Whether it opens on the phone, goes to the
        // model only, or is not staged at all is `FigureAutoOpenPolicy`'s call (Plan GB P1): a
        // reading, a correction or job bookkeeping asked for no page, and a table opens only when
        // asked for. Ranking is untouched — the passages below go to the model whatever is staged.
        // Read from what the turn found itself: a page added for the job's subject asked for
        // nothing to open.
        let candidate = Self.bestFigure(in: ownOutcome.passages)
        let passageKind = candidate.map { FigureAutoOpenPolicy.PassageKind($0.kind) }
        var decision = FigureAutoOpenPolicy.decide(
            turnKind: kind,
            passageKind: passageKind,
            tokenHits: candidate?.matchedTokens ?? [],
            namedPages: PageReference.pages(in: searchTurn),
            passagePage: candidate?.page)
        // A table goes to the model as the turn's picture only under the label the technician
        // named or table_lookup read, and no page under another label opens (Plan KD P3). The
        // catalogue (for a table named by its title) is read only when a page would be staged.
        if decision.stagesFigure {
            decision = RetrievedFigureLabelGate.apply(
                decision, passageKind: passageKind, passageLabel: candidate?.figure,
                namedLabels: RetrievedFigureLabelGate.namedLabels(in: searchTurn,
                                                                  catalogue: retriever.tableCatalogue?() ?? []),
                lookedUpLabels: lookedUpTableLabel.map { [$0] } ?? [])
        }
        var staged = decision.stagesFigure ? makeStagedFigure(for: candidate, vaultId: store.manifest.id) : nil
        staged?.origin = kind == .showMe ? .requested : .automatic

        // A code book opens when it is asked for through its citation (`show_source`), never off
        // a turn's wording (Plan IN decisions 1 and 2). The passages still go to the model.
        if let figure = staged, StandardDocumentOpenPolicy.keepsToRequest(
            documentKind: StandardDocumentOpenPolicy.documentKind(of: figure.documentId, in: store.manifest)) {
            staged = nil
        }
        staged?.presentOnPhone = decision.presentsOnPhone
        stageFigure(staged)
        logFigurePresentation(staged ?? candidate.flatMap { makeStagedFigure(for: $0, vaultId: store.manifest.id) },
                              decision: decision, turnKind: kind)
        var block = VaultRetriever.promptBlock(outcome, leadIn: disclosure?.leadIn)
        // A value a table would hold, asked in plain words with no table named (Plan JW P1b): the
        // passages rarely carry the table's rows, so name the one or two tables whose titles and
        // headings fit, for table_lookup to read. Nothing when no table clears the threshold.
        if TableDirectory.asksForValue(searchTurn),
           let hint = TableDirectory.hint(for: searchTurn, in: retriever.tableCatalogue?() ?? []) {
            block += "\n\n" + hint
        }
        if let note = editionNote(for: editionRequest, store: store) { block += "\n\n" + note }
        if let documents = assignedDocumentsNote() { block += "\n\n" + documents }
        if kind == .question || kind == .statement || kind == .reading { block += "\n\n" + Self.oneCheckRule }
        return scopeNote.map { block + "\n\n" + $0 } ?? block
    }

    /// How a diagnostic turn is answered (Plan KE P1). Beside the passages it speaks of, on the turns
    /// that can be diagnostic, so a job turn or a page request does not pay for it.
    static let oneCheckRule = """
        DIAGNOSING: give one check the passages support and say what to observe, then use the answer \
        to pick the next. A check needs a passage behind it; with none, name the specific gap. Never \
        call a check the manufacturer's first step unless a passage says so.
        """

    /// Every other model's spellings, which an earlier turn must not carry into this one's search.
    private var otherModelTokens: Set<String> {
        let active = modelIndex.models.first { $0.heading == activeEquipment?.heading }
        return modelIndex.knownModelTokens.subtracting(active?.tokens ?? [])
    }

    /// The technician's recent turns on the unit the job is on, for `JobSearchContext`. Held here
    /// and nowhere else: nothing about a turn is stored for this, and a crash loses only the
    /// follow-up's context. Keyed so another job, or the next unit, starts clean.
    private var jobTurns = (key: "", turns: [String]())

    private var jobTurnsKey: String { activeSession.map { $0.id + "/" + $0.continuityScope } ?? "" }

    private var heldJobTurns: [String] { jobTurns.key == jobTurnsKey ? jobTurns.turns : [] }

    private func noteJobTurn() {
        guard activeSession != nil, let said = technicianWords() else { return }
        jobTurns = (jobTurnsKey, JobSearchContext.keeping(said, after: heldJobTurns))
    }

    /// The per-turn retriever for the active vault: the shared factory with its default namespaces,
    /// searching the edition `editionRequest` asks for (the newest unless a turn reaches past it).
    func manualRetriever(store: VaultStore, editionRequest: EditionRequest = .newest) -> VaultRetriever {
        makeRetriever(store: store, documentStore: documentStore, editionRequest: editionRequest)
    }

    // MARK: - Searching the book's way (Plan IV P5)

    /// The clause numbers and tables the vault's manuals' own back-of-book indexes give for a
    /// lookup's words, best first — nothing when no manual searched has an index.
    func indexReferences(for query: String, store: VaultStore, documentIds: [String]?, limit: Int = 3) -> [String] {
        guard let documentStore else { return [] }
        let docs = documentStore.list(namespace: DocumentStore.vaultNamespace(store.manifest.id))
            .filter { documentIds?.contains($0.id) ?? true }
        var seen = Set<String>()
        return docs.compactMap { documentStore.backOfBookIndex(documentId: $0.id) }
            .flatMap { $0.references(for: query, limit: limit) }
            .filter { seen.insert($0).inserted }
            .prefix(limit).map { $0 }
    }

    /// The headings of the sections nearest a lookup's words, ungated — what a lookup that found
    /// nothing it would stand behind offers, so the one retry uses the book's own terms.
    func closestSections(for query: String, store: VaultStore, documentIds: [String]?,
                         editionRequest: EditionRequest, limit: Int = 3,
                         asked: String? = nil, rewrites: ManualLanguageSearch.Rewrites = .none) -> [String] {
        func sections(_ text: String, scope: Set<String>?) -> [String] {
            let open = makeRetriever(store: store, documentStore: documentStore, documentIds: documentIds,
                                     editionRequest: editionRequest, policy: RetrievalEvidencePolicy(similarityFloor: 0),
                                     scope: scope)
            return open.retrieve(.init(turn: text, limit: 8)).passages
                .filter { $0.source.isReference }
                .compactMap { $0.section?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        var seen = Set<String>()
        // Manuals in more than one language (Plan JY P5a): each group's nearest headings for its
        // own question — its rewrite, else the question as asked — taken in turn, first of each
        // group before the second of any, so two script models' cosines are never ranked in one
        // list and no language's headings bury another's. One language: as before.
        let groups = manualLanguageGroups(store: store, documentIds: documentIds, editionRequest: editionRequest)
        guard groups.count > 1 else {
            return sections(query, scope: nil).filter { seen.insert($0.lowercased()).inserted }.prefix(limit).map { $0 }
        }
        let lists = groups.map { group in
            sections(rewrites.query(for: group.language) ?? asked ?? query, scope: Set(group.documentIds))
                .filter { !$0.isEmpty }
        }
        var out: [String] = []
        var rank = 0
        while out.count < limit, lists.contains(where: { rank < $0.count }) {
            for list in lists where rank < list.count && out.count < limit {
                if seen.insert(list[rank].lowercased()).inserted { out.append(list[rank]) }
            }
            rank += 1
        }
        return out
    }

    // MARK: - Editions (Plan IV P2)

    /// The works the vault holds in more than one edition, read off its manifest.
    func documentEditions(of store: VaultStore) -> DocumentEditions {
        DocumentEditions(documents: store.manifest.documents)
    }

    /// What the model is told about editions beside a turn's passages, or nil when the vault holds
    /// one edition of everything. The default is said out loud so the model doesn't present the
    /// newest edition's rule as the only one there is, and a reach past it is said so each answer
    /// names its edition.
    func editionNote(for request: EditionRequest, store: VaultStore) -> String? {
        let editions = documentEditions(of: store)
        guard !editions.isEmpty else { return nil }
        switch request {
        case .newest:
            let works = editions.works.map { work in
                "\(work[0].title) is the newest edition; "
                    + work.dropFirst().map { "\($0.title) (\($0.label))" }.joined(separator: ", ")
                    + (work.count > 2 ? " are" : " is") + " loaded as well"
            }
            return "EDITIONS: these passages are from the newest edition. " + works.joined(separator: ". ")
                + ". Use an older edition only when the technician asks for it by its year, as the previous edition, "
                + "or to compare editions."
        case .named, .previous:
            return "EDITIONS: the technician asked for an older edition. Each passage is marked with its edition; "
                + "say which edition your answer comes from."
        case .compare:
            return "EDITIONS: the technician asked to compare editions. Each passage is marked with its edition. "
                + "Answer only from these passages, name the edition beside each point, and if one edition has "
                + "no passage for this, say you couldn't find it there rather than that nothing changed."
        }
    }

    // MARK: - The retrieval factory (Plan FP P2)

    /// One namespace a retrieval reads, and what its passages are.
    struct RetrievalNamespace: Equatable {
        let namespace: String
        let source: RetrievalSource
    }

    /// The approved entries, for the disclosure and for scoping a learning by its model. Injected
    /// by `AppState`; nil in headless contexts, where a learning is still retrieved and disclosed
    /// by what its own document carries.
    var learningEntries: LearningEntryStore?

    /// The namespaces a vault's retrieval reads: its manuals, then its published team learnings —
    /// unless HIPAA mode is on, where the corpus is not queried at all. Already-published learnings
    /// stay readable on a lapsed licence (FP §5), so no entitlement is asked here. A later corpus
    /// joins this list rather than growing a fourth set of closures.
    func retrievalNamespaces(vaultId: String) -> [RetrievalNamespace] {
        var namespaces = [RetrievalNamespace(namespace: DocumentStore.vaultNamespace(vaultId), source: .manual)]
        if !Config.hipaaMode {
            namespaces.append(RetrievalNamespace(namespace: DocumentStore.learningNamespace(vaultId),
                                                 source: .teamLearning))
        }
        namespaces += capturedManuals.eligible(for: activeSession, vaultID: vaultId)
            .map { RetrievalNamespace(namespace: CapturedManualCatalog.namespace($0), source: .capturedManual) }
        return namespaces
    }

    /// What a vault has to retrieve from: imported manuals, published learnings, or neither.
    func retrievableCorpus(store: VaultStore, documentStore: DocumentStore?) -> (manuals: Bool, learnings: Bool, any: Bool) {
        guard let documentStore else { return (false, false, false) }
        let manuals = (store.manifest.hasDocuments
            && documentStore.documentCount(namespace: DocumentStore.vaultNamespace(store.manifest.id)) > 0)
            || retrievalNamespaces(vaultId: store.manifest.id).filter { $0.source == .capturedManual }
                .contains { documentStore.documentCount(namespace: $0.namespace) > 0 }
        let learnings = retrievalNamespaces(vaultId: store.manifest.id)
            .filter { $0.source == .teamLearning }
            .contains { documentStore.documentCount(namespace: $0.namespace) > 0 }
        return (manuals, learnings, manuals || learnings)
    }

    /// The vault's pictured tables whose row passages must not be searched once its table checks
    /// are applied (Plan JN P3). Empty, and nothing read, when the vault has no checks and the
    /// organisation does not require them.
    func withheldRowPassages(vaultId: String, documentStore: DocumentStore?) -> Set<String> {
        guard let documentStore else { return [] }
        let checks = VaultTableChecks.checks(vaultId: vaultId)
        let require = Config.organizationRequiresTableChecks
        var withheld = Set<String>()
        if !checks.isEmpty || require {
            let stored = documentStore.storedTables(namespace: DocumentStore.vaultNamespace(vaultId))
            let applied = VaultTableChecks.applied(stored, checks: checks,
                                                   hashes: VaultTableChecks.documentHashes(VaultImporter.documentLedger(for: vaultId)),
                                                   requireChecked: require)
            withheld = VaultTableChecks.rowPassagesWithheld(original: stored, applied: applied)
        }
        // A photographed manual's tables (Plan JN P4), with the phone's checks of them.
        let captured = capturedManuals.eligible(for: activeSession, vaultID: vaultId)
        let capturedChecks = captured.isEmpty ? [] : VaultTableChecks.capturedChecks(vaultId: vaultId)
        if !captured.isEmpty, !capturedChecks.isEmpty || require {
            let stored = captured.flatMap { documentStore.storedTables(namespace: CapturedManualCatalog.namespace($0)) }
            let applied = VaultTableChecks.applied(stored, checks: capturedChecks,
                                                   hashes: CapturedManualTables.checkHashes(captured), requireChecked: require)
            withheld.formUnion(VaultTableChecks.rowPassagesWithheld(original: stored, applied: applied))
        }
        return withheld
    }

    /// The documents of a namespace a retrieval searches, or nil for all of them: the manuals a
    /// lookup named, else the edition's; photographed manuals the named ones; learnings all.
    static func searchedIds(for space: RetrievalNamespace, documentIds: [String]?, editionIds: [String]?) -> [String]? {
        if space.source == .manual { return documentIds ?? editionIds }
        return space.source.isReference ? documentIds : nil
    }

    /// Editions (Plan IV P2): the vault manuals a request may search, or nil for all of them. The
    /// filter is on the vault's manual namespace only; learnings and photographed manuals are
    /// searched as before.
    func editionDocumentIds(store: VaultStore, documentStore: DocumentStore?, editionRequest: EditionRequest) -> [String]? {
        guard let documentStore,
              let titles = documentEditions(of: store).searchableTitles(for: editionRequest,
                                                                         among: store.manifest.documents.map(\.title))
        else { return nil }
        return documentStore.list(namespace: DocumentStore.vaultNamespace(store.manifest.id))
            .filter { titles.contains($0.name) }.map(\.id)
    }

    // MARK: - Manuals in more than one language (Plan JY P2)

    /// The documents a lookup searches, by language group (`ManualLanguageSearch.groups`): the
    /// same namespaces and filters as `makeRetriever`, each document grouped by its stored
    /// language profile.
    func manualLanguageGroups(store: VaultStore, documentIds: [String]? = nil,
                              editionRequest: EditionRequest = .newest) -> [ManualLanguageSearch.Group] {
        guard let documentStore else { return [] }
        let editionIds = documentIds == nil ? editionDocumentIds(store: store, documentStore: documentStore,
                                                                 editionRequest: editionRequest) : nil
        let all = retrievalNamespaces(vaultId: store.manifest.id)
        let searched = documentIds == nil ? all : all.filter { $0.source.isReference }
        // A team learning joins its reference manuals' group, never one of its own.
        let documents = searched.flatMap { space -> [(id: String, profile: DocumentLanguageProfile, isReference: Bool)] in
            let ids = documentStore.list(namespace: space.namespace).map(\.id)
            let kept = Self.searchedIds(for: space, documentIds: documentIds, editionIds: editionIds)
                .map { wanted in ids.filter(wanted.contains) } ?? ids
            return kept.map { (id: $0, profile: documentStore.languageProfile(documentId: $0),
                               isReference: space.source.isReference) }
        }
        return ManualLanguageSearch.groups(documents)
    }

    /// Retrieve manual passages for a turn or a lookup, once per language group when the searched
    /// manuals are in more than one (Plan JY P2): each group with its own question — the model's
    /// rewrite for it, else `request.turn` — through a retriever scoped to it, the results merged
    /// by rank. A library in one language is `retrieveManualPassages` with `retriever`, exactly as
    /// before (with the rewrite for that language, when the model passed one).
    ///
    /// `fixedLimit` (Plan JY P5a) is a caller's own passage count — `equipment_lookup`'s
    /// fall-through asks for three — used as given for each group and for the merge, with no
    /// shape-dependent budget; one group is then `retriever.retrieve` exactly as before.
    func retrieveByLanguage(_ request: VaultRetriever.Request, with retriever: VaultRetriever, store: VaultStore,
                            documentIds: [String]? = nil, editionRequest: EditionRequest = .newest,
                            rewrites: ManualLanguageSearch.Rewrites = .none,
                            fixedLimit: Int? = nil) -> ManualLanguageSearch.Result {
        let groups = manualLanguageGroups(store: store, documentIds: documentIds, editionRequest: editionRequest)
        func retrieve(_ asked: VaultRetriever.Request, with retriever: VaultRetriever, documentIds: [String]?) -> RetrievalOutcome {
            guard let fixedLimit else { return retrieveManualPassages(asked, with: retriever, store: store, documentIds: documentIds) }
            var limited = asked
            limited.limit = fixedLimit
            return retriever.retrieve(limited)
        }
        // A merge keeps the larger budget and is then shaped by its best passage (Plan JY P5a):
        // merged at the prose number, a Chinese manual's first passage — which alone takes six —
        // was cut to four as soon as a second language was searched.
        let result = ManualLanguageSearch.search(
            groups: groups, query: request.turn, rewrites: rewrites,
            limit: fixedLimit ?? max(passageLimit.prose, passageLimit.clauseNumbered),
            shape: { merged in
                guard fixedLimit == nil else { return merged }
                return passageLimit.shaped(merged, isClauseNumbered: { documentStore?.usesClausePassageBudget(documentId: $0) ?? false })
            },
            whole: { query in
                var asked = request
                asked.turn = query
                return retrieve(asked, with: retriever, documentIds: documentIds)
            },
            scoped: { group, query in
                var asked = request
                asked.turn = query
                let scoped = makeRetriever(store: store, documentStore: documentStore, documentIds: documentIds,
                                           editionRequest: editionRequest, policy: retriever.policy,
                                           scope: Set(group.documentIds))
                return retrieve(asked, with: scoped, documentIds: group.documentIds)
            })
        if result.searchedByLanguage {
            // Counts only: how many languages, how many rewrites, whether anything answered.
            PrivacyLog.store(.ragDocuments, .searchedByLanguage, count: result.groups.count, total: rewrites.count,
                             detail: PrivacyToken(result.outcome.answers ? "answers" : "insufficient"))
        }
        return result
    }

    /// The vault's manuals with their languages, for the prompt (`ManualLanguageSearch.promptLine`):
    /// nil when every one is English.
    func manualLanguagesPromptLine(store: VaultStore) -> String? {
        guard let documentStore else { return nil }
        let spaces = retrievalNamespaces(vaultId: store.manifest.id).filter { $0.source.isReference }
        let manuals = spaces.flatMap { documentStore.list(namespace: $0.namespace) }.map { document in
            (title: document.name,
             language: ManualLanguageSearch.code(for: documentStore.languageProfile(documentId: document.id)))
        }
        return ManualLanguageSearch.promptLine(manuals)
    }

    /// The one way a `VaultRetriever` is built (Plan FP P2): the per-turn block, `manual_lookup`
    /// and `equipment_lookup`'s manual fall-through all come here, so every route sees the same
    /// corpus with the same tags.
    ///
    /// Each namespace is queried and the results merged; every passage is tagged with its
    /// `source` from the namespace it came out of, and a learning with its entry's model token so
    /// `ModelScope` scores it by identity. A `documentIds` filter names manuals by title, so a
    /// filtered search reads the manuals alone. The availability check is the manual removal's for
    /// a manual, and "still in its namespace" for a learning — a learning retracted mid-turn is not
    /// quoted — and the removal journal is never consulted for a learning.
    ///
    /// `scope` (Plan JY P2) narrows every namespace to the documents of one language group, so a
    /// lookup over manuals in two languages searches each with its own question and never ranks
    /// two script models' cosines in one list. Nil searches everything, as before.
    func makeRetriever(store: VaultStore, documentStore: DocumentStore?, documentIds: [String]? = nil,
                       namespaces: [RetrievalNamespace]? = nil,
                       editionRequest: EditionRequest = .newest,
                       policy: RetrievalEvidencePolicy? = nil,
                       scope: Set<String>? = nil) -> VaultRetriever {
        let vaultId = store.manifest.id
        let editions = documentEditions(of: store)
        let editionIds = documentIds == nil ? editionDocumentIds(store: store, documentStore: documentStore,
                                                                 editionRequest: editionRequest) : nil
        let labelsEditions = editionRequest.reachesOlderEditions && !editions.isEmpty
        let all = namespaces ?? retrievalNamespaces(vaultId: vaultId)
        let unscoped = documentIds == nil ? all : all.filter { $0.source.isReference }
        // A language group's documents in each namespace; a namespace with none of them is not
        // searched at all (an empty id list is not "no filter").
        let scopedIds: [String: [String]] = scope.map { scope in
            Dictionary(unscoped.map { space -> (String, [String]) in
                let base = Self.searchedIds(for: space, documentIds: documentIds, editionIds: editionIds)
                    ?? (documentStore?.list(namespace: space.namespace).map(\.id) ?? [])
                return (space.namespace, base.filter(scope.contains))
            }, uniquingKeysWith: { first, _ in first })
        } ?? [:]
        let searched = scope == nil ? unscoped : unscoped.filter { !(scopedIds[$0.namespace] ?? []).isEmpty }
        let manualNamespaces = searched.filter { $0.source == .manual }.map(\.namespace)
        let learningNamespaces = searched.filter { $0.source == .teamLearning }.map(\.namespace)
        let entries = learningEntries

        // Row passages of a pictured table whose checks changed a value, disagree, or withhold it
        // (Plan JN P3) still say what was read: they are not searched, and its values come from
        // table_lookup, which applies the checks.
        let withheldRows = withheldRowPassages(vaultId: vaultId, documentStore: documentStore)
        func tagged(_ passages: [DocumentStore.Passage], _ space: RetrievalNamespace) -> [DocumentStore.Passage] {
            passages.filter { raw in
                raw.kind != .tableRow || (space.source != .manual && space.source != .capturedManual) || withheldRows.isEmpty
                    || !withheldRows.contains(VaultTableChecks.withheldKey(documentId: raw.documentId, label: raw.figure ?? ""))
            }.map { raw in
                var passage = raw
                passage.source = space.source
                if space.source == .capturedManual, let page = raw.page {
                    passage.printedPage = capturedManuals.eligible(for:activeSession,vaultID:vaultId)
                        .first { $0.documentID == raw.documentId }?.pages.first { $0.index == page }
                        .flatMap { $0.printedPage > 0 ? $0.printedPage : nil }
                }
                if space.source == .teamLearning {
                    passage.subjectModelToken = entries?.entry(forDocumentId: raw.documentId).map { $0.subject.modelToken }
                        ?? LearningCorpus.subjectModelToken(fromDocumentText: raw.text)
                }
                if labelsEditions, space.source == .manual {
                    passage.editionLabel = editions.edition(of: raw.documentName)?.label
                }
                return passage
            }
        }
        func ids(for space: RetrievalNamespace) -> [String]? {
            if scope != nil { return scopedIds[space.namespace] ?? [] }
            return Self.searchedIds(for: space, documentIds: documentIds, editionIds: editionIds)
        }

        let manualAvailable = VaultManualRemoval.availabilityCheck(forVault: vaultId, documentStore: documentStore, capturedCatalog:capturedManuals)
        return VaultRetriever(query: { query, limit in
            searched.flatMap { space in
                tagged(documentStore?.query(query, limit: limit, namespace: space.namespace,
                                            documentIds: ids(for: space)) ?? [], space)
            }
        }, tokenSearch: { token, limit in
            searched.flatMap { space in
                tagged(documentStore?.passages(containingToken: token, namespace: space.namespace,
                                               documentIds: ids(for: space), limit: limit) ?? [], space)
            }
        }, clauseSearch: { clause, limit in
            searched.flatMap { space in
                tagged(documentStore?.passages(clause: clause, namespace: space.namespace,
                                               documentIds: ids(for: space), limit: limit) ?? [], space)
            }
        }, termSearch: { query, limit in
            searched.flatMap { space in
                tagged(documentStore?.passages(sharingTermsWith: query, limit: limit, namespace: space.namespace,
                                               documentIds: ids(for: space)) ?? [], space)
            }
        }, tableSearch: { label in
            // Tables are extracted from the vault's own manuals (Plan JJ P0) and read from the
            // pages of a photographed manual (Plan JN P4); never from a learning.
            searched.filter { $0.source == .manual || $0.source == .capturedManual }.flatMap { space in
                tagged(documentStore?.passages(table: label, namespace: space.namespace,
                                               documentIds: ids(for: space)) ?? [], space)
            }
        }, tableCatalogue: {
            searched.filter { $0.source == .manual || $0.source == .capturedManual }.flatMap { space in
                (documentStore?.storedTables(namespace: space.namespace, documentIds: ids(for: space)) ?? [])
                    .map { TableReference.Entry(table: $0.table, documentName: $0.documentName, termRule: $0.termRule) }
            }
        }, termStatistics: {
            documentStore?.termStatistics(namespaces: searched.map(\.namespace))
        }, provenance: { documentId in
            if documentId.hasPrefix("captured:") { return true }
            return manualNamespaces.contains { namespace in
                documentStore?.list(namespace: namespace).first { $0.id == documentId }?.sourceType
                    == VaultImporter.recognisedSourceType
            }
        }, availability: { [weak self] documentId in
            if documentId.hasPrefix("captured:") {
                return self?.capturedManuals.available(documentId, session: self?.activeSession, vaultID: vaultId) == true
                    && documentStore?.documents.contains { $0.id == documentId } == true
            }
            if learningNamespaces.contains(where: { namespace in
                documentStore?.list(namespace: namespace).contains { $0.id == documentId } ?? false
            }) { return true }
            return manualAvailable(documentId)
        }, policy: policy ?? retrievalPolicy(forVault: vaultId), modelScope: retrievalModelScope)
    }

    // MARK: - Team learnings at answer time (Plan FP P2)

    /// The evidence behind the latest answer: its basis and the team-learning badge flag the
    /// phone and the lens read. Published; the visible badge is P4's.
    @Published private(set) var answerEvidence: AnswerEvidence?

    /// The learning-alone disclosure the turn in flight owes its reply, keyed by the turn's id.
    private var pendingDisclosure: (turnID: String, disclosure: TeamLearningDisclosure)?
    /// Learning-alone answers already logged, so a prompt rebuilt after a tool call does not log
    /// the same answer twice.
    private var loggedLearningAnswers = Set<String>()

    /// The disclosure an outcome calls for, resolved against the approved entries.
    func disclosure(for outcome: RetrievalOutcome) -> TeamLearningDisclosure? {
        let entries = learningEntries
        return TeamLearningDisclosure.from(outcome) { entries?.entry(forDocumentId: $0) }
    }

    /// Record what a retrieval found, wherever it ran: the answer's evidence for the phone and the
    /// lens, the lead-in the reply owes when it rests on learnings alone, and — for a learning-alone
    /// answer — a line in the job's log and the entry on its record. Returns the disclosure, whose
    /// `leadIn` the caller hands the model.
    @discardableResult
    func noteRetrieval(_ outcome: RetrievalOutcome, now: Date = Date()) -> TeamLearningDisclosure? {
        sourceCenter.noteRetrieved(outcome.passages, sessionId: activeSession?.id)
        let disclosure = disclosure(for: outcome)
        answerEvidence = AnswerEvidence(outcome: outcome, disclosure: disclosure)
        guard let disclosure, disclosure.restsOnLearningAlone else { return disclosure }
        if let turnSourceID { pendingDisclosure = (turnSourceID, disclosure) }
        recordTeamLearningAnswer(disclosure, now: now)
        return disclosure
    }

    /// Put the owed lead-in in front of the reply to the turn in flight (Direct mode), exactly
    /// once. A reply to any other turn, or to a turn that owed nothing, is returned unchanged.
    func applyTeamLearningDisclosure(to reply: String) -> String {
        guard let pending = pendingDisclosure, let turnSourceID, pending.turnID == turnSourceID,
              let leadIn = pending.disclosure.leadIn else { return reply }
        pendingDisclosure = nil
        return TeamLearningDisclosure.prepend(leadIn, to: reply)
    }

    /// The job's log and record say the answer rested on a learning alone: the entries' ids and
    /// approver roles, never the words.
    private func recordTeamLearningAnswer(_ disclosure: TeamLearningDisclosure, now: Date) {
        guard activeSession != nil, let logger else { return }
        // One line per answer: the turn when the Direct path names one, else the minute (live modes).
        let answerKey = turnSourceID ?? "live:\(Int(now.timeIntervalSince1970 / 60))"
        let fresh = disclosure.entries.filter { loggedLearningAnswers.insert(answerKey + "|" + $0.entryID).inserted }
        guard !fresh.isEmpty else { return }
        mutateSession { session in
            var answers = session.teamLearningAnswers ?? []
            for entry in fresh {
                if let index = answers.firstIndex(where: { $0.entryID == entry.entryID }) {
                    answers[index].answers += 1
                } else {
                    answers.append(TeamLearningAnswer(entryID: entry.entryID, approvedByRole: entry.approvedByRole,
                                                      answeredAt: now))
                }
            }
            session.teamLearningAnswers = answers
        }
        logger.append(.init(timestamp: now, kind: .teamLearningAnswered, text: nil, payload: [
            "entry_ids": AnyCodable(fresh.map(\.entryID)),
            "approved_by_roles": AnyCodable(fresh.map(\.approvedByRole)),
            "learning_alone": AnyCodable(true),
        ]))
    }

    /// Whether the active vault has manuals available to search.
    /// Whether a job is open on a vault that seals it (`VaultOnlyPolicy`, Plan KE). A paused job is
    /// still the job. Read from the vault as well as the job, so a job carried over a restart,
    /// before the vault is reloaded, is sealed all the same.
    var vaultOnlyJobOpen: Bool {
        let manifest = activeSession.flatMap { activeVault?.manifest ?? VaultRegistry.shared.manifest(id: $0.vaultId) }
        return VaultOnlyPolicy.isSealed(jobOpen: activeSession != nil, recordedOnJob: activeSession?.vaultOnly,
                                        vaultSays: manifest?.vaultOnly)
    }

    var activeVaultHasManuals: Bool {
        guard let store = activeVault, let documentStore,
              retrievableCorpus(store: store, documentStore: documentStore).manuals else { return false }
        return documentStore.documentCount(namespace: DocumentStore.vaultNamespace(store.manifest.id)) > 0
    }

    /// Whether a session is currently active and accepting input.
    var isSessionActive: Bool { activeSession?.isActive == true }

    // MARK: - A manual was removed under a live session (Plan FN)

    /// Bring the active session in line with a vault a manual has just been removed from.
    ///
    /// **What this must not do is end anything.** A technician removing a superseded manual from
    /// Settings has not finished the job they are standing in: the session id, the machine, the
    /// tasks and their decisions, the parts, the audit log and the chat all continue. What changes
    /// is the vault the session reads from, and the material derived from the manual that has gone.
    ///
    /// Safe to call when the removal was for some other vault, when no session is running, and
    /// twice for the same removal.
    func vaultDidRemoveManual(_ result: VaultManualRemoval.RemovalResult) {
        removedManualTitles[result.vaultId, default: []].insert(result.title)
        guard let session = activeSession, session.vaultId == result.vaultId else { return }

        // The registry's cached store still holds the manifest as it was; the removal has already
        // reloaded the installed manifests, so asking for the store again builds it from the
        // reduced one. The session keeps everything else it has.
        if let refreshed = VaultRegistry.shared.store(forId: result.vaultId) {
            activeVault = refreshed
            modelIndex = VaultModelIndex(store: refreshed)
            partsIndex = VaultPartsIndex(store: refreshed)
            library = ProcedureLibrary(store: refreshed)
        }

        // A figure staged from the removed manual would otherwise stay on the turn and reopen from
        // "show that again". The other manual's figure is left exactly where it is.
        if stagedFigure.map({ isFrom(result, figure: $0) }) == true { stagedFigure = nil }
        if lastShownFigure.map({ isFrom(result, figure: $0) }) == true { lastShownFigure = nil }

        logger?.append(.init(timestamp: Date(), kind: .manualRemoved, text: result.title,
                             payload: ["document": AnyCodable(result.title),
                                       "file": AnyCodable(result.file),
                                       "vault": AnyCodable(result.vaultId),
                                       "remaining_documents": AnyCodable(result.remainingDocuments)]))
    }

    /// Plan FS §4 — record what a vault link came to, when a job is open.
    ///
    /// Reviewing an offered vault mid-job and refusing it is a fact about the visit: the record
    /// says an archive was offered, from which site, and whether it was signed, installed or
    /// turned away. The note carries the source **host** and never the link, which may be a
    /// purchase capability. Inert when no session is running.
    func noteVaultLink(_ note: String, installed: Bool) {
        guard activeSession != nil else { return }
        logger?.appendLifecycle(installed ? .vaultReceived : .vaultLinkReviewed, note: note)
    }

    /// Whether a staged figure came off the manual this result removed. By document id when the
    /// manual was indexed, by file name when it never was — the same identity rule the removal
    /// itself uses, and never the displayed title.
    private func isFrom(_ result: VaultManualRemoval.RemovalResult, figure: StagedFigure) -> Bool {
        if let documentId = result.documentId, figure.documentId == documentId { return true }
        return figure.sourceFile == result.file
    }

    /// Manual titles removed from a vault since launch. For the tests and for a citation that has
    /// to say what happened to the page it names.
    func removedManuals(inVault vaultId: String) -> Set<String> {
        removedManualTitles[vaultId] ?? []
    }

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
        /// Whether the technician asked for this page or the app put it up by itself (Plan GB P1).
        /// Decides what the page can be evidence of — see `PageEvidencePolicy`.
        var origin: PageOrigin
        /// Whether the phone opens it. False when the page goes to the model as the turn's picture
        /// but was not asked for (`FigureAutoOpenPolicy.Decision.attachToModelOnly`).
        var presentOnPhone: Bool
        /// The passages an answer cited on this document, marked on the page (Plan IN P1).
        var citedPassages: [CitedPassage] = []
        /// Where a table a lookup read from a picture was recognised, outlined on the page, since a
        /// picture has no text to mark (Plan JN P2).
        var pictureAreas: [ManualTable.PictureArea] = []
        /// Library pages bind both searchable content and original-PDF revisions.
        let sourceRevision: String?

        init(documentId: String, documentTitle: String, page: Int, figure: String? = nil,
             sourceFile: String? = nil, origin: PageOrigin = .requested,
             presentOnPhone: Bool = true, sourceRevision: String? = nil) {
            self.sourceRevision = sourceRevision
            self.documentId = documentId
            self.documentTitle = documentTitle
            self.page = page
            self.figure = figure
            self.sourceFile = sourceFile
            self.origin = origin
            self.presentOnPhone = presentOnPhone
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

        /// What the page marks, as part of what identifies the page on screen (Plan JW P0): the
        /// cited passages by document and chunk, and the outlined regions. Empty for a plain page.
        /// The sheet used to be identified by its citation alone, so a second "show me" on the same
        /// table page — a later answer marking other rows — was taken for the page already open,
        /// and the sheet kept the first answer's row while the reply said the new rows were marked.
        var marksKey: String {
            guard !citedPassages.isEmpty || !pictureAreas.isEmpty else { return "" }
            let passages = citedPassages.map { "\($0.number)@\($0.anchor.documentId)#\($0.anchor.chunkIndex)" }.sorted()
            let areas = pictureAreas.map { "\($0.physical):\($0.x),\($0.y),\($0.width),\($0.height)" }.sorted()
            return " [" + (passages + areas).joined(separator: " ") + "]"
        }

        /// Whether the vault holds a page that can be rendered at all. The Markdown route holds
        /// extracted text and has none — the honest limit the vault guide names.
        var hasSourcePage: Bool { sourceFile?.lowercased().hasSuffix(".pdf") == true || documentTitle.hasPrefix("Reviewed photographed manual · ") }
    }

    /// The best drawing among a turn's evidence: a drawing outright, else prose that names one.
    /// Ranked order is the retriever's, so "best" is "highest ranked" and nothing re-scores here.
    static func bestFigure(in passages: [VaultRetriever.Passage]) -> VaultRetriever.Passage? {
        passages.first { $0.kind == .diagram && $0.page != nil }
            ?? passages.first { $0.figure?.isEmpty == false && $0.page != nil }
    }

    /// Stage a figure for this turn, or clear the staging when there is none. A figure the phone
    /// puts up stays reachable as `lastShownFigure` for the rest of the session; one staged for
    /// the model only does not (Plan KD P3: an unrelated table the model was handed became what
    /// "show that again" reopened, though the technician had never seen it).
    func stageFigure(_ figure: StagedFigure?) {
        stagedFigure = figure
        if let figure, figure.presentOnPhone { lastShownFigure = figure }
    }

    /// A page `show_source` put on the phone, which it presents itself rather than through the
    /// staging: it is what "show that again" reopens (Plan KD P3).
    func noteShownOnPhone(_ figure: StagedFigure) {
        lastShownFigure = figure
    }

    /// The table `table_lookup` read (Plan KD P3). A later lookup replaces it; the session's end
    /// clears it.
    func noteLookedUpTable(_ label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lookedUpTableLabel = trimmed
    }

    /// Put the session's last figure back on the turn ("show me that figure again").
    @discardableResult
    func restageLastFigure(origin: PageOrigin = .requested) -> StagedFigure? {
        guard var last = lastShownFigure else { return nil }
        if last.documentId.hasPrefix("captured:") {
            guard capturedManuals.historical(citation: last.documentTitle) != nil,
                  manufacturerPDFURL(for: last) != nil else { return nil }
            last.origin = origin; last.presentOnPhone = true; stageFigure(last)
            return last
        }
        // Put back on the phone, whatever the turn that found it did with it (Plan GB P1).
        last.origin = origin
        last.presentOnPhone = true
        // "Show that again" is the one path that reaches back past the current turn, so it is also
        // the one that can reach a manual removed since it was shown. The session's own refresh
        // clears this; the check is here too because a figure outliving its manual by a route
        // nobody thought of is exactly the failure removal exists to prevent.
        if let store = activeVault, let documentStore,
           !VaultManualRemoval.availabilityCheck(forVault: store.manifest.id,
                                                 documentStore: documentStore, capturedCatalog:capturedManuals)(last.documentId) {
            lastShownFigure = nil
            return nil
        }
        stagedFigure = last
        return last
    }

    /// Build a staged figure from a retrieved passage, filling in the source file from the vault's
    /// document ledger so the page can be found again. Nil when the passage names no page.
    func makeStagedFigure(for passage: VaultRetriever.Passage?, vaultId: String) -> StagedFigure? {
        guard let passage, let page = passage.page else { return nil }
        if passage.source == .capturedManual {
            guard let m = capturedManuals.historical(citation:passage.documentName),
                  (1...m.pageCount).contains(page) else { return nil }
            return StagedFigure(documentId:m.documentID,documentTitle:passage.documentName,
                                page:page,figure:passage.figure,sourceFile:"pages.pdf")
        }
        let file = VaultImporter.documentLedger(for: vaultId)
            .entries.first { $0.documentId == passage.documentId }?.file
        return StagedFigure(documentId: passage.documentId, documentTitle: passage.documentName,
                            page: page, figure: passage.figure, sourceFile: file)
    }

    /// The PDF in the vault's read-only baseline that a staged figure's page comes from, or nil
    /// when the document was imported as text (or is no longer installed).
    func sourcePDFURL(for figure: StagedFigure) -> URL? {
        if !Config.fieldAssistActive {
            return PersonalManualLibrary.shared.sourceURL(for: figure)
        }
        guard let vault = activeVault, VaultRegistry.shared.isUnlocked(vault.manifest) else { return nil }
        if figure.documentId.hasPrefix("captured:") {
            guard let m = capturedManuals.historical(citation:figure.documentTitle),
                  (1...m.pageCount).contains(figure.page) else { return nil }
            return try? capturedManuals.source?.file(m,name:"pages.pdf")
        }
        if let entry = ledgerEntry(for:figure),entry.capturedManual != nil {
            guard let store = activeVault,capturedManuals.reviewedDocumentAllowed(figure.documentId,vaultID:store.manifest.id),
                  let document = manifestDocument(for:figure),let path = store.manifest.documentSourceRelativePath(document) else {return nil}
            let url = VaultImporter.baselineDirectory(for:store.manifest.id).appendingPathComponent(path)
            return FileManager.default.fileExists(atPath:url.path) ? url : nil
        }
        guard figure.hasSourcePage, let file = figure.sourceFile, let store = activeVault else { return nil }
        if let entry = ledgerEntry(for:figure),entry.capturedManual != nil,
           !capturedManuals.reviewedDocumentAllowed(figure.documentId,vaultID:store.manifest.id) {return nil}
        let manifest = store.manifest
        // A manual with a removal in flight is already unavailable: its file may still be on disk
        // until cleanup finishes, and opening it would show the page a citation was told to forget.
        guard !VaultManualRemoval.isPending(file: file, vaultId: manifest.id) else { return nil }
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
        if !Config.fieldAssistActive { return PersonalManualLibrary.shared.sourceURL(for: figure) }
        guard let vault = activeVault, VaultRegistry.shared.isUnlocked(vault.manifest) else { return nil }
        if figure.documentId.hasPrefix("captured:") {
            guard let m = capturedManuals.historical(citation: figure.documentTitle) else { return nil }
            return try? capturedManuals.source?.file(m, name: "pages.pdf")
        }
        if let entry = ledgerEntry(for:figure),entry.capturedManual != nil,
           let vaultID = activeVault?.manifest.id,!capturedManuals.reviewedDocumentAllowed(figure.documentId,vaultID:vaultID) {return nil}
        if let direct = sourcePDFURL(for: figure) { return direct }
        guard let store = activeVault, let document = manifestDocument(for: figure),
              !VaultManualRemoval.isPending(file: document.file, vaultId: store.manifest.id),
              let relative = store.manifest.documentSourceRelativePath(document) else { return nil }
        let url = VaultImporter.baselineDirectory(for: store.manifest.id).appendingPathComponent(relative)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// What a citation parsed out of an answer resolves to now.
    ///
    /// A citation outlives the manual it names: an answer given ten minutes ago stays in the chat,
    /// and the manual it quoted can be removed from the vault in between. The three cases are
    /// genuinely different to the reader, so they are three cases and not an optional — opening the
    /// page, being told the manual has gone, and being told this vault never had it.
    enum CitationResolution: Equatable {
        case figure(StagedFigure)
        /// The manual was removed from this vault. `title` is the manual's own title.
        case removed(title: String)
        /// No manual in this vault answers to that title, and nothing says one ever did.
        case unknown(title: String)
    }

    /// Titles of manuals removed from a vault while this app has been running, so a chip tapped
    /// afterwards can say what happened rather than nothing.
    ///
    /// In memory and small on purpose: once the removal has completed there is no record of the
    /// manual left anywhere — Plan FN keeps no tombstone, because an explicit later import is
    /// authoritative and an exclusion list would be a lie. After a restart a stale chip falls to
    /// `.unknown`, which is the honest answer then.
    private var removedManualTitles: [String: Set<String>] = [:]

    /// Turn a citation back into the page it names.
    ///
    /// Matching is by the title the ledger recorded — the title the citation was built from — so a
    /// chip can only ever open the document it names. A manual with a removal in flight resolves as
    /// removed rather than as a page, because its file may still be on disk until cleanup finishes.
    func resolveCitation(_ citation: Citation) -> CitationResolution {
        if !Config.fieldAssistActive {
            if let figure = PersonalManualLibrary.shared.resolve(citation) { return .figure(figure) }
            return .unknown(title: citation.title)
        }
        guard let vault = activeVault, VaultRegistry.shared.isUnlocked(vault.manifest) else { return .unknown(title: citation.title) }
        if citation.title.hasPrefix("Photographed manual · ") {
            guard let m = capturedManuals.historical(citation: citation.title),
                  let page = citation.page, (1...m.pageCount).contains(page),
                  (try? capturedManuals.source?.file(m, name: "pages.pdf")) != nil else {
                return .unknown(title: citation.title)
            }
            return .figure(StagedFigure(documentId: m.documentID, documentTitle: citation.title,
                                        page: page, sourceFile: "pages.pdf"))
        }
        guard citation.kind == .manual, let store = activeVault else {
            return .unknown(title: citation.title)
        }
        let wanted = citation.title.lowercased()
        let entries = VaultImporter.documentLedger(for: store.manifest.id).entries
        guard let entry = entries.first(where: { $0.title.lowercased() == wanted })
                ?? entries.first(where: { $0.title.lowercased().contains(wanted) }) else {
            let removed = removedManualTitles[store.manifest.id] ?? []
            return removed.contains(where: { $0.lowercased() == wanted || $0.lowercased().contains(wanted) })
                ? .removed(title: citation.title)
                : .unknown(title: citation.title)
        }
        guard !VaultManualRemoval.isPending(file: entry.file, vaultId: store.manifest.id) else {
            return .removed(title: entry.title)
        }
        if entry.capturedManual != nil,!capturedManuals.reviewedDocumentAllowed(entry.documentId,vaultID:store.manifest.id) {
            return .unknown(title:citation.title)
        }
        // Only a printed label to go on: through the manual's page labels, never as a PDF page of
        // the same number (Plan KE).
        let printed = citation.printedPage.flatMap { documentStore?.pageLabels(documentId: entry.documentId).physical(forPrinted: $0) }
        return .figure(StagedFigure(documentId: entry.documentId, documentTitle: entry.title,
                                    page: max(citation.page ?? printed ?? 1, 1), figure: citation.figure,
                                    sourceFile: entry.file))
    }

    /// The page a citation names, or nil when it no longer names one. `resolveCitation` says which
    /// kind of nothing it is; this is for the callers that only need the page.
    func stagedFigure(for citation: Citation) -> StagedFigure? {
        if case .figure(let staged) = resolveCitation(citation) { return staged }
        return nil
    }

    /// Everything the figure sheet needs for one staged figure: which document it can show, the
    /// pages it can turn to, the hash the manufacturer's file is checked against, and the
    /// manufacturer's published copy when the manifest names one.
    func manualPageSheet(for figure: StagedFigure) -> ManualPageSheetModel {
        if !Config.fieldAssistActive {
            return PersonalManualLibrary.shared.sheet(for: figure)
                ?? ManualPageSheetModel(citation: "Manual unavailable", documentTitle: "Manual unavailable", citedPage: figure.page)
        }
        guard let vault = activeVault, VaultRegistry.shared.isUnlocked(vault.manifest) else {
            return ManualPageSheetModel(citation: "Manual unavailable", documentTitle: "Manual unavailable", citedPage: figure.page)
        }
        if let m = capturedManuals.historical(citation: figure.documentTitle) {
            let pdf = try? capturedManuals.source?.file(m, name: "pages.pdf")
            // A table read from a photographed page is outlined where it was read (Plan JN P4).
            return ManualPageSheetModel(citation: figure.citation, documentTitle: m.title,
                citedPage: figure.page, manufacturerPDF: pdf, pdfPageCount: m.pageCount,
                ledgerHash: m.pdfSHA256, documentIsPDF: true, photographed: true,
                printedPages: Dictionary(uniqueKeysWithValues: m.pages.map { ($0.index, $0.printedPage) }),
                pictureAreas: figure.pictureAreas)
        }
        let pdf = manufacturerPDFURL(for: figure)
        let document = manifestDocument(for: figure)
        let entry = ledgerEntry(for: figure)
        let reviewed = entry?.capturedManual
        let isPDF = reviewed != nil || (document?.isPDF ?? (figure.sourceFile?.lowercased().hasSuffix(".pdf") == true))
        // The extracted-text route reads the index by document id, so it needs the availability
        // check the PDF route gets for free through `manufacturerPDFURL`: a manual whose rows have
        // gone has no pages, and one whose removal is in flight must not show the ones it still has.
        let isAvailable = activeVault.map {
            VaultManualRemoval.availabilityCheck(forVault: $0.manifest.id, documentStore: documentStore, capturedCatalog:capturedManuals)
        }
        let pages: [ManualPageSheetModel.Page] = isPDF || isAvailable?(figure.documentId) == false ? [] :
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
            ledgerHash: reviewed != nil ? entry?.sourceContentHash : (isPDF ? entry?.contentHash : entry?.sourceContentHash),
            documentIsPDF: isPDF,
            citedFigure: figure.figure,photographed:reviewed != nil,reviewedPhotograph:reviewed != nil,
            printedPages:Dictionary(uniqueKeysWithValues:reviewed?.pages.map {($0.index,$0.printedPage)} ?? []),
            citedPassages: figure.citedPassages, pictureAreas: figure.pictureAreas)
    }

    /// Audit: a technician opened a citation — from a chip under the answer, or by asking.
    func logCitationOpened(_ citation: Citation, origin: CitationOrigin) {
        let label = PageEvidencePolicy.label(for: citation)
        logger?.append(SessionLogger.Event(
            timestamp: Date(), kind: .citationOpened, text: label,
            payload: ["document": AnyCodable(citation.title),
                      "page": AnyCodable(citation.page ?? 0),
                      "origin": AnyCodable(origin.rawValue),
                      "kind": AnyCodable(citation.kind.rawValue)]))
        attachEvidence { evidence in
            if !evidence.citationsOpened.contains(label) { evidence.citationsOpened.append(label) }
        }
    }

    /// The kind of the turn retrieval last ran for (Plan GB P1). `manual_figure` reads it: a page
    /// the model opens during a turn that asked for one is the technician's request; one it opens
    /// on its own initiative is the app's.
    private(set) var lastTurnKind: ManualTurnKind?

    /// Whether the turn in progress asked for a page.
    var turnAskedForPage: Bool { lastTurnKind == .showMe }

    /// The manual page on the technician's screen, while there is one (Plan GB P1). What a spoken
    /// "checked" is about.
    struct OpenPage: Equatable {
        let title: String
        let page: Int
        let figure: String?
        let origin: PageOrigin
        let source: ManualPageRoute

        var label: String { PageEvidencePolicy.label(title: title, page: page, figure: figure) }
    }

    private(set) var openPage: OpenPage?

    /// A page went on screen — or moved to another page. Records it as what `PageEvidencePolicy`
    /// says it is before any confirmation: shown when the app put it there, opened when the
    /// technician asked. **Never verified.** Job 1011 recorded six pages as verified this way.
    func pageDidOpen(_ page: OpenPage) {
        openPage = page
        let state = PageEvidencePolicy.classify(origin: page.origin, confirmation: .none)
        let label = page.label
        logger?.append(SessionLogger.Event(
            timestamp: Date(), kind: state == .shown ? .pageShown : .pageOpened, text: label,
            payload: ["document": AnyCodable(page.title),
                      "page": AnyCodable(page.page),
                      "origin": AnyCodable(page.origin.rawValue),
                      "source": AnyCodable(page.source.rawValue)]))
        attachEvidence { evidence in
            switch state {
            case .shown:
                if !evidence.pagesShown.contains(label) { evidence.pagesShown.append(label) }
            case .opened, .verified:
                if !evidence.citationsOpened.contains(label) { evidence.citationsOpened.append(label) }
            }
        }
    }

    /// The sheet closed.
    func pageDidClose() { openPage = nil }

    /// The technician confirmed the page on screen — a tap on "Checked against manual", or a
    /// spoken confirmation. Returns what the page now counts as, or nil when nothing is open.
    @discardableResult
    func confirmOpenPage(_ confirmation: PageConfirmation) -> PageEvidenceState? {
        guard let page = openPage else { return nil }
        let state = PageEvidencePolicy.classify(origin: page.origin, confirmation: confirmation)
        guard state == .verified else { return state }
        logPageVerified(title: page.title, page: page.page, figure: page.figure, source: page.source,
                        confirmation: confirmation)
        return state
    }

    /// Audit: the technician confirmed a page, and against which route.
    func logPageVerified(title: String, page: Int, figure: String? = nil, source: ManualPageRoute,
                         confirmation: PageConfirmation = .tap) {
        let label = PageEvidencePolicy.label(title: title, page: page, figure: figure)
        logger?.append(SessionLogger.Event(
            timestamp: Date(), kind: .pageVerified, text: label,
            payload: ["document": AnyCodable(title),
                      "page": AnyCodable(page),
                      "source": AnyCodable(source.rawValue),
                      "confirmed_by": AnyCodable(confirmation == .spoken ? "speech" : "tap")]))
        attachEvidence { evidence in
            if !evidence.pagesVerified.contains(label) { evidence.pagesVerified.append(label) }
        }
    }

    /// The pages the technician has verified so far on this job, newest last — what a reading may
    /// cite (Plan GB Decision 2).
    var verifiedPages: [String] {
        guard let session = activeSession else { return [] }
        return EvidenceRollup(tasks: session.tasks, jobEvidence: session.jobEvidence).verifiedPages
    }

    /// Audit: what the figure policy did with a turn's page, and why (Plan GB P1) — so the
    /// diagnostics can say which turn put which page on screen. The turn's words are not written;
    /// its kind is.
    private func logFigurePresentation(_ figure: StagedFigure?, decision: FigureAutoOpenPolicy.Decision,
                                       turnKind: ManualTurnKind) {
        guard let figure else { return }
        let presented: String
        switch decision {
        case .present: presented = "phone"
        case .attachToModelOnly: presented = "model_only"
        case .none: presented = "none"
        }
        logger?.append(SessionLogger.Event(
            timestamp: Date(), kind: .figurePresented, text: figure.citation,
            payload: ["document": AnyCodable(figure.documentTitle),
                      "page": AnyCodable(figure.page),
                      "presented": AnyCodable(presented),
                      "reason": AnyCodable(decision.reason.rawValue),
                      "turn_kind": AnyCodable(turnKind.rawValue)]))
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
        recordConversationTurn(text, sourceID: UUID().uuidString)
    }

    /// The next user-role turn is the app's own instruction, not the technician's words
    /// (Plan GB P0). Set by the caller that sends it — the Field Assist quick action — immediately
    /// before the message goes, and consumed by the turn that carries exactly this text.
    func expectAppInstruction(_ text: String) {
        pendingAppInstruction = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var pendingAppInstruction: String?

    /// The next technician line is a transcript the wearer corrected before it went (Plan JM P1,
    /// "Check what I said before sending"). Set by the caller that sends the corrected text,
    /// immediately before it goes, and consumed by the turn that carries exactly this text; a
    /// different line in between drops it, so it can never mark a later turn.
    func expectEditedTranscript(_ text: String) {
        pendingEditedTranscript = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var pendingEditedTranscript: String?

    /// Preserve exact reports without interpreting questions as performed work.
    ///
    /// An app instruction is logged as what it is — `appInstruction`, never `userMessage` — so no
    /// transcript can quote the app under the technician's name (Plan GB P0).
    func recordConversationTurn(_ text: String, sourceID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var origin = TranscriptOriginClassifier.origin(of: trimmed)
        if let pending = pendingAppInstruction, pending == trimmed {
            origin = .appInstruction
            pendingAppInstruction = nil
        }
        // Plan JM P1: an edited transcript is still the technician's — more so — so the origin
        // stays `.technician` and the line carries an `edited` flag beside it.
        var edited = false
        if let pendingEdit = pendingEditedTranscript {
            if pendingEdit == trimmed { edited = origin == .technician } else { pendingEditedTranscript = nil }
        }
        guard let session = activeSession, let logger, !text.isEmpty else { return }
        // A paused job's record is not the transcript of whatever the wearer says meanwhile
        // (2026-10-03): a weather question asked while a job sat paused landed in that job's log.
        // Checked before the source id is claimed, on purpose — "resume the job" arrives paused,
        // and the providers that re-record every tool round find it unclaimed once the tool has
        // resumed the job, so the turn that brought the job back still makes the record.
        guard session.pausedAt == nil else { return }
        guard claimConversationSource(sourceID, logger: logger) else { return }
        var payload: [String: AnyCodable] = [
            "source_id": AnyCodable(sourceID),
            "equipment_scope": AnyCodable(session.continuityScope),
            "task_id": AnyCodable(session.activeTask?.id ?? "")
        ]
        if edited {
            payload[TranscriptOriginClassifier.editedKey] = AnyCodable(true)
            pendingEditedTranscript = nil
        }
        let now = Date()
        if origin == .technician {
            // A live-mode transcript that lands just after a team learning was filed is the turn
            // that filed it (Plan FP P1): tag it withheld as it is written.
            if let pending = pendingTurnWithhold, now <= pending.until {
                payload[TeamLearningTurnWithholding.withheldByKey] = AnyCodable(pending.candidateId)
                pendingTurnWithhold = nil
            }
            recentTechnicianTurns.append((sourceID, now))
            if recentTechnicianTurns.count > 8 { recentTechnicianTurns.removeFirst() }
        }
        logger.append(.init(timestamp: now,
                            kind: origin == .appInstruction ? .appInstruction : .userMessage,
                            text: text, payload: payload))
    }

    // MARK: Team learnings (Plan FP P1)

    /// The source id of the Direct-path turn in flight, when there is one: set by `LLMService` for
    /// the length of a turn, and by the Tier-0 phrase route around its tool call. Nil on the live
    /// modes, whose transcripts are given their ids when they land.
    ///
    /// Read when a team learning is filed, so the turn that filed it can be withheld from the
    /// model's view of the job exactly — see `TeamLearningTurnWithholding`.
    var turnSourceID: String?

    /// `manual_lookup` searches that found nothing, in the turn in flight — keyed like a
    /// learning answer: the Direct turn's id, else the minute (live modes).
    private var lookupMisses: (turnKey: String, count: Int)?

    /// Count a `manual_lookup` miss against the turn in flight and return the turn's total.
    func noteManualLookupMiss(now: Date = Date()) -> Int {
        let key = turnSourceID ?? "live:\(Int(now.timeIntervalSince1970 / 60))"
        let count = lookupMisses?.turnKey == key ? (lookupMisses?.count ?? 0) + 1 : 1
        lookupMisses = (key, count)
        return count
    }

    /// Technician lines logged recently, newest last — what a live-mode filing withholds.
    private var recentTechnicianTurns: [(sourceID: String, at: Date)] = []
    /// A live-mode filing waiting for its transcript.
    private var pendingTurnWithhold: (candidateId: String, until: Date)?

    /// Record a team-learning candidate on its job: upsert its reference on the session — the
    /// active one, or a finished one through a logger opened on its own directory — and write the
    /// event, which withholds the turn that filed or amended it.
    ///
    /// The event goes into the **active** job's log when there is one, because that is where the
    /// turn that carried the words was logged; a candidate filed on an earlier job also gets the
    /// event in its own job's log, for that job's audit, with nothing withheld there. A status
    /// (`.teamLearningStatus`, Plan FP P3 — sent, received, approved, merged, not taken up) is
    /// written only to the log of the job the candidate was filed on, ended or not.
    func recordTeamLearning(_ kind: SessionLogger.Event.Kind, reference: LearningCandidateReference,
                            sessionId: String, now: Date = Date()) {
        // The reference, on the job it was filed on.
        func upsert(_ session: inout FieldSession) {
            var references = session.teamLearnings ?? []
            if let index = references.firstIndex(where: { $0.candidateId == reference.candidateId }) {
                references[index] = reference
            } else {
                references.append(reference)
            }
            session.teamLearnings = references
        }
        var otherLogger: SessionLogger?
        if activeSession?.id == sessionId {
            mutateSession { upsert(&$0) }
        } else if let stored = history.first(where: { $0.id == sessionId }) {
            let logger = SessionLogger(session: stored,
                                       root: sessionsRoot.appendingPathComponent(sessionId, isDirectory: true))
            let updated = logger.updateSession { upsert(&$0) }
            history = history.replacingFirst(matching: sessionId, with: updated)
            otherLogger = logger
        }

        var payload: [String: AnyCodable] = [
            "candidate_id": AnyCodable(reference.candidateId),
            "status": AnyCodable(reference.status.rawValue),
            "source_id": AnyCodable("team-learning:\(reference.candidateId):\(kind.rawValue):\(Int(now.timeIntervalSince1970))")
        ]
        if let model = reference.modelToken { payload["model_token"] = AnyCodable(model) }
        if reference.inUse { payload["in_use"] = AnyCodable(true) }
        if let otherLogger {
            otherLogger.append(.init(timestamp: now, kind: kind, text: nil, payload: payload))
        }
        guard let session = activeSession, let logger else { return }
        // A status is about the job it was filed on, not whatever job is open when it arrives.
        if kind == .teamLearningStatus, session.id != sessionId { return }
        var activePayload = payload
        activePayload["equipment_scope"] = AnyCodable(session.continuityScope)
        if kind == .teamLearningFiled || kind == .teamLearningAmended {
            activePayload[TeamLearningTurnWithholding.withheldSourceIDsKey] =
                AnyCodable(withheldTurns(candidateId: reference.candidateId, now: now))
        }
        logger.append(.init(timestamp: now, kind: kind, text: nil, payload: activePayload))
    }

    /// Which turns a filing withholds. The turn in flight when the Direct path names one; on the
    /// live modes, the technician lines of the last few seconds, and the next one to land.
    private func withheldTurns(candidateId: String, now: Date) -> [String] {
        if let turnSourceID { return [turnSourceID] }
        let window = TeamLearningTurnWithholding.liveWindow
        pendingTurnWithhold = (candidateId, now.addingTimeInterval(window))
        return recentTechnicianTurns.filter { now.timeIntervalSince($0.at) <= window }.map { $0.sourceID }
    }

    /// Log the assistant's final reply to a Direct-mode turn (Plan GB P0), so the job's transcript
    /// carries both sides and the export's citations — which are read off assistant turns — are
    /// not empty. Called once per turn with the text that was spoken; the turn's source id keeps a
    /// retried or re-entered turn from logging its answer twice. The `Source:` lines are passed as
    /// the answer's citations. Live modes (Gemini Live, OpenAI Realtime) keep what Plan FW says.
    func recordAssistantReply(_ text: String, sourceID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // What "show me the page" refers to next (Plan IN P2): kept whatever the log does.
        sourceCenter.noteAnswer(trimmed, sessionId: PersonalManualLibrary.shared.sourceScope ?? activeSession?.id)
        guard let session = activeSession, let logger, !trimmed.isEmpty else { return }
        // Paused, the job takes no reply — unless the question it answers is already in the
        // record, which is the turn that paused it: "pause the job" was logged while the job ran,
        // and its answer belongs beside it rather than leaving a question with no reply.
        if session.pausedAt != nil, !conversationSourceRecorded(sourceID, logger: logger) { return }
        guard claimConversationSource("assistant:" + sourceID, logger: logger) else { return }
        var payload: [String: AnyCodable] = ["source_id": AnyCodable("assistant:" + sourceID)]
        let citations = CitationLineParser.parse(trimmed).map(\.label)
        if !citations.isEmpty { payload["citations"] = AnyCodable(citations) }
        logger.append(.init(timestamp: Date(), kind: .assistantMessage, text: trimmed, payload: payload))
    }

    /// Whether a turn's source id is new to this session's log. The first sight claims it.
    private func claimConversationSource(_ sourceID: String, logger: SessionLogger) -> Bool {
        loadConversationSources(logger: logger)
        return conversationSourceIDs?.insert(sourceID).inserted == true
    }

    /// Whether a turn with this source id is already in the log. Asks without claiming.
    private func conversationSourceRecorded(_ sourceID: String, logger: SessionLogger) -> Bool {
        loadConversationSources(logger: logger)
        return conversationSourceIDs?.contains(sourceID) == true
    }

    private func loadConversationSources(logger: SessionLogger) {
        guard conversationSourceIDs == nil else { return }
        conversationSourceIDs = Set(logger.readEvents().compactMap {
            $0.payload?["source_id"]?.value as? String
        })
    }

    func continuityContext(turn: String? = nil) -> String? {
        guard let session = activeSession else { return nil }
        return FieldSessionContextSnapshot.render(session: session, events: logger?.readEvents() ?? [],
                                                  siteSystem: siteSystemLines())
    }

    func recallContinuity(query: String?, offset: Int = 0) -> String {
        guard let session = activeSession else { return "No active Field Assist session." }
        return FieldSessionContextSnapshot.recall(session: session, events: logger?.readEvents() ?? [],
                                                  query: query, offset: offset)
    }

    func logAssistantMessage(_ text: String, citations: [String]? = nil) {
        logger?.appendAssistantMessage(text, citations: citations)
    }

    /// Append a finished capture-flow record to the audit log so `SessionExporter` folds it into
    /// the consolidated export (no-op if no session).
    func logCaptureRecord(_ record: CaptureRecord) {
        let event = record.auditEvent
        var payload = event.payload ?? [:]
        payload["equipment_scope"] = AnyCodable(activeSession?.continuityScope ?? "initial")
        payload["source_id"] = AnyCodable(record.id)
        logger?.append(.init(timestamp: event.timestamp, kind: event.kind, text: event.text, payload: payload))
        // A reading taken while a task is running belongs to that task; with none running it
        // belongs to the job (Plan EM).
        attachEvidence { evidence in
            if !evidence.readings.contains(record.id) { evidence.readings.append(record.id) }
        }
    }

    // MARK: Spoken readings (Plan GB P3)

    /// Record a value the technician read out. It attaches to the task in progress — the one a
    /// procedure opened, usually (Decision 1) — or to the job. `page` is kept only when the
    /// technician verified that page (Decision 2); speech is the technician's report (FM).
    @discardableResult
    func recordReading(quantity: String, value: String, unit: String?, page: String? = nil,
                       at: Date = Date()) -> SpokenReading? {
        let quantity = quantity.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let session = activeSession, !quantity.isEmpty, !value.isEmpty else { return nil }
        let reading = SpokenReading(quantity: quantity, value: value,
                                    unit: SpokenReading.normalisedUnit(unit),
                                    unitScope: session.continuityScope,
                                    taskId: session.activeTask?.id, at: at,
                                    citation: verifiedCitation(page))
        mutateSession { $0.spokenReadings.append(reading) }
        attachEvidence { evidence in
            if !evidence.readings.contains(reading.id) { evidence.readings.append(reading.id) }
        }
        logReading(reading, kind: .readingRecorded)
        return reading
    }

    /// Record a value read off a photographed instrument (Plan IS P1): the same shape as a spoken
    /// reading, with the method, the job photo it was read from, and — for a refrigeration reading —
    /// the refrigerant and where that came from. `method` nil records a value the technician said.
    @discardableResult
    func recordInstrumentReading(quantity: String, value: String, unit: String?, method: String?,
                                 photoId: String?, refrigerant: String?, refrigerantSource: String?,
                                 at: Date = Date()) -> SpokenReading? {
        let quantity = quantity.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let session = activeSession, !quantity.isEmpty, !value.isEmpty else { return nil }
        let reading = SpokenReading(quantity: quantity, value: value,
                                    unit: SpokenReading.normalisedUnit(unit),
                                    unitScope: session.continuityScope,
                                    taskId: session.activeTask?.id, at: at,
                                    method: method, photoId: photoId,
                                    refrigerant: refrigerant, refrigerantSource: refrigerantSource)
        mutateSession { $0.spokenReadings.append(reading) }
        attachEvidence { evidence in
            if !evidence.readings.contains(reading.id) { evidence.readings.append(reading.id) }
        }
        logReading(reading, kind: .readingRecorded)
        return reading
    }

    /// Keep the running rule chain with the job record, or clear it (Plan JJ P3), through the one
    /// update path, so a relaunch resumes the chain at the step it was on.
    func persistChainRun(_ record: PersistedChainRun?) {
        guard activeSession != nil, activeSession?.ruleChainRun != record else { return }
        mutateSession { $0.ruleChainRun = record }
    }

    /// Record a rule chain's read-back on the job as a reading (Plan JJ P2): "chain: <name>", the
    /// steps with their citations as the value, worked by the chain rather than said. It attaches
    /// where a spoken reading does — the task in progress, else the job.
    /// A step that used a value read from a picture of a table is kept in `pictureMarks` as well
    /// as in the read-back's text (Plan JN P2).
    @discardableResult
    func recordChainReading(chain: String, readBack: String, pictureMarks: [String] = [],
                            at: Date = Date()) -> SpokenReading? {
        let readBack = readBack.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let session = activeSession, !readBack.isEmpty else { return nil }
        let reading = SpokenReading(quantity: "chain: \(chain)", value: readBack, unit: nil,
                                    unitScope: session.continuityScope, taskId: session.activeTask?.id, at: at,
                                    method: SpokenReading.ruleChainMethod, pictureMarks: pictureMarks)
        mutateSession { $0.spokenReadings.append(reading) }
        attachEvidence { evidence in
            if !evidence.readings.contains(reading.id) { evidence.readings.append(reading.id) }
        }
        logReading(reading, kind: .readingRecorded)
        return reading
    }

    /// The refrigerant written down for the unit the job is on — from the nameplate, the
    /// technician or the unit's display — or nil. Never a default (Plan IS decision 3).
    var activeRefrigerant: DeviceIdentityField? {
        guard let session = activeSession else { return nil }
        return session.identityFields.last {
            $0.name.lowercased().contains("refrigerant")
                && (session.identityEquipmentScopes[$0.name.lowercased()] ?? "initial") == session.continuityScope
        }
    }

    /// Correct a reading: the new value supersedes the old one. It is **not** a second reading and
    /// never a second finished task — the record prints "140 °F (corrected to 135 °F at 5:28 PM)".
    /// With no id, the latest reading of that quantity on this unit (or the latest at all).
    @discardableResult
    func correctReading(id: String? = nil, quantity: String? = nil, value: String, unit: String?,
                        page: String? = nil, at: Date = Date()) -> SpokenReading? {
        guard let session = activeSession else { return nil }
        let wanted = quantity?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // A chain's read-back is worked, not said: it is never what "no, 135" corrects.
        let said = session.spokenReadings.filter { !$0.isRuleChain }
        let candidates = said.filter { $0.unitScope == session.continuityScope }
        let target = id.flatMap { id in said.first { $0.id == id } }
            ?? candidates.last { wanted == nil || wanted?.isEmpty == true || $0.quantity.lowercased() == wanted }
            ?? said.last
        guard let target else { return nil }
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let correction = SpokenReading(quantity: target.quantity, value: value,
                                       unit: SpokenReading.normalisedUnit(unit) ?? target.unit,
                                       unitScope: target.unitScope, taskId: target.taskId, at: at,
                                       supersedes: target.id,
                                       citation: verifiedCitation(page) ?? target.citation,
                                       // Said, so no method or photo — but on the same refrigerant.
                                       refrigerant: target.refrigerant,
                                       refrigerantSource: target.refrigerantSource)
        mutateSession { $0.spokenReadings.append(correction) }
        logReading(correction, kind: .readingCorrected)
        return correction
    }

    /// A page may be cited by a reading only once the technician verified it.
    private func verifiedCitation(_ page: String?) -> String? {
        guard let page = page?.trimmingCharacters(in: .whitespacesAndNewlines), !page.isEmpty else { return nil }
        let wanted = page.lowercased()
        return verifiedPages.first { $0.lowercased() == wanted || $0.lowercased().hasPrefix(wanted + ",") }
    }

    private func logReading(_ reading: SpokenReading, kind: SessionLogger.Event.Kind) {
        var payload: [String: AnyCodable] = [
            "reading_id": AnyCodable(reading.id),
            "quantity": AnyCodable(reading.quantity),
            "value": AnyCodable(reading.value),
            "unit": AnyCodable(reading.unit ?? ""),
            "equipment_scope": AnyCodable(reading.unitScope),
            "task_id": AnyCodable(reading.taskId ?? ""),
            "reported_by": AnyCodable(reading.isInstrumentReading ? "instrument_reading"
                                      : reading.isRuleChain ? SpokenReading.ruleChainMethod : "technician")
        ]
        if let method = reading.method { payload["method"] = AnyCodable(method) }
        if let photoId = reading.photoId { payload["photo_id"] = AnyCodable(photoId) }
        if let refrigerant = reading.refrigerant { payload["refrigerant"] = AnyCodable(refrigerant) }
        if let source = reading.refrigerantSource { payload["refrigerant_source"] = AnyCodable(source) }
        if let supersedes = reading.supersedes { payload["supersedes"] = AnyCodable(supersedes) }
        if let citation = reading.citation { payload["citation"] = AnyCodable(citation) }
        if let marks = reading.pictureMarks { payload["picture_marks"] = AnyCodable(marks) }
        logger?.append(.init(timestamp: reading.at, kind: kind,
                             text: "\(reading.quantity) \(reading.valueWithUnit)", payload: payload))
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

    /// Whether a job is open enough to take evidence. **Paused counts**: the billing clock has
    /// stopped, not the visit, and the same `endedAt` rule the rest of the guided flow keys on
    /// (Plan FO P1) is the one that decides whether a photograph belongs to this job.
    var isOpenForEvidence: Bool {
        guard let session = activeSession else { return false }
        return session.endedAt == nil && session.outcome != .cancelled
    }

    /// Attach a photo to the open job (Plan FO P2a).
    ///
    /// The bytes are expected to be the *filtered* copy: every route asks for one in its own right
    /// — `filteredStill(for:source:)` for a glasses still, `JobPhotoEvidenceService` for a picture
    /// the phone already holds — because filtering is not inherited, and the copy stored here is
    /// the only one that survives. `filterWasOn` records the app-wide setting as it stood at
    /// capture, so review can say what the recipient will see.
    @discardableResult
    func attachPhoto(_ data: Data, caption: String? = nil,
                     origin: JobMediaItem.Origin = .photoLog,
                     filterWasOn: Bool = false) -> URL? {
        guard isOpenForEvidence, let url = logger?.attachPhoto(data, caption: caption) else {
            return nil
        }
        let name = url.lastPathComponent
        let taskId = activeSession?.tasks.last { $0.status == .inProgress }?.id
        attachEvidence { evidence in
            if !evidence.photos.contains(name) { evidence.photos.append(name) }
        }
        mutateSession { session in
            session.media.append(JobMediaItem(
                id: name, kind: .photo, capturedAt: Date(), origin: origin,
                taskId: taskId,
                caption: caption?.isEmpty == false ? caption : nil,
                filterWasOn: filterWasOn))
            // A selection made earlier in the visit has to learn about a photo taken after it.
            if let selection = session.evidenceSelection {
                session.evidenceSelection = selection.reconciled(with: session.media)
            }
            return ()
        }
        if let sessionId = activeSession?.id {
            offlineQueue?.enqueue(QueuedOp.make(
                kind: .photoUpload, sessionId: sessionId,
                json: ["path": url.path, "caption": caption ?? ""]))
        }
        return url
    }

    /// File a clip against the open job (Plan FO P2b).
    ///
    /// The bytes are already blurred: a clip is recorded off `OutboundFrameRelay`, which is where
    /// the bystander filter runs once for every camera-rate consumer, so there is nothing left to
    /// filter here. What this records beside the file is what the review needs and the file cannot
    /// say for itself — how long it runs, what it weighs (which is what decides whether a channel
    /// can carry it), which poster frame stands in for it, and whether it was cut short.
    @discardableResult
    func attachClip(_ data: Data, posterJPEG: Data?, caption: String?,
                    durationSeconds: TimeInterval, filterWasOn: Bool,
                    cutShort: Bool) -> String? {
        guard isOpenForEvidence,
              let url = logger?.attachClip(data, posterJPEG: posterJPEG, caption: caption,
                                           durationSeconds: durationSeconds,
                                           cutShort: cutShort) else { return nil }
        let name = url.lastPathComponent
        let taskId = activeSession?.tasks.last { $0.status == .inProgress }?.id
        mutateSession { session in
            session.media.append(JobMediaItem(
                id: name, kind: .clip, capturedAt: Date(), origin: .clipRecord,
                taskId: taskId,
                caption: caption?.isEmpty == false ? caption : nil,
                filterWasOn: filterWasOn,
                durationSeconds: durationSeconds,
                byteCount: data.count,
                posterId: posterJPEG == nil ? nil : name + ".jpg",
                cutShort: cutShort))
            if let selection = session.evidenceSelection {
                session.evidenceSelection = selection.reconciled(with: session.media)
            }
            return ()
        }
        // **Not** a `photoUpload`. That op kind is what `OfflineQueue.prunePhotoEvidence` evicts
        // files for once they are delivered, and a clip is part of a compliance record that the
        // store already refuses to delete. It is queued under its own kind, which nothing prunes.
        if let sessionId = activeSession?.id {
            offlineQueue?.enqueue(QueuedOp.make(
                kind: .clipUpload, sessionId: sessionId,
                json: ["path": url.path, "caption": caption ?? "",
                       "duration_seconds": durationSeconds, "bytes": data.count]))
        }
        return name
    }

    // MARK: Evidence review (Plan FO P2a)

    /// The job's evidence, oldest first — what the review grid draws and the export renders.
    var jobMedia: [JobMediaItem] { activeSession?.media ?? [] }

    /// The selection as it stands, reconciled against whatever evidence the job holds right now.
    /// A job that has never reached the review step gets the proposal: `photo_log` ticked, every
    /// other route offered.
    func evidenceSelection() -> EvidenceSelection {
        let media = jobMedia
        guard let stored = activeSession?.evidenceSelection else {
            return EvidenceSelection.proposed(for: media)
        }
        return stored.reconciled(with: media)
    }

    /// Include or leave out one piece of evidence as the technician's own choice (Plan GB P3) —
    /// a tap on its thumbnail, or "leave that photo out". `itemId` nil means the latest one.
    /// Returns the item decided, or nil when there is nothing to decide about.
    @discardableResult
    func decideEvidence(itemId: String?, included: Bool) -> JobMediaItem? {
        guard isOpenForEvidence else { return nil }
        guard let item = itemId.flatMap({ id in jobMedia.first { $0.id == id } }) ?? jobMedia.last else {
            return nil
        }
        var selection = evidenceSelection()
        selection.decide(item.id, included: included)
        setEvidenceSelection(selection)
        return item
    }

    /// Every piece of evidence decided at once: all in, all out, or kept as it stands.
    func decideAllEvidence(included: Bool?) {
        guard isOpenForEvidence, !jobMedia.isEmpty else { return }
        var selection = evidenceSelection()
        selection.decideAll(included: included)
        setEvidenceSelection(selection)
    }

    /// Record what the technician chose. Written **before** the job is closed, so the record the
    /// close takes already carries it and the re-send reproduces the same PDF.
    func setEvidenceSelection(_ selection: EvidenceSelection) {
        guard isOpenForEvidence else { return }
        mutateSession { $0.evidenceSelection = selection; return () }
        logger?.append(.init(timestamp: Date(), kind: .evidenceSelected,
                             text: "evidence selection",
                             payload: ["reviewed": AnyCodable(selection.reviewed),
                                       "included": AnyCodable(selection.includedCount),
                                       "total": AnyCodable(selection.entries.count)]))
    }

    /// Plan CT PR 4 — erase session logs from a phone that has left the firm: its logs from the
    /// managed period are the firm's record, delivered to it first (`OrgDepartureService`). Never
    /// the session in progress. Returns how many were removed.
    @discardableResult
    func deleteSessions(ids: Set<String>) -> Int {
        let erasable = ids.subtracting(activeSession.map { [$0.id] } ?? [])
        var removed = 0
        for id in erasable {
            let directory = sessionsRoot.appendingPathComponent(id, isDirectory: true)
            if (try? FileManager.default.removeItem(at: directory)) != nil { removed += 1 }
        }
        _ = try? capturedManuals.source?.deleteMatching { metadata, _ in
            guard erasable.contains(metadata.sessionID) else { return false }
            for document in self.documentStore?.documents ?? []
                where document.id.hasPrefix("captured:\(metadata.captureID):") {
                self.documentStore?.forget(documentId:document.id)
            }
            return true
        }
        history.removeAll { erasable.contains($0.id) }
        return removed
    }

    /// Where a session's evidence files live. Needed by the share sheet, which hands out the
    /// stored (already filtered) originals rather than anything re-encoded.
    func photosDirectory(sessionId: String) -> URL {
        sessionDirectory(sessionId: sessionId)
            .appendingPathComponent("photos", isDirectory: true)
    }

    /// Where a session's `session.json` and `log.jsonl` live, for readers that only read
    /// (`SessionLogger.readEvents(at:)`) and must not open a logger on a finished job.
    func sessionDirectory(sessionId: String) -> URL {
        sessionsRoot.appendingPathComponent(sessionId, isDirectory: true)
    }

    /// The finished session's own evidence, for a past job's review and re-share.
    func media(sessionId: String) -> [JobMediaItem] {
        history.first { $0.id == sessionId }?.media ?? []
    }

    // MARK: Customer sign-off (Plan FO P2c)

    /// Whether the organisation asks for a signature on every job. A stand-in for CT's profile —
    /// read here so every surface asks one question rather than each reading a preference.
    var customerSignOffRequired: Bool { Config.organizationRequiresCustomerSignOff }

    /// The acceptance recorded against a session, open or finished.
    func signOff(sessionId: String) -> CustomerSignOff? {
        if activeSession?.id == sessionId { return activeSession?.signOff }
        return history.first { $0.id == sessionId }?.signOff
    }

    /// Whether a finished job can still be signed.
    ///
    /// **Until the report has been sent**, which is the line the plan draws: a customer's signature
    /// added after the work order left would describe a document nobody holds. Read off the
    /// session's own append-only log rather than a flag, because that log is what actually records
    /// a send and it survives a relaunch.
    func signOffIsStillOpen(sessionId: String) -> Bool {
        guard signOff(sessionId: sessionId) == nil else { return false }
        return !reportWasSent(sessionId: sessionId)
    }

    /// Whether this session's report has gone out by any channel.
    func reportWasSent(sessionId: String) -> Bool {
        let events: [SessionLogger.Event]
        if activeSession?.id == sessionId, let logger {
            events = logger.readEvents()
        } else {
            events = SessionLogger.readEvents(
                at: sessionsRoot.appendingPathComponent(sessionId, isDirectory: true))
        }
        return events.contains { $0.kind == .reportSent }
    }

    /// Where a session's signature picture lives, for the page and the work order.
    func signatureURL(sessionId: String, imageId: String) -> URL {
        photosDirectory(sessionId: sessionId).appendingPathComponent(imageId)
    }

    /// Write the customer's answer onto a session — the open one at close, or a finished one from
    /// its page (Plan FO P2c).
    ///
    /// **It sends nothing.** Delivery is still the technician's Send tap, and this deliberately
    /// touches neither `stagedDelivery` nor the offline queue: a signature is a record of what the
    /// customer agreed to, and turning it into a trigger would make the acceptance the act of
    /// sending, which is exactly the confusion the sign-off exists to avoid.
    ///
    /// The picture and its strokes are written first, so the value that lands on the session names
    /// files that exist. A finished session is updated through a logger opened on its own directory,
    /// which is the only owner of that directory and the one `DataStoreRegistry` registers.
    @discardableResult
    func recordSignOff(_ signOff: CustomerSignOff, pngData: Data? = nil, strokeData: Data? = nil,
                       sessionId: String? = nil) -> CustomerSignOff? {
        let targetId = sessionId ?? activeSession?.id
        guard let targetId else { return nil }
        let isActive = activeSession?.id == targetId
        guard isActive || history.contains(where: { $0.id == targetId }) else { return nil }
        // A report that has already gone cannot gain a signature afterwards. The open job is
        // exempt by definition: its report has not been built yet.
        guard isActive || !reportWasSent(sessionId: targetId) else { return nil }

        let directory = sessionsRoot.appendingPathComponent(targetId, isDirectory: true)
        let target: SessionLogger?
        if isActive, let logger {
            target = logger
        } else if let stored = history.first(where: { $0.id == targetId }) {
            target = SessionLogger(session: stored, root: directory)
        } else {
            target = nil
        }

        var filed = signOff
        if let pngData, let target {
            let names = target.attachSignature(pngData: pngData, strokeData: strokeData)
            filed = signOff.filed(imageId: names.image, strokeDataId: names.strokes)
        }

        let written = filed
        if isActive {
            mutateSession { $0.signOff = written; return () }
        } else if let target {
            let updated = target.updateSession { $0.signOff = written }
            history = history.replacingFirst(matching: targetId, with: updated)
        }

        // The log carries the fact and the digest, never the drawing and never the customer's
        // comment: a signature is a picture of somebody's name, and an audit needs to know what
        // was agreed to, not to hold a second copy of it.
        target?.append(.init(timestamp: Date(), kind: .customerSignOff,
                             text: written.method.rawValue,
                             payload: ["method": AnyCodable(written.method.rawValue),
                                       "summary_digest": AnyCodable(written.summaryDigest),
                                       "summary_lines": AnyCodable(written.summaryLines.count),
                                       "named": AnyCodable(!written.customerName.isEmpty),
                                       "signature": AnyCodable(written.signatureImageId != nil),
                                       "declined_reason": AnyCodable(written.declinedReason != nil)]))
        return written
    }

    /// The hand-over sheet was put in front of a customer and closed without an answer.
    func logSignOffCancelled(sessionId: String? = nil) {
        let targetId = sessionId ?? activeSession?.id
        guard let targetId else { return }
        let event = SessionLogger.Event(timestamp: Date(), kind: .customerSignOffCancelled,
                                        text: "cancelled", payload: nil)
        if activeSession?.id == targetId {
            logger?.append(event)
        } else if let stored = history.first(where: { $0.id == targetId }) {
            SessionLogger(session: stored,
                          root: sessionsRoot.appendingPathComponent(targetId, isDirectory: true))
                .append(event)
        }
    }

    // MARK: Debriefs (Plan FO P3b)

    /// Every debrief on a session, open or finished, newest first.
    func debriefs(sessionId: String) -> [JobDebrief] {
        let session = activeSession?.id == sessionId ? activeSession
            : history.first { $0.id == sessionId }
        return (session?.debriefs ?? []).sorted { $0.recordedAt > $1.recordedAt }
    }

    /// Append a debrief to a job — the **only** write the whole debrief flow makes.
    ///
    /// It is deliberately narrow. Nothing here touches `billableSeconds`, the tasks, the
    /// equipment, the evidence selection or the customer's sign-off: a debrief is an account added
    /// after the visit, not a re-opening of it, and a method that could reach any of those would
    /// be a method somebody eventually would. A finished session is updated through a logger
    /// opened on its own directory, the same route `recordSignOff` takes and for the same reason.
    @discardableResult
    func recordDebrief(_ debrief: JobDebrief, sessionId: String? = nil) -> JobDebrief? {
        let targetId = sessionId ?? activeSession?.id
        guard let targetId else { return nil }
        let isActive = activeSession?.id == targetId
        guard isActive || history.contains(where: { $0.id == targetId }) else { return nil }

        if isActive {
            mutateSession { $0.debriefs.append(debrief); return () }
        } else if let stored = history.first(where: { $0.id == targetId }) {
            let logger = SessionLogger(session: stored,
                                       root: sessionsRoot.appendingPathComponent(targetId,
                                                                                 isDirectory: true))
            let updated = logger.updateSession { $0.debriefs.append(debrief) }
            history = history.replacingFirst(matching: targetId, with: updated)
        }

        // Counts and provenance, never the items: the entries are the technician's words and they
        // are already on the session record. An audit needs to know a debrief was saved, by which
        // model, from how many turns.
        logDebrief(.debriefSaved, sessionId: targetId, text: debrief.id, payload: [
            "entries": AnyCodable(debrief.entries.count),
            "turns": AnyCodable(debrief.turns.count),
            "unsummarised": AnyCodable(debrief.unsummarised),
            "model": AnyCodable(debrief.provenance?.modelIdentifier ?? ""),
            "prompt_digest": AnyCodable(debrief.provenance?.promptVersionDigest ?? "")
        ])
        return debrief
    }

    /// Give a job the conversation its debrief is landing in (Plan FO P3b).
    ///
    /// Only when it has none. A job that already owns a thread keeps it — the debrief's turns join
    /// that conversation, which is the point — and a finished job that never had one gains this
    /// binding so review later finds the debrief in place rather than in an orphan thread.
    func bindDebriefThread(_ threadId: String, sessionId: String) {
        if activeSession?.id == sessionId {
            guard activeSession?.conversationThreadId == nil else { return }
            bindConversationThread(threadId, reason: .debriefStarted)
            return
        }
        guard let stored = history.first(where: { $0.id == sessionId }),
              stored.conversationThreadId == nil else { return }
        let logger = SessionLogger(session: stored,
                                   root: sessionsRoot.appendingPathComponent(sessionId,
                                                                             isDirectory: true))
        let updated = logger.updateSession { $0.conversationThreadId = threadId }
        history = history.replacingFirst(matching: sessionId, with: updated)
        logger.append(.init(timestamp: Date(), kind: .jobThreadBound,
                            text: JobThreadPolicy.BindReason.debriefStarted.rawValue,
                            payload: ["thread": AnyCodable(threadId),
                                      "reason": AnyCodable(JobThreadPolicy.BindReason.debriefStarted.rawValue)]))
    }

    /// The channel this job's report went by last time, when it went at all.
    ///
    /// Read off the session's own append-only log, which is the only place a send is recorded.
    /// **The addresses are not there and that is deliberate** (Plan EM): `completeDelivery` writes
    /// down how many recipients there were and never who they were, so an addendum can follow the
    /// original's *channel* and takes its recipients from the settings or the organisation profile.
    func lastDeliveryChannel(sessionId: String) -> DeliveryChannel? {
        let events: [SessionLogger.Event]
        if activeSession?.id == sessionId, let logger {
            events = logger.readEvents()
        } else {
            events = SessionLogger.readEvents(
                at: sessionsRoot.appendingPathComponent(sessionId, isDirectory: true))
        }
        guard let sent = events.last(where: { $0.kind == .reportSent }),
              let raw = sent.payload?["channel"]?.value as? String else { return nil }
        return DeliveryChannel(rawValue: raw)
    }

    /// The addendum document for a job, or nil when it has nothing to add.
    ///
    /// Rendered from the debriefs `DebriefDocumentPolicy` places outside the work order, so a job
    /// whose report has not gone produces **no** addendum — its debriefs are in the work order
    /// where a reader will find them.
    func addendumAttachment(sessionId: String) -> DeliveryRequest.Attachment? {
        guard let session = activeSession?.id == sessionId ? activeSession
                : history.first(where: { $0.id == sessionId }) else { return nil }
        let name = VaultRegistry.shared.manifest(id: session.vaultId)?.name ?? session.vaultId
        let record = WorkRecord(session: session, vaultName: name,
                                vaultSourceNote: VaultSourceBadge.forInstalledVault(id: session.vaultId)?
                                    .recordLine(vaultName: name),
                                usage: jobUsage(sessionId: session.id))
        let placement = DebriefDocumentPolicy.placement(
            debriefs: record.debriefs,
            reportAlreadySent: reportWasSent(sessionId: sessionId))
        let debriefs = placement.addendumDebriefs
        guard !debriefs.isEmpty else { return nil }
        let provenance = debriefs.compactMap(\.provenance).last
        guard let lease = try? StagedExportCoordinator.fieldSession.makeLease(
            fileExtension: "pdf", displayName: "debrief_addendum.pdf",
            fallbackName: "debrief_addendum.pdf", write: { url in
                try SessionExporter.writeAddendumPDF(record: record, debriefs: debriefs, to: url,
                                                     provenance: provenance)
            }) else { return nil }
        return DeliveryRequest.Attachment(url: lease.fileURL, kind: .pdf,
                                          filename: record.reportFileStem + "-addendum.pdf")
    }

    /// Write one debrief event against a session, open or finished.
    ///
    /// The turns are logged as they are said — before any save — so an abandoned debrief leaves a
    /// record of what was said and of the fact that nothing was written onto the job.
    func logDebrief(_ kind: SessionLogger.Event.Kind, sessionId: String, text: String? = nil,
                    payload: [String: AnyCodable] = [:]) {
        let event = SessionLogger.Event(timestamp: Date(), kind: kind, text: text,
                                        payload: payload.isEmpty ? nil : payload)
        if activeSession?.id == sessionId {
            logger?.append(event)
        } else if let stored = history.first(where: { $0.id == sessionId }) {
            SessionLogger(session: stored,
                          root: sessionsRoot.appendingPathComponent(sessionId, isDirectory: true))
                .append(event)
        }
    }

    /// Write one recorded-job event against a session, open or finished (Plan HE). There is no
    /// text on purpose: these lines carry counts and digests, never a word that was said.
    func logRecording(_ kind: SessionLogger.Event.Kind, sessionId: String, payload: [String: AnyCodable]) {
        logDebrief(kind, sessionId: sessionId, payload: payload)
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
        mutateSession { $0.procedureEquipmentScope = $0.continuityScope }
        attachProcedureTask(procedure)
        guard let entry = newRunner.currentStep else { throw FieldSessionError.unknownProcedure(id) }
        return entry
    }

    /// A procedure opens — or attaches to — a task on the current unit (Plan GB Decision 1), so
    /// the pages, photos and readings gathered while it runs have somewhere to go. Before this a
    /// procedure started by `procedure_runner` created no task, and everything it gathered landed
    /// on the job. An open task already naming the procedure is the one it attaches to — that is
    /// how accepting a recommendation starts its procedure — and otherwise the procedure is the
    /// technician's own work, recorded as such.
    private func attachProcedureTask(_ procedure: Procedure) {
        guard let session = activeSession else { return }
        let now = Date()
        if let existing = session.tasks.last(where: {
            $0.procedureId == procedure.id && $0.status.isOpen && session.belongsToCurrentEquipment($0)
        }) {
            guard existing.status != .inProgress else { return }
            mutateSession { session in
                guard let idx = session.tasks.firstIndex(where: { $0.id == existing.id }) else { return }
                session.tasks[idx].status = .inProgress
                session.tasks[idx].acceptedAt = session.tasks[idx].acceptedAt ?? now
            }
            return
        }
        let task = FieldSession.Task(title: procedure.title, origin: .operatorAdded,
                                     status: .inProgress, procedureId: procedure.id,
                                     createdAt: now, acceptedAt: now)
        mutateSession {
            $0.tasks.append(task)
            $0.taskEquipmentScopes[task.id] = $0.continuityScope
        }
        logger?.append(.init(timestamp: now, kind: .taskStarted, text: task.title,
                             payload: ["task_id": AnyCodable(task.id),
                                       "origin": AnyCodable("procedure"),
                                       "procedure_id": AnyCodable(procedure.id)]))
        raiseTaskCue(task, phase: .started)
    }

    @discardableResult
    func advanceProcedure(choice: String?) throws -> ProcedureRunner.Transition {
        guard let runner else { throw FieldSessionError.noProcedureRunning }
        let transition = try runner.advance(choice: choice)
        switch transition {
        case .completed(let outcome):
            closeTaskForProcedure(id: activeProcedureId, outcome: outcome)
            clearRunner()
        case .arrivedAtTerminal(let step):
            requireVerification(for: step)
        case .moved:
            break
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

    /// Finish the running procedure. On a last step that asks for a check, `confirmed` is the
    /// technician saying it passed; without it the procedure ends as `pending_verification`, its
    /// fix is recorded done, and a "Verify: …" task stays open (Plan GB P3). Returns the outcome
    /// recorded and the title of any check left open.
    @discardableResult
    func completeProcedure(outcome: String, confirmed: Bool = false) throws
        -> (outcome: String, openVerification: String?) {
        guard let runner else { throw FieldSessionError.noProcedureRunning }
        if let step = runner.currentStep { requireVerification(for: step) }
        let owesCheck = runner.currentStep?.needsConfirmation == true && !confirmed
        let recorded = owesCheck ? Self.pendingVerificationOutcome : outcome
        _ = runner.complete(outcome: recorded)
        let procedureId = activeProcedureId
        closeTaskForProcedure(id: procedureId, outcome: recorded, confirmed: !owesCheck)
        clearRunner()
        let open = owesCheck ? activeSession?.openVerifications.last?.title : nil
        return (recorded, open)
    }

    /// The outcome a procedure ends with when its check is still owed.
    static let pendingVerificationOutcome = "pending_verification"

    private func clearRunner() {
        runner = nil
        activeProcedureId = nil
    }

    // MARK: - Export

    /// Export a session's compliance artifacts (consolidated JSON audit and/or PDF work order).
    /// Defaults to the active session, falling back to the most recent. Returns one protected
    /// staging lease per artifact; holding a lease is what keeps its file.
    @discardableResult
    ///
    /// - Parameter transcript: who the record is for (Plan HD). Nil is an export taken for the
    ///   record — the office's, under the organisation's policy.
    func exportSession(id: String? = nil,
                       formats: Set<SessionExporter.Format> = [.json, .pdf],
                       clipPlan: ClipDeliveryPlan = .undecided,
                       transcript: ReportTranscriptPolicy.Decision? = nil) throws -> [StagedExportLease] {
        guard let sessionId = id ?? activeSession?.id ?? history.first?.id else {
            throw FieldSessionError.noActiveSession
        }
        guard !lockedSessionIDs.contains(sessionId) else { throw FieldSessionError.vaultLocked(sessionId) }
        let dir = sessionsRoot.appendingPathComponent(sessionId, isDirectory: true)
        let liveSnapshot = activeSession?.id == sessionId ? activeSessionSnapshot() : nil
        let leases = try SessionExporter.export(sessionDir: dir, formats: formats,
                                                sessionOverride: liveSnapshot,
                                                clipPlan: clipPlan,
                                                reportAlreadySent: reportWasSent(sessionId: sessionId),
                                                transcript: transcript
                                                    ?? ReportTranscriptPolicy.archive(context: reportTranscriptContext()))
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
        history = loaded.filter { !lockedSessionIDs.contains($0.id) }.sorted { $0.startedAt > $1.startedAt }
    }

    /// If the previous app run was interrupted (in_progress session left behind), pick it up.
    private func restoreInProgressSessionIfAny() {
        guard let inProgress = history.first(where: { $0.endedAt == nil && $0.outcome != .cancelled }) else { return }
        guard let manifest = VaultRegistry.shared.manifest(id: inProgress.vaultId) else { return }
        activeSession = inProgress
        if hasCurrentWorkAccess, VaultRegistry.shared.isUnlocked(manifest) {
            let store = VaultRegistry.shared.store(for: manifest)
            activeVault = store
            modelIndex = VaultModelIndex(store: store)
            partsIndex = VaultPartsIndex(store: store)
            library = ProcedureLibrary(store: store)
        }
        // The machine is part of the session record, so a crash-restored session still knows what
        // it is standing in front of.
        activeEquipment = activeVault == nil ? nil : inProgress.equipment
        let restoredLogger = SessionLogger(session: inProgress, root: sessionsRoot.appendingPathComponent(inProgress.id, isDirectory: true))
        logger = restoredLogger
        let events = restoredLogger.readEvents()
        reconstructRunner(from: events, logger: restoredLogger)
        // On crash recovery the job is paused so the technician resumes it deliberately — but at
        // the app's last sign of life, with the time worked up to it counted (Plan GB P3). Pausing
        // "now" with nothing to count from is how job 1011 lost twenty minutes.
        lastResumeAt = nil
        recoverBillableTime(lastEvidenceOfLife: events.map(\.timestamp).max(), now: Date())
        scheduleAccessCheck()
    }

    /// Credit the time worked before the app died, and pause the job at its last sign of life.
    func recoverBillableTime(lastEvidenceOfLife: Date?, now: Date) {
        guard var session = activeSession, let logger else { return }
        let recovery = BillableClock.recover(session: session, lastEvidenceOfLife: lastEvidenceOfLife,
                                             now: now)
        guard recovery.wasRunning else { return }
        session.billableSeconds += recovery.creditedSeconds
        session.pausedAt = recovery.pausedAt
        session.outcome = .paused
        session.appClosedPause = FieldSession.AppClosedPause(pausedAt: recovery.pausedAt,
                                                             uncountedSeconds: recovery.uncountedSeconds)
        activeSession = session
        history = history.replacingFirst(matching: session.id, with: session)
        logger.updateSession { $0 = session }
        logger.appendLifecycle(.sessionPaused,
                               note: "app_closed credited_seconds=\(Int(recovery.creditedSeconds)) "
                                   + "uncounted_seconds=\(Int(recovery.uncountedSeconds))")
    }

    /// Fold the running clock into the saved total (Plan GB P3). Called when the app leaves the
    /// foreground; harmless when no job is running.
    func checkpointBillableTime(now: Date = Date()) {
        guard var session = activeSession, session.pausedAt == nil, let lastResumeAt else { return }
        session.billableSeconds += max(0, now.timeIntervalSince(lastResumeAt))
        session.billableCheckpointAt = now
        self.lastResumeAt = now
        activeSession = session
        history = history.replacingFirst(matching: session.id, with: session)
        logger?.updateSession { $0 = session }
    }

    /// Billable time on the open job right now, counting the running clock.
    var liveBillableSeconds: TimeInterval? { activeSessionSnapshot()?.billableSeconds }

    /// Rebuild the active `ProcedureRunner` from the audit log, if a procedure was in progress
    /// when the app was interrupted. Replays procedure events, using the visited-stack snapshot
    /// carried in the last `procedureStep` event to restore position.
    private func reconstructRunner(from events: [SessionLogger.Event], logger: SessionLogger) {
        guard let session = activeSession,
              (session.procedureEquipmentScope ?? "initial") == session.continuityScope else { return }
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
    /// The organisation asks for the customer's sign-off, and this job has neither a signature nor
    /// a recorded decline (Plan FO P2c).
    case customerSignOffRequired(String)
    /// A check a fix waits on has not been confirmed (Plan GB P3).
    case verificationOwed(String)
    /// The close is held on a question the technician has to answer first (Plan GB P3).
    case jobCloseHeld(String)

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
        case .customerSignOffRequired(let reason): return reason
        case .verificationOwed(let reason): return reason
        case .jobCloseHeld(let question): return question
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
