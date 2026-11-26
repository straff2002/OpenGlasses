import XCTest
@testable import LicenceIssuance

/// Plan LR — the vault pack rules the phone and the licence service share. The app's
/// `VaultPackRulesTests` runs the phone's validator and install on the same cases.
final class VaultPackRulesTests: XCTestCase {

    let rules = ["Never fabricate a value.", "Cite the file every answer comes from."]

    func manifest(_ json: String) throws -> VaultPackRules.Manifest {
        try XCTUnwrap(VaultPackRules.Manifest(json: Data(json.utf8)))
    }

    func testAManifestIsReadAsThePhoneReadsItsOptionalKeys() throws {
        let full = try manifest(#"""
        {"id":"fixture_rtu","name":"Fixture Rooftop Units","version":"1.0.0","files":["core.md","faults.md"],
         "documents":[],"prompt_rules":["Never fabricate.","Always cite."],"gating":{"iap":"com.openglasses.vault.fixture_rtu"},
         "procedures_dir":"procedures","sites":null}
        """#)
        XCTAssertEqual(full, .init(id: "fixture_rtu", name: "Fixture Rooftop Units", files: ["core.md", "faults.md"],
                                   promptRules: ["Never fabricate.", "Always cite."], gatingIAP: "com.openglasses.vault.fixture_rtu",
                                   proceduresDir: "procedures"))
        XCTAssertEqual(try manifest("{}"), .init(id: "", name: "", files: []))
        // A pack carries no documents and no sites, so anything there but nothing counts as some.
        XCTAssertEqual(try manifest(#"{"documents":[{"file":"a.pdf"},{"file":"b.pdf"}]}"#).documentCount, 2)
        XCTAssertEqual(try manifest(#"{"documents":"a.pdf"}"#).documentCount, 1)
        XCTAssertTrue(try manifest(#"{"sites":[]}"#).hasSites)
        XCTAssertFalse(try manifest(#"{"sites":null}"#).hasSites)
        XCTAssertNil(VaultPackRules.Manifest(json: Data("[]".utf8)))
        XCTAssertNil(VaultPackRules.Manifest(json: Data("not json".utf8)))
    }

    func testTheManifestIssuesAreThePhonesInItsOrder() {
        XCTAssertEqual(VaultPackRules.manifestIssues(.init(id: "v", name: "V", files: ["core.md"], promptRules: rules)), [])
        XCTAssertEqual(VaultPackRules.manifestIssues(.init(id: "  ", name: "V", files: [])), [
            "manifest id is empty",
            "manifest lists no files and no documents",
            "manifest must include prompt_rules (grounding discipline)",
        ])
        XCTAssertEqual(VaultPackRules.manifestIssues(.init(id: "v", name: "V", files: ["core.md"], promptRules: ["Be brief."])), [
            "prompt_rules should address 'fabricate' (anti-fabrication / source citation)",
            "prompt_rules should address 'cite' (anti-fabrication / source citation)",
        ])
        XCTAssertEqual(VaultPackRules.manifestIssues(.init(id: "v", name: "V", files: [], documentCount: 1, promptRules: ["NEVER FABRICATE; CITE."])), [],
                       "documents alone are enough, and the themes are matched whatever their case")
        // A manual-only vault has no grounding rules of its own.
        XCTAssertEqual(VaultPackRules.manifestIssues(.init(id: "v", name: "V", files: [], documentCount: 1), manualOnly: true), [])
    }

    /// Plan IM decision 4: `equipment_types`, the closed list a symptom subject's type comes from.
    func testEquipmentTypesAreAClosedListOfPlainNames() throws {
        XCTAssertNil(try manifest("{}").equipmentTypes)
        let listed = try manifest(#"{"equipment_types":["Dryer","walk-in cooler"]}"#)
        XCTAssertEqual(listed.equipmentTypes, ["Dryer", "walk-in cooler"])
        XCTAssertFalse(listed.equipmentTypesUnreadable)
        XCTAssertTrue(try manifest(#"{"equipment_types":"dryer"}"#).equipmentTypesUnreadable)
        XCTAssertTrue(try manifest(#"{"equipment_types":[1,2]}"#).equipmentTypesUnreadable)
        XCTAssertFalse(try manifest(#"{"equipment_types":null}"#).equipmentTypesUnreadable, "null reads as absent")

        let base = VaultPackRules.Manifest(id: "v", name: "V", files: ["core.md"], promptRules: rules)
        var good = base
        good.equipmentTypes = ["Dryer", "walk-in cooler"]
        XCTAssertEqual(VaultPackRules.manifestIssues(good), [])
        var bad = base
        bad.equipmentTypes = ["Dryer", " ", "DRYER", "door\u{7}", String(repeating: "x", count: 81)]
        XCTAssertEqual(VaultPackRules.manifestIssues(bad), [
            "equipment_types has an empty name",
            "equipment type 'dryer' is listed twice",
            "equipment type 'door\u{7}' contains a control character",
            "equipment type '\(String(repeating: "x", count: 81))' is longer than 80 characters",
        ])
        var empty = base
        empty.equipmentTypes = []
        XCTAssertEqual(VaultPackRules.manifestIssues(empty), ["equipment_types lists nothing; leave it out instead"])
        var unreadable = base
        unreadable.equipmentTypesUnreadable = true
        XCTAssertEqual(VaultPackRules.manifestIssues(unreadable), ["equipment_types must be a list of names"])

        XCTAssertEqual(VaultPackRules.equipmentTypeKey("  Walk-in   Cooler "), "walk-in cooler")
        XCTAssertEqual(VaultPackRules.listedEquipmentType("WALK-IN cooler", in: ["Dryer", "walk-in cooler"]), "walk-in cooler")
        XCTAssertNil(VaultPackRules.listedEquipmentType("dishwasher", in: ["Dryer"]))
        XCTAssertNil(VaultPackRules.listedEquipmentType("  ", in: ["Dryer"]))
    }

    func testAListedFileIsTextAndNotEmpty() {
        XCTAssertNil(VaultPackRules.listedFileIssue("core.md", contents: "# Core\n"))
        XCTAssertEqual(VaultPackRules.listedFileIssue("core.md", contents: nil), "listed file missing: core.md")
        XCTAssertEqual(VaultPackRules.listedFileIssue("core.md", contents: " \n\t"), "listed file is empty: core.md")
    }

    func testProceduresAreTheJSONFilesDirectlyInTheirFolder() {
        for dir in ["procedures", "procedures/", "./procedures"] {
            XCTAssertTrue(VaultPackRules.isProcedureFile("procedures/reset.json", proceduresDir: dir), dir)
            XCTAssertTrue(VaultPackRules.isProcedureFile("procedures/RESET.JSON", proceduresDir: dir), dir)
            XCTAssertFalse(VaultPackRules.isProcedureFile("procedures/old/reset.json", proceduresDir: dir), dir)
            XCTAssertFalse(VaultPackRules.isProcedureFile("procedures/notes.md", proceduresDir: dir), dir)
            XCTAssertFalse(VaultPackRules.isProcedureFile("reset.json", proceduresDir: dir), dir)
        }
        XCTAssertEqual(VaultPackRules.procedureDoesNotDecode("reset.json"), "procedure does not decode: reset.json")
    }

    func testAPackIsGatedByItselfAndCarriesNoDocumentsAndNoSites() {
        let packId = CompanyVaultContract.packIdPrefix + "v"
        XCTAssertEqual(VaultPackRules.packIssues(.init(id: "v", name: "V", files: ["core.md"], gatingIAP: packId), packId: packId), [])
        XCTAssertEqual(VaultPackRules.packIssues(.init(id: "v", name: "V", files: ["core.md"], documentCount: 1, hasSites: true), packId: packId), [
            "vault gating must name the pack id",
            "a pack must not ship documents; customers load their own manuals",
            "a pack must not carry site documents; sites belong in a customer's own vault",
        ])
        XCTAssertEqual(VaultPackRules.packIssues(.init(id: "v", name: "V", files: ["core.md"], gatingIAP: packId + "x"), packId: packId),
                       ["vault gating must name the pack id"])
    }

    func testAnUploadedManifestsIdAndNameCanBecomeACatalogRow() {
        XCTAssertNil(CompanyVaultContract.manifestProblem(id: "fixture_rtu", name: "Fixture Rooftop Units"))
        let longest = String(repeating: "a", count: 80 - CompanyVaultContract.packIdPrefix.count)
        XCTAssertNil(CompanyVaultContract.manifestProblem(id: longest, name: "V"))
        for id in [longest + "a", "a/b", "..", "a b", ""] {
            XCTAssertEqual(CompanyVaultContract.manifestProblem(id: id, name: "V"),
                           "manifest id \(id) must be 1–58 of A–Z a–z 0–9 - _ .", id)
        }
        for name in ["", String(repeating: "n", count: 201), "tab\there"] {
            XCTAssertEqual(CompanyVaultContract.manifestProblem(id: "v", name: name), "manifest name is empty, or longer than 200 characters")
        }
        // What passes here passes the catalog's own row check.
        let row = CompanyVaultContract.Vault(id: CompanyVaultContract.packIdPrefix + longest, vaultId: longest, version: "1",
                                             name: String(repeating: "n", count: 200), sizeBytes: 1,
                                             downloadURL: "https://licence.example.test/c/o/v-1.zip",
                                             sha256: String(repeating: "a", count: 64), packSignature: "c2ln")
        XCTAssertNil(CompanyVaultContract.problem(with: row))
    }

    /// The app compiles this one file into its own target, so it may use nothing else in the package.
    func testTheRulesFileStandsAlone() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LicenceIssuance/VaultPackRules.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let imports = text.split(separator: "\n").filter { $0.hasPrefix("import ") }
        XCTAssertEqual(imports, ["import Foundation"])
        for name in ["CompanyVaultContract", "ProfileContract", "IssuanceWire", "Limits."] {
            XCTAssertFalse(text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .contains { $0.contains(name) }, name)
        }
    }
}
