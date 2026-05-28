import XCTest
@testable import OpenGlasses

/// Tests for the Personal Health Vault (Plan B): manifest registration, bundled templates,
/// the locked-path of the tool, and the append/search foundation it relies on.
@MainActor
final class HealthVaultTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        VaultRegistry.shared.resetCache()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthVaultTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    func testHealthManifestRegistered() throws {
        let manifest = try XCTUnwrap(VaultRegistry.shared.manifest(id: "health"))
        XCTAssertEqual(manifest.gating.iap, "medical_compliance")
        XCTAssertEqual(Set(manifest.files), [
            "biometrics.md", "conditions.md", "dietary_context.md",
            "lab_baselines.md", "medications.md", "wearables.md"
        ])
        XCTAssertTrue(manifest.sourceAttributionRequired)
    }

    func testBundledTemplatesLoad() throws {
        let store = try XCTUnwrap(VaultRegistry.shared.store(forId: "health"))
        let files = store.readAll()
        XCTAssertEqual(files.count, 6, "All six health templates should ship and be non-empty")
        let medications = try XCTUnwrap(store.read("medications.md"))
        XCTAssertTrue(medications.contains("Medications"))
    }

    func testToolReportsLockedWhenComplianceInactive() async throws {
        // In tests StoreKit has no active subscription, so the vault is locked.
        let result = try await HealthVaultTool().execute(args: ["action": "query", "question": "what meds am I on"])
        XCTAssertTrue(result.lowercased().contains("locked"), "Got: \(result)")
    }

    func testAppendAndSearchFoundation() throws {
        // Exercises the VaultStore append/read the tool's log+query are built on, without StoreKit.
        let manifest = VaultManifest(id: "health_test", name: "Health Test", version: "1.0.0",
                                     files: ["medications.md"], proceduresDir: nil)
        let store = VaultStore(manifest: manifest, bundleRoot: nil, overlayRoot: tempRoot)
        try store.append("medications.md", entry: "Started Metformin 500mg")

        let all = store.readAll()
        XCTAssertEqual(all.first?.filename, "medications.md")
        XCTAssertTrue(all.first?.contents.contains("Metformin") ?? false)
    }
}
