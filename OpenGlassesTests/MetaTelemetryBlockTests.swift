import XCTest
@testable import OpenGlasses

/// The glasses SDK uploads `ar_wearables_sdk_*` analytics batches to a hard-coded Meta endpoint
/// unless the app opts out. These cover both halves of switching that off: the Info.plist keys
/// that are supposed to do it, and the `URLProtocol` backstop that makes it true regardless.
final class MetaTelemetryBlockTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MetaTelemetryBlock.resetCountForTesting()
    }

    // MARK: - Endpoint matching

    func testMatchesTheSDKTelemetryEndpoint() {
        XCTAssertTrue(MetaTelemetryBlock.isTelemetryURL(URL(string: "https://api2.ar.meta.com/mwsdk/telemetry")))
    }

    /// The SDK owns the tail of this URL. Matching host + prefix rather than the exact string is
    /// what keeps an appended path segment or query from silently reopening the upload.
    func testMatchesTelemetryURLsWithExtraPathOrQuery() {
        XCTAssertTrue(MetaTelemetryBlock.isTelemetryURL(URL(string: "https://api2.ar.meta.com/mwsdk/telemetry/batch")))
        XCTAssertTrue(MetaTelemetryBlock.isTelemetryURL(URL(string: "https://api2.ar.meta.com/mwsdk/telemetry?v=2")))
    }

    func testHostMatchIsCaseInsensitive() {
        XCTAssertTrue(MetaTelemetryBlock.isTelemetryURL(URL(string: "https://API2.AR.META.COM/mwsdk/telemetry")))
    }

    /// Attestation shares the host and is how the SDK proves the app may talk to the glasses.
    /// Blocking it would break device access, not protect privacy — this is the line that keeps
    /// the interceptor from being widened to the whole host by accident.
    func testDoesNotMatchAttestationOnTheSameHost() {
        XCTAssertFalse(MetaTelemetryBlock.isTelemetryURL(
            URL(string: "https://api2.ar.meta.com/wearables/attestation/challenge")))
    }

    func testDoesNotMatchOtherHostsOrNil() {
        XCTAssertFalse(MetaTelemetryBlock.isTelemetryURL(URL(string: "https://api.anthropic.com/mwsdk/telemetry")))
        XCTAssertFalse(MetaTelemetryBlock.isTelemetryURL(URL(string: "https://evil.api2.ar.meta.com/mwsdk/telemetry")))
        XCTAssertFalse(MetaTelemetryBlock.isTelemetryURL(nil))
    }

    // MARK: - Interception

    /// The claim worth testing: a telemetry POST is answered locally and never leaves the process.
    ///
    /// The interceptor is injected into an ephemeral session's `protocolClasses` rather than
    /// registered globally — `URLProtocol.registerClass` against the shared session is
    /// registration-order and timing sensitive when other suites are doing networking in
    /// parallel. What this test owns is the interceptor's behaviour; the global registration
    /// path is `install()`, covered below.
    func testTelemetryUploadIsAnsweredLocallyAndNeverSent() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetaTelemetryBlock.Interceptor.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: URL(string: "https://api2.ar.meta.com/mwsdk/telemetry")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{\"events\":[]}".utf8)

        let blockedBefore = MetaTelemetryBlock.blockedCount
        let (data, response) = try await session.data(for: request)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204,
                       "a success drops the SDK's cached batch; a failure would leave it retrying forever")
        XCTAssertTrue(data.isEmpty)
        XCTAssertEqual(MetaTelemetryBlock.blockedCount, blockedBefore + 1,
                       "the counter is how a regression becomes visible without a packet capture")
    }

    func testInstallIsIdempotent() {
        MetaTelemetryBlock.install()
        MetaTelemetryBlock.install()
        XCTAssertEqual(MetaTelemetryBlock.statusDescription, "installed")
    }

    // MARK: - Info.plist opt-out

    func testReadsBothOptOutKeys() {
        let info: [String: Any] = [
            "MWDAT": [
                "Analytics": ["OptOut": true],
                "CrashReporting": ["OptOut": true],
            ]
        ]
        let state = MetaTelemetryBlock.plistOptOut(in: info)
        XCTAssertTrue(state.analytics)
        XCTAssertTrue(state.crashReporting)
    }

    /// Absent means opted **in** — the SDK's default. A missing key must not read as a safe
    /// default here, or the Developer-panel probe would report privacy we don't have.
    func testMissingKeysReadAsOptedIn() {
        XCTAssertFalse(MetaTelemetryBlock.plistOptOut(in: nil).analytics)
        XCTAssertFalse(MetaTelemetryBlock.plistOptOut(in: [:]).crashReporting)
        XCTAssertFalse(MetaTelemetryBlock.plistOptOut(in: ["MWDAT": ["Analytics": [:]]]).analytics)
        XCTAssertFalse(MetaTelemetryBlock.plistOptOut(in: ["MWDAT": ["Analytics": ["OptOut": false]]]).analytics)
    }

    // MARK: - Settings disclosure

    /// "Off" is the strongest claim, and it is only made when both halves hold. The app should
    /// never tell a user their data is not being collected on the strength of a flag alone.
    func testDisclosureClaimsOffOnlyWhenOptedOutAndNothingWasBlocked() {
        XCTAssertEqual(
            MetaTelemetryBlock.disclosure(optOut: (analytics: true, crashReporting: true), blockedCount: 0),
            .off)
    }

    func testDisclosureReportsBlockedWhenTheOptOutWasIgnored() {
        XCTAssertEqual(
            MetaTelemetryBlock.disclosure(optOut: (analytics: true, crashReporting: true), blockedCount: 3),
            .blocked(3),
            "an opt-out that is set but not honoured must not read as \"Off\" in Settings")
    }

    /// Either key missing means the SDK is collecting by default — Settings has to say so rather
    /// than round it down to the reassuring answer.
    func testDisclosureReportsOnWhenEitherKeyIsMissing() {
        XCTAssertEqual(
            MetaTelemetryBlock.disclosure(optOut: (analytics: false, crashReporting: true), blockedCount: 0),
            .on)
        XCTAssertEqual(
            MetaTelemetryBlock.disclosure(optOut: (analytics: true, crashReporting: false), blockedCount: 0),
            .on)
    }

    func testDisclosureSummariesAreTheUserFacingWords() {
        XCTAssertEqual(MetaTelemetryBlock.Disclosure.off.summary, "Off")
        XCTAssertEqual(MetaTelemetryBlock.Disclosure.blocked(2).summary, "Blocked")
        XCTAssertEqual(MetaTelemetryBlock.Disclosure.on.summary, "On")
    }

    /// Guards the shipped bundle, not just the parser: this fails if anyone drops the keys from
    /// `OpenGlasses/Info.plist`.
    func testShippedBundleOptsOutOfBothAnalyticsAndCrashReporting() throws {
        // These tests are hosted by the app (TEST_HOST), so `Bundle.main` is the app bundle —
        // this reads the plist that actually ships, not the test bundle's generated one.
        let state = MetaTelemetryBlock.bundleOptOut
        XCTAssertTrue(state.analytics, "MWDAT/Analytics/OptOut must be YES in the app's Info.plist")
        XCTAssertTrue(state.crashReporting, "MWDAT/CrashReporting/OptOut must be YES in the app's Info.plist")
    }
}
