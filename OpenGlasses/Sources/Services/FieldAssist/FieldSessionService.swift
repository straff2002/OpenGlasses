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
        startLocation: CLLocation? = nil
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
        let session = FieldSession(
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

        activeSession = session
        activeVault = store
        library = ProcedureLibrary(store: store)
        let newLogger = SessionLogger(session: session, root: sessionsRoot.appendingPathComponent(session.id, isDirectory: true))
        logger = newLogger
        newLogger.appendLifecycle(.sessionStarted, note: "vault=\(vaultId), mode=\(mode.rawValue), asset=\(assetId ?? "-")")
        EscalationCoordinator.shared.reset()
        lastResumeAt = Date()
        history.insert(session, at: 0)
        return session
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
        activeSession = nil
        activeVault = nil
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

    // MARK: - Prompt context

    /// System-prompt addendum for the active session, or nil when no session is active.
    /// Hooked into `LLMService.buildSystemPrompt`.
    func promptContext() -> String? {
        guard let store = activeVault else { return nil }
        var context = VaultPromptBuilder.promptContext(for: store)
        if let runner {
            let procedureContext = runner.promptContext()
            if !procedureContext.isEmpty {
                context = (context.map { $0 + "\n\n" } ?? "") + procedureContext
            }
        }
        return context
    }

    /// Whether a session is currently active and accepting input.
    var isSessionActive: Bool { activeSession?.isActive == true }

    // MARK: - Audit-log convenience

    func logUserMessage(_ text: String) {
        logger?.appendUserMessage(text)
    }

    func logAssistantMessage(_ text: String, citations: [String]? = nil) {
        logger?.appendAssistantMessage(text, citations: citations)
    }

    /// Offline store-and-forward queue (Plan T). Set by AppState. Photo captures are written to
    /// disk durably by the logger; we additionally enqueue an upload op so the evidence syncs to a
    /// backend when one exists — best-effort, never blocking the capture.
    var offlineQueue: OfflineQueue?

    func attachPhoto(_ data: Data, caption: String? = nil) -> URL? {
        let url = logger?.attachPhoto(data, caption: caption)
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
        if case .completed = transition { clearRunner() }
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
        clearRunner()
    }

    private func clearRunner() {
        runner = nil
        activeProcedureId = nil
    }

    // MARK: - Export

    /// Export a session's compliance artifacts (consolidated JSON audit and/or PDF work order).
    /// Defaults to the active session, falling back to the most recent. Returns the written file URLs.
    func exportSession(id: String? = nil, formats: Set<SessionExporter.Format> = [.json, .pdf]) throws -> [URL] {
        guard let sessionId = id ?? activeSession?.id ?? history.first?.id else {
            throw FieldSessionError.noActiveSession
        }
        let dir = sessionsRoot.appendingPathComponent(sessionId, isDirectory: true)
        return try SessionExporter.export(sessionDir: dir, formats: formats)
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

    var errorDescription: String? {
        switch self {
        case .alreadyActive: return "A Field Assist session is already active. End it before starting another."
        case .noActiveSession: return "No active Field Assist session."
        case .unknownVault(let id): return "Unknown vault: \(id)"
        case .vaultLocked(let id): return "The '\(id)' vault is locked. Unlock the corresponding pack to use it."
        case .procedureAlreadyRunning: return "A procedure is already running. Complete it before starting another."
        case .noProcedureRunning: return "No procedure is currently running. Start one first."
        case .unknownProcedure(let id): return "Unknown procedure: \(id)"
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
