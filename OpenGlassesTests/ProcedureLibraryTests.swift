import XCTest
@testable import OpenGlasses

/// Tests for Procedure JSON decoding and ProcedureLibrary loading from a vault store overlay.
final class ProcedureLibraryTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcedureLibraryTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    private let sampleJSON = """
    {
      "id": "sample_diag",
      "title": "Sample Diagnostic",
      "version": "1.0.0",
      "vault": "refrigeration",
      "safety_notes": ["Wear PPE."],
      "entry_step": "first",
      "steps": [
        {
          "id": "first",
          "title": "First step",
          "instruction": "Do the thing.",
          "expected_input": "a reading",
          "citations": ["pt_charts.md"],
          "branches": [
            { "id": "ok", "condition": "reading is normal", "next": "done" }
          ],
          "default_next": "done"
        },
        {
          "id": "done",
          "title": "Done",
          "instruction": "Finished.",
          "terminal": true,
          "outcome": "resolved"
        }
      ]
    }
    """

    // MARK: - Decoding

    func testDecodesSnakeCaseSchema() throws {
        let procedure = try JSONDecoder().decode(Procedure.self, from: Data(sampleJSON.utf8))
        XCTAssertEqual(procedure.id, "sample_diag")
        XCTAssertEqual(procedure.entryStep, "first")
        XCTAssertEqual(procedure.safetyNotes, ["Wear PPE."])
        XCTAssertEqual(procedure.steps.count, 2)

        let first = try XCTUnwrap(procedure.step(id: "first"))
        XCTAssertEqual(first.expectedInput, "a reading")
        XCTAssertEqual(first.citations, ["pt_charts.md"])
        XCTAssertEqual(first.defaultNext, "done")
        XCTAssertEqual(first.branches.first?.id, "ok")
        XCTAssertEqual(first.branches.first?.next, "done")
        XCTAssertFalse(first.terminal)

        let done = try XCTUnwrap(procedure.step(id: "done"))
        XCTAssertTrue(done.terminal)
        XCTAssertEqual(done.outcome, "resolved")
    }

    func testEntryFallsBackToFirstStepWhenUnset() {
        let procedure = Procedure(
            id: "p", title: "P", version: "1.0.0",
            steps: [.init(id: "only", title: "Only", instruction: "x")]
        )
        XCTAssertEqual(procedure.entry?.id, "only")
    }

    // MARK: - Loading from a vault store

    private func makeStore() -> VaultStore {
        let manifest = VaultManifest(
            id: "refrigeration", name: "Refrigeration Service", version: "1.0.0",
            files: [], proceduresDir: "procedures"
        )
        // bundleRoot nil → overlay-only; matches how user-uploaded procedures would load.
        return VaultStore(manifest: manifest, bundleRoot: nil, overlayRoot: tempRoot)
    }

    func testLoadsProceduresFromOverlayDirectory() throws {
        let proceduresDir = tempRoot.appendingPathComponent("procedures", isDirectory: true)
        try FileManager.default.createDirectory(at: proceduresDir, withIntermediateDirectories: true)
        try Data(sampleJSON.utf8).write(to: proceduresDir.appendingPathComponent("sample.json"))

        let library = ProcedureLibrary(store: makeStore())
        XCTAssertFalse(library.isEmpty)
        XCTAssertNotNil(library.procedure(id: "sample_diag"))
        XCTAssertEqual(library.summaries(), ["sample_diag — Sample Diagnostic"])
    }

    func testEmptyWhenNoProceduresDirectoryExists() {
        let library = ProcedureLibrary(store: makeStore())
        XCTAssertTrue(library.isEmpty)
    }

    func testIgnoresNonJSONFiles() throws {
        let proceduresDir = tempRoot.appendingPathComponent("procedures", isDirectory: true)
        try FileManager.default.createDirectory(at: proceduresDir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: proceduresDir.appendingPathComponent("readme.txt"))
        try Data(sampleJSON.utf8).write(to: proceduresDir.appendingPathComponent("sample.json"))

        let library = ProcedureLibrary(store: makeStore())
        XCTAssertEqual(library.all.count, 1)
    }
}
