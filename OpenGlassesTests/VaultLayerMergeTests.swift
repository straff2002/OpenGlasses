import XCTest
@testable import OpenGlasses

/// Plan LV P0 — `VaultLayerMerge`: publisher baseline → company layer → technician overlay, the
/// company layer add-only. Headless.
final class VaultLayerMergeTests: XCTestCase {

    typealias Merge = VaultLayerMerge

    let publisher = Merge.Part(files: ["safety.md", "fault_codes.md"],
                               promptRules: ["Never fabricate a value.", "Cite the source file for every claim."])
    let company = Merge.Part(files: ["site_notes.md"],
                             promptRules: ["Prefer the company's own part numbers from site_notes.md.", "Never fabricate a value."])

    func merged(_ company: Merge.Part?, overlay: Set<String> = []) throws -> Merge.Merged {
        try Merge.merge(publisher: publisher, company: company, technicianFiles: overlay).get()
    }

    func testThePublisherAloneReadsAsItAlwaysHas() throws {
        let result = try merged(nil)
        XCTAssertEqual(result.files, publisher.files)
        XCTAssertEqual(result.promptRules, publisher.promptRules)
        XCTAssertEqual(result.companyFiles, [])
        XCTAssertEqual(result.sources, ["safety.md": .publisher, "fault_codes.md": .publisher])
    }

    func testTheCompanyLayerAddsFilesAfterThePublishersAndRulesOnce() throws {
        let result = try merged(company)
        XCTAssertEqual(result.files, ["safety.md", "fault_codes.md", "site_notes.md"])
        XCTAssertEqual(result.companyFiles, ["site_notes.md"])
        XCTAssertEqual(result.promptRules, ["Never fabricate a value.", "Cite the source file for every claim.",
                                            "Prefer the company's own part numbers from site_notes.md."],
                       "a rule the company repeats word for word is kept once, in the publisher's place")
        XCTAssertEqual(result.source(of: "site_notes.md"), .company)
        XCTAssertEqual(result.source(of: "safety.md"), .publisher)
        XCTAssertNil(result.source(of: "elsewhere.md"))
    }

    func testTheCompanyLayerMayNeverReplaceAPublisherFile() {
        let replacing = Merge.Part(files: ["site_notes.md", "fault_codes.md"])
        XCTAssertEqual(Merge.merge(publisher: publisher, company: replacing), .failure(.replacesPublisherFiles(["fault_codes.md"])))
        // However it is spelt.
        let respelt = Merge.Part(files: ["./FAULT_codes.md"])
        XCTAssertEqual(Merge.merge(publisher: publisher, company: respelt), .failure(.replacesPublisherFiles(["./FAULT_codes.md"])))
    }

    func testTheTechniciansOverlayWinsOverBothLayers() throws {
        let result = try merged(company, overlay: ["fault_codes.md", "site_notes.md", "my_own_scratch.md"])
        XCTAssertEqual(result.source(of: "fault_codes.md"), .technician)
        XCTAssertEqual(result.source(of: "site_notes.md"), .technician)
        XCTAssertEqual(result.source(of: "safety.md"), .publisher)
        XCTAssertFalse(result.files.contains("my_own_scratch.md"), "the overlay edits listed files and adds none")
    }

    /// A publisher update changes only the baseline; the company's additions and the technician's
    /// edits are still there.
    func testAPublisherUpdateKeepsTheCompanysFilesAndTheTechniciansEdits() throws {
        let version6 = Merge.Part(files: ["safety.md", "fault_codes.md", "charging.md"], promptRules: publisher.promptRules)
        let result = try Merge.merge(publisher: version6, company: company, technicianFiles: ["fault_codes.md"]).get()
        XCTAssertEqual(result.files, ["safety.md", "fault_codes.md", "charging.md", "site_notes.md"])
        XCTAssertEqual(result.source(of: "fault_codes.md"), .technician)
        XCTAssertEqual(result.source(of: "site_notes.md"), .company)
        XCTAssertEqual(result.source(of: "charging.md"), .publisher)
    }

    /// The partner later adds a file the company layer already added: that update collides, and the
    /// merge refuses rather than letting either silently win.
    func testAPublisherFileThatArrivesWhereTheCompanysWasIsACollision() {
        let version7 = Merge.Part(files: ["safety.md", "fault_codes.md", "site_notes.md"])
        XCTAssertEqual(Merge.merge(publisher: version7, company: company), .failure(.replacesPublisherFiles(["site_notes.md"])))
    }

    func testRemovingTheCompanyLayerLeavesThePublisherAndTheTechnician() throws {
        let result = try merged(nil, overlay: ["fault_codes.md", "site_notes.md"])
        XCTAssertEqual(result.files, publisher.files)
        XCTAssertEqual(result.source(of: "fault_codes.md"), .technician)
        XCTAssertNil(result.source(of: "site_notes.md"))
    }

    func testALayerListingAFileTwiceListsItOnce() throws {
        let result = try merged(.init(files: ["site_notes.md", "Site_Notes.md", "parts.md"]))
        XCTAssertEqual(result.companyFiles, ["site_notes.md", "parts.md"])
    }

    // MARK: - Manifests

    func manifest(_ id: String, files: [String], rules: [String] = ["Never fabricate a value.", "Cite the source."],
                  documents: [VaultDocument] = [], sites: [String]? = nil) -> VaultManifest {
        VaultManifest(id: id, name: id, version: "7", files: files, documentsDir: "documents", documents: documents,
                      gating: .init(iap: "com.openglasses.vault." + id), promptRules: rules, trades: ["refrigeration_hvac"],
                      sites: sites, vaultOnly: true)
    }

    func testTheMergedManifestIsThePublishersWithTheLayerLaidOver() throws {
        let base = manifest("fixture-split-systems", files: ["safety.md", "fault_codes.md"],
                            documents: [VaultDocument(file: "Installation manual.md", title: "Installation manual")])
        let layer = manifest("fixture-split-systems-company", files: ["site_notes.md"],
                             rules: ["Prefer the company's own part numbers."])
        let merged = try Merge.manifest(publisher: base, company: layer).get()
        XCTAssertEqual(merged.id, base.id)
        XCTAssertEqual(merged.gating, base.gating)
        XCTAssertEqual(merged.documents, base.documents)
        XCTAssertEqual(merged.vaultOnly, true)
        XCTAssertEqual(merged.trades, base.trades)
        XCTAssertEqual(merged.files, ["safety.md", "fault_codes.md", "site_notes.md"])
        XCTAssertEqual(merged.promptRules, base.promptRules + ["Prefer the company's own part numbers."])
        XCTAssertEqual(try Merge.manifest(publisher: base, company: nil).get(), base, "no layer: the publisher's manifest")
    }

    func testAManifestLayerWithDocumentsOrSitesIsRefused() {
        let base = manifest("fixture-split-systems", files: ["safety.md"])
        let documents = manifest("l", files: ["a.md"], documents: [VaultDocument(file: "x.md", title: "X")])
        let sites = manifest("l", files: ["a.md"], sites: ["sites/one.json"])
        guard case .failure(.notALayer(let issues))? = Optional(Merge.manifest(publisher: base, company: documents)) else {
            return XCTFail("a layer with documents installed")
        }
        XCTAssertEqual(issues.count, 1)
        guard case .failure(.notALayer)? = Optional(Merge.manifest(publisher: base, company: sites)) else {
            return XCTFail("a layer with sites installed")
        }
        XCTAssertEqual(Merge.manifest(publisher: base, company: manifest("l", files: ["safety.md"])),
                       .failure(.replacesPublisherFiles(["safety.md"])))
    }

    /// The shared fixture's colliding layer is refused by the phone in the core's words.
    func testTheSharedCollidingLayerFixtureIsRefused() throws {
        let data = try CompanyVaultPublishedContractTests.fixture("layer-collides-manifest.json")
        let layer = try JSONDecoder().decode(VaultManifest.self, from: data)
        let base = manifest("fixture-split-systems", files: ["safety.md", "fault_codes.md"])
        XCTAssertEqual(Merge.manifest(publisher: base, company: layer), .failure(.replacesPublisherFiles(["fault_codes.md"])))
        XCTAssertEqual(OpenGlasses.VaultPackRules.layerIssues(OpenGlasses.VaultPackRules.Manifest(layer), baseFiles: base.files),
                       ["a company layer may add files, not replace the vault's own: fault_codes.md"])
    }
}
