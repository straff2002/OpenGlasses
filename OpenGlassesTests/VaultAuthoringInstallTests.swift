import XCTest
@testable import OpenGlasses

private typealias AppTemplate = OpenGlasses.TradeTemplate
private typealias AppStarter = OpenGlasses.VaultStarter
private typealias FaultRow = OpenGlasses.FaultCodeRow
private typealias ModelRowT = OpenGlasses.ModelRow
private typealias SymptomRowT = OpenGlasses.SymptomRow
private typealias Page = OpenGlasses.DraftPage

/// Plan LW P1 — the authoring paths on a real install: New Vault through the importer, Add manual and
/// Add file as re-lays of the baseline, a kept row written to the overlay, the live page text over an
/// indexed manual, the export, and the My Manuals move (copy, check, then remove; a failure part-way
/// leaves the personal library as it was). Every vault, manual, code and model is invented.
@MainActor
final class VaultAuthoringInstallTests: XCTestCase {
    private var previousEntitlement: FieldAssistEntitlementProvider!
    private var temp: URL!
    private var made: Set<String> = []

    /// A three-page manual, its pages split as the extractor splits a text file.
    nonisolated static let pages = [
        "Installation manual\nRooftop unit QX-100\nThis manual covers the QX-100 and the QX-100A.",
        "Fault codes\nE9 Low suction pressure. Look for a restriction in the suction line, then confirm the charge.\nF17 Outdoor fan motor overload. Let the motor cool, then check the fan turns freely.",
        "Troubleshooting\nProblem: Unit runs but the room stays warm\nCause: Dirty outdoor coil\nCheck: Clean the outdoor coil and measure the airflow."
    ]

    override func setUp() {
        super.setUp()
        previousEntitlement = EntitlementTestScope.grant()
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("VaultAuthoringInstallTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for id in made { VaultImporter.uninstall(id: id) }
        for manifest in VaultImporter.installedManifests() where manifest.id.hasPrefix("lw_p1_") {
            VaultImporter.uninstall(id: manifest.id)
        }
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        EntitlementTestScope.restore(previousEntitlement)
        try? FileManager.default.removeItem(at: temp)
        super.tearDown()
    }

    private func newVault(_ name: String = "LW P1 Rooftop", models: [AppStarter.Model] = [.init("QX-100")]) throws -> VaultManifest {
        let manifest = try VaultAuthoring.createVault(name: name, template: .hvacR, models: models)
        made.insert(manifest.id)
        return manifest
    }

    private func manualFile(_ name: String = "fixture.txt", pages: [String] = VaultAuthoringInstallTests.pages) throws -> URL {
        let url = temp.appendingPathComponent(name)
        try pages.joined(separator: VaultDocumentExtractor.pageSeparator).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func addFixtureManual(to id: String, title: String = "Installation manual", edition: String? = "Rev A",
                                  photographed: Bool = false) throws -> VaultManifest {
        let url = try manualFile()
        return try VaultAuthoring.addManual(.init(original: url, readingPDF: url, converted: false, title: title,
                                                  edition: edition, photographed: photographed), to: id)
    }

    // MARK: - New Vault

    func testNewVaultInstallsTheStarterAsAVaultOfYourOwn() throws {
        let manifest = try newVault()
        XCTAssertEqual(manifest.id, "lw_p1_rooftop")
        XCTAssertEqual(VaultImporter.installedManifest(id: manifest.id)?.files, AppStarter.fileNames)
        XCTAssertTrue(VaultAuthoring.isOwned(manifest.id))
        XCTAssertTrue(VaultExporter.isExportable(manifest))
        XCTAssertTrue(VaultRegistry.shared.isUnlocked(manifest.id), "A vault of your own opens with the capability")
        XCTAssertEqual(VaultAuthoringRecord.load(vaultId: manifest.id)?.template, "hvac_r")
        XCTAssertEqual(VaultAuthoring.template(for: manifest).id, .hvacR)
        let store = try XCTUnwrap(VaultRegistry.shared.store(forId: manifest.id))
        XCTAssertTrue(store.read("models.md")?.contains("## QX-100") == true)
    }

    func testANameAlreadyInstalledGetsTheNextFreeId() throws {
        let first = try newVault()
        let second = try newVault()
        XCTAssertEqual(first.id, "lw_p1_rooftop")
        XCTAssertEqual(second.id, "lw_p1_rooftop_2")
        XCTAssertNotNil(VaultImporter.installedManifest(id: first.id), "The first vault was replaced")
    }

    func testABundledVaultsIdIsNeverTaken() throws {
        let bundled = try XCTUnwrap(VaultRegistry.shared.allManifests.first { VaultImporter.installedManifest(id: $0.id) == nil })
        XCTAssertNotNil(VaultAuthoring.freeId(forName: bundled.id.replacingOccurrences(of: "_", with: " "),
                                              taken: VaultAuthoring.takenIds))
    }

    func testMyManualsAndAPackAreNotVaultsOfYourOwn() {
        XCTAssertFalse(VaultAuthoring.isOwned("my-manuals"))
        XCTAssertFalse(VaultAuthoring.isOwned("lw_p1_never_installed"))
    }

    // MARK: - Add manual

    func testAnAddedManualRecordsItsRevisionOriginAndEdition() throws {
        let vault = try newVault()
        let manifest = try addFixtureManual(to: vault.id)
        let document = try XCTUnwrap(manifest.documents.first)
        XCTAssertEqual(document.file, "installation-manual.txt")
        XCTAssertEqual(document.title, "Installation manual")
        XCTAssertEqual(document.edition, "Rev A")
        XCTAssertEqual(document.origin, .technician)
        XCTAssertEqual(document.revision, VaultDocumentLedger.hash(of: try Data(contentsOf: try manualFile())))
        XCTAssertEqual(manifest.documentsDir, "documents")
        let baseline = VaultImporter.baselineDirectory(for: vault.id).appendingPathComponent("documents/installation-manual.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: baseline.path))
        XCTAssertEqual(manifest.files, AppStarter.fileNames, "The core files were dropped")
    }

    func testPhotographedPagesAreACaptureAndAnEmptyEditionIsNone() throws {
        let vault = try newVault()
        let document = try XCTUnwrap(try addFixtureManual(to: vault.id, title: "Wiring sheet", edition: "  ",
                                                          photographed: true).documents.first)
        XCTAssertEqual(document.origin, .capture)
        XCTAssertEqual(document.personalCapture, true)
        XCTAssertNil(document.edition)
    }

    func testAWordOrMarkdownUploadKeepsItsReadingCopyBesideIt() throws {
        let vault = try newVault()
        let markdown = temp.appendingPathComponent("Service notes.md")
        try "# Service notes\n\nE9 means low suction pressure on the QX-100.".write(to: markdown, atomically: true, encoding: .utf8)
        let prepared = try ManualFileUpload.prepare(markdown)
        defer { prepared.discard() }
        let manifest = try VaultAuthoring.addManual(.init(prepared, title: "Service notes", edition: nil, photographed: false), to: vault.id)
        let document = try XCTUnwrap(manifest.documents.first)
        XCTAssertEqual(document.file, "service-notes.md")
        XCTAssertEqual(document.source, "service-notes.reading.pdf")
        XCTAssertEqual(document.personalReadingCopy, true)
        XCTAssertEqual(document.revision, VaultDocumentLedger.hash(of: try Data(contentsOf: prepared.original)))
    }

    func testASecondManualOfTheSameTitleGetsItsOwnFile() throws {
        let vault = try newVault()
        _ = try addFixtureManual(to: vault.id)
        let manifest = try addFixtureManual(to: vault.id)
        XCTAssertEqual(manifest.documents.map(\.file), ["installation-manual.txt", "installation-manual-2.txt"])
    }

    func testAddingAManualKeepsTheAuthorsEdits() throws {
        let vault = try newVault()
        let store = try XCTUnwrap(VaultRegistry.shared.store(forId: vault.id))
        try store.write("safety.md", contents: "# Safety\n\nInvented site rule: two people at the panel.")
        _ = try addFixtureManual(to: vault.id)
        XCTAssertEqual(VaultRegistry.shared.store(forId: vault.id)?.read("safety.md"),
                       "# Safety\n\nInvented site rule: two people at the panel.")
    }

    func testAManualCannotBeAddedToAVaultThatIsNotYourOwn() throws {
        XCTAssertThrowsError(try addFixtureManual(to: "lw_p1_not_here")) { error in
            XCTAssertEqual(error as? VaultAuthoring.Failure, .notOwned)
        }
    }

    // MARK: - Add file

    func testAnAddedFileIsListedInTheManifestAndReadable() throws {
        let vault = try newVault()
        let file = try VaultAuthoring.addFile(named: "Wiring notes", to: vault.id)
        XCTAssertEqual(file, "wiring-notes.md")
        let manifest = try XCTUnwrap(VaultImporter.installedManifest(id: vault.id))
        XCTAssertEqual(manifest.files, AppStarter.fileNames + ["wiring-notes.md"])
        XCTAssertEqual(VaultRegistry.shared.store(forId: vault.id)?.read("wiring-notes.md"), "# Wiring notes\n")
        XCTAssertTrue(VaultValidator.validate(directory: VaultImporter.baselineDirectory(for: vault.id)).issues
            .allSatisfy { !$0.contains("wiring-notes") })
    }

    func testAFileThatExistsOrHasNoNameIsRefused() throws {
        let vault = try newVault()
        XCTAssertThrowsError(try VaultAuthoring.addFile(named: "Safety", to: vault.id)) { error in
            XCTAssertEqual(error as? VaultAuthoring.Failure, .fileExists("safety.md"))
        }
        XCTAssertThrowsError(try VaultAuthoring.addFile(named: "  ", to: vault.id)) { error in
            XCTAssertEqual(error as? VaultAuthoring.Failure, .emptyFileName)
        }
    }

    // MARK: - Keep

    func testAKeptFaultCodeIsWrittenUnderTheTableWithItsCitation() throws {
        let vault = try newVault()
        let labels = PageLabelMap([PageLabel(page: 43, label: "41", source: .printed)])
        let kept = try VaultAuthoring.keep(.faultCode(FaultRow(code: "E9", label: "Low suction pressure", page: Page(cited: "41"))),
                                           key: "installation-manual", page: 43, labels: labels, inManualsWords: false,
                                           vaultId: vault.id)
        XCTAssertEqual(kept.file, "fault-codes.md")
        XCTAssertEqual(kept.citation, "installation-manual p. 43 (printed 41)")
        XCTAssertEqual(kept.line, "| E9 | Low suction pressure | installation-manual p. 43 (printed 41) |")
        let text = try XCTUnwrap(VaultRegistry.shared.store(forId: vault.id)?.read("fault-codes.md"))
        XCTAssertTrue(text.contains(AppStarter.faultCodeTableHeader + "\n" + kept.line), text)
        XCTAssertEqual(VaultRegistry.shared.store(forId: vault.id)?.layer(of: "fault-codes.md"), .technician,
                       "A kept row is an edit, written to the overlay")
        XCTAssertEqual(VaultAuthoringRecord.load(vaultId: vault.id)?.copiedLines, [])
    }

    func testAKeptRowInTheManualsWordsIsRecordedForThePublishingCheck() throws {
        let vault = try newVault()
        let kept = try VaultAuthoring.keep(.faultCode(FaultRow(code: "F17", label: "Outdoor fan motor overload let the motor cool", page: Page(cited: "2"))),
                                           key: "installation-manual", page: 2, labels: PageLabelMap([]), inManualsWords: true,
                                           vaultId: vault.id)
        let record = try XCTUnwrap(VaultAuthoringRecord.load(vaultId: vault.id))
        XCTAssertEqual(record.copiedLines, [.init(file: "fault-codes.md", line: kept.line)])
        let store = try XCTUnwrap(VaultRegistry.shared.store(forId: vault.id))
        let files = Dictionary(uniqueKeysWithValues: store.manifest.files.map { ($0, store.read($0) ?? "") })
        XCTAssertTrue(PublishingCheck.warnings(files: files, record: record, privateExport: false).contains(.rowsInManualsWords(1)))
        XCTAssertEqual(PublishingCheck.warnings(files: files, record: record, privateExport: true), [])
    }

    func testAKeptModelAndSymptomGoToTheirFiles() throws {
        let vault = try newVault()
        try VaultAuthoring.keep(.model(ModelRowT(model: "QX-100", aliases: ["QX100"])), key: "installation-manual", page: 1,
                                labels: PageLabelMap([]), inManualsWords: false, vaultId: vault.id)
        try VaultAuthoring.keep(.symptom(SymptomRowT(symptom: "Not cooling", cause: "Dirty outdoor coil", check: "Clean the coil",
                                                     page: Page(cited: "3"))),
                                key: "installation-manual", page: 3, labels: PageLabelMap([]), inManualsWords: false, vaultId: vault.id)
        let store = try XCTUnwrap(VaultRegistry.shared.store(forId: vault.id))
        XCTAssertTrue(store.read("models.md")?.contains("## QX-100 (QX100)\nManuals: installation-manual p. 1.") == true,
                      store.read("models.md") ?? "")
        XCTAssertTrue(store.read("symptoms.md")?.contains("## Not cooling\n\n1. Clean the coil. Likely cause: Dirty outdoor coil. installation-manual p. 3.") == true,
                      store.read("symptoms.md") ?? "")
    }

    func testARowWithNoFileForItsLayerIsRefused() throws {
        let folder = temp.appendingPathComponent("lw_p1_bare", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = VaultManifest(id: "lw_p1_bare", name: "LW P1 Bare", version: "1.0.0", files: ["safety.md"],
                                     gating: .init(iap: "enterprise"),
                                     promptRules: ["Never fabricate a value.", "Cite the manual and page."])
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("manifest.json"))
        try "# Safety\n\nIsolate first.".write(to: folder.appendingPathComponent("safety.md"), atomically: true, encoding: .utf8)
        _ = try VaultImporter.installReporting(from: folder)
        made.insert("lw_p1_bare")
        VaultRegistry.shared.reloadUserManifests()
        XCTAssertThrowsError(try VaultAuthoring.keep(.faultCode(FaultRow(code: "E9", label: "x", page: Page(cited: "1"))),
                                                     key: "k", page: 1, labels: PageLabelMap([]), inManualsWords: false,
                                                     vaultId: "lw_p1_bare")) { error in
            XCTAssertEqual(error as? VaultAuthoring.Failure, .noFileForLayer("fault-codes.md"))
        }
    }

    // MARK: - The live page text

    func testTheLivePageTextReadsAnIndexedManualByPage() async throws {
        let vault = try newVault()
        let manifest = try addFixtureManual(to: vault.id)
        let storeDir = temp.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let documentStore = DocumentStore(directory: storeDir)
        _ = try await VaultImporter.syncDocuments(manifest: manifest, into: documentStore)

        let manual = try XCTUnwrap(LiveDraftPageText.manual(vaultId: vault.id, file: "installation-manual.txt",
                                                            documentStore: documentStore))
        XCTAssertEqual(manual.key, "installation-manual")
        XCTAssertEqual(manual.pageText.pageNumbers, [1, 2, 3])
        XCTAssertTrue(manual.pageText.text(onPage: 2)?.contains("E9 Low suction pressure") == true)
        XCTAssertTrue(manual.pageText.recognisedPages.isEmpty, "A text manual was not read by recognition")
        let outcome = DraftRowCheck.check(.faultCode(FaultRow(code: "E9", label: "Low suction pressure", page: Page(cited: "2"))),
                                          in: manual.pageText)
        XCTAssertEqual(outcome.mark, .checked)
        XCTAssertEqual(outcome.page, 2)
        XCTAssertNil(LiveDraftPageText.manual(vaultId: vault.id, file: "not-a-manual.pdf", documentStore: documentStore))
    }

    func testAManualNotYetIndexedHasNoPageText() throws {
        let vault = try newVault()
        _ = try addFixtureManual(to: vault.id)
        let documentStore = DocumentStore(directory: temp.appendingPathComponent("empty-store", isDirectory: true))
        XCTAssertNil(LiveDraftPageText.manual(vaultId: vault.id, file: "installation-manual.txt", documentStore: documentStore))
    }

    // MARK: - Export

    func testTheExportListsTheManualByTheKeyItsRowsCite() throws {
        let vault = try newVault()
        _ = try addFixtureManual(to: vault.id)
        let folder = try VaultExporter.export(id: vault.id, learnings: { _ in nil })
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as? [String: Any])
        let expects = try XCTUnwrap(json["expects"] as? [[String: Any]])
        XCTAssertEqual(expects.first?["key"] as? String, "installation-manual")
        XCTAssertEqual(expects.first?["edition"] as? String, "Rev A")
        XCTAssertEqual((expects.first?["revision"] as? String)?.count, 64)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("documents/installation-manual.txt").path),
                       "A manual left the phone")
    }

    // MARK: - A publisher's link

    func testALinksManualsAreAddedToTheVaultAndItsCoreFilesAreNot() throws {
        let vault = try newVault()
        let received = VaultManifest(id: "publisher_set", name: "Publisher set", version: "1.0.0", files: ["fault-codes.md"],
                                     documentsDir: "documents",
                                     documents: [VaultDocument(file: "service.txt", title: "Service manual", edition: "Rev C")])
        let request = VaultLinkInstaller.Request(files: ["manifest.json": try JSONEncoder().encode(received),
                                                         "fault-codes.md": Data("# Not the author's".utf8),
                                                         "documents/service.txt": Data("Service manual\nE9 means low suction.".utf8)],
                                                 receipt: VaultReceipt(publisherId: nil, publisherName: nil, verification: .unverified,
                                                                       sourceHost: "manuals.example.test", receivedAt: Date(),
                                                                       archiveSHA256: "0000"))
        let outcome = try AuthoringLinkIntake.add(request, to: vault.id)
        XCTAssertEqual(outcome.vaultId, vault.id)
        let document = try XCTUnwrap(outcome.manifest.documents.first)
        XCTAssertEqual(document.file, "service-manual.txt")
        XCTAssertEqual(document.edition, "Rev C")
        XCTAssertEqual(document.origin, .technician)
        XCTAssertEqual(VaultRegistry.shared.store(forId: vault.id)?.read("fault-codes.md")?.hasPrefix("# Fault codes"), true)
        XCTAssertNil(VaultImporter.installedManifest(id: "publisher_set"), "The publisher's vault was installed beside it")
    }

    // MARK: - The My Manuals move

    /// A stand-in for My Manuals: a documents-only vault holding one manual (the real library is
    /// installed only through its own admission path, which a test cannot reach).
    private func installPersonalStandIn(id: String = "lw_p1_personal") throws -> String {
        let folder = temp.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stem = "3f1b2c4d-0000-4000-8000-000000000001"
        try FileManager.default.copyItem(at: try manualFile(), to: folder.appendingPathComponent("\(stem).txt"))
        let manifest = VaultManifest(id: id, name: "LW P1 Personal", version: "1.0.0", files: [],
                                     documents: [VaultDocument(file: "\(stem).txt", title: "Installation manual", origin: .technician)],
                                     promptRules: ["Never fabricate a value.", "Cite the manual and page."])
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("manifest.json"))
        _ = try VaultImporter.installReporting(from: folder)
        made.insert(id)
        VaultRegistry.shared.reloadUserManifests()
        return id
    }

    func testTheMoveCopiesChecksThenEmptiesTheLibrary() async throws {
        let source = try installPersonalStandIn()
        let documentStore = DocumentStore(directory: temp.appendingPathComponent("move-store", isDirectory: true))
        MyManualsMove.isAnswered = false
        defer { MyManualsMove.isAnswered = false }
        let moved = try await MyManualsMove.move(name: "LW P1 Moved", template: .general, from: source, documentStore: documentStore)
        made.insert(moved.id)
        let document = try XCTUnwrap(moved.documents.first)
        XCTAssertEqual(document.file, "installation-manual.txt", "The manual is named by its title, not its old id")
        XCTAssertEqual(document.origin, .technician)
        XCTAssertEqual(document.revision?.count, 64)
        XCTAssertNil(VaultImporter.installedManifest(id: source), "The personal library still holds the manuals")
        XCTAssertTrue(VaultAuthoring.isOwned(moved.id))
        XCTAssertTrue(MyManualsMove.isAnswered)
    }

    func testAFailureBeforeTheRemovalLeavesTheLibraryIntactAndNoHalfVault() async throws {
        let source = try installPersonalStandIn()
        let documentStore = DocumentStore(directory: temp.appendingPathComponent("fail-store", isDirectory: true))
        struct Interrupted: Error {}
        do {
            _ = try await MyManualsMove.move(name: "LW P1 Interrupted", template: .general, from: source,
                                             documentStore: documentStore, verify: { _, _ in throw Interrupted() })
            XCTFail("The move went on past a failed check")
        } catch is Interrupted {}
        let kept = try XCTUnwrap(VaultImporter.installedManifest(id: source))
        XCTAssertEqual(kept.documents.count, 1)
        let file = VaultImporter.baselineDirectory(for: source).appendingPathComponent(kept.documentRelativePath(kept.documents[0]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "The personal manual's file went")
        XCTAssertNil(VaultImporter.installedManifest(id: "lw_p1_interrupted"), "The half-made vault was left behind")
    }

    func testAMissingManualFileStopsTheMoveBeforeAnythingIsRemoved() async throws {
        let source = try installPersonalStandIn()
        let manifest = try XCTUnwrap(VaultImporter.installedManifest(id: source))
        try FileManager.default.removeItem(at: VaultImporter.baselineDirectory(for: source)
            .appendingPathComponent(manifest.documentRelativePath(manifest.documents[0])))
        let documentStore = DocumentStore(directory: temp.appendingPathComponent("missing-store", isDirectory: true))
        do {
            _ = try await MyManualsMove.move(name: "LW P1 Missing", template: .general, from: source, documentStore: documentStore)
            XCTFail("A manual that could not be copied was moved")
        } catch {}
        XCTAssertNotNil(VaultImporter.installedManifest(id: source))
        XCTAssertNil(VaultImporter.installedManifest(id: "lw_p1_missing"))
    }

    func testTheRealCheckPassesOnAnIntactCopy() throws {
        let source = try installPersonalStandIn()
        let carried = try MyManualsMove.carried(from: source)
        let vault = try newVault("LW P1 Checked")
        _ = try VaultDocumentCarry.relay(vaultId: vault.id, removing: [], adding: carried)
        XCTAssertNoThrow(try MyManualsMove.verify(carried, in: vault.id))
        // A copy that differs from its source fails the check.
        let copy = VaultImporter.baselineDirectory(for: vault.id).appendingPathComponent("documents/installation-manual.txt")
        try "changed".write(to: copy, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try MyManualsMove.verify(carried, in: vault.id))
    }

    func testNothingToMoveMakesNoVault() async throws {
        let folder = temp.appendingPathComponent("lw_p1_empty_personal", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let documentStore = DocumentStore(directory: temp.appendingPathComponent("none-store", isDirectory: true))
        do {
            _ = try await MyManualsMove.move(name: "LW P1 Nothing", template: .general, from: "lw_p1_absent", documentStore: documentStore)
            XCTFail("Moved nothing")
        } catch let failure as MyManualsMove.Failure {
            XCTAssertEqual(failure, .nothingToMove)
        }
        XCTAssertNil(VaultImporter.installedManifest(id: "lw_p1_nothing"))
    }
}
