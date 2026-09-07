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
        modelIndex = VaultModelIndex(store: store)
        activeEquipment = nil
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
        activeSession = nil
        activeVault = nil
        activeEquipment = nil
        modelIndex = VaultModelIndex(vaultName: "", files: [])
        stagedFigure = nil
        lastShownFigure = nil
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
    }

    /// Audit: the page behind a citation was actually put on screen, and against what.
    func logPageVerified(title: String, page: Int, source: ManualPageRoute) {
        logger?.append(SessionLogger.Event(
            timestamp: Date(), kind: .pageVerified, text: "\(title), page \(page)",
            payload: ["document": AnyCodable(title),
                      "page": AnyCodable(page),
                      "source": AnyCodable(source.rawValue)]))
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
        let urls = try SessionExporter.export(sessionDir: dir, formats: formats)
        // Plan T: store-and-forward the audit — enqueue an op so the export syncs to a backend
        // when one exists (no-op locally beyond a queued tombstone until a networked sink lands).
        offlineQueue?.enqueue(QueuedOp.make(
            kind: .auditExport, sessionId: sessionId,
            json: ["files": urls.map(\.path), "exportedAt": Date().timeIntervalSince1970]))
        return urls
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
