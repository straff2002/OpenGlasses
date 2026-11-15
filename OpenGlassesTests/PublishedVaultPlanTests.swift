import XCTest
@testable import OpenGlasses

/// Plan LV P1 — the pure parts of a published vault on the phone: the plan's ordering of a company
/// layer after its base, its removal with its base, the rows' wording, the answer's note, the
/// state's decoding and the vault store's three-layer reads. Every name is invented.
final class PublishedVaultPlanTests: XCTestCase {

    typealias Plan = CompanyVaultPlan
    let base = "fixture-split-systems"
    let layer = "fixture-split-systems-company"

    func vault(_ id: String, version: String = "1", size: Int = 1_000, publisher: Int? = nil, frozen: Bool? = nil,
               extends: String? = nil, expects: [CompanyVaultCatalog.ExpectedManual]? = nil) -> CompanyVaultCatalog.Vault {
        .init(id: "com.openglasses.vault." + id, vaultId: id, version: version, name: id == layer ? "Fixture Company Notes" : "Fixture Split Systems",
              summary: nil, author: nil, minAppBuild: nil, sizeBytes: size, downloadURL: "https://licence.example.test/\(id).zip",
              sha256: String(repeating: "a", count: 64), packSignature: "s",
              publisher: publisher.map { .init(id: "p-fixture", name: "Fixture Partner", version: $0) },
              sealedCore: publisher != nil ? true : nil, expects: expects, frozen: frozen, extends: extends)
    }

    func catalog(_ vaults: [CompanyVaultCatalog.Vault], problems: [String: String] = [:]) -> CompanyVaultCatalog.Verified {
        .init(profileId: "p", generation: 2, issued: Date(), manualsOnAnyNetwork: true, vaults: vaults, manuals: [], problems: problems)
    }

    func installedVaults(_ vaults: [String: (String, String?)]) -> Plan.Installed {
        var result = Plan.Installed()
        for (id, value) in vaults {
            result.vaults[id] = .init(packId: "com.openglasses.vault." + id, version: value.0, extends: value.1)
        }
        return result
    }

    func conditions(job: Plan.Job = .none, free: Int64 = 50 * 1_073_741_824) -> Plan.Conditions {
        .init(job: job, freeBytes: free, currentBuild: 700)
    }

    // MARK: - The plan

    func testALayerListedFirstInstallsAfterItsBase() {
        let steps = Plan.steps(installed: .init(), catalog: catalog([vault(layer, extends: base), vault(base, publisher: 5)]),
                               conditions: conditions())
        XCTAssertEqual(steps, [.install(vault(base, publisher: 5)), .install(vault(layer, extends: base))])
    }

    func testALayerWaitsWhileItsBaseCannotInstall() {
        let steps = Plan.steps(installed: .init(), catalog: catalog([vault(base, size: 2_000_000_000, publisher: 5), vault(layer, extends: base)]),
                               conditions: conditions(free: 1_073_741_824))
        XCTAssertEqual(steps.count, 1)
        guard case .notEnoughSpace(let id, _)? = steps.first else { return XCTFail("\(steps)") }
        XCTAssertEqual(id, base, "the layer has no step of its own until its base is in")
    }

    func testANewLayerWaitsForAJobOnItsBase() {
        let steps = Plan.steps(installed: installedVaults([base: ("1", nil)]),
                               catalog: catalog([vault(base, publisher: 5), vault(layer, extends: base)]),
                               conditions: conditions(job: .open(vaultId: base)))
        XCTAssertEqual(steps, [.waitForJob(vaultId: layer, version: "1", removal: false)])
    }

    func testAnUpdatedBaseLaysItsLayerAgain() {
        let steps = Plan.steps(installed: installedVaults([base: ("1", nil), layer: ("1", base)]),
                               catalog: catalog([vault(base, version: "2", publisher: 6), vault(layer, extends: base)]),
                               conditions: conditions())
        XCTAssertEqual(steps, [.update(vault(base, version: "2", publisher: 6), from: "1"), .update(vault(layer, extends: base), from: "1")])
    }

    func testAnUnchangedBaseLeavesItsLayerAlone() {
        XCTAssertEqual(Plan.steps(installed: installedVaults([base: ("1", nil), layer: ("1", base)]),
                                  catalog: catalog([vault(base, publisher: 5), vault(layer, extends: base)]), conditions: conditions()), [])
    }

    func testABaseUpdateWaitingForTheJobHoldsItsLayerToo() {
        let steps = Plan.steps(installed: installedVaults([base: ("1", nil), layer: ("1", base)]),
                               catalog: catalog([vault(base, version: "2", publisher: 6), vault(layer, version: "2", extends: base)]),
                               conditions: conditions(job: .open(vaultId: base)))
        XCTAssertEqual(steps, [.waitForJob(vaultId: base, version: "2", removal: false),
                               .waitForJob(vaultId: layer, version: "2", removal: false)])
    }

    func testALayerWhoseBaseLeftIsRemovedFirstEvenThoughItsRowWasRefused() {
        // The screen leaves out a layer whose base is gone, and names it; that is not a reason to
        // keep it, as it is for any other refused row.
        let steps = Plan.steps(installed: installedVaults([base: ("1", nil), layer: ("1", base)]),
                               catalog: catalog([], problems: [layer: "incomplete"]), conditions: conditions())
        XCTAssertEqual(steps, [.remove(vaultId: layer), .remove(vaultId: base)])
    }

    func testARefusedLayerRowWithItsBaseStillListedStays() {
        let steps = Plan.steps(installed: installedVaults([base: ("1", nil), layer: ("1", base)]),
                               catalog: catalog([vault(base, publisher: 5)], problems: [layer: "incomplete"]), conditions: conditions())
        XCTAssertEqual(steps, [])
    }

    func testALayerRemovalWaitsForAJobOnItsBase() {
        let steps = Plan.steps(installed: installedVaults([base: ("1", nil), layer: ("1", base)]),
                               catalog: catalog([vault(base, publisher: 5)]), conditions: conditions(job: .open(vaultId: base)))
        XCTAssertEqual(steps, [.waitForJob(vaultId: layer, version: nil, removal: true)])
    }

    func testAFrozenVaultInstallsWhereItIsMissingAndIsNeverUpdated() {
        let frozen = vault(base, version: "9", publisher: 6, frozen: true)
        XCTAssertEqual(Plan.steps(installed: .init(), catalog: catalog([frozen]), conditions: conditions()), [.install(frozen)])
        XCTAssertEqual(Plan.steps(installed: installedVaults([base: ("1", nil)]), catalog: catalog([frozen]), conditions: conditions()), [])
    }

    func testAPlainCatalogPlansExactlyAsBefore() {
        let a = vault("fixture-a"), b = vault("fixture-b", version: "2")
        let steps = Plan.steps(installed: installedVaults(["fixture-b": ("1", nil), "fixture-z": ("1", nil), "fixture-c": ("1", nil)]),
                               catalog: catalog([a, b]), conditions: conditions())
        XCTAssertEqual(steps, [.remove(vaultId: "fixture-c"), .remove(vaultId: "fixture-z"), .install(a), .update(b, from: "1")])
    }

    // MARK: - The state

    func testAStateWrittenBeforePublishedVaultsStillReads() throws {
        let json = #"{"vaults":{"fixture-a":{"packId":"com.openglasses.vault.fixture-a","name":"A","version":"3","updatedAt":0}},"removedNames":["B"]}"#
        let state = try JSONDecoder().decode(CompanyVaultState.self, from: Data(json.utf8))
        XCTAssertEqual(state.vaults["fixture-a"]?.version, "3")
        XCTAssertNil(state.vaults["fixture-a"]?.publisherName)
        XCTAssertNil(state.vaults["fixture-a"]?.publisherVersion)
        XCTAssertNil(state.vaults["fixture-a"]?.extends)
        XCTAssertEqual(state.removedNames, ["B"])
        XCTAssertEqual(state.removedPublished, [])
        XCTAssertNil(state.installed.vaults["fixture-a"]?.extends)
    }

    func testThePublisherRoundTripsThroughTheState() throws {
        var state = CompanyVaultState()
        state.vaults[base] = .init(packId: "p", name: "Fixture Split Systems", version: "7", updatedAt: Date(timeIntervalSince1970: 0),
                                   publisherName: "Fixture Partner", publisherVersion: 5)
        state.vaults[layer] = .init(packId: "l", name: "Fixture Company Notes", version: "2", updatedAt: Date(timeIntervalSince1970: 0),
                                    extends: base)
        state.removedPublished = [.init(name: "Old", publisher: "Fixture Partner")]
        let decoded = try JSONDecoder().decode(CompanyVaultState.self, from: try JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
        XCTAssertEqual(decoded.installed.vaults[layer]?.extends, base)
    }

    // MARK: - The rows

    let expects: [CompanyVaultCatalog.ExpectedManual] = [
        .init(key: "install-manual", title: "Installation manual", revision: String(repeating: "1", count: 64)),
        .init(key: "service-manual", title: "Service manual", edition: "Rev B"),
    ]

    func testAChecklistWithEverythingHeldSaysOnlyHowMany() throws {
        let summary = ExpectedManualMatch.match(expects: expects, documents: [
            VaultDocument(file: "i.md", title: "Installation manual", revision: String(repeating: "1", count: 64), origin: .company),
            VaultDocument(file: "s.md", title: "Service manual", origin: .technician),
        ])
        let checklist = try XCTUnwrap(CompanyVaultRow.ManualChecklist.make(summary))
        XCTAssertEqual(checklist.summary, "2 of 2 manuals")
        XCTAssertFalse(checklist.hasDifferences)
        XCTAssertEqual(checklist.entries.map(\.title), ["Installation manual", "Service manual (Rev B)"])
        XCTAssertNil(CompanyVaultRow.ManualChecklist.make(ExpectedManualMatch.match(expects: [], documents: [])))
    }

    func testARowBeforeItsVaultArrivesNamesThePartnerButNoChecklist() {
        let rows = CompanyVaultRow.rows(state: CompanyVaultState(), catalog: catalog([vault(base, publisher: 5, expects: expects)]))
        XCTAssertEqual(rows.first?.byline, "from Fixture Partner · version 5")
        XCTAssertNil(rows.first?.checklist, "nothing is held yet to compare")
        XCTAssertEqual(rows.first?.status, "Installing.")
    }

    func testAFrozenRowSaysTheVersionKeptAndAPlainRowSaysNothingNew() {
        var state = CompanyVaultState()
        state.vaults[base] = .init(packId: "p", name: "Fixture Split Systems", version: "7", updatedAt: Date(),
                                   publisherName: "Fixture Partner", publisherVersion: 4)
        state.vaults["fixture-a"] = .init(packId: "a", name: "Fixture A", version: "3", updatedAt: Date())
        let rows = CompanyVaultRow.rows(state: state, catalog: catalog([vault(base, version: "9", publisher: 6, frozen: true),
                                                                        vault("fixture-a", version: "3")]))
        XCTAssertEqual(rows[0].frozenNote, "No longer updated by Fixture Partner · version 4 kept")
        XCTAssertEqual(rows[0].byline, "from Fixture Partner · version 4", "the version on this phone, not the list's")
        XCTAssertNil(rows[1].byline)
        XCTAssertNil(rows[1].frozenNote)
        XCTAssertNil(rows[1].layerNote)
        XCTAssertNil(rows[1].checklist)
    }

    func testTheRemovalNoticeNamesThePartner() {
        XCTAssertEqual(CompanyVaultRowList.removalNotices([.init(name: "Fixture Split Systems", publisher: "Fixture Partner")]),
                       ["Fixture Split Systems was removed by Fixture Partner."])
    }

    // MARK: - The answer's note

    let files: [(filename: String, contents: String)] = [
        ("fault_codes.md", "| QX1 | install-manual p. 4 |\n| QX2 | Service-Manual page 12 |\n| QX3 | see service-manual, p 40 |"),
        ("wiring.md", "Wiring: wiring-diagram pp. 3. Not the install-manualish key."),
    ]

    func testIndexCitationsAreFoundInTheOrderCited() {
        let citations = PublishedVaultAnswerNote.indexCitations(in: files, keys: ["install-manual", "service-manual", "wiring-diagram"])
        XCTAssertEqual(citations, [.init(key: "install-manual", page: 4), .init(key: "service-manual", page: 12),
                                   .init(key: "service-manual", page: 40), .init(key: "wiring-diagram", page: 3)])
    }

    func testTheNoteNamesOnlyCitedPagesInADifferentRevisionAndMissingManuals() throws {
        let expects: [CompanyVaultCatalog.ExpectedManual] = [
            .init(key: "install-manual", title: "Installation manual", revision: String(repeating: "1", count: 64)),
            .init(key: "service-manual", title: "Service manual", revision: String(repeating: "2", count: 64)),
            .init(key: "wiring-diagram", title: "Wiring diagram"),
        ]
        let documents = [
            VaultDocument(file: "i.md", title: "Installation manual", revision: String(repeating: "1", count: 64)),
            VaultDocument(file: "s.md", title: "Service manual", revision: String(repeating: "3", count: 64)),
        ]
        let note = try XCTUnwrap(PublishedVaultAnswerNote.promptNote(publisher: "Fixture Partner", publisherFiles: ["fault_codes.md"],
                                                                     expects: expects, documents: documents, files: files))
        XCTAssertTrue(note.hasPrefix("PUBLISHED VAULT: these files of this vault are Fixture Partner's: fault_codes.md."), note)
        XCTAssertTrue(note.contains("check page 12.\""))
        XCTAssertTrue(note.contains("check page 40.\""))
        XCTAssertTrue(note.contains("This vault expects Wiring diagram, which isn't on this phone."))
        XCTAssertFalse(note.contains("Installation manual"), "a matched manual says nothing")
    }

    func testAVaultWhoseManualsAllMatchSaysOnlyWhoseFilesTheyAre() {
        let note = PublishedVaultAnswerNote.promptNote(
            publisher: "Fixture Partner", publisherFiles: ["fault_codes.md"],
            expects: [.init(key: "install-manual", title: "Installation manual")],
            documents: [VaultDocument(file: "i.md", title: "Installation manual")], files: files)
        XCTAssertEqual(note, "PUBLISHED VAULT: these files of this vault are Fixture Partner's: fault_codes.md. When an answer draws on any of them, end it with this line, in the language of the answer: \"From Fixture Partner's vault\".")
        XCTAssertNil(PublishedVaultAnswerNote.promptNote(publisher: nil, publisherFiles: [], expects: [], documents: [], files: files))
    }

    func testAPageCitedInAManualOfAnotherRevisionWithoutAPageSaysNothing() {
        let note = PublishedVaultAnswerNote.promptNote(
            publisher: nil, publisherFiles: [],
            expects: [.init(key: "service-manual", title: "Service manual", edition: "Rev B")],
            documents: [VaultDocument(file: "s.md", title: "Service manual", edition: "Rev A")],
            files: [("a.md", "See service-manual for the procedure.")])
        XCTAssertNil(note, "decision 6: a page, or nothing")
    }

    // MARK: - The store's three layers

    func testTheStoreReadsPublisherThenCompanyThenTechnician() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PublishedVaultStore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let publisher = root.appendingPathComponent("publisher"), company = root.appendingPathComponent("company")
        let overlay = root.appendingPathComponent("overlay")
        for dir in [publisher, company, overlay] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try "partner codes".write(to: publisher.appendingPathComponent("fault_codes.md"), atomically: true, encoding: .utf8)
        try "partner safety".write(to: publisher.appendingPathComponent("safety.md"), atomically: true, encoding: .utf8)
        try "company notes".write(to: company.appendingPathComponent("site_notes.md"), atomically: true, encoding: .utf8)
        // A stray file of the company's own name under the publisher's root is never read for it.
        try "stray".write(to: publisher.appendingPathComponent("site_notes.md"), atomically: true, encoding: .utf8)
        let merged = try VaultLayerMerge.merge(publisher: .init(files: ["fault_codes.md", "safety.md"]),
                                               company: .init(files: ["site_notes.md"])).get()
        let manifest = VaultManifest(id: base, name: "Fixture Split Systems", version: "1", files: merged.files,
                                     gating: .init(iap: nil), promptRules: [])
        let store = VaultStore(manifest: manifest, bundleRoot: publisher, overlayRoot: overlay,
                               companyLayer: .init(root: company, merged: merged))
        XCTAssertEqual(store.read("fault_codes.md"), "partner codes")
        XCTAssertEqual(store.read("site_notes.md"), "company notes")
        XCTAssertEqual(store.layer(of: "site_notes.md"), .company)
        _ = try store.write("safety.md", contents: "technician safety")
        _ = try store.write("site_notes.md", contents: "technician notes")
        XCTAssertEqual(store.read("safety.md"), "technician safety")
        XCTAssertEqual(store.read("site_notes.md"), "technician notes")
        XCTAssertEqual(store.layer(of: "site_notes.md"), .technician)
        XCTAssertEqual(store.baseLayer(of: "site_notes.md"), .company)
        XCTAssertEqual(store.readAll().map(\.filename), ["fault_codes.md", "safety.md", "site_notes.md"])

        // Without a layer, the store is the one it always was.
        let plainStore = VaultStore(manifest: manifest, bundleRoot: publisher, overlayRoot: root.appendingPathComponent("o2"))
        XCTAssertNil(plainStore.companyLayer)
        XCTAssertEqual(plainStore.read("site_notes.md"), "stray")
        XCTAssertEqual(plainStore.layer(of: "fault_codes.md"), .publisher)
    }
}
