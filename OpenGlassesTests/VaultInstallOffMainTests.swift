import XCTest
@testable import OpenGlasses

/// Installing a vault validates it first, and validation reads every manual's text and, in a vault
/// with rule chains, every PDF page for tables. On build 728 that ran on the main thread while a
/// company's code books were being added: the app froze and iOS killed it (`0x8BADF00D`).
/// `installReportingOffMain` validates on a background task and installs on the main actor.
/// These tests hold the three things that makes true: where the validation runs, that a validation
/// is only ever reused for the folder it checked, and that the company-manual path uses it.
@MainActor
final class VaultInstallOffMainTests: XCTestCase {
    private var temp: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!
    private var previousValidator: (@Sendable (URL, Bool) -> VaultValidator.Result)!
    private static let vaultId = "install_off_main_test"

    override func setUp() {
        super.setUp()
        temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultInstallOffMainTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        previousEntitlement = EntitlementTestScope.grant()
        previousValidator = VaultImporter.offMainValidator
    }

    override func tearDown() {
        VaultImporter.offMainValidator = previousValidator
        VaultImporter.uninstall(id: Self.vaultId)
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        EntitlementTestScope.restore(previousEntitlement)
        try? FileManager.default.removeItem(at: temp)
        super.tearDown()
    }

    /// A small valid vault, or one whose manifest lists a file the folder does not hold.
    private func vaultFolder(missingSafetyFile: Bool = false) throws -> URL {
        let dir = temp.appendingPathComponent("vault-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = VaultManifest(
            id: Self.vaultId, name: "Install Off Main Test", version: "1.0.0",
            files: ["safety.md"], proceduresDir: nil, documentsDir: nil, documents: [],
            gating: .init(iap: "enterprise"), promptRules: ["Never fabricate.", "Cite the source."])
        try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        if !missingSafetyFile {
            try "# Safety\n\nInvented: isolate before work.".write(to: dir.appendingPathComponent("safety.md"),
                                                                    atomically: true, encoding: .utf8)
        }
        return dir
    }

    func testTheValidationRunsOffTheMainThreadAndTheVaultInstalls() async throws {
        let ranOnMain = LockedFlag()
        let real = previousValidator!
        VaultImporter.offMainValidator = { directory, manualOnly in
            ranOnMain.set(Thread.isMainThread)
            return real(directory, manualOnly)
        }
        let report = try await VaultImporter.installReportingOffMain(from: try vaultFolder())
        XCTAssertEqual(ranOnMain.value, false, "the validation ran on the main thread")
        XCTAssertEqual(report.manifest.id, Self.vaultId)
        XCTAssertEqual(VaultImporter.installedManifest(id: Self.vaultId)?.files, ["safety.md"])
    }

    func testAnInvalidFolderIsStillRefusedOffTheMainThread() async throws {
        do {
            _ = try await VaultImporter.installReportingOffMain(from: try vaultFolder(missingSafetyFile: true))
            XCTFail("a folder missing a listed file installed")
        } catch VaultImporter.ImportError.invalid(let issues) {
            XCTAssertFalse(issues.isEmpty)
        }
        XCTAssertNil(VaultImporter.installedManifest(id: Self.vaultId))
    }

    /// A validation is reused only for the folder it checked: a passing result handed in for a
    /// different folder is ignored, and that folder is validated (and refused) as before.
    func testAPassingValidationOfAnotherFolderDoesNotLetABrokenOneIn() throws {
        let good = try vaultFolder()
        let broken = try vaultFolder(missingSafetyFile: true)
        let passed = VaultValidator.validate(directory: good)
        XCTAssertTrue(passed.isValid)
        XCTAssertThrowsError(try VaultImporter.installReporting(
            from: broken, prevalidated: .init(directory: good, manualOnly: false, result: passed)))
        XCTAssertNil(VaultImporter.installedManifest(id: Self.vaultId))
    }

    /// The same for a validation made under the other rule set (manuals only).
    func testAValidationMadeAsManualsOnlyIsNotReusedForAFullVault() throws {
        let broken = try vaultFolder(missingSafetyFile: true)
        let pretend = VaultValidator.Result(manifest: VaultValidator.validate(directory: try vaultFolder()).manifest,
                                            issues: [])
        XCTAssertThrowsError(try VaultImporter.installReporting(
            from: broken, prevalidated: .init(directory: broken, manualOnly: true, result: pretend)))
        XCTAssertNil(VaultImporter.installedManifest(id: Self.vaultId))
    }

    func testOnlyTheReceivedAndPersonalOriginsValidateAsManualsOnly() {
        XCTAssertFalse(VaultImporter.validatesManualOnly(.folder))
        XCTAssertTrue(VaultImporter.validatesManualOnly(.personalPDF))
        XCTAssertTrue(VaultImporter.validatesManualOnly(.receivedSigned))
    }

    /// The path in the crash: company manuals are laid into their vault with the validation off
    /// the main thread, under the vault's lock.
    func testCompanyManualsAreLaidInWithTheOffMainRelay() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "OpenGlasses/Sources/Services/OrgProfile/CompanyVaultService.swift"), encoding: .utf8)
        let live = try XCTUnwrap(source.range(of: "final class LiveCompanyVaultInstaller"))
        let start = try XCTUnwrap(source.range(of: "func applyManuals(vaultId: String, adding: [StagedCompanyManual]",
                                                range: live.upperBound..<source.endIndex))
        let end = source.range(of: "func uninstall(vaultId:", range: start.upperBound..<source.endIndex)?.lowerBound
            ?? source.endIndex
        let body = source[start.upperBound..<end]
        XCTAssertTrue(body.contains("VaultOperationLock.withLock(vaultId)"))
        XCTAssertTrue(body.contains("VaultDocumentCarry.relayOffMain("),
                      "company manuals must not be validated on the main thread")
        XCTAssertFalse(body.contains("VaultDocumentCarry.relay(vaultId"))
    }
}

/// A Bool set from the validation's thread and read back on the test's.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?
    func set(_ newValue: Bool) { lock.lock(); stored = newValue; lock.unlock() }
    var value: Bool? { lock.lock(); defer { lock.unlock() }; return stored }
}
