import XCTest
@testable import OpenGlasses

/// Plan Q, Slice 2: `VaultExporter` round-trips through `VaultImporter`, captures overlay edits, and
/// refuses to export a paid bundled baseline (licensing gate).
@MainActor
final class VaultExportTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultExportTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        VaultImporter.uninstall(id: "custom_test")
        VaultRegistry.shared.reloadUserManifests()
        super.tearDown()
    }

    private func writeVault(id: String) -> URL {
        let dir = tempRoot.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = VaultManifest(id: id, name: "Custom Test", version: "1.0.0",
                                     files: ["info.md"], proceduresDir: nil,
                                     gating: .init(iap: "enterprise"),
                                     promptRules: ["Never fabricate data.", "Always cite the source file."])
        try? JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        try? "# Info\n\nShipped content.".write(to: dir.appendingPathComponent("info.md"), atomically: true, encoding: .utf8)
        return dir
    }

    func testExportCapturesOverlayEditsAndReimports() throws {
        try VaultImporter.install(from: writeVault(id: "custom_test"))
        VaultRegistry.shared.reloadUserManifests()

        // A tech edits a reference file — lands in the overlay.
        let store = try XCTUnwrap(VaultRegistry.shared.store(forId: "custom_test"))
        try store.write("info.md", contents: "# Info\n\nEDITED on device.")

        // Export reflects the edit and is import-valid.
        let exported = try VaultExporter.export(id: "custom_test")
        let exportedInfo = try String(contentsOf: exported.appendingPathComponent("info.md"), encoding: .utf8)
        XCTAssertTrue(exportedInfo.contains("EDITED on device."))
        XCTAssertTrue(VaultValidator.validate(directory: exported).isValid)

        // Full round-trip back through the importer.
        let reimported = try VaultImporter.install(from: exported)
        XCTAssertEqual(reimported.id, "custom_test")
    }

    func testExportabilityRespectsLicensing() throws {
        // Paid bundled baseline — never exportable.
        let refrigeration = try XCTUnwrap(VaultRegistry.shared.manifest(id: "refrigeration"))
        XCTAssertFalse(VaultExporter.isExportable(refrigeration))

        // Free bundled vault — exportable.
        let notes = try XCTUnwrap(VaultRegistry.shared.manifest(id: "notes"))
        XCTAssertTrue(VaultExporter.isExportable(notes))

        // User-imported vault — exportable.
        try VaultImporter.install(from: writeVault(id: "custom_test"))
        VaultRegistry.shared.reloadUserManifests()
        let custom = try XCTUnwrap(VaultRegistry.shared.manifest(id: "custom_test"))
        XCTAssertTrue(VaultExporter.isExportable(custom))
    }

    func testExportRejectsPaidBundledVault() {
        XCTAssertThrowsError(try VaultExporter.export(id: "refrigeration")) { error in
            guard case VaultExporter.ExportError.notExportable = error else {
                return XCTFail("Expected .notExportable, got \(error)")
            }
        }
    }
}
