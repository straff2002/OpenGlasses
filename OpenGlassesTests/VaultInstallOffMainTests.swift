import CryptoKit
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
    private static let packVaultId = "install_off_main_pack"
    private var made: [String] = []

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
        for id in [Self.vaultId, Self.packVaultId] + made { VaultImporter.uninstall(id: id) }
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

    // MARK: - The other install paths

    /// Every place a vault is installed or re-laid validates it off the main thread, apart from the
    /// roster below, each with its reason. A new call to a synchronous install fails here until it
    /// is either moved off the main thread or added to the roster with a comment beside it.
    func testNoInstallPathValidatesOnTheMainThreadOutsideTheRoster() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("OpenGlasses/Sources")
        let allowed: [String: Int] = [
            // The synchronous relay itself, which `relayOffMain` stands beside.
            "Services/Vault/VaultDocumentCarry.swift": 1,
            // A new starter: short Markdown files, no manuals, an id nothing else holds.
            "Services/Vault/Authoring/VaultAuthoring.swift": 1,
            // Already inside a detached task, under the My Manuals lock.
            "Services/Vault/PersonalManualLibrary.swift": 1,
        ]
        let calls = ["VaultImporter.installReporting(", "VaultImporter.install(from", "VaultDocumentCarry.relay("]
        var found: [String: Int] = [:]
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        for case let url as URL in files where url.pathExtension == "swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
            let count = lines.filter { line in
                !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") && calls.contains { line.contains($0) }
            }.count
            if count > 0 {
                found[String(url.path.dropFirst(sources.path.count + 1)), default: 0] += count
            }
        }
        XCTAssertEqual(found, allowed, "a vault install validates on the main thread outside the roster")
        for file in allowed.keys {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(text.contains("installReportingOffMain") || text.contains("relayOffMain")
                          || text.contains("Task.detached") || text.contains("on purpose"),
                          "\(file) is on the roster without its reason")
        }
    }

    /// A folder import waits for its vault's lock, so an index or a removal of that vault never
    /// runs while the folder is checked, and is then checked off the main thread.
    func testAFolderImportWaitsForTheVaultsLockAndValidatesOffMain() async throws {
        let calls = Calls()
        let real = previousValidator!
        VaultImporter.offMainValidator = { directory, manualOnly in
            calls.note(onMain: Thread.isMainThread)
            return real(directory, manualOnly)
        }
        let folder = try vaultFolder()
        var install: Task<VaultImporter.InstallReport, Error>?
        await VaultOperationLock.withLock(Self.vaultId) {
            install = Task { try await VaultImporter.installReportingOffMainLocked(from: folder) }
            try? await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(calls.count, 0, "the folder was checked while another operation held the vault")
        }
        let report = try await XCTUnwrap(install).value
        XCTAssertEqual(report.manifest.id, Self.vaultId)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.onMain, false, "the folder was checked on the main thread")
        XCTAssertFalse(VaultOperationLock.isBusy(Self.vaultId))
    }

    /// A manual added to a vault of your own: under the vault's lock, checked off the main thread.
    func testAnAuthoredManualWaitsForTheVaultsLockAndValidatesOffMain() async throws {
        let vault = try VaultAuthoring.createVault(name: "Install Off Main Authoring", template: .hvacR)
        made.append(vault.id)
        let calls = Calls()
        let real = previousValidator!
        VaultImporter.offMainValidator = { directory, manualOnly in
            calls.note(onMain: Thread.isMainThread)
            return real(directory, manualOnly)
        }
        let manual = temp.appendingPathComponent("service.txt")
        try "Service manual\n\nInvented: E9 means low suction.".write(to: manual, atomically: true, encoding: .utf8)
        var add: Task<VaultManifest, Error>?
        await VaultOperationLock.withLock(vault.id) {
            add = Task {
                try await VaultAuthoring.addManual(.init(original: manual, readingPDF: manual, converted: false,
                                                         title: "Service manual"), to: vault.id)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(calls.count, 0, "the manual was added while another operation held the vault")
        }
        let manifest = try await XCTUnwrap(add).value
        XCTAssertEqual(manifest.documents.map(\.title), ["Service manual"])
        XCTAssertEqual(calls.onMain, false, "the vault was checked on the main thread")

        let file = try await VaultAuthoring.addFile(named: "Wiring notes", to: vault.id)
        XCTAssertEqual(file, "wiring-notes.md")
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.onMain, false, "the vault was checked on the main thread when a file was added")
        XCTAssertFalse(VaultOperationLock.isBusy(vault.id))
    }

    /// A pack install (a company vault's core update among them) waits for the vault's lock, so a
    /// manual added while it is checked is not overwritten by an update that never saw it.
    func testAPackInstallWaitsForTheVaultsLockAndValidatesOffMain() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let packId = "com.openglasses.vault.\(Self.packVaultId)"
        let pack = VaultPackManifest(id: packId, vaultId: Self.packVaultId, version: "1.0.0", name: "Off main pack",
                                     summary: "s", author: "Example author", minAppBuild: nil, licensePack: nil)
        let manifest = VaultManifest(id: Self.packVaultId, name: "Off main pack", version: "1.0.0", files: ["safety.md"],
                                     gating: .init(iap: packId), promptRules: ["Never fabricate.", "Cite the source."])
        var files: [String: Data] = ["manifest.json": try JSONEncoder().encode(manifest),
                                     "safety.md": Data("# Safety\n\nInvented: isolate before work.".utf8)]
        let packData = try JSONEncoder().encode(pack)
        let signature = try VaultPackSignature.sign(packManifestData: packData, files: files,
                                                    privateKeyBase64: key.rawRepresentation.base64EncodedString())
        files[VaultPackManifest.filename] = packData
        let service = VaultPackCatalogService(catalogURL: { nil }, fetch: { _ in Data() },
                                              publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString(),
                                              currentBuild: 400)
        let calls = Calls()
        let real = previousValidator!
        VaultImporter.offMainValidator = { directory, manualOnly in
            calls.note(onMain: Thread.isMainThread)
            return real(directory, manualOnly)
        }
        let zip = VaultPackTests.makeZip(files)
        var install: Task<Result<[String], VaultPackCatalogService.InstallFailure>, Never>?
        await VaultOperationLock.withLock(Self.packVaultId) {
            install = Task { await service.installPack(zipData: zip, signatureBase64: signature, expectedId: packId) }
            try? await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(calls.count, 0, "the pack was checked while another operation held the vault")
        }
        let installing = try XCTUnwrap(install)
        guard case .success = await installing.value else { return XCTFail("the pack did not install") }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.onMain, false, "the pack was checked on the main thread")
        XCTAssertEqual(VaultImporter.installedPack(for: Self.packVaultId)?.id, packId)
    }
}

/// How often the validation ran, and whether the last run was on the main thread.
private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var runs = 0
    private var lastOnMain: Bool?
    func note(onMain: Bool) { lock.lock(); runs += 1; lastOnMain = onMain; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return runs }
    var onMain: Bool? { lock.lock(); defer { lock.unlock() }; return lastOnMain }
}

/// A Bool set from the validation's thread and read back on the test's.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?
    func set(_ newValue: Bool) { lock.lock(); stored = newValue; lock.unlock() }
    var value: Bool? { lock.lock(); defer { lock.unlock() }; return stored }
}
