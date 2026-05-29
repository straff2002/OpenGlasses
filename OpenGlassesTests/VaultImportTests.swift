import XCTest
@testable import OpenGlasses

/// Tests for Plan H: VaultValidator graph/manifest checks and a VaultImporter install round-trip.
@MainActor
final class VaultImportTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultImportTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        // Clean any vault this test installed.
        VaultImporter.uninstall(id: "custom_test")
        VaultRegistry.shared.reloadUserManifests()
        super.tearDown()
    }

    // MARK: - Procedure graph validation

    private func procedure(steps: [Procedure.Step], entry: String? = nil) -> Procedure {
        Procedure(id: "p", title: "P", version: "1.0.0", entryStep: entry, steps: steps)
    }

    func testValidGraphHasNoIssues() {
        let p = procedure(steps: [
            .init(id: "a", title: "A", instruction: "x",
                  branches: [.init(id: "y", condition: "c", next: "b")], defaultNext: "b"),
            .init(id: "b", title: "B", instruction: "x", terminal: true, outcome: "resolved")
        ])
        XCTAssertTrue(VaultValidator.validateProcedureGraph(p).isEmpty)
    }

    func testDanglingBranchTargetFlagged() {
        let p = procedure(steps: [
            .init(id: "a", title: "A", instruction: "x", branches: [.init(id: "y", condition: "c", next: "ghost")], defaultNext: "ghost"),
            .init(id: "b", title: "B", instruction: "x", terminal: true, outcome: "resolved")
        ])
        let issues = VaultValidator.validateProcedureGraph(p)
        XCTAssertTrue(issues.contains { $0.contains("ghost") })
    }

    func testDeadEndNonTerminalFlagged() {
        let p = procedure(steps: [
            .init(id: "a", title: "A", instruction: "x") // not terminal, no transitions
        ])
        let issues = VaultValidator.validateProcedureGraph(p)
        XCTAssertTrue(issues.contains { $0.contains("dead end") })
    }

    func testNoReachableTerminalFlagged() {
        // a → b → a loop, no terminal.
        let p = procedure(steps: [
            .init(id: "a", title: "A", instruction: "x", defaultNext: "b"),
            .init(id: "b", title: "B", instruction: "x", defaultNext: "a")
        ])
        let issues = VaultValidator.validateProcedureGraph(p)
        XCTAssertTrue(issues.contains { $0.contains("terminal") })
    }

    // MARK: - Directory validation

    private func writeVault(id: String, promptRules: [String], includeFile: Bool = true) -> URL {
        let dir = tempRoot.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = VaultManifest(id: id, name: "Custom Test", version: "1.0.0",
                                     files: ["info.md"], proceduresDir: nil,
                                     gating: .init(iap: "enterprise"), promptRules: promptRules)
        try? JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        if includeFile {
            try? "# Info\n\nSome grounded content.".write(to: dir.appendingPathComponent("info.md"), atomically: true, encoding: .utf8)
        }
        return dir
    }

    func testValidDirectoryPasses() {
        let dir = writeVault(id: "custom_test",
                             promptRules: ["Never fabricate data.", "Cite the source file."])
        let result = VaultValidator.validate(directory: dir)
        XCTAssertTrue(result.isValid, "Issues: \(result.issues)")
        XCTAssertEqual(result.manifest?.id, "custom_test")
    }

    func testMissingFileFails() {
        let dir = writeVault(id: "custom_test",
                             promptRules: ["Never fabricate.", "Cite sources."], includeFile: false)
        let result = VaultValidator.validate(directory: dir)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.issues.contains { $0.contains("info.md") })
    }

    func testMissingGroundingRulesFails() {
        let dir = writeVault(id: "custom_test", promptRules: ["Be helpful."])
        let result = VaultValidator.validate(directory: dir)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.issues.contains { $0.lowercased().contains("fabricate") || $0.lowercased().contains("cite") })
    }

    // MARK: - Importer round-trip

    func testInstallMakesVaultDiscoverable() throws {
        let dir = writeVault(id: "custom_test",
                             promptRules: ["Never fabricate.", "Always cite sources."])
        let manifest = try VaultImporter.install(from: dir)
        XCTAssertEqual(manifest.id, "custom_test")

        VaultRegistry.shared.reloadUserManifests()
        XCTAssertNotNil(VaultRegistry.shared.manifest(id: "custom_test"))
        let store = VaultRegistry.shared.store(forId: "custom_test")
        XCTAssertTrue(store?.read("info.md")?.contains("grounded content") ?? false)
    }

    func testInstallRejectsInvalidVault() {
        let dir = writeVault(id: "custom_test", promptRules: ["no rules theme"], includeFile: false)
        XCTAssertThrowsError(try VaultImporter.install(from: dir)) { error in
            guard case VaultImporter.ImportError.invalid = error else {
                return XCTFail("Expected .invalid, got \(error)")
            }
        }
    }
}
