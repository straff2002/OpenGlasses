import XCTest
@testable import OpenGlasses

/// The cloud voice turning a reply away for a reason only the wearer can fix: which responses
/// count, and that the wearer is told once per episode rather than never or on every reply.
final class CloudVoiceFallbackTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "CloudVoiceFallbackTests"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    // MARK: - Which responses count

    func testQuotaIsReadFromTheBodyBecauseItsStatusIsTheSameAsABadKey() {
        let body = #"{"detail":{"status":"quota_exceeded","message":"…"}}"#
        XCTAssertEqual(CloudVoiceRejection.classify(statusCode: 401, body: body), .outOfCredit)
        XCTAssertEqual(CloudVoiceRejection.classify(statusCode: 401, body: #"{"detail":"invalid_api_key"}"#),
                       .refused)
    }

    func testARefusedKeyOrVoiceCounts() {
        for status in [401, 402, 403] {
            XCTAssertEqual(CloudVoiceRejection.classify(statusCode: status, body: ""), .refused, "\(status)")
        }
    }

    func testAServerFaultOrARateLimitIsNotTheWearersToFix() {
        for status in [0, 400, 404, 429, 500, 503] {
            XCTAssertNil(CloudVoiceRejection.classify(statusCode: status, body: ""), "\(status)")
        }
    }

    // MARK: - Said once

    func testARejectionIsSaidOnceAndNotAgain() {
        var announcer = CloudVoiceFallbackAnnouncer(defaults: defaults)
        XCTAssertEqual(announcer.lineToSpeak(for: .outOfCredit, plainReply: true),
                       CloudVoiceRejection.outOfCredit.spokenLine)
        XCTAssertNil(announcer.lineToSpeak(for: .outOfCredit, plainReply: true))
    }

    func testItStaysSaidAcrossALaunch() {
        var first = CloudVoiceFallbackAnnouncer(defaults: defaults)
        _ = first.lineToSpeak(for: .outOfCredit, plainReply: true)
        var afterRelaunch = CloudVoiceFallbackAnnouncer(defaults: defaults)
        XCTAssertNil(afterRelaunch.lineToSpeak(for: .outOfCredit, plainReply: true))
    }

    func testADifferentReasonIsNews() {
        var announcer = CloudVoiceFallbackAnnouncer(defaults: defaults)
        _ = announcer.lineToSpeak(for: .outOfCredit, plainReply: true)
        XCTAssertEqual(announcer.lineToSpeak(for: .refused, plainReply: true),
                       CloudVoiceRejection.refused.spokenLine)
    }

    func testAnAlertIsNeverLengthenedAndTheNextReplyStillCarriesIt() {
        var announcer = CloudVoiceFallbackAnnouncer(defaults: defaults)
        XCTAssertNil(announcer.lineToSpeak(for: .outOfCredit, plainReply: false))
        XCTAssertNotNil(announcer.lineToSpeak(for: .outOfCredit, plainReply: true))
    }

    func testTheCloudVoiceComingBackMakesTheNextRejectionNews() {
        var announcer = CloudVoiceFallbackAnnouncer(defaults: defaults)
        _ = announcer.lineToSpeak(for: .outOfCredit, plainReply: true)
        announcer.episodeEnded()
        XCTAssertNotNil(announcer.lineToSpeak(for: .outOfCredit, plainReply: true))
    }

    // MARK: - What is said

    func testBothTellingsNameWhereTheVoiceIsChanged() {
        for rejection in CloudVoiceRejection.allCases {
            XCTAssertTrue(rejection.spokenLine.contains("Connections"), "\(rejection)")
            XCTAssertTrue(rejection.spokenLine.contains("built-in voice"), "\(rejection)")
            XCTAssertTrue(rejection.banner.contains(SettingsCatalog.category(.connections).title),
                          "\(rejection)")
        }
    }
}
