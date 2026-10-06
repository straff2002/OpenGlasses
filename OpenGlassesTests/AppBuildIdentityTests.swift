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
        XCTAssertEqual(identity.summary, "2026.10 (460) · 9f9f57e28 · TestFlight · com.example.app")
        identity.commit = nil
        XCTAssertEqual(identity.summary, "2026.10 (460) · TestFlight · com.example.app")
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
