import XCTest
@testable import OpenGlasses

/// Tests for the generic vault foundation: manifest decoding, file I/O with bundle/overlay merge,
/// append behavior, and prompt-context assembly.
final class VaultStoreTests: XCTestCase {

    private var tempRoot: URL!
    private var manifest: VaultManifest!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        manifest = VaultManifest(
            id: "test_vault",
            name: "Test Vault",
            version: "1.0.0",
            files: ["a.md", "b.md", "c.md"],
            proceduresDir: nil,
            gating: .init(iap: nil),
            promptRules: ["Cite sources.", "No fabrication."],
            sourceAttributionFormat: "Source: {files}",
            sourceAttributionRequired: true
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    // MARK: - Manifest decoding

    func testManifestDecodesFromJSON() throws {
        let json = """
        {
          "id": "refrigeration",
          "name": "Refrigeration",
          "version": "1.0.0",
          "files": ["error_codes.md", "pt_charts.md"],
          "procedures_dir": "procedures",
          "gating": { "iap": "field_assist_refrigeration" },
          "prompt_rules": ["Never fabricate."],
          "source_attribution_format": "Source: {files}",
          "source_attribution_required": true
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(VaultManifest.self, from: json)
        XCTAssertEqual(decoded.id, "refrigeration")
        XCTAssertEqual(decoded.files, ["error_codes.md", "pt_charts.md"])
        XCTAssertEqual(decoded.gating.iap, "field_assist_refrigeration")
        XCTAssertTrue(decoded.sourceAttributionRequired)
        XCTAssertEqual(decoded.promptRules, ["Never fabricate."])
    }

    func testManifestSurvivesRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(manifest)
        let decoded = try JSONDecoder().decode(VaultManifest.self, from: data)
        XCTAssertEqual(decoded, manifest)
    }

    // MARK: - VaultStore I/O

    func testWriteAndReadRoundTrip() throws {
        let store = VaultStore(manifest: manifest, bundleRoot: nil, overlayRoot: tempRoot)
        try store.write("a.md", contents: "hello")
        XCTAssertEqual(store.read("a.md"), "hello")
    }

    func testReadReturnsNilWhenMissing() {
        let store = VaultStore(manifest: manifest, bundleRoot: nil, overlayRoot: tempRoot)
        XCTAssertNil(store.read("a.md"))
    }

    func testReadAllSkipsEmptyAndMissingFiles() throws {
        let store = VaultStore(manifest: manifest, bundleRoot: nil, overlayRoot: tempRoot)
        try store.write("a.md", contents: "alpha")
        try store.write("b.md", contents: "   \n  ")  // whitespace-only — skipped
        // c.md missing — skipped

        let all = store.readAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.filename, "a.md")
        XCTAssertEqual(all.first?.contents, "alpha")
    }

    func testHasContentDetectsAnyNonEmptyFile() throws {
        let store = VaultStore(manifest: manifest, bundleRoot: nil, overlayRoot: tempRoot)
        XCTAssertFalse(store.hasContent)
        try store.write("c.md", contents: "content")
        XCTAssertTrue(store.hasContent)
    }

    func testOverlayOverridesBundle() throws {
        // Build a fake bundle dir with one file, then overlay a different one.
        let bundleDir = tempRoot.appendingPathComponent("bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        try "bundled content".write(to: bundleDir.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)

        let overlayDir = tempRoot.appendingPathComponent("overlay", isDirectory: true)
        let store = VaultStore(manifest: manifest, bundleRoot: bundleDir, overlayRoot: overlayDir)

        // Initially returns bundle content
        XCTAssertEqual(store.read("a.md"), "bundled content")

        // After overlay write, overlay wins
        try store.write("a.md", contents: "user override")
        XCTAssertEqual(store.read("a.md"), "user override")
    }

    func testAppendAddsTimestampedEntry() throws {
        let store = VaultStore(manifest: manifest, bundleRoot: nil, overlayRoot: tempRoot)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try store.append("a.md", entry: "First entry", date: date)
        try store.append("a.md", entry: "Second entry", date: date.addingTimeInterval(60))

        let contents = store.read("a.md") ?? ""
        XCTAssertTrue(contents.contains("First entry"))
        XCTAssertTrue(contents.contains("Second entry"))
        XCTAssertTrue(contents.contains("## "))  // ISO date heading
    }

    // MARK: - VaultPromptBuilder

    func testPromptBuilderReturnsNilForEmptyVault() {
        let store = VaultStore(manifest: manifest, bundleRoot: nil, overlayRoot: tempRoot)
        XCTAssertNil(VaultPromptBuilder.promptContext(for: store))
    }

    func testPromptBuilderIncludesRulesAndContent() throws {
        let store = VaultStore(manifest: manifest, bundleRoot: nil, overlayRoot: tempRoot)
        try store.write("a.md", contents: "alpha content")
        try store.write("b.md", contents: "beta content")

        let prompt = VaultPromptBuilder.promptContext(for: store) ?? ""
        XCTAssertTrue(prompt.contains("KNOWLEDGE VAULT — Test Vault"))
        XCTAssertTrue(prompt.contains("Cite sources."))
        XCTAssertTrue(prompt.contains("No fabrication."))
        XCTAssertTrue(prompt.contains("alpha content"))
        XCTAssertTrue(prompt.contains("beta content"))
        XCTAssertTrue(prompt.contains("=== a.md ==="))
        XCTAssertTrue(prompt.contains("=== b.md ==="))
        XCTAssertTrue(prompt.contains("Source: {files}"))
        XCTAssertTrue(prompt.contains("REQUIRED"))
    }

    func testPromptBuilderOmitsSourceLineWhenOptional() throws {
        var optionalManifest = manifest!
        optionalManifest = VaultManifest(
            id: optionalManifest.id,
            name: optionalManifest.name,
            version: optionalManifest.version,
            files: optionalManifest.files,
            sourceAttributionFormat: nil,
            sourceAttributionRequired: false
        )
        let store = VaultStore(manifest: optionalManifest, bundleRoot: nil, overlayRoot: tempRoot)
        try store.write("a.md", contents: "alpha")

        let prompt = VaultPromptBuilder.promptContext(for: store) ?? ""
        XCTAssertFalse(prompt.contains("REQUIRED"))
        XCTAssertFalse(prompt.contains("Source: {files}"))
    }
}
