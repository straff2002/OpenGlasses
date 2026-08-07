import XCTest
@testable import OpenGlasses

/// MWDATConfigCheck — the DAT credentials are substituted into the committed Info.plist from
/// build settings whose real values live in the gitignored project.local.yml. A build missing
/// them launches fine and then stalls registration below state 3, which reads to the user as
/// "Connect does nothing" and "the camera permission never fires". These tests pin the
/// diagnosis so that failure stays named. All pure/headless.
final class MWDATConfigCheckTests: XCTestCase {

    /// Shape-accurate but entirely fictional — never the project's real credentials, which
    /// belong only in the gitignored project.local.yml.
    private static let fakeAppID = "100000000000001"
    private static let fakeTokenHash = String(repeating: "a1b2c3d4", count: 4)

    private func dict(appID: String = fakeAppID,
                      token: String = "AR|\(fakeAppID)|\(fakeTokenHash)") -> [String: Any] {
        ["MetaAppID": appID, "ClientToken": token, "AppLinkURLScheme": "openglasses://"]
    }

    // MARK: - The good case

    func testRealCredentialsAreUsable() {
        let status = MWDATConfigCheck.validate(dict())
        XCTAssertEqual(status, .ok)
        XCTAssertTrue(status.isUsable)
        XCTAssertNil(MWDATConfigCheck.message(for: status), "a healthy config must log nothing")
    }

    // MARK: - The failure that cost a debugging session

    func testCommittedPlaceholderIsDetected() {
        // Exactly what project.base.yml ships, i.e. any clone without project.local.yml.
        let status = MWDATConfigCheck.validate(
            dict(appID: "YOUR_META_APP_ID", token: "AR|YOUR_META_APP_ID|YOUR_CLIENT_TOKEN_HASH"))
        XCTAssertEqual(status, .placeholder(key: "MetaAppID"))
        XCTAssertFalse(status.isUsable)
    }

    func testPlaceholderSurvivingOnlyInTheTokenIsStillDetected() {
        // A half-configured local spec: app id set, token hash never filled in.
        let status = MWDATConfigCheck.validate(
            dict(token: "AR|\(Self.fakeAppID)|YOUR_CLIENT_TOKEN_HASH"))
        XCTAssertEqual(status, .placeholder(key: "ClientToken"))
    }

    func testUnexpandedBuildSettingIsReportedSeparatelyFromPlaceholder() {
        // The setting is undefined, so Xcode left the $(…) reference literal. Different fix
        // from a placeholder value, so it must not collapse into the same diagnosis.
        let status = MWDATConfigCheck.validate(dict(appID: "$(MWDAT_META_APP_ID)"))
        XCTAssertEqual(status, .unsubstituted(key: "MetaAppID"))
    }

    func testUnsubstitutedWinsOverPlaceholderWithinOneValue() {
        // "AR|$(X)|YOUR_CLIENT_TOKEN_HASH" contains both markers; the unexpanded reference is
        // the more specific (and more actionable) diagnosis.
        let status = MWDATConfigCheck.validate(
            dict(token: "AR|$(MWDAT_META_APP_ID)|YOUR_CLIENT_TOKEN_HASH"))
        XCTAssertEqual(status, .unsubstituted(key: "ClientToken"))
    }

    // MARK: - Structural failures

    func testMissingDictionary() {
        XCTAssertEqual(MWDATConfigCheck.validate(nil), .missingDictionary)
    }

    func testMissingAndEmptyValues() {
        XCTAssertEqual(MWDATConfigCheck.validate(["ClientToken": "AR|1|2"]),
                       .missingValue(key: "MetaAppID"))
        XCTAssertEqual(MWDATConfigCheck.validate(dict(appID: "   ")),
                       .missingValue(key: "MetaAppID"))
    }

    // MARK: - Messages

    func testEveryFailureMessageNamesTheFixAndLeaksNoCredential() {
        let failures: [MWDATConfigCheck.Status] = [
            .missingDictionary,
            .missingValue(key: "MetaAppID"),
            .placeholder(key: "MetaAppID"),
            .unsubstituted(key: "ClientToken"),
        ]
        for status in failures {
            let message = MWDATConfigCheck.message(for: status)
            XCTAssertNotNil(message, "\(status) must produce a diagnosis")
            XCTAssertFalse(message?.isEmpty ?? true)
        }
        // The two fixable cases must point at where the real values belong.
        XCTAssertTrue(MWDATConfigCheck.message(for: .placeholder(key: "MetaAppID"))!
            .contains("project.local.yml"))
        XCTAssertTrue(MWDATConfigCheck.message(for: .unsubstituted(key: "ClientToken"))!
            .contains("project.local.yml"))
    }
}

/// The connect-failure path must blame a broken *build* config before it blames the user's
/// Meta AI approval — the two produce an identical stalled registration state.
final class RegistrationFlowConfigMessageTests: XCTestCase {

    func testBadConfigPreemptsTheGenericApprovalAdvice() {
        let message = RegistrationFlow.connectFailureMessage(
            stateRaw: 0, configStatus: .placeholder(key: "MetaAppID"))
        XCTAssertTrue(message.contains("project.local.yml"))
        XCTAssertFalse(message.contains("associated-domains"),
                       "must not send the user chasing an AppLink problem they don't have")
    }

    func testHealthyConfigKeepsTheExistingLinkBackDiagnosis() {
        let message = RegistrationFlow.connectFailureMessage(stateRaw: 0, configStatus: .ok)
        XCTAssertTrue(message.contains("registration didn't complete"))
    }

    func testRegisteredStateIgnoresConfigStatus() {
        // Past registration, the credentials demonstrably worked — a config gripe here would
        // be a false lead pointing away from the real cause (no device in range).
        let message = RegistrationFlow.connectFailureMessage(
            stateRaw: 3, configStatus: .placeholder(key: "MetaAppID"))
        XCTAssertTrue(message.contains("no device appeared"))
    }

    func testDefaultArgumentPreservesExistingBehaviour() {
        XCTAssertEqual(RegistrationFlow.connectFailureMessage(stateRaw: 0),
                       RegistrationFlow.connectFailureMessage(stateRaw: 0, configStatus: .ok))
    }
}
