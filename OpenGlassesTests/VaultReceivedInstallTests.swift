import XCTest
@testable import OpenGlasses

/// Plan FS PR2 — what installing a received vault actually leaves on the phone: the vault, the
/// receipt beside its baseline, the badge that follows from it, and the lines a work record
/// carries because of it. Plus the two rules a received vault must not escape: PR1's
/// manuals-never-leave-the-phone export, and "a failure installs nothing".
@MainActor
final class VaultReceivedInstallTests: XCTestCase {

    private static let vaultId = "acme_rtu"
    /// A token that exists only inside the fixture manual, so "the manual is not in the export" is
    /// asserted on the manual's own content rather than on a word a query might share.
    private static let manualOnlyToken = "QZ7731"

    private var previousEntitlement: FieldAssistEntitlementProvider!

    override func setUp() {
        super.setUp()
        previousEntitlement = FieldAssistEntitlement.shared.provider
        FieldAssistEntitlement.shared.provider = StubEntitlementProvider.subscriber()
        VaultRegistry.shared.resetCache()
    }

    override func tearDown() {
        EntitlementTestScope.restore(previousEntitlement)
        VaultImporter.uninstall(id: Self.vaultId)
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        super.tearDown()
    }

    private func receipt(verification: VaultReceipt.Verification = .unverified,
                         publisher: (id: String, name: String)? = nil) -> VaultReceipt {
        VaultReceipt(publisherId: publisher?.id, publisherName: publisher?.name,
                     verification: verification, sourceHost: "manuals.example.com",
                     receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
                     archiveSHA256: "abc123")
    }

    private func files(version: String = "1.0.0",
                       manualText: String = "Fault \(VaultReceivedInstallTests.manualOnlyToken) is logged when the inducer stalls.",
                       core: String = "# Fault codes\n\nQZ7731 — inducer stalled.") -> [String: Data] {
        let manifest = VaultManifest(
            id: Self.vaultId, name: "Acme RTU Service", version: version,
            files: ["fault-codes.md"], documentsDir: "documents",
            documents: [VaultDocument(file: "manual.txt", title: "RTU-500 Service Manual")],
            promptRules: ["Never fabricate a value.", "Cite the source file."])
        return [
            "manifest.json": (try? JSONEncoder().encode(manifest)) ?? Data(),
            "fault-codes.md": Data(core.utf8),
            "documents/manual.txt": Data(manualText.utf8),
        ]
    }

    // MARK: - The receipt

    func testAnInstallFromALinkIsMarkedReceived() async throws {
        let outcome = try await VaultLinkInstaller.install(
            .init(files: files(), receipt: receipt(verification: .signed,
                                                   publisher: ("acme", "Acme Manuals"))))
        XCTAssertEqual(outcome.vaultId, Self.vaultId)

        let stored = try XCTUnwrap(VaultImporter.receipt(for: Self.vaultId))
        XCTAssertEqual(stored.verification, .signed)
        XCTAssertEqual(stored.publisherName, "Acme Manuals")
        XCTAssertEqual(stored.sourceHost, "manuals.example.com")
        // The sidecar sits beside the pack record and is read by the same pattern.
        XCTAssertNil(VaultImporter.installedPack(for: Self.vaultId))
        XCTAssertTrue(VaultImporter.installedManifests().contains { $0.id == Self.vaultId })
    }

    func testTheReceiptCarriesTheHostAndNotTheLink() async throws {
        _ = try await VaultLinkInstaller.install(.init(files: files(), receipt: receipt()))
        let url = VaultImporter.baselineDirectory(for: Self.vaultId)
            .appendingPathComponent(VaultReceipt.filename)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("manuals.example.com"))
        XCTAssertFalse(text.contains("https://"), "the sidecar never stores the link")
        XCTAssertFalse(text.contains("ZZ9PLURAL"))
    }

    func testAnUnverifiedInstallIsBadgedAndASignedOneIsNot() async throws {
        _ = try await VaultLinkInstaller.install(.init(files: files(), receipt: receipt()))
        XCTAssertEqual(VaultSourceBadge.resolve(receipt: VaultImporter.receipt(for: Self.vaultId),
                                                publishers: []),
                       .unverifiedSource)

        _ = try await VaultLinkInstaller.install(
            .init(files: files(version: "1.1.0"),
                  receipt: receipt(verification: .signed, publisher: ("acme", "Acme Manuals"))))
        XCTAssertNil(VaultSourceBadge.resolve(receipt: VaultImporter.receipt(for: Self.vaultId),
                                              publishers: [VaultPublisher(id: "acme",
                                                                          name: "Acme Manuals",
                                                                          publicKey: "AAAA")]))
    }

    // MARK: - Update in place

    func testTheSameIdUpdatesInPlaceAndKeepsTheReadersEdits() async throws {
        _ = try await VaultLinkInstaller.install(.init(files: files(version: "1.0.0"),
                                                       receipt: receipt()))
        // A technician's edit lives in the overlay, which an update must not touch.
        let overlay = VaultImporter.overlayDirectory(for: Self.vaultId)
        try FileManager.default.createDirectory(at: overlay, withIntermediateDirectories: true)
        try "# Fault codes\n\nQZ7731 — and check the pressure switch first."
            .write(to: overlay.appendingPathComponent("fault-codes.md"), atomically: true,
                   encoding: .utf8)

        _ = try await VaultLinkInstaller.install(
            .init(files: files(version: "2.0.0", core: "# Fault codes\n\nPublisher's newer text."),
                  receipt: receipt(verification: .signed, publisher: ("acme", "Acme Manuals"))))

        let installed = try XCTUnwrap(VaultImporter.installedManifests().first { $0.id == Self.vaultId })
        XCTAssertEqual(installed.version, "2.0.0")
        let edit = try String(contentsOf: overlay.appendingPathComponent("fault-codes.md"),
                              encoding: .utf8)
        XCTAssertTrue(edit.contains("check the pressure switch first"),
                      "an update replaces the baseline and leaves the overlay alone")
        XCTAssertEqual(VaultImporter.receipt(for: Self.vaultId)?.verification, .signed,
                       "the receipt describes the archive that is installed now")
    }

    // MARK: - Nothing half-installed

    func testARefusedArchiveInstallsNothingAndLeavesNoReceipt() async {
        // A manifest with no prompt rules fails the validator, which is the last gate before the
        // baseline is written.
        let manifest = VaultManifest(id: Self.vaultId, name: "Acme RTU Service", version: "1.0.0",
                                     files: ["fault-codes.md"])
        let bad: [String: Data] = [
            "manifest.json": (try? JSONEncoder().encode(manifest)) ?? Data(),
            "fault-codes.md": Data("# Codes".utf8),
        ]
        do {
            _ = try await VaultLinkInstaller.install(.init(files: bad, receipt: receipt()))
            XCTFail("a vault with no grounding rules must not install")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: VaultImporter.baselineDirectory(for: Self.vaultId).path),
                           "a refused install leaves no baseline")
            XCTAssertNil(VaultImporter.receipt(for: Self.vaultId))
            XCTAssertFalse(VaultImporter.installedManifests().contains { $0.id == Self.vaultId })
        }
    }

    func testAPathThatEscapesTheVaultRootIsRefusedAtInstall() async {
        var escaping = files()
        escaping["../../evil.md"] = Data("no".utf8)
        do {
            _ = try await VaultLinkInstaller.install(.init(files: escaping, receipt: receipt()))
            XCTFail("a path outside the vault must be refused")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: VaultImporter.baselineDirectory(for: Self.vaultId).path))
        }
    }

    // MARK: - PR1's rule still holds for a received vault

    func testExportingAReceivedVaultStillLeavesTheManualsBehind() async throws {
        _ = try await VaultLinkInstaller.install(.init(files: files(), receipt: receipt()))
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()

        let exported = try VaultExporter.export(id: Self.vaultId)
        defer { try? FileManager.default.removeItem(at: exported.deletingLastPathComponent()) }

        let written = (FileManager.default.enumerator(at: exported, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? [])
        for url in written {
            let bytes = (try? Data(contentsOf: url)) ?? Data()
            let text = String(data: bytes, encoding: .utf8) ?? ""
            XCTAssertFalse(text.contains(Self.manualOnlyToken) && url.lastPathComponent == "manual.txt",
                           "the manual travelled in an export of a received vault")
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: exported.appendingPathComponent("documents/manual.txt").path),
                       "a received vault's export carries no manuals either")

        // …and the manifest still says the vault needs them.
        let manifestData = try Data(contentsOf: exported.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(VaultManifest.self, from: manifestData)
        XCTAssertEqual(manifest.documents.map(\.title), ["RTU-500 Service Manual"])
        XCTAssertFalse(manifest.documentsIncluded)
    }

    // MARK: - The work record

    func testTheWorkRecordCarriesTheUnverifiedSourceLine() throws {
        let session = FieldSession(
            id: "s1", vaultId: Self.vaultId, assetId: nil, mode: .aiOnly,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000), endedAt: nil, pausedAt: nil,
            resumedAt: nil, outcome: .inProgress, startLocation: nil, endLocation: nil,
            escalations: [], billableSeconds: 0)
        let note = VaultSourceBadge.unverifiedSource.recordLine(vaultName: "Acme RTU Service")
        let record = WorkRecord(session: session, vaultName: "Acme RTU Service", vaultSourceNote: note)

        XCTAssertEqual(record.summaryLines[1], "Reference vault: Acme RTU Service — unverified source.")

        // …and in the machine-readable record, under its own key.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(data: try encoder.encode(record), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"vault_source_note\""))
        XCTAssertTrue(json.contains("unverified source"))

        // A record from a vault that did not come from a link says nothing at all.
        let plain = WorkRecord(session: session, vaultName: "Acme RTU Service")
        XCTAssertFalse(plain.summaryLines.contains { $0.contains("unverified source") })
        let plainJSON = String(data: try encoder.encode(plain), encoding: .utf8) ?? ""
        XCTAssertFalse(plainJSON.contains("vault_source_note"))
    }

    func testAnOlderRecordWithoutTheKeyStillDecodes() throws {
        let session = FieldSession(
            id: "s1", vaultId: Self.vaultId, assetId: nil, mode: .aiOnly,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000), endedAt: nil, pausedAt: nil,
            resumedAt: nil, outcome: .inProgress, startLocation: nil, endLocation: nil,
            escalations: [], billableSeconds: 0)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: encoder.encode(WorkRecord(session: session, vaultName: "A"))) as? [String: Any])
        object.removeValue(forKey: "vault_source_note")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WorkRecord.self,
                                         from: try JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.vaultSourceNote)
    }
}
