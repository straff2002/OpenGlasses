import XCTest
@testable import OpenGlasses

/// Admin-pushed vaults install a read-only baseline; technician edits live in a separate overlay that
/// merges over it. Editing never mutates the baseline, and re-pushing a new baseline preserves the
/// technician's overlay edits.
@MainActor
final class VaultBaselineOverlayTests: XCTestCase {

    private let vaultId = "baseline_test"
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultBaselineTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        VaultImporter.uninstall(id: vaultId)
        VaultRegistry.shared.reloadUserManifests()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        VaultImporter.uninstall(id: vaultId)
        VaultRegistry.shared.reloadUserManifests()
        super.tearDown()
    }

    /// Write a source vault directory with the given files (name → contents).
    private func makeSource(_ files: [String: String]) -> URL {
        let dir = tempRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = VaultManifest(id: vaultId, name: "Baseline Test", version: "1.0.0",
                                     files: Array(files.keys).sorted(), proceduresDir: nil,
                                     gating: .init(iap: "enterprise"),
                                     promptRules: ["Never fabricate data.", "Always cite the source file."])
        try? JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        for (name, contents) in files {
            try? contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return dir
    }

    private func freshStore() -> VaultStore {
        VaultRegistry.shared.reloadUserManifests()   // clears the store cache
        return VaultRegistry.shared.store(forId: vaultId)!
    }

    func testEditingDoesNotMutateBaseline() throws {
        try VaultImporter.install(from: makeSource(["info.md": "ADMIN baseline content."]))
        let store = freshStore()
        try store.write("info.md", contents: "TECH edited content.")

        // Overlay wins for reads…
        XCTAssertEqual(freshStore().read("info.md"), "TECH edited content.")
        // …but the pushed baseline file on disk is untouched.
        let baselineFile = VaultImporter.baselineDirectory(for: vaultId).appendingPathComponent("info.md")
        XCTAssertEqual(try String(contentsOf: baselineFile, encoding: .utf8), "ADMIN baseline content.")
    }

    func testRepushUpdatesBaselineButPreservesOverlayEdits() throws {
        // v1 baseline, then a technician edits info.md.
        try VaultImporter.install(from: makeSource([
            "info.md": "v1 info.",
            "codes.md": "v1 codes."
        ]))
        try freshStore().write("info.md", contents: "TECH note on info.")

        // Admin re-pushes v2: changes both files and adds a new one.
        try VaultImporter.install(from: makeSource([
            "info.md": "v2 info.",
            "codes.md": "v2 codes.",
            "extra.md": "v2 extra."
        ]))

        let store = freshStore()
        // Edited file: overlay edit survives the re-push.
        XCTAssertEqual(store.read("info.md"), "TECH note on info.")
        // Unedited file: picks up the new baseline.
        XCTAssertEqual(store.read("codes.md"), "v2 codes.")
        // New file from v2 is available.
        XCTAssertEqual(store.read("extra.md"), "v2 extra.")
    }

    func testUninstallRemovesBaselineAndOverlay() throws {
        try VaultImporter.install(from: makeSource(["info.md": "content."]))
        try freshStore().write("info.md", contents: "edit.")

        VaultImporter.uninstall(id: vaultId)
        XCTAssertFalse(FileManager.default.fileExists(atPath: VaultImporter.baselineDirectory(for: vaultId).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: VaultImporter.overlayDirectory(for: vaultId).path))
        XCTAssertNil(VaultImporter.installedManifests().first { $0.id == vaultId })
    }
}
