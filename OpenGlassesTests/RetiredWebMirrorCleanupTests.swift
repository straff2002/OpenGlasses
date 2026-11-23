import XCTest
@testable import OpenGlasses

/// The web mirror of the lens was retired on 2026-11-23. What it left on an existing install — its
/// access token in the Keychain and its preferences — goes once at launch, and is tried again while
/// the Keychain cannot be reached. Every case runs against its own defaults suite and a recording
/// stand-in for the Keychain: never the wearer's own.
final class RetiredWebMirrorCleanupTests: XCTestCase {

    private typealias Cleanup = RetiredWebMirrorCleanup

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var deleted: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "RetiredWebMirrorCleanupTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        deleted = []
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try super.tearDownWithError()
    }

    private func runCleanup(keychainReachable: Bool = true) -> Cleanup.Outcome {
        Cleanup.run(defaults: defaults) { account in
            self.deleted.append(account)
            return keychainReachable
        }
    }

    /// A Debug install that had the mirror on, the way the removed server left it.
    private func plantAMirrorInstall() {
        defaults.set(true, forKey: "hudMirrorEnabled")
        defaults.set(true, forKey: "followUpsOnMirrorEnabled")
        defaults.set(true, forKey: "followUpsOnDisplayEnabled")
    }

    func testTheTokenAndThePreferencesGoAndNothingElse() {
        plantAMirrorInstall()

        XCTAssertEqual(runCleanup(), .removed)
        XCTAssertEqual(deleted, ["hudMirrorBearerToken"], "the mirror's own Keychain item, by its account")
        XCTAssertNil(defaults.object(forKey: "hudMirrorEnabled"))
        XCTAssertNil(defaults.object(forKey: "followUpsOnMirrorEnabled"))
        XCTAssertEqual(defaults.bool(forKey: "followUpsOnDisplayEnabled"), true,
                       "the Display's own follow-ups setting is not the mirror's")
        XCTAssertTrue(defaults.bool(forKey: Cleanup.doneKey))
    }

    func testAnInstallThatNeverHadTheMirrorIsMarkedDone() {
        XCTAssertEqual(runCleanup(), .removed)
        XCTAssertTrue(defaults.bool(forKey: Cleanup.doneKey))
    }

    func testItRunsOnceThenCostsNothing() {
        plantAMirrorInstall()
        XCTAssertEqual(runCleanup(), .removed)
        XCTAssertEqual(runCleanup(), .alreadyDone)
        XCTAssertEqual(deleted.count, 1, "the Keychain is not touched again once done")
    }

    /// Before first unlock the Keychain cannot be reached: the preferences still go, the marker
    /// stays unset, and the next launch tries the token again.
    func testAnUnreachableKeychainIsTriedAgainNextLaunch() {
        plantAMirrorInstall()

        XCTAssertEqual(runCleanup(keychainReachable: false), .incomplete)
        XCTAssertFalse(defaults.bool(forKey: Cleanup.doneKey))
        XCTAssertNil(defaults.object(forKey: "hudMirrorEnabled"))

        XCTAssertEqual(runCleanup(), .removed)
        XCTAssertEqual(deleted, ["hudMirrorBearerToken", "hudMirrorBearerToken"])
        XCTAssertTrue(defaults.bool(forKey: Cleanup.doneKey))
    }

    /// Nothing in the app reads the mirror's preferences or its token any more, and launch runs the
    /// cleanup beside the face-data one.
    func testNothingReadsTheRetiredKeysAndLaunchRunsTheCleanup() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("OpenGlasses/Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var readers: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard url.lastPathComponent != "RetiredWebMirrorCleanup.swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for key in Cleanup.retiredPreferenceKeys + [Cleanup.tokenKeychainAccount] where text.contains(key) {
                readers.append("\(url.lastPathComponent): \(key)")
            }
        }
        XCTAssertEqual(readers, [], "a retired key is read again")

        let app = try String(contentsOf: sources.appendingPathComponent("App/OpenGlassesApp.swift"), encoding: .utf8)
        let face = try XCTUnwrap(app.range(of: "RetiredFaceDataCleanup.run()"))
        let mirror = try XCTUnwrap(app.range(of: "RetiredWebMirrorCleanup.run()"))
        XCTAssertLessThan(app.distance(from: face.lowerBound, to: mirror.lowerBound), 400,
                          "it runs at launch, beside the face-data cleanup")
    }
}
