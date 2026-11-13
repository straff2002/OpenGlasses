import XCTest
import CryptoKit
@testable import OpenGlasses

/// Face recognition was removed on 2026-11-13. What it left on an existing install — the sealed
/// template file, its scoped key and its preferences — is erased once at launch, retried while it
/// cannot finish, and erased again if the file ever comes back. Every case runs against its own
/// defaults suite, a temporary folder and an in-memory key store: never the wearer's own.
final class RetiredFaceDataCleanupTests: XCTestCase {

    private typealias Cleanup = RetiredFaceDataCleanup

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var workspace: URL!
    private var store: InMemoryScopedKeyStore!
    private var keyring: ScopedKeyring!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "RetiredFaceDataCleanupTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetiredFaceData_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        store = InMemoryScopedKeyStore()
        keyring = ScopedKeyring(store: store)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: workspace)
        defaults = nil
        try super.tearDownWithError()
    }

    private var database: URL { workspace.appendingPathComponent(Cleanup.databaseFileName) }

    private func runCleanup() -> Cleanup.Outcome {
        Cleanup.run(defaults: defaults, directory: workspace, keyring: keyring)
    }

    /// An install that had enrolled someone: the file sealed under the `.faces` key, the way the
    /// removed service wrote it, and the preferences it kept.
    private func plantAnEnrolledInstall() throws {
        let templates = Data(#"[{"name":"Maria","faceprint":[0.1,0.2]}]"#.utf8)
        try XCTUnwrap(keyring.seal(templates, for: .faces)).write(to: database)
        defaults.set(true, forKey: "faceRecognitionEnabled")
        defaults.set(0.05, forKey: "faceMatchAmbiguityMargin")
        defaults.set(true, forKey: "capabilityDefaultMigration.faceRecognition.v1")
    }

    func testTheDatabaseItsKeyAndItsPreferencesAreErased() throws {
        try plantAnEnrolledInstall()
        XCTAssertTrue(keyring.hasKey(for: .faces))

        XCTAssertEqual(runCleanup(), .erased(filesRemoved: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
        XCTAssertFalse(keyring.hasKey(for: .faces), "the key goes, so any copy elsewhere is ciphertext")
        for key in Cleanup.retiredPreferenceKeys {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
        XCTAssertTrue(defaults.bool(forKey: Cleanup.doneKey))
    }

    /// A database written before sealing existed is plaintext; it goes all the same.
    func testAnUnsealedDatabaseIsRemovedToo() throws {
        try Data(#"[{"name":"Maria"}]"#.utf8).write(to: database)
        XCTAssertEqual(runCleanup(), .erased(filesRemoved: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
    }

    func testAnInstallThatNeverEnrolledAnyoneIsMarkedDone() {
        XCTAssertEqual(runCleanup(), .erased(filesRemoved: 0))
        XCTAssertTrue(defaults.bool(forKey: Cleanup.doneKey))
    }

    func testItRunsOnceThenCostsNothing() throws {
        try plantAnEnrolledInstall()
        XCTAssertEqual(runCleanup(), .erased(filesRemoved: 1))
        XCTAssertEqual(runCleanup(), .alreadyDone)
    }

    /// A database that comes back after the cleanup — a container put back from a copy — is
    /// erased again rather than read.
    func testADatabaseThatComesBackIsErasedAgain() throws {
        XCTAssertEqual(runCleanup(), .erased(filesRemoved: 0))
        try Data("[]".utf8).write(to: database)
        XCTAssertEqual(runCleanup(), .erased(filesRemoved: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
    }

    /// A key store that cannot destroy the key (a Keychain locked before first unlock) leaves the
    /// cleanup unfinished, so the next launch tries again.
    func testAKeyThatCannotBeDestroyedIsRetriedNextLaunch() throws {
        final class StubbornStore: ScopedKeyStore {
            func key(for erasable: ErasableClass) -> SymmetricKey? { nil }
            func createKey(for erasable: ErasableClass) -> SymmetricKey? { nil }
            func destroyKey(for erasable: ErasableClass) -> Bool { false }
        }
        let stubborn = ScopedKeyring(store: StubbornStore())
        try Data("[]".utf8).write(to: database)

        XCTAssertEqual(Cleanup.run(defaults: defaults, directory: workspace, keyring: stubborn), .incomplete)
        XCTAssertFalse(defaults.bool(forKey: Cleanup.doneKey))
        XCTAssertEqual(runCleanup(), .erased(filesRemoved: 0), "the file went on the first try; the key now goes")
        XCTAssertTrue(defaults.bool(forKey: Cleanup.doneKey))
    }

    /// The cleanup leaves every other preference alone.
    func testOtherPreferencesAreLeftAlone() {
        defaults.set(true, forKey: "assistiveSocialEnabled")
        defaults.set(true, forKey: "privacyFilterEnabled")
        _ = runCleanup()
        XCTAssertEqual(defaults.object(forKey: "assistiveSocialEnabled") as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: "privacyFilterEnabled") as? Bool, true)
    }

    // MARK: - What the agent is told it can do

    /// The default skills document used to list face recognition. A copy an earlier build wrote
    /// loses that line the next time it is read; a line the wearer wrote stays.
    func testTheRetiredSkillLineIsTakenOutOfAnOldSkillsFile() throws {
        let old = """
        ## Knowledge
        - Remember where things are (object memory with GPS)
        - Face recognition with social context recall
        - My own note: recognise birdsong
        """
        let cleaned = AgentDocumentStore.removingRetiredSkillLines(from: old)
        XCTAssertFalse(cleaned.contains("Face recognition"))
        XCTAssertTrue(cleaned.contains("- Remember where things are (object memory with GPS)"))
        XCTAssertTrue(cleaned.contains("- My own note: recognise birdsong"))
        XCTAssertEqual(AgentDocumentStore.removingRetiredSkillLines(from: cleaned), cleaned)
        XCTAssertFalse(AgentDocumentStore.defaultSkills.contains("Face recognition"))
    }

    @MainActor
    func testAnOldSkillsFileIsRewrittenWhenRead() throws {
        let file = workspace.appendingPathComponent(AgentDocumentStore.DocumentType.skills.filename)
        try "# Skills\n- Face recognition with social context recall\n- Timers".write(
            to: file, atomically: true, encoding: .utf8)
        let store = AgentDocumentStore(directory: workspace)
        XCTAssertEqual(store.skills, "# Skills\n- Timers")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# Skills\n- Timers")
    }
}
