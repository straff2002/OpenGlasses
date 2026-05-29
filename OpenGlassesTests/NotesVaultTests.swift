import XCTest
@testable import OpenGlasses

/// Tests the Personal Notes vault: registration, free unlock, bundled templates, and log/query.
@MainActor
final class NotesVaultTests: XCTestCase {

    override func setUp() {
        super.setUp()
        VaultRegistry.shared.resetCache()
        // Clear any overlay notes from prior runs so query/log start clean.
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        try? FileManager.default.removeItem(at: docs.appendingPathComponent("Vaults/notes"))
        VaultRegistry.shared.resetCache()
    }

    func testNotesVaultRegisteredAndFree() throws {
        let manifest = try XCTUnwrap(VaultRegistry.shared.manifest(id: "notes"))
        XCTAssertNil(manifest.gating.iap, "Notes vault should be free")
        XCTAssertTrue(VaultRegistry.shared.isUnlocked("notes"))
        XCTAssertEqual(Set(manifest.files), ["general.md", "people.md", "ideas.md", "todos.md"])
    }

    func testBundledTemplatesLoad() throws {
        let store = try XCTUnwrap(VaultRegistry.shared.store(forId: "notes"))
        XCTAssertEqual(store.readAll().count, 4)
    }

    func testLogThenQueryRecallsTheNote() async throws {
        let tool = NotesVaultTool()
        let logResult = try await tool.execute(args: ["action": "log", "file": "ideas", "entry": "build a parking-spot logger"])
        XCTAssertTrue(logResult.lowercased().contains("noted"), logResult)

        let queryResult = try await tool.execute(args: ["action": "query", "question": "parking"])
        XCTAssertTrue(queryResult.contains("parking-spot logger"), queryResult)
        XCTAssertTrue(queryResult.contains("ideas.md"))
    }

    func testLogDefaultsToGeneralFile() async throws {
        let tool = NotesVaultTool()
        let result = try await tool.execute(args: ["action": "log", "entry": "remember the gate code is 4821"])
        XCTAssertTrue(result.lowercased().contains("general"), result)
    }

    func testQueryWithNoMatchIsHonest() async throws {
        let tool = NotesVaultTool()
        let result = try await tool.execute(args: ["action": "query", "question": "nonexistent topic xyzzy"])
        XCTAssertTrue(result.lowercased().contains("don't have") || result.lowercased().contains("add one"), result)
    }
}
