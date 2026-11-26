import CryptoKit
import XCTest
@testable import OpenGlasses

/// The app's copy of the shared core's set (compiled into the app for Plan NF P1); the unqualified
/// name in this bundle is the licence core's own, compiled into the test bundle beside it.
private typealias AppSet = OpenGlasses.CrewExperienceSet

/// Plan NF P1 — the seal, the catalog pointer and the store, against the golden fixtures the licence
/// core's `CrewExperienceTests` read too. Invented brands, models, codes and people only.
@MainActor
final class CompanyExperienceContractTests: XCTestCase {

    static let profileId = "fixture-company"
    static let vaultId = "fixture-crew-units"
    /// The company-vault fixtures' company secret: SHA-256 of a public label, no authority anywhere.
    static let companySecret = Data(SHA256.hash(data: Data("Avenkin public fixture company secret v1".utf8)))

    static func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: CompanyExperienceContractTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: "crew-experience-v1", withExtension: nil))
        return try Data(contentsOf: url.appendingPathComponent(name))
    }

    static func digest(_ data: Data) -> String { VaultPackArchive.sha256Hex(data) }

    func testThePhoneOpensTheGoldenSealedSet() throws {
        let plain = try Self.fixture("set-v1.json")
        let sealed = try Self.fixture("set-v1.sealed")
        XCTAssertEqual(sealed.count, CompanyExperienceSeal.sealedLength(plaintextBytes: plain.count))
        let context = CompanyExperienceSeal.Context(profileId: Self.profileId, vaultId: Self.vaultId, sequence: 1,
                                                    revision: Self.digest(plain))
        XCTAssertEqual(try CompanyExperienceSeal.open(sealed, context: context, companySecret: Self.companySecret), plain)
        let set = try JSONDecoder().decode(AppSet.self, from: plain)
        XCTAssertNoThrow(try AppSet.check(set))
        XCTAssertEqual(set.entries.count, 4)
    }

    func testTheSealRefusesAnotherCompanyVaultSequenceOrKey() throws {
        let plain = try Self.fixture("set-v1.json")
        let sealed = try Self.fixture("set-v1.sealed")
        let revision = Self.digest(plain)
        for context in [CompanyExperienceSeal.Context(profileId: "fixture-other-company", vaultId: Self.vaultId, sequence: 1, revision: revision),
                        .init(profileId: Self.profileId, vaultId: "fixture-other-vault", sequence: 1, revision: revision),
                        .init(profileId: Self.profileId, vaultId: Self.vaultId, sequence: 2, revision: revision)] {
            XCTAssertThrowsError(try CompanyExperienceSeal.open(sealed, context: context, companySecret: Self.companySecret)) {
                XCTAssertEqual($0 as? CompanyManualSeal.Failure, .tampered)
            }
        }
        let right = CompanyExperienceSeal.Context(profileId: Self.profileId, vaultId: Self.vaultId, sequence: 1, revision: revision)
        XCTAssertThrowsError(try CompanyExperienceSeal.open(sealed, context: right, companySecret: Data(repeating: 7, count: 32)))
        let wrongRevision = CompanyExperienceSeal.Context(profileId: Self.profileId, vaultId: Self.vaultId, sequence: 1,
                                                          revision: String(repeating: "d", count: 64))
        XCTAssertThrowsError(try CompanyExperienceSeal.open(sealed, context: wrongRevision, companySecret: Self.companySecret))
    }

    func testTheAppAndTheServiceSealTheSameWay() throws {
        let plain = try Self.fixture("set-v1.json")
        let revision = Self.digest(plain)
        let core = CompanyVaultContract.ExperienceSeal.Context(profileId: Self.profileId, vaultId: Self.vaultId, sequence: 1, revision: revision)
        let app = CompanyExperienceSeal.Context(profileId: Self.profileId, vaultId: Self.vaultId, sequence: 1, revision: revision)
        let fromService = try CompanyVaultContract.ExperienceSeal.seal(plain, context: core, companySecret: Self.companySecret)
        XCTAssertEqual(try CompanyExperienceSeal.open(fromService, context: app, companySecret: Self.companySecret), plain)
        let fromApp = try CompanyExperienceSeal.seal(plain, context: app, companySecret: Self.companySecret)
        XCTAssertEqual(try CompanyVaultContract.ExperienceSeal.open(fromApp, context: core, companySecret: Self.companySecret), plain)
        XCTAssertEqual(CompanyExperienceSeal.sealingDomain, CompanyVaultContract.ExperienceSeal.domain)
        // A manual sealed with the same company secret never opens as a set.
        let manual = try CompanyManualSeal.seal(plain, context: .init(profileId: Self.profileId, vaultId: Self.vaultId,
                                                                      fileName: "1", revision: revision),
                                                companySecret: Self.companySecret)
        XCTAssertThrowsError(try CompanyExperienceSeal.open(manual, context: app, companySecret: Self.companySecret))
    }

    func testTheCatalogPointerDecodesAndAnUnusablePointerIsLeftOutWithTheVaultKept() throws {
        let payload = try Self.fixture("catalog-experience-v1.json")
        let catalog = try CompanyVaultCatalog.decoder.decode(CompanyVaultCatalog.Payload.self, from: payload)
        let pointer = try XCTUnwrap(catalog.vaults.first?.experience)
        XCTAssertEqual(pointer.sequence, 1)
        XCTAssertEqual(pointer.sealedSha256, Self.digest(try Self.fixture("set-v1.sealed")))
        XCTAssertEqual(CompanyVaultCatalog.screen(catalog).vault(Self.vaultId)?.experience, pointer)

        var vault = try XCTUnwrap(catalog.vaults.first)
        vault.experience = .init(sequence: 0, count: 4, sizeBytes: pointer.sizeBytes, revision: pointer.revision,
                                 sealedSha256: pointer.sealedSha256, downloadURL: pointer.downloadURL)
        let bad = CompanyVaultCatalog.Payload(format: catalog.format, version: catalog.version, profileId: catalog.profileId,
                                              generation: catalog.generation, issued: catalog.issued,
                                              manualsOnAnyNetwork: false, vaults: [vault], manuals: [])
        let screened = CompanyVaultCatalog.screen(bad)
        XCTAssertNotNil(screened.vault(Self.vaultId), "the vault itself is kept")
        XCTAssertNil(screened.vault(Self.vaultId)?.experience)
        XCTAssertEqual(screened.experienceProblems[Self.vaultId], "incomplete")
        XCTAssertNil(screened.problems[Self.vaultId], "never the vault's failure")

        vault.experience = .init(sequence: 1, count: 4, sizeBytes: pointer.sizeBytes, revision: pointer.revision,
                                 sealedSha256: pointer.sealedSha256, downloadURL: "http://licence.example.test/x")
        XCTAssertEqual(CompanyVaultCatalog.experienceProblem(try XCTUnwrap(vault.experience), in: vault), "incomplete")
        vault.extends = "fixture-base"
        vault.experience = pointer
        XCTAssertEqual(CompanyVaultCatalog.experienceProblem(pointer, in: vault), "onLayer")
    }

    // MARK: - The store

    func testASetBecomesRecollectionEntriesCitedAsCrewExperience() throws {
        let set = try JSONDecoder().decode(AppSet.self, from: try Self.fixture("set-v1.json"))
        let entries = CompanyExperienceStore.entries(of: set)
        XCTAssertEqual(entries.count, 4)
        XCTAssertTrue(entries.allSatisfy { $0.origin == .recollection && $0.isCrewExperience && $0.vaultIDs == [Self.vaultId] })
        let first = try XCTUnwrap(entries.first)
        XCTAssertEqual(first.subject.modelToken, "QXRT-990")
        XCTAssertEqual(first.faultCode, "E999")
        XCTAssertEqual(first.citationName, "Crew experience · QXRT-990 · 2026-11-25 · approved by Service manager")
        XCTAssertEqual(first.citationName, set.entries[0].citationName, "the phone cites exactly what the portal names")
        XCTAssertTrue(LearningCorpus.documentText(first).contains("How sure: fixed it most times"))
        XCTAssertNil(first.confirmedJobCount)
    }

    func testTheStoreKeepsItsSetsProtectedAndOutOfBackup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CompanyExperienceStore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CompanyExperienceStore(directory: dir)
        let set = try JSONDecoder().decode(AppSet.self, from: try Self.fixture("set-v1.json"))
        store.apply(.init(profileId: Self.profileId, vaultId: Self.vaultId, sequence: 1, revision: "r",
                          issuedAt: Date(timeIntervalSince1970: 1_795_564_800), appliedAt: Date(),
                          entries: CompanyExperienceStore.entries(of: set), retractedIDs: []))
        let again = CompanyExperienceStore(directory: dir)
        XCTAssertEqual(again.set(for: Self.vaultId)?.entries.count, 4)
        XCTAssertNotNil(again.entry(forDocumentId: LearningCorpus.documentId(entryID: "00000000000000000000000000000001", vaultId: Self.vaultId)))
        let values = try store.fileLocation.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        XCTAssertEqual(CompanyExperienceStore.fileProtection, .completeUntilFirstUserAuthentication)
        XCTAssertEqual(SensitiveStore.companyExperience.record.protection, .completeUntilFirstUserAuthentication)
        XCTAssertTrue(SensitiveStore.companyExperience.record.backupExcluded)

        store.remove(vaultId: Self.vaultId)
        XCTAssertNil(CompanyExperienceStore(directory: dir).set(for: Self.vaultId))
    }

    func testTheCustomVaultsLineCountsFixesAndDatesThePublish() {
        let day = Date(timeIntervalSince1970: 1_795_564_800 + 12 * 3600) // 25 Nov 2026, midday UTC
        let locale = Locale(identifier: "en_GB"), utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(CompanyExperienceStore.summaryLine(count: 42, updated: day, locale: locale, timeZone: utc),
                       "Crew experience · 42 fixes · updated 25 Nov")
        XCTAssertEqual(CompanyExperienceStore.summaryLine(count: 1, updated: day, locale: locale, timeZone: utc),
                       "Crew experience · 1 fix · updated 25 Nov")
        XCTAssertFalse(CompanyExperienceStore.summaryLine(count: 42, updated: day, locale: locale, timeZone: utc).contains("NF"),
                       "no plan letters in the interface")
    }

    // MARK: - Subject erasure

    func testSubjectErasureRemovesACrewEntryThatNamesThePerson() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CompanyExperienceErasure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CompanyExperienceStore(directory: dir)
        let named = LearningEntry(id: String(repeating: "a", count: 32), subject: .model(modelToken: "QXRT-990"),
                                  vaultIDs: [Self.vaultId], finding: "Called Avery Example at the depot before the reset",
                                  approvedAt: Date(), approvedByRole: "Service manager", approvedByName: "", origin: .recollection)
        let other = LearningEntry(id: String(repeating: "b", count: 32), subject: .model(modelToken: "QXRT-990"),
                                  vaultIDs: [Self.vaultId], finding: "Reseated the harness at the plug",
                                  approvedAt: Date(), approvedByRole: "Service manager", approvedByName: "", origin: .recollection)
        store.apply(.init(profileId: Self.profileId, vaultId: Self.vaultId, sequence: 3, revision: "r", issuedAt: Date(),
                          appliedAt: Date(), entries: [named, other], retractedIDs: []))
        XCTAssertTrue(SubjectErasureCoordinator.order.contains(.companyExperience))
        var stores = SubjectErasureCoordinator.Stores()
        stores.companyExperience = store
        let receipts = await SubjectErasureCoordinator(stores: stores).erase(.person("Avery Example"), recordInLedger: false)
        let receipt = try XCTUnwrap(receipts.first { $0.store == .companyExperience })
        XCTAssertTrue(receipt.localComplete)
        XCTAssertEqual(receipt.removed, 1)
        XCTAssertEqual(store.set(for: Self.vaultId)?.entries.map(\.id), [other.id])
        XCTAssertEqual(store.set(for: Self.vaultId)?.sequence, 3, "the same set is not applied again over the erasure")
    }

    // MARK: - No spreadsheet from a catalog

    /// The phone never reads a spreadsheet (Plan NF decision 1): the portal converts the sheet, and
    /// what arrives on the company-vault catalog is a sealed JSON set. No company-catalog code path
    /// names a `.xlsx` or `.csv`, no manual kind is one, and the catalog's file download accepts no
    /// spreadsheet or CSV media type.
    func testNoCompanyCatalogPathReadsASpreadsheet() throws {
        XCTAssertEqual(Set(CompanyVaultCatalog.ManualKind.allCases.flatMap(\.extensions)), ["pdf", "docx", "md", "markdown"])
        let accepted = Set(BoundedHTTPClient.Profile.companyVaultFile(maximumBytes: 1).acceptedMIMETypes)
            .union(BoundedHTTPClient.Profile.companyVaultCatalog.acceptedMIMETypes)
        for type in accepted {
            XCTAssertFalse(type.contains("csv") || type.contains("spreadsheet") || type.contains("excel") || type.contains("sheet"), type)
        }
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenGlasses/Sources", isDirectory: true)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        var scanned = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let isCatalogPath = file.path.contains("/OrgProfile/CompanyVault") || file.lastPathComponent == "CompanyExperienceStore.swift"
                || text.contains("CompanyVaultCatalog.Manual") || text.contains("CompanyVaultCatalog.Experience")
            guard isCatalogPath else { continue }
            scanned += 1
            let lower = text.lowercased()
            for word in [".xlsx", "\"xlsx\"", ".csv", "\"csv\"", "text/csv", "spreadsheetml"] {
                XCTAssertFalse(lower.contains(word), "\(file.lastPathComponent) names \(word) on a company-catalog path")
            }
        }
        XCTAssertGreaterThanOrEqual(scanned, 4, "the guard must actually read the catalog code")
    }
}

/// Plan NF P1 — the corpus: an experience-only vault places a model entry; the reconcile runs over
/// the union of the phone-reviewed entries and the sets, so neither removes the other; the citation,
/// the lead-in and the parser; HIPAA, a lapsed licence and the safety-note rule.
@MainActor
final class CompanyExperienceCorpusTests: XCTestCase {

    private typealias F = TeamLearningFixtures
    private let vaultId = "fixture-crew-units"

    private var root: URL!
    private var store: DocumentStore!
    private var reviewed: LearningEntryStore!
    private var experience: CompanyExperienceStore!
    private var previousEntitlement: FieldAssistEntitlementProvider!
    private var previousEnabled: Any?
    private var previousHipaa = false

    override func setUp() async throws {
        try await super.setUp()
        root = F.tempDirectory("CompanyExperienceCorpus")
        previousEnabled = UserDefaults.standard.object(forKey: "fieldAssistEnabled")
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousHipaa = Config.hipaaMode
        Config.hipaaMode = false
        previousEntitlement = EntitlementTestScope.grant(tier: .team)
        store = F.documentStore(in: root)
        reviewed = LearningEntryStore(directory: root.appendingPathComponent("entries", isDirectory: true))
        experience = CompanyExperienceStore(directory: root.appendingPathComponent("experience", isDirectory: true))
    }

    override func tearDown() async throws {
        VaultImporter.uninstall(id: vaultId)
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

    private func fixtureText(_ path: String) throws -> String {
        String(decoding: try CompanyExperienceContractTests.fixture(path), as: UTF8.self)
    }

    /// The experience-only vault's model index: its `crew-models.md` and nothing else.
    private func crewTarget() throws -> LearningCorpus.VaultTarget {
        .init(id: vaultId, modelIndex: VaultModelIndex(vaultName: "Fixture Crew Units",
                                                       files: [(filename: "crew-models.md",
                                                                contents: try fixtureText("experience-only-vault/crew-models.md"))]))
    }

    private func portalSet() throws -> [LearningEntry] {
        CompanyExperienceStore.entries(of: try JSONDecoder().decode(AppSet.self, from: try CompanyExperienceContractTests.fixture("set-v1.json")))
    }

    private func apply(_ entries: [LearningEntry], sequence: Int = 1) {
        experience.apply(.init(profileId: "fixture-company", vaultId: vaultId, sequence: sequence, revision: "r",
                               issuedAt: Date(timeIntervalSince1970: 1_795_564_800), appliedAt: Date(),
                               entries: entries, retractedIDs: []))
    }

    private func reconcile(_ targets: [LearningCorpus.VaultTarget]) {
        TeamLearningSources.reconcile(reviewed: reviewed, experience: experience, vaults: targets, store: store,
                                      hipaa: Config.hipaaMode)
    }

    private func documentIds() -> Set<String> {
        Set(store.list(namespace: DocumentStore.learningNamespace(vaultId)).map(\.id))
    }

    private func reviewedEntry(_ id: String = String(repeating: "e", count: 32)) -> LearningEntry {
        LearningEntry(id: id, subject: .model(modelToken: "QXRT-990"), vaultIDs: [vaultId],
                      finding: "The fan relay chatters below 200 volts on this unit",
                      approvedAt: Date(timeIntervalSince1970: 1_795_000_000), approvedByRole: "Supervisor",
                      approvedByName: "Fixture Reviewer")
    }

    // MARK: - Gotcha 1: an experience-only vault knows its models

    func testAnExperienceOnlyVaultPlacesAModelEntry() throws {
        let entry = try XCTUnwrap(try portalSet().first)
        let placement = LearningCorpus.placement(of: entry, among: [try crewTarget()])
        XCTAssertEqual(placement.published, [vaultId], "crew-models.md is the whole model index")
        XCTAssertEqual(placement.unknownModel, [])
        // Without it the vault knows no model, and the entry would be held back: the gotcha.
        let bare = LearningCorpus.VaultTarget(id: vaultId, modelIndex: VaultModelIndex(vaultName: "Bare", files: []))
        XCTAssertEqual(LearningCorpus.placement(of: entry, among: [bare]).unknownModel, [vaultId])
    }

    func testTheInstalledExperienceOnlyVaultReadsCrewModelsIntoItsIndex() throws {
        let folder = root.appendingPathComponent("experience-only-vault", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["manifest.json", "crew-models.md"] {
            try CompanyExperienceContractTests.fixture("experience-only-vault/\(name)").write(to: folder.appendingPathComponent(name))
        }
        _ = try VaultImporter.install(from: folder)
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        let target = try XCTUnwrap(LearningReviewService.installedVaults().first { $0.id == vaultId })
        XCTAssertTrue(target.knowsModel("QXRT-990"))
        XCTAssertTrue(target.knowsModel("ZPL2040"))
        apply(try portalSet())
        reconcile([target])
        XCTAssertEqual(documentIds().count, 4, "every model entry of the set answers from the experience-only vault")
    }

    // MARK: - Gotcha 2: the reconcile runs over the union

    func testApplyingAPortalSetLeavesPhoneReviewedEntriesInPlace() throws {
        let targets = [try crewTarget()]
        let own = reviewedEntry()
        reviewed.upsert(own)
        LearningCorpus.publish(own, vaults: targets, store: store)
        let ownDocument = LearningCorpus.documentId(entryID: own.id, vaultId: vaultId)

        apply(try portalSet())
        reconcile(targets)
        XCTAssertTrue(documentIds().contains(ownDocument), "a portal set never removes a phone-reviewed entry")
        XCTAssertEqual(documentIds().count, 5)

        // A newer set with one entry fewer: that entry's document goes, the phone's stays.
        apply(Array(try portalSet().dropLast()), sequence: 2)
        reconcile(targets)
        XCTAssertEqual(documentIds().count, 4)
        XCTAssertTrue(documentIds().contains(ownDocument))
    }

    func testAPhoneRepublishLeavesThePortalSetInPlace() throws {
        let targets = [try crewTarget()]
        apply(try portalSet())
        reconcile(targets)
        let portal = documentIds()
        XCTAssertEqual(portal.count, 4)

        let review = LearningReviewService(entries: reviewed, experience: experience, documentStore: store)
        review.vaults = { targets }
        review.hipaaMode = { false }
        let own = reviewedEntry()
        reviewed.upsert(own)
        review.republish()
        XCTAssertTrue(portal.isSubset(of: documentIds()), "reviewing on the phone never removes the company's set")
        XCTAssertTrue(documentIds().contains(LearningCorpus.documentId(entryID: own.id, vaultId: vaultId)))
        _ = review.retract(entryID: own.id, reason: "Superseded by the manual's revision")
        review.republish()
        XCTAssertEqual(documentIds(), portal)
    }

    // MARK: - Gates

    func testHIPAAModeWithholdsTheSet() throws {
        Config.hipaaMode = true
        apply(try portalSet())
        reconcile([try crewTarget()])
        XCTAssertTrue(documentIds().isEmpty, "nothing is published under HIPAA mode")
        let review = LearningReviewService(entries: reviewed, experience: experience, documentStore: store)
        review.vaults = { [try! self.crewTarget()] }
        review.hipaaMode = { true }
        review.republish()
        XCTAssertTrue(documentIds().isEmpty)
        let sessions = FieldSessionService(sessionsRoot: root.appendingPathComponent("sessions", isDirectory: true))
        XCTAssertEqual(sessions.retrievalNamespaces(vaultId: vaultId).map(\.source), [.manual],
                       "and a set published before HIPAA mode was turned on is not read")
        XCTAssertNotNil(experience.set(for: vaultId), "the set is kept for when HIPAA mode is off")
    }

    // MARK: - An answer from experience alone

    func testAnExperienceOnlyAnswerOpensWithTheLeadInAndCitesCrewExperience() throws {
        let folder = root.appendingPathComponent("experience-only-vault", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["manifest.json", "crew-models.md"] {
            try CompanyExperienceContractTests.fixture("experience-only-vault/\(name)").write(to: folder.appendingPathComponent(name))
        }
        _ = try VaultImporter.install(from: folder)
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        apply(try portalSet())
        reconcile(LearningReviewService.installedVaults().filter { $0.id == vaultId })

        let sessions = FieldSessionService(sessionsRoot: root.appendingPathComponent("sessions", isDirectory: true))
        sessions.documentStore = store
        sessions.companyExperience = experience
        sessions.retrievalPolicy = RetrievalEvidencePolicy(similarityFloor: 1.01)
        _ = try sessions.startSession(vaultId: vaultId, assetId: nil)
        let retriever = sessions.makeRetriever(store: try XCTUnwrap(sessions.activeVault), documentStore: store)
        let outcome = retriever.retrieve(.init(turn: "what does E999 mean", limit: 4))
        XCTAssertTrue(outcome.isTeamLearningOnly, "an experience-only vault has no manual to put first: \(outcome)")
        let citation = try XCTUnwrap(outcome.passages.first?.citation)
        XCTAssertTrue(citation.hasPrefix("Crew experience · "), citation)

        let disclosure = try XCTUnwrap(sessions.disclosure(for: outcome))
        XCTAssertEqual(disclosure.leadIn, "From your company's experience (not the manufacturer's manual):")
        XCTAssertTrue(disclosure.entries.allSatisfy(\.isCrewExperience))
        let block = VaultRetriever.promptBlock(outcome, leadIn: disclosure.leadIn)
        XCTAssertTrue(block.contains("Open your answer with exactly this sentence: \"From your company's experience (not the manufacturer's manual):\""), block)
        XCTAssertTrue(block.contains("never let it override a safety note"), block)
        XCTAssertEqual(TeamLearningDisclosure.prepend(disclosure.leadIn!, to: "Reseat the harness."),
                       "From your company's experience (not the manufacturer's manual): Reseat the harness.")

        // A lapsed licence: what was published still answers.
        FieldAssistEntitlement.shared.provider = DeniedEntitlementProvider()
        XCTAssertTrue(retriever.retrieve(.init(turn: "what does E999 mean", limit: 4)).isTeamLearningOnly)
    }

    func testTheLeadInComesFromTheCitationWhenTheEntryIsNotHeld() {
        let name = "Crew experience · QXRT-990 · 2026-11-25 · approved by Service manager"
        let passage = VaultRetriever.Passage(documentId: LearningCorpus.documentId(entryID: String(repeating: "c", count: 32), vaultId: vaultId),
                                             documentName: name, chunkIndex: 0, text: "Model: QXRT-990", page: nil, section: nil,
                                             similarity: 0.9, score: 0.9, matchedTokens: [], source: .teamLearning)
        let crew = TeamLearningDisclosure.from(.teamLearningOnly([passage])) { _ in nil }
        XCTAssertEqual(crew?.leadIn, TeamLearningDisclosure.crewExperienceLeadIn)
        XCTAssertEqual(crew?.entries.first?.approvedByRole, "Service manager")
        // A team learning keeps FP's own lead-in.
        let team = VaultRetriever.Passage(documentId: passage.documentId, documentName: "Team learning · QXRT-990 · 2026-11-25 · approved by Supervisor",
                                          chunkIndex: 0, text: "Model: QXRT-990", page: nil, section: nil,
                                          similarity: 0.9, score: 0.9, matchedTokens: [], source: .teamLearning)
        XCTAssertEqual(TeamLearningDisclosure.from(.teamLearningOnly([team])) { _ in nil }?.leadIn,
                       TeamLearningDisclosure.leadIn(confirmedJobCount: nil))
    }

    func testCrewExperienceNeverOutranksTheManualOrASafetyNote() {
        let policy = RetrievalEvidencePolicy(similarityFloor: 0.3)
        func passage(_ id: String, _ source: RetrievalSource, _ sim: Float, _ name: String) -> VaultRetriever.Passage {
            VaultRetriever.Passage(documentId: id, documentName: name, chunkIndex: 0, text: "x", page: nil, section: nil,
                                   similarity: sim, score: sim, matchedTokens: [], source: source)
        }
        let crew = passage("c", .teamLearning, 0.95, "Crew experience · QXRT-990 · 2026-11-25 · approved by Service manager")
        let manual = passage("m", .manual, 0.5, "Fixturetherm QXRT service manual")
        XCTAssertEqual(policy.decide([crew, manual], limit: 1), .sufficient([manual]),
                       "the manual passage is never cut for crew experience, however close it scores")
        let block = VaultRetriever.promptBlock(.sufficient([crew, manual]), leadIn: nil)
        XCTAssertTrue(block.contains(VaultRetriever.Passage.teamLearningLabel), block)
        XCTAssertTrue(block.contains("never let it override a safety note"), block)
    }

    // MARK: - The citation in an answer's own text

    func testTheParserReadsACrewExperienceCitationWhole() {
        XCTAssertTrue(TeamLearningCitation.isTeamLearning("Crew experience · QXRT-990 · 2026-11-25 · approved by Service manager"))
        XCTAssertTrue(TeamLearningCitation.isCrewExperience("Crew experience · QXRT-990 · 2026-11-25 · approved by Service manager"))
        XCTAssertFalse(TeamLearningCitation.isCrewExperience("Team learning · QXRT-990 · 2026-11-25 · approved by Supervisor"))
        let citations = CitationLineParser.citations(inBody: "Crew experience · QXRT-990 · 2026-11-25 · approved by Service manager, East")
        XCTAssertEqual(citations.count, 1)
        XCTAssertEqual(citations.first?.kind, .teamLearning)
        XCTAssertEqual(citations.first?.title, "Crew experience · QXRT-990 · 2026-11-25 · approved by Service manager, East")
        let mixed = CitationLineParser.citations(inBody: "Fixturetherm QXRT service manual, page 12; Crew experience · QXRT-990 · 2026-11-25 · approved by Service manager")
        XCTAssertEqual(mixed.map(\.kind), [.manual, .teamLearning])
    }
}
