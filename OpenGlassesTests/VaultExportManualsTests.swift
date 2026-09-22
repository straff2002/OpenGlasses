import UIKit
import XCTest
@testable import OpenGlasses

/// Plan FS PR1 — manuals never leave the phone through the app. What a vault export writes, what
/// its manifest claims, and what happens when that folder is imported somewhere else.
@MainActor
final class VaultExportManualsTests: XCTestCase {

    private static let vaultId = "export_manuals_test"
    /// A token that exists only inside the fixture manual, so "the manuals are not in the export"
    /// is asserted on the manual's own content rather than on a word a query might share.
    private static let manualOnlyToken = "QZ7731"
    private static let manualText = "Fault \(manualOnlyToken) is logged when the inducer stalls."

    private var tempRoot: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!

    override func setUp() {
        super.setUp()
        previousEntitlement = FieldAssistEntitlement.shared.provider
        FieldAssistEntitlement.shared.provider = StubEntitlementProvider.subscriber()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultExportManualsTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        EntitlementTestScope.restore(previousEntitlement)
        VaultImporter.uninstall(id: Self.vaultId)
        VaultRegistry.shared.reloadUserManifests()
        VaultRegistry.shared.resetCache()
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    /// A vault with one manual, the manufacturer's original PDF beside it, and a core file.
    private func writeVault(named name: String = "source") -> URL {
        let dir = tempRoot.appendingPathComponent(name, isDirectory: true)
        let documents = dir.appendingPathComponent("documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let manual = VaultDocument(file: "manual.txt", title: "RTU-500 Service Manual",
                                   kind: "service_manual", source: "manual.pdf",
                                   sourceUrl: "https://example.com/manual.pdf")
        let manifest = VaultManifest(id: Self.vaultId, name: "Export Manuals Test", version: "1.0.0",
                                     files: ["info.md"], documentsDir: "documents", documents: [manual],
                                     promptRules: ["Never fabricate a value.", "Cite the source file."])
        try? JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        try? "# Info\n\nShipped content.".write(to: dir.appendingPathComponent("info.md"),
                                                atomically: true, encoding: .utf8)
        try? Self.manualText.write(to: documents.appendingPathComponent("manual.txt"),
                                   atomically: true, encoding: .utf8)
        try? Self.pdfBytes().write(to: documents.appendingPathComponent("manual.pdf"))
        return dir
    }

    /// The smallest thing PDFKit will open, so the validator's original-PDF check has a real file.
    private static func pdfBytes() -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 200))
        return renderer.pdfData { context in
            context.beginPage()
            (manualText as NSString).draw(at: CGPoint(x: 10, y: 10),
                                          withAttributes: [.font: UIFont.systemFont(ofSize: 12)])
        }
    }

    private func everyFile(under root: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    private func install() throws -> VaultManifest {
        let manifest = try VaultImporter.install(from: writeVault())
        VaultRegistry.shared.reloadUserManifests()
        return manifest
    }

    // MARK: - What the export writes

    func testExportCarriesNoManualTextOriginalOrAnythingDerivedFromThem() throws {
        let manifest = try install()
        // A technician's edit to a core file, to prove the export is still the effective content.
        let store = try XCTUnwrap(VaultRegistry.shared.store(forId: Self.vaultId))
        try store.write("info.md", contents: "# Info\n\nEDITED on device.")

        let exported = try VaultExporter.export(id: manifest.id)
        let files = everyFile(under: exported)
        let names = Set(files.map(\.lastPathComponent))
        XCTAssertEqual(names, ["manifest.json", "info.md"],
                       "an export is the manifest and the core files, nothing else: \(names)")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: exported.appendingPathComponent("documents").path), "no documents/ directory at all")

        // Nothing anywhere in the folder carries the manual's own content.
        for file in files {
            let data = try Data(contentsOf: file)
            let text = String(data: data, encoding: .utf8) ?? ""
            XCTAssertFalse(text.contains(Self.manualOnlyToken),
                           "\(file.lastPathComponent) carries manual content")
            XCTAssertFalse(data.starts(with: Data("%PDF".utf8)), "\(file.lastPathComponent) is a PDF")
        }
        XCTAssertTrue(try String(contentsOf: exported.appendingPathComponent("info.md"), encoding: .utf8)
            .contains("EDITED on device."), "the reader's overlay edits survive the export")
    }

    func testTheExportedManifestStillRequiresTheManualsAndSaysTheyAreNotIncluded() throws {
        _ = try install()
        let exported = try VaultExporter.export(id: Self.vaultId)
        let manifest = try JSONDecoder().decode(
            VaultManifest.self, from: Data(contentsOf: exported.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.documents.map(\.file), ["manual.txt"], "the manual is still required")
        XCTAssertEqual(manifest.documents.first?.title, "RTU-500 Service Manual")
        XCTAssertEqual(manifest.documents.first?.source, "manual.pdf", "and so is its original")
        XCTAssertEqual(manifest.documents.first?.sourceUrl, "https://example.com/manual.pdf",
                       "the link that says where to get it is not a manual and stays")
        XCTAssertFalse(manifest.documentsIncluded)

        // The marker is a manifest key an older build simply does not know, so its absence still
        // reads as "included" and no already-exported folder changes meaning.
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(contentsOf: exported.appendingPathComponent("manifest.json"))) as? [String: Any])
        XCTAssertEqual(json["documents_included"] as? Bool, false)
        var without = json
        without.removeValue(forKey: "documents_included")
        let legacy = try JSONDecoder().decode(
            VaultManifest.self, from: try JSONSerialization.data(withJSONObject: without))
        XCTAssertTrue(legacy.documentsIncluded, "a manifest without the key reads exactly as it did")
    }

    func testAMarkdownOnlyVaultExportsUnchanged() throws {
        let dir = tempRoot.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = VaultManifest(id: Self.vaultId, name: "Plain", version: "1.0.0", files: ["info.md"],
                                     promptRules: ["Never fabricate.", "Cite the source."])
        try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        try "# Info\n\nPlain.".write(to: dir.appendingPathComponent("info.md"), atomically: true, encoding: .utf8)
        _ = try VaultImporter.install(from: dir)
        VaultRegistry.shared.reloadUserManifests()

        let exported = try VaultExporter.export(id: Self.vaultId)
        let decoded = try JSONDecoder().decode(
            VaultManifest.self, from: Data(contentsOf: exported.appendingPathComponent("manifest.json")))
        XCTAssertTrue(decoded.documentsIncluded, "there are no manuals to leave out")
        XCTAssertTrue(VaultValidator.validate(directory: exported).isValid)
        XCTAssertEqual(try VaultImporter.install(from: exported).id, Self.vaultId)
    }

    // MARK: - What happens when that folder is imported

    func testImportingAnExportAsksForTheManualsInsteadOfInstallingAVaultWithoutThem() throws {
        _ = try install()
        let exported = try VaultExporter.export(id: Self.vaultId)

        let validated = VaultValidator.validate(directory: exported)
        XCTAssertFalse(validated.isValid, "a vault that claims manuals it has not got must not install")
        let issue = try XCTUnwrap(validated.issues.first { $0.contains("manual.txt") })
        XCTAssertTrue(issue.contains("not included in this export"), issue)
        XCTAssertTrue(issue.contains("RTU-500 Service Manual"), "the message names the manual to supply: \(issue)")

        XCTAssertThrowsError(try VaultImporter.install(from: exported)) { error in
            guard case VaultImporter.ImportError.invalid(let issues) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(issues.contains { $0.contains("RTU-500 Service Manual") }, "\(issues)")
        }
    }

    func testSupplyingTheManualsMakesTheExportImportAndTheInstalledVaultSaysSo() throws {
        _ = try install()
        let exported = try VaultExporter.export(id: Self.vaultId)

        // Whoever received the folder puts the manuals back beside it, as the message asked.
        let documents = exported.appendingPathComponent("documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try Self.manualText.write(to: documents.appendingPathComponent("manual.txt"),
                                  atomically: true, encoding: .utf8)
        try Self.pdfBytes().write(to: documents.appendingPathComponent("manual.pdf"))

        XCTAssertTrue(VaultValidator.validate(directory: exported).isValid)
        let installed = try VaultImporter.install(from: exported)
        XCTAssertTrue(installed.documentsIncluded, "an installed vault always has the manuals it lists")
        VaultRegistry.shared.reloadUserManifests()
        let reloaded = try XCTUnwrap(VaultImporter.installedManifests().first { $0.id == Self.vaultId })
        XCTAssertTrue(reloaded.documentsIncluded, "and the recorded manifest says so too")
        XCTAssertEqual(reloaded.documents.map(\.file), ["manual.txt"])
    }
}
