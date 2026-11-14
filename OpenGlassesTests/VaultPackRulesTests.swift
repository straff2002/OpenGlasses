import XCTest
@testable import OpenGlasses

/// Plan LR — the vault pack rules the phone shares with the licence service through the licence
/// core (`Tools/LicenceIssuance`, `VaultPackRules`). The app compiles that one file into its own
/// target; this bundle compiles the whole core, so `VaultPackRules` here is the core's copy and the
/// validator's is the app's, built from the same file. The validator still reports what it always
/// has, in the same order, alongside its own checks.
final class VaultPackRulesTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultPackRulesTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func vault(_ manifest: [String: Any], files: [String: String] = [:]) throws -> URL {
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: manifest).write(to: dir.appendingPathComponent("manifest.json"))
        for (path, text) in files {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return dir
    }

    private let grounded = ["Never fabricate a value.", "Cite the file every answer comes from."]

    func testTheValidatorReportsTheCoresManifestAndFileIssuesInItsOwnOrder() throws {
        let dir = try vault(["id": " ", "name": "V", "version": "1", "files": ["core.md", "blank.md", "absent.md"],
                             "prompt_rules": ["Be brief."]],
                            files: ["core.md": "# Core\n", "blank.md": " \n"])
        let result = VaultValidator.validate(directory: dir)
        let manifest = try XCTUnwrap(VaultPackRules.Manifest(json: Data(contentsOf: dir.appendingPathComponent("manifest.json"))))
        let expected = VaultPackRules.manifestIssues(manifest)
            + ["core.md", "blank.md", "absent.md"].compactMap { file in
                VaultPackRules.listedFileIssue(file, contents: try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8))
            }
        XCTAssertEqual(result.issues, expected)
        XCTAssertEqual(result.issues, [
            "manifest id is empty",
            "prompt_rules should address 'fabricate' (anti-fabrication / source citation)",
            "prompt_rules should address 'cite' (anti-fabrication / source citation)",
            "listed file is empty: blank.md",
            "listed file missing: absent.md",
        ])
    }

    func testAGroundedVaultPassesBothAndAManualOnlyOneNeedsNoRules() throws {
        let dir = try vault(["id": "v", "name": "V", "version": "1", "files": ["core.md"], "prompt_rules": grounded],
                            files: ["core.md": "# Core\n"])
        XCTAssertEqual(VaultValidator.validate(directory: dir).issues, [])
        let bare = try vault(["id": "v", "name": "V", "version": "1", "files": ["core.md"]], files: ["core.md": "# Core\n"])
        XCTAssertEqual(VaultValidator.validate(directory: bare).issues, ["manifest must include prompt_rules (grounding discipline)"])
        XCTAssertEqual(VaultValidator.validate(directory: bare, manualOnly: true).issues, [])
        XCTAssertEqual(VaultValidator.requiredRuleThemes, VaultPackRules.requiredRuleThemes)
    }

    func testAProcedureThatDoesNotDecodeIsNamedInTheCoresWords() throws {
        let dir = try vault(["id": "v", "name": "V", "version": "1", "files": ["core.md"], "prompt_rules": grounded,
                             "procedures_dir": "procedures"],
                            files: ["core.md": "# Core\n", "procedures/broken.json": "{\"id\": 1}"])
        XCTAssertEqual(VaultValidator.validate(directory: dir).issues, [VaultPackRules.procedureDoesNotDecode("broken.json")])
        XCTAssertTrue(VaultPackRules.isProcedureFile("procedures/broken.json", proceduresDir: "procedures"))
    }

    func testTheAppsManifestReadsAsTheCoreReadsTheSameBytes() throws {
        let packId = VaultPackManifest.productPrefix + "v"
        let object: [String: Any] = ["id": "v", "name": "V", "version": "1", "files": ["core.md"], "prompt_rules": grounded,
                                     "gating": ["iap": packId], "procedures_dir": "procedures", "sites": ["sites/a.json"]]
        let data = try JSONSerialization.data(withJSONObject: object)
        let app = OpenGlasses.VaultPackRules.Manifest(try JSONDecoder().decode(VaultManifest.self, from: data))
        let core = try XCTUnwrap(VaultPackRules.Manifest(json: data))
        XCTAssertEqual([app.id, app.name] + app.files + app.promptRules, [core.id, core.name] + core.files + core.promptRules)
        XCTAssertEqual(app.gatingIAP, core.gatingIAP); XCTAssertEqual(app.hasSites, core.hasSites)
        XCTAssertEqual(app.documentCount, core.documentCount); XCTAssertEqual(app.proceduresDir, core.proceduresDir)
        XCTAssertEqual(VaultPackRules.packIssues(core, packId: packId), ["a pack must not carry site documents; sites belong in a customer's own vault"])
        XCTAssertEqual(VaultPackManifest.productPrefix, "com.openglasses.vault.", "CompanyVaultContract.packIdPrefix")
    }
}
