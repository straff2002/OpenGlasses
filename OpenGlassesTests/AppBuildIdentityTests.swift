import XCTest
@testable import OpenGlasses

/// Which copy of the app a support report came from.
final class AppBuildIdentityTests: XCTestCase {

    private typealias Identity = AppBuildIdentity

    func testAProvisioningProfileMeansAContributorOrXcodeBuild() {
        XCTAssertEqual(Identity.channel(isSimulator: false, hasEmbeddedProfile: true,
                                        receiptName: "sandboxReceipt"), .development)
    }

    func testTestFlightIsTheSandboxReceiptWithoutAProfile() {
        XCTAssertEqual(Identity.channel(isSimulator: false, hasEmbeddedProfile: false,
                                        receiptName: "sandboxReceipt"), .testFlight)
    }

    func testTheStoreIsEverythingElseWithoutAProfile() {
        XCTAssertEqual(Identity.channel(isSimulator: false, hasEmbeddedProfile: false,
                                        receiptName: "receipt"), .appStore)
        XCTAssertEqual(Identity.channel(isSimulator: false, hasEmbeddedProfile: false,
                                        receiptName: nil), .appStore)
    }

    func testTheSimulatorIsNamedAsOne() {
        XCTAssertEqual(Identity.channel(isSimulator: true, hasEmbeddedProfile: false,
                                        receiptName: "sandboxReceipt"), .simulator)
    }

    func testAStampedCommitIsShortened() {
        XCTAssertEqual(Identity.commit(fromInfoValue: "9f9f57e2813a5fcf2172c1b6c1a822409885db6b"),
                       "9f9f57e28")
    }

    func testAnUnstampedBuildHasNoCommit() {
        for value in [nil, "", "  ", "unknown", "$(AVENKIN_SOURCE_COMMIT)", "${AVENKIN_SOURCE_COMMIT}", "main"] {
            XCTAssertNil(Identity.commit(fromInfoValue: value), String(describing: value))
        }
    }

    func testTheSummaryLeadsWithVersionAndBuildAndOmitsAMissingCommit() {
        var identity = Identity(version: "2026.10", build: "460", commit: "9f9f57e28",
                                channel: .testFlight, bundleID: "com.example.app")
        XCTAssertEqual(identity.summary, "2026.10 (460) · 9f9f57e28 · TestFlight · \(AppBuildVariant.current.rawValue) · com.example.app")
        identity.commit = nil
        XCTAssertEqual(identity.summary, "2026.10 (460) · TestFlight · \(AppBuildVariant.current.rawValue) · com.example.app")
    }

    /// Plan JV: a flagged TestFlight build says so on the report's first line.
    func testAFlaggedBuildSaysDATExperimentalAfterTheChannel() {
        let identity = Identity(version: "2026.10", build: "570", commit: "1a2b3c4d5",
                                channel: .testFlight, bundleID: "com.example.app", datExperimental: true)
        XCTAssertEqual(identity.summary,
                       "2026.10 (570) · 1a2b3c4d5 · TestFlight · DAT experimental · \(AppBuildVariant.current.rawValue) · com.example.app")
    }

    func testOnlyTheLiteralYesIsTheExperimentalStamp() {
        XCTAssertTrue(Identity.datExperimental(fromInfoValue: "YES"))
        for value in [nil, "", "NO", "yes", "1", "$(AVENKIN_DAT_EXPERIMENTAL)"] {
            XCTAssertFalse(Identity.datExperimental(fromInfoValue: value), String(describing: value))
        }
    }

    func testTheRunningTestHostDescribesItself() {
        let current = Identity.current
        XCTAssertFalse(current.version.isEmpty)
        XCTAssertFalse(current.bundleID.isEmpty)
        #if targetEnvironment(simulator)
        XCTAssertEqual(current.channel, .simulator)
        #endif
    }
}
