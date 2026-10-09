import CryptoKit
import XCTest
@testable import OpenGlasses

/// Plan FP P2 — retrieval: the evidence gate (a learning is never sufficient alone), the citation
/// name, scoping by model identity, the shared factory every retriever site uses, the namespace's
/// independence from a vault's own lifecycle, and the personal surfaces it must not appear on.
///
/// Headless: a custom vault installed from a temporary folder, a temporary `DocumentStore`, a
/// fresh `FieldSessionService` and a fresh entry store.
@MainActor
final class TeamLearningRetrievalTests: XCTestCase {

    private typealias F = TeamLearningFixtures

    private var root: URL!
    private var store: DocumentStore!
    private var entries: LearningEntryStore!
    private var sessions: FieldSessionService!
    private var vaultDir: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!
    private var previousEnabled: Any?
    private var previousHipaa = false

    private let packVaultId = "fp_pack_vault"
    private let packId = "com.openglasses.vault.fp_pack_vault"

    override func setUp() async throws {
        try await super.setUp()
        root = F.tempDirectory("TeamLearningRetrieval")
        previousEnabled = UserDefaults.standard.object(forKey: "fieldAssistEnabled")
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousHipaa = Config.hipaaMode
        Config.hipaaMode = false
        previousEntitlement = EntitlementTestScope.grant(tier: .team)
        VaultRegistry.shared.resetCache()

        store = F.documentStore(in: root)
        entries = LearningEntryStore(directory: root.appendingPathComponent("entries", isDirectory: true))
        vaultDir = F.writeVault(in: root)
        let manifest = try VaultImporter.install(from: vaultDir)
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        _ = try await VaultImporter.syncDocuments(manifest: manifest, into: store)

        sessions = FieldSessionService(sessionsRoot: root.appendingPathComponent("sessions", isDirectory: true))
        sessions.documentStore = store
        sessions.learningEntries = entries
        _ = try sessions.startSession(vaultId: F.vaultId, assetId: nil)
    }

    override func tearDown() async throws {
        sessions = nil
        entries = nil
        store = nil
        VaultImporter.uninstall(id: F.vaultId)
        VaultImporter.uninstall(id: packVaultId)
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        try? FileManager.default.removeItem(at: root)
        if let previousEnabled { UserDefaults.standard.set(previousEnabled, forKey: "fieldAssistEnabled") }
        else { UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled") }
        Config.hipaaMode = previousHipaa
        EntitlementTestScope.restore(previousEntitlement)
        try await super.tearDown()
    }

    // MARK: - Helpers

    private var targets: [LearningCorpus.VaultTarget] {
        [LearningCorpus.VaultTarget(id: F.vaultId, modelIndex: F.modelIndex())]
    }

    @discardableResult
    private func publish(_ entry: LearningEntry) -> LearningEntry {
        entries.upsert(entry)
        LearningCorpus.publish(entry, vaults: targets, store: store)
        return entry
    }

    private func identify(_ token: String) throws {
        let model = try XCTUnwrap(sessions.modelIndex.models.first { $0.tokens.contains(token) })
        sessions.setEquipment(EquipmentIdentity(model: model, token: token, source: .spoken))
    }

    private var retriever: VaultRetriever {
        sessions.makeRetriever(store: sessions.activeVault!, documentStore: store)
    }

    private func passage(_ id: String, source: RetrievalSource, sim: Float = 0.9, text: String = "x") -> VaultRetriever.Passage {
        VaultRetriever.Passage(documentId: id, documentName: id, chunkIndex: 0, text: text, page: nil, section: nil,
                               similarity: sim, score: sim, matchedTokens: [], source: source)
    }

    // MARK: - The evidence gate

    func testTheGateNeverCallsALearningSufficientAlone() {
        let policy = RetrievalEvidencePolicy(similarityFloor: 0.3)
        let learning = passage("l", source: .teamLearning)
        let manual = passage("m", source: .manual, sim: 0.5)
        let weakManual = passage("w", source: .manual, sim: 0.1)

        XCTAssertEqual(policy.decide([learning], limit: 4), .teamLearningOnly([learning]))
        XCTAssertEqual(policy.decide([learning, weakManual], limit: 4), .teamLearningOnly([learning]),
                       "a manual passage below the floor does not make a learning sufficient")
        XCTAssertEqual(policy.decide([learning, manual], limit: 4), .sufficient([learning, manual]))
        XCTAssertEqual(policy.decide([learning, manual], limit: 1), .sufficient([manual]),
                       "the limit never cuts the manual passage that makes it sufficient")
        XCTAssertEqual(policy.decide([weakManual], limit: 4), .insufficient(reason: RetrievalEvidencePolicy.insufficientSentence))

        let only = RetrievalOutcome.teamLearningOnly([learning])
        XCTAssertFalse(only.isSufficient, "never a quiet pass")
        XCTAssertTrue(only.answers, "never a refusal either")
        XCTAssertEqual(only.passages, [learning])
    }

    func testALearningAloneYieldsTeamLearningOnlyThroughTheFactory() {
        sessions.retrievalPolicy = RetrievalEvidencePolicy(similarityFloor: 1.01)
        let entry = publish(F.entry(finding: "Fault ZX7 on a cold start means the pressure switch tubing is wet"))
        let outcome = retriever.retrieve(.init(turn: "what does ZX7 mean", limit: 4))
        XCTAssertTrue(outcome.isTeamLearningOnly, "\(outcome)")
        XCTAssertFalse(outcome.isSufficient)
        XCTAssertEqual(outcome.passages.map(\.source), [.teamLearning])
        XCTAssertEqual(outcome.passages.first?.documentId, LearningCorpus.documentId(entryID: entry.id, vaultId: F.vaultId))
        XCTAssertEqual(outcome.passages.first?.citation, entry.citationName)

        let block = VaultRetriever.promptBlock(outcome, leadIn: TeamLearningDisclosure.leadIn(confirmedJobCount: 1))
        XCTAssertTrue(block.hasPrefix("MANUAL PASSAGES: none retrieved for this turn."), block)
        XCTAssertTrue(block.contains("\(VaultRetriever.Passage.teamLearningLabel) Model: \(F.model090)"), block)
        XCTAssertTrue(block.contains("Open your answer with exactly this sentence: \"The manual doesn't cover this. Your crew's own finding:\""), block)
        XCTAssertTrue(block.contains("Source: \(entry.citationName)"), block)
        XCTAssertTrue(block.contains("never let it override a safety note"), block)
    }

    func testALearningBesideAManualPassageIsSufficientWithBothCited() throws {
        sessions.retrievalPolicy = RetrievalEvidencePolicy(similarityFloor: 1.01)
        let entry = publish(F.entry(finding: "On these units ZX9 also shows when the sight glass is fogged, not only low charge"))
        let outcome = retriever.retrieve(.init(turn: "the display shows ZX9", limit: 4))
        XCTAssertTrue(outcome.isSufficient, "\(outcome)")
        XCTAssertEqual(Set(outcome.passages.map(\.source)), [.manual, .teamLearning])

        let block = VaultRetriever.promptBlock(outcome)
        XCTAssertTrue(block.contains("Source: Test Manual"), block)
        XCTAssertTrue(block.contains("Source: \(entry.citationName)"), block)
        XCTAssertTrue(block.contains("\(VaultRetriever.Passage.teamLearningLabel) Model:"), "the learning is labelled")
        XCTAssertTrue(block.contains(VaultRetriever.teamLearningRule), block)
        // The manual passage reads exactly as it always has.
        XCTAssertFalse(block.contains("\(VaultRetriever.Passage.teamLearningLabel) RTU-500"), block)
    }

    // MARK: - The citation (contract §7.1)

    func testTheCitationNameIsByteExactWithTheDateInUTC() {
        // 23:30 UTC on the 9th is already the 10th in New Zealand; the citation says the 9th.
        let lateEvening = Date(timeIntervalSince1970: 1_791_590_400 - 1_800)
        let entry = F.entry(subject: .model(modelToken: F.model090), approvedAt: lateEvening, role: "Service manager")
        let expected = "Team learning \u{00B7} SLP99UH090XV60CK \u{00B7} 2026-10-09 \u{00B7} approved by Service manager"
        XCTAssertEqual(Array(entry.citationName.utf8), Array(expected.utf8))
        XCTAssertEqual(TeamLearningCitation.utcDate(Date(timeIntervalSince1970: 0)), "1970-01-01")
        XCTAssertEqual(F.entry(subject: .practice(topic: "Condensate traps"), approvedAt: lateEvening, role: "Lead tech").citationName,
                       "Team learning · Condensate traps · 2026-10-09 · approved by Lead tech")

        // The corpus document carries it as its name, so the machine-attached citation is exactly it.
        publish(entry)
        let ref = store.list(namespace: DocumentStore.learningNamespace(F.vaultId)).first
        XCTAssertEqual(ref?.name, expected)
        XCTAssertEqual(ref?.id, LearningCorpus.documentId(entryID: entry.id, vaultId: F.vaultId))
        XCTAssertEqual(ref?.chunkCount, 1, "one chunk per entry")

        // The chip parser reads it as a team learning, whole, even with a comma in the role.
        let citations = CitationLineParser.parse("Answer.\nSource: Team learning · X1 · 2026-10-09 · approved by Lead, North")
        XCTAssertEqual(citations.map(\.kind), [.teamLearning])
        XCTAssertEqual(citations.first?.title, "Team learning · X1 · 2026-10-09 · approved by Lead, North")
        XCTAssertTrue(citations.first?.isTeamLearning ?? false)
    }

    // MARK: - Scoping by identity (contract §7.2)

    func testLearningsAreScopedByModelIdentityNotByProse() throws {
        sessions.retrievalPolicy = RetrievalEvidencePolicy(similarityFloor: 0)
        try identify(F.model090)
        // A practice entry that names another model in its text: prose is not scanned.
        let practice = publish(F.entry(subject: .practice(topic: "Pressure switch tubing"),
                                       finding: "Unlike the \(F.model070), the pressure switch tubing sweats on cold starts"))
        // An entry for the other model, by identity.
        let other = publish(F.entry(subject: .model(modelToken: F.model070),
                                    finding: "The pressure switch tubing kinks behind the inducer"))
        // An entry for this model whose text mentions the other one.
        let same = publish(F.entry(subject: .model(modelToken: " slp99uh090xv60ck "),
                                   finding: "The pressure switch tubing sweats; the \(F.model070) does not"))

        let outcome = retriever.retrieve(.init(turn: "pressure switch tubing sweats", limit: 20))
        func penalty(_ entry: LearningEntry) -> Float? {
            outcome.passages.first { $0.documentId == LearningCorpus.documentId(entryID: entry.id, vaultId: F.vaultId) }?.modelPenalty
        }
        XCTAssertEqual(penalty(practice), 0, "a practice entry is never model-penalised")
        XCTAssertEqual(penalty(other), 0.5, "an entry for another model is penalised by identity")
        XCTAssertEqual(penalty(same), 0, "trimmed and case-folded, the token is this machine's")

        let scope = try XCTUnwrap(sessions.retrievalModelScope)
        XCTAssertEqual(scope.penalty(forSubjectToken: nil), 0)
        XCTAssertEqual(scope.penalty(forSubjectToken: "090XV60C"), 0, "any spelling of the active model")
        XCTAssertEqual(scope.penalty(forSubjectToken: "XR15CUTOFF"), 0.5, "a model this vault does not even name")
    }

    // MARK: - Every retriever site, through the factory

    func testEveryRetrieverSiteSeesLearnings() async throws {
        sessions.retrievalPolicy = RetrievalEvidencePolicy(similarityFloor: 1.01)
        let entry = publish(F.entry(finding: "Fault ZX7 on a cold start means the pressure switch tubing is wet"))

        // 1. The per-turn block.
        let context = try XCTUnwrap(sessions.promptContext(turn: "what does ZX7 mean"))
        XCTAssertTrue(context.contains("Source: \(entry.citationName)"), context)
        XCTAssertTrue(context.contains(VaultPromptBuilder.teamLearningRule), "the standing rule rides with a published corpus")

        // 2. manual_lookup.
        let lookup = ManualLookupTool(documentStore: store, sessionService: sessions)
        let looked = try await lookup.execute(args: ["query": "ZX7"])
        XCTAssertTrue(looked.contains(VaultRetriever.Passage.teamLearningLabel), looked)
        XCTAssertTrue(looked.contains("Source: \(entry.citationName)"), looked)
        // A search narrowed to one manual by title reads the manuals alone.
        let narrowed = try await lookup.execute(args: ["query": "ZX7", "document": "Test Manual"])
        XCTAssertEqual(narrowed, RetrievalEvidencePolicy.insufficientSentence)

        // 3. equipment_lookup's manual fall-through.
        let equipment = EquipmentLookupTool(documentStore: store, sessionService: sessions)
        let fellThrough = try await equipment.execute(args: ["query": "ZX7"])
        XCTAssertTrue(fellThrough.contains("Source: \(entry.citationName)"), fellThrough)
    }

    func testWithoutPublishedLearningsEverySiteIsUnchanged() async throws {
        sessions.retrievalPolicy = RetrievalEvidencePolicy(similarityFloor: 1.01)
        let context = try XCTUnwrap(sessions.promptContext(turn: "what does ZX7 mean"))
        XCTAssertFalse(context.contains(VaultPromptBuilder.teamLearningRule))
        XCTAssertTrue(context.contains(RetrievalEvidencePolicy.insufficientSentence))
        let looked = try await ManualLookupTool(documentStore: store, sessionService: sessions).execute(args: ["query": "ZX7"])
        XCTAssertEqual(looked, RetrievalEvidencePolicy.insufficientSentence)
    }

    func testHIPAAModeDoesNotQueryTheCorpus() {
        sessions.retrievalPolicy = RetrievalEvidencePolicy(similarityFloor: 1.01)
        publish(F.entry(finding: "Fault ZX7 on a cold start means the pressure switch tubing is wet"))
        Config.hipaaMode = true
        XCTAssertEqual(sessions.retrievalNamespaces(vaultId: F.vaultId).map(\.source), [.manual])
        let outcome = retriever.retrieve(.init(turn: "what does ZX7 mean", limit: 4))
        XCTAssertEqual(outcome, .insufficient(reason: RetrievalEvidencePolicy.insufficientSentence))
        XCTAssertFalse(sessions.promptContext(turn: "ZX7")?.contains(VaultPromptBuilder.teamLearningRule) ?? true)
    }

    func testPublishedLearningsStayReadableOnALapsedLicence() {
        sessions.retrievalPolicy = RetrievalEvidencePolicy(similarityFloor: 1.01)
        publish(F.entry(finding: "Fault ZX7 on a cold start means the pressure switch tubing is wet"))
        FieldAssistEntitlement.shared.provider = DeniedEntitlementProvider()
        XCTAssertTrue(retriever.retrieve(.init(turn: "ZX7", limit: 4)).isTeamLearningOnly,
                      "retrieval asks no licence (FP §5)")
    }

    // MARK: - Personal surfaces

    func testTheCorpusIsAbsentFromThePersonalListings() async throws {
        _ = await store.ingest(name: "Grocery list", text: "Milk, bread and eggs for the week.", namespace: "global")
        let entry = publish(F.entry())
        let learningId = LearningCorpus.documentId(entryID: entry.id, vaultId: F.vaultId)
        XCTAssertTrue(store.list().contains { $0.id == learningId }, "the store itself holds it")

        // DocumentsView lists `personalDocuments()`: neither manuals nor learnings.
        XCTAssertEqual(store.personalDocuments().map(\.name), ["Grocery list"])
        // ReadingStatsView and StudyService read `listExcludingTeamLearnings()`.
        XCTAssertFalse(store.listExcludingTeamLearnings().contains { $0.id == learningId })
        XCTAssertTrue(store.listExcludingTeamLearnings().contains { $0.name == "Test Manual" })

        let study = StudyService()
        study.documentStore = store
        study.generate = { _, _, _ in nil }
        do {
            _ = try await study.makeDeck(fromDocument: "Team learning")
            XCTFail("a learning is never a study source")
        } catch StudyServiceError.noDocument {
        } catch {
            XCTFail("expected noDocument, got \(error)")
        }
        do {
            _ = try await study.makeDeck(fromDocument: learningId)
            XCTFail("not by id either")
        } catch StudyServiceError.noDocument {
        } catch {
            XCTFail("expected noDocument, got \(error)")
        }
    }

    // MARK: - The namespace outlives the vault's own lifecycle

    func testAVaultReimportLeavesTheNamespaceAlone() async throws {
        let entry = publish(F.entry())
        let documentId = LearningCorpus.documentId(entryID: entry.id, vaultId: F.vaultId)
        let before = store.fullText(documentId: documentId)

        try (F.manualText + "\n\n3 ADDENDUM\nFault code ZX1 indicates a sensor fault.")
            .write(to: vaultDir.appendingPathComponent("documents/manual.txt"), atomically: true, encoding: .utf8)
        let manifest = try VaultImporter.install(from: vaultDir)
        _ = try await VaultImporter.syncDocuments(manifest: manifest, into: store)

        XCTAssertEqual(store.documentCount(namespace: DocumentStore.vaultNamespace(F.vaultId)), 1, "the manual was replaced")
        XCTAssertEqual(store.documentCount(namespace: DocumentStore.learningNamespace(F.vaultId)), 1)
        XCTAssertEqual(store.fullText(documentId: documentId), before)
    }

    func testAPackUpdateLeavesTheNamespaceAlone() async throws {
        FieldAssistEntitlement.shared.provider = AlwaysGrantedEntitlementProvider(tier: .enterprise)
        let key = Curve25519.Signing.PrivateKey()
        func pack(_ version: String, codes: String) throws -> (zip: Data, entry: VaultPackCatalogEntry, service: VaultPackCatalogService) {
            let packManifest = VaultPackManifest(id: packId, vaultId: packVaultId, version: version, name: "FP Pack",
                                                 summary: "s", author: "Test", minAppBuild: nil, licensePack: packVaultId)
            let manifest = VaultManifest(id: packVaultId, name: "FP Pack", version: version,
                                         files: ["safety.md", "error_codes.md"], documents: [],
                                         gating: .init(iap: packId), promptRules: ["Never fabricate.", "Cite the source."])
            let files: [String: Data] = [
                "manifest.json": try JSONEncoder().encode(manifest),
                "safety.md": Data("# Safety\n\nLock out power.".utf8),
                "error_codes.md": Data("# Fault Codes\n\n\(codes)".utf8),
            ]
            let packData = try JSONEncoder().encode(packManifest)
            let signature = try VaultPackSignature.sign(packManifestData: packData, files: files,
                                                        privateKeyBase64: key.rawRepresentation.base64EncodedString())
            var zipEntries = files
            zipEntries[VaultPackManifest.filename] = packData
            let zip = VaultPackTests.makeZip(zipEntries)
            let entry = VaultPackCatalogEntry(id: packId, vaultId: packVaultId, version: version, name: "FP Pack",
                                              summary: "s", author: "Test", minAppBuild: nil,
                                              downloadURL: "https://example.test/fp.zip",
                                              sha256: VaultPackArchive.sha256Hex(zip), packSignature: signature)
            let envelope = try VaultPackCatalog.makeEnvelope(index: .init(version: 1, packs: [entry]),
                                                             privateKeyBase64: key.rawRepresentation.base64EncodedString())
            let service = VaultPackCatalogService(
                catalogURL: { URL(string: "https://example.test/catalog.json") },
                fetch: { url in url.lastPathComponent == "catalog.json" ? envelope : zip },
                publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString(), currentBuild: 400)
            return (zip, entry, service)
        }

        let v1 = try pack("1.0.0", codes: "| ZX9 | Low charge |")
        await v1.service.loadCatalog()
        await v1.service.install(v1.service.entries[0])
        VaultRegistry.shared.reloadUserManifests()
        XCTAssertTrue(VaultImporter.installedManifests().contains { $0.id == packVaultId },
                      "the pack installed: \(v1.service.catalogState) \(v1.service.installStates)")

        let entry = F.entry(subject: .practice(topic: "Rooftop units"), vaultIDs: [packVaultId],
                            finding: "Rooftop units on the coast corrode at the economiser hinge")
        entries.upsert(entry)
        LearningCorpus.publish(entry, vaults: [.init(id: packVaultId, modelIndex: F.modelIndex([]))], store: store)
        let documentId = LearningCorpus.documentId(entryID: entry.id, vaultId: packVaultId)
        let before = store.fullText(documentId: documentId)
        XCTAssertNotNil(before)

        let v2 = try pack("1.1.0", codes: "| ZX9 | Low charge |\n| ZX3 | Fan failure |")
        await v2.service.loadCatalog()
        await v2.service.install(v2.service.entries[0])
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        XCTAssertTrue(VaultRegistry.shared.store(forId: packVaultId)?.read("error_codes.md")?.contains("ZX3") ?? false,
                      "the pack updated")
        XCTAssertEqual(store.documentCount(namespace: DocumentStore.learningNamespace(packVaultId)), 1)
        XCTAssertEqual(store.fullText(documentId: documentId), before)
        guard case .protectedPack = VaultManualRemoval.eligibility(of: packVaultId) else {
            return XCTFail("the pack's own content is protected; the learning namespace is not part of it")
        }
    }

    func testManualRemovalNeverListsOrTouchesALearning() async throws {
        let entry = publish(F.entry())
        let learningId = LearningCorpus.documentId(entryID: entry.id, vaultId: F.vaultId)
        let removalSees = VaultManualRemoval.availabilityCheck(forVault: F.vaultId, documentStore: store)
        XCTAssertFalse(removalSees(learningId), "the removal's view of the vault is its manuals alone")
        XCTAssertFalse(VaultManualRemoval.pendingDocumentIds(for: F.vaultId).contains(learningId))

        _ = try await VaultManualRemoval.remove(file: "manual.txt", fromVault: F.vaultId, documentStore: store)
        XCTAssertEqual(store.documentCount(namespace: DocumentStore.vaultNamespace(F.vaultId)), 0)
        XCTAssertEqual(store.documentCount(namespace: DocumentStore.learningNamespace(F.vaultId)), 1,
                       "removing every manual leaves the vault's learnings in place")

        // …and the factory still answers from the learning, which the removal check never gates.
        sessions.retrievalPolicy = RetrievalEvidencePolicy(similarityFloor: 0)
        XCTAssertTrue(retriever.retrieve(.init(turn: "pressure switch tubing", limit: 4)).isTeamLearningOnly)
    }
}
