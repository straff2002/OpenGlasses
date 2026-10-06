import XCTest
@testable import OpenGlasses

/// Plan HP P1 item 1 — face recognition's default moved from on to off, and nobody who already had
/// it loses it. The rule is a pure decision over four inputs; the adapter is exercised against its
/// own defaults suite (never `.standard`) and a face-database closure, so no file is needed.
final class CapabilityDefaultMigrationTests: XCTestCase {

    private typealias Migration = CapabilityDefaultMigration

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "CapabilityDefaultMigrationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func inputs(written: Bool = false, onboarded: Bool = false, faces: Bool = false,
                        done: Bool = false) -> Migration.Inputs {
        Migration.Inputs(keyEverWritten: written, hasCompletedOnboarding: onboarded,
                         faceDatabaseHasEntries: faces, alreadyMigrated: done)
    }

    // MARK: - The pure decision

    func testAFreshInstallIsSeededOff() {
        XCTAssertEqual(Migration.decide(inputs()), .seedOff)
    }

    func testAnInstallThatFinishedOnboardingIsAnExistingUserAndKeepsIt() {
        XCTAssertEqual(Migration.decide(inputs(onboarded: true)), .seedOn)
    }

    func testAnInstallWithEnrolledFacesKeepsItEvenWithoutOnboarding() {
        XCTAssertEqual(Migration.decide(inputs(faces: true)), .seedOn)
        XCTAssertEqual(Migration.decide(inputs(onboarded: true, faces: true)), .seedOn)
    }

    func testAKeyAlreadyWrittenIsLeftAloneWhateverElseIsTrue() {
        for onboarded in [false, true] {
            for faces in [false, true] {
                XCTAssertEqual(Migration.decide(inputs(written: true, onboarded: onboarded, faces: faces)),
                               .leaveAlone, "onboarded \(onboarded), faces \(faces)")
            }
        }
    }

    func testTheDoneMarkerWinsOverEveryOtherInput() {
        for written in [false, true] {
            for onboarded in [false, true] {
                for faces in [false, true] {
                    XCTAssertEqual(Migration.decide(inputs(written: written, onboarded: onboarded, faces: faces,
                                                           done: true)), .leaveAlone)
                }
            }
        }
    }

    // MARK: - The adapter

    func testRunSeedsAnExistingUserOnAndMarksItselfDone() {
        defaults.set(true, forKey: Migration.onboardingKey)
        XCTAssertEqual(Migration.run(defaults: defaults, faceDatabaseHasEntries: { false }), .seedOn)
        XCTAssertEqual(defaults.object(forKey: Migration.faceRecognitionKey) as? Bool, true)
        XCTAssertTrue(defaults.bool(forKey: Migration.doneKey))
    }

    func testRunSeedsAFreshInstallOffAsAStoredValue() {
        XCTAssertEqual(Migration.run(defaults: defaults, faceDatabaseHasEntries: { false }), .seedOff)
        XCTAssertEqual(defaults.object(forKey: Migration.faceRecognitionKey) as? Bool, false,
                       "stored, so a later default change cannot flip a fresh install on")
    }

    func testRunReadsTheFaceDatabaseOnlyWhenTheAnswerDependsOnIt() {
        var asked = 0
        XCTAssertEqual(Migration.run(defaults: defaults, faceDatabaseHasEntries: { asked += 1; return true }), .seedOn)
        XCTAssertEqual(asked, 1)

        let other = UserDefaults(suiteName: suiteName + ".onboarded")!
        defer { other.removePersistentDomain(forName: suiteName + ".onboarded") }
        other.set(true, forKey: Migration.onboardingKey)
        Migration.run(defaults: other, faceDatabaseHasEntries: { asked += 1; return false })
        XCTAssertEqual(asked, 1, "onboarding alone decides it; the file is not opened")
    }

    func testRunLeavesTheWearersOwnChoiceAlone() {
        defaults.set(true, forKey: Migration.onboardingKey)
        defaults.set(false, forKey: Migration.faceRecognitionKey)   // the wearer turned it off
        XCTAssertEqual(Migration.run(defaults: defaults, faceDatabaseHasEntries: { true }), .leaveAlone)
        XCTAssertEqual(defaults.object(forKey: Migration.faceRecognitionKey) as? Bool, false)
        XCTAssertTrue(defaults.bool(forKey: Migration.doneKey))
    }

    func testRunIsIdempotent() {
        XCTAssertEqual(Migration.run(defaults: defaults, faceDatabaseHasEntries: { false }), .seedOff)
        // The wearer finishes onboarding and enrols a face afterwards; a second launch changes nothing.
        defaults.set(true, forKey: Migration.onboardingKey)
        XCTAssertEqual(Migration.run(defaults: defaults, faceDatabaseHasEntries: { true }), .leaveAlone)
        XCTAssertEqual(defaults.object(forKey: Migration.faceRecognitionKey) as? Bool, false)

        // Even with the key cleared, the done-marker keeps it from running again.
        defaults.removeObject(forKey: Migration.faceRecognitionKey)
        XCTAssertEqual(Migration.run(defaults: defaults, faceDatabaseHasEntries: { true }), .leaveAlone)
        XCTAssertNil(defaults.object(forKey: Migration.faceRecognitionKey))
    }

    /// The keys the migration reads and writes are the ones the rest of the app uses.
    func testKeysMatchTheSwitchAndOnboarding() {
        XCTAssertEqual(Migration.faceRecognitionKey, AIFeature.faceRecognition.record.disableSwitch.key)
        XCTAssertEqual(Migration.faceRecognitionKey, SettingKey.faceRecognitionEnabled.rawValue)
        XCTAssertEqual(Migration.onboardingKey, "hasCompletedOnboarding")
    }

    // MARK: - The face database reader

    func testFaceDatabaseReaderSeesEmptyMissingAndEnrolled() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("CapabilityMigration_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let keyring = ScopedKeyring(store: InMemoryScopedKeyStore())
        let file = workspace.appendingPathComponent("known_faces.json")

        XCTAssertFalse(Migration.knownFacesFileHasEntries(directory: workspace, keyring: keyring), "no file")

        try JSONEncoder().encode([FaceRecognitionService.KnownFace]()).write(to: file)
        XCTAssertFalse(Migration.knownFacesFileHasEntries(directory: workspace, keyring: keyring), "empty list")

        let face = FaceRecognitionService.KnownFace(name: "Maria", faceprint: Array(repeating: 0.1, count: 128))
        try JSONEncoder().encode([face]).write(to: file)
        XCTAssertTrue(Migration.knownFacesFileHasEntries(directory: workspace, keyring: keyring))

        // Sealed at rest, the way the service writes it: opened through the keyring.
        try XCTUnwrap(keyring.seal(JSONEncoder().encode([face]), for: .faces)).write(to: file)
        XCTAssertTrue(Migration.knownFacesFileHasEntries(directory: workspace, keyring: keyring))
        try XCTUnwrap(keyring.seal(JSONEncoder().encode([FaceRecognitionService.KnownFace]()), for: .faces))
            .write(to: file)
        XCTAssertFalse(Migration.knownFacesFileHasEntries(directory: workspace, keyring: keyring), "sealed empty list")

        // Unreadable counts as non-empty: an existing user keeps the capability.
        try Data("not json".utf8).write(to: file)
        XCTAssertTrue(Migration.knownFacesFileHasEntries(directory: workspace, keyring: keyring))
    }
}
