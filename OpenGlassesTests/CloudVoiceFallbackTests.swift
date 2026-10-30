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
        XCTAssertNil(CloudVoiceRejection.classify(
            statusCode: 429, body: #"{"error":{"code":"rate_limit_exceeded"}}"#))
    }

    /// OpenAI sends an empty account as a 429, which the status alone reads as a rate limit.
    func testOpenAIsInsufficientQuotaIsOutOfCredit() {
        let body = #"{"error":{"message":"You exceeded your current quota.","type":"insufficient_quota","code":"insufficient_quota"}}"#
        XCTAssertEqual(CloudVoiceRejection.classify(statusCode: 429, body: body), .outOfCredit)
    }

    func testXAIsSpentCreditIsOutOfCredit() {
        let body = #"{"error":"Your team has either used all available credits or reached its monthly spending limit."}"#
        XCTAssertEqual(CloudVoiceRejection.classify(statusCode: 403, body: body), .outOfCredit)
    }

    // MARK: - A withdrawn model

    private let modelGoneBodies = [
        #"{"error":{"message":"The model `gpt-4o-mini-tts` does not exist or you do not have access to it.","type":"invalid_request_error","code":"model_not_found"}}"#,
        #"{"error":{"message":"The model `gpt-4o-mini-tts` does not exist or you do not have access to it."}}"#,
        #"{"error":{"message":"The model `tts-1` has been deprecated, learn more here: https://platform.openai.com/docs/deprecations","code":null}}"#,
        #"{"error":{"code":"model_not_found"}}"#
    ]

    func testAWithdrawnModelIsReadFromTheBodyAtAnyStatus() {
        for body in modelGoneBodies {
            for status in [400, 403, 404] {
                XCTAssertEqual(CloudVoiceRejection.classify(statusCode: status, body: body),
                               .modelUnavailable, "\(status) \(body)")
            }
        }
    }

    /// "Check the key" would be untrue: the key is fine and the model is gone.
    func testA403NamingAWithdrawnModelIsNotAnsweredWithCheckTheKey() {
        XCTAssertEqual(CloudVoiceRejection.classify(statusCode: 403, body: modelGoneBodies[0]),
                       .modelUnavailable)
        XCTAssertEqual(CloudVoiceRejection.classify(statusCode: 403, body: ""), .refused)
    }

    func testA404OrA400WithoutAMarkerStaysUnclassified() {
        for status in [400, 404] {
            XCTAssertNil(CloudVoiceRejection.classify(statusCode: status, body: ""), "\(status)")
            XCTAssertNil(CloudVoiceRejection.classify(
                statusCode: status, body: #"{"error":{"message":"Not found"}}"#), "\(status)")
        }
    }

    /// A bad voice is the wearer's to fix, so it must not latch the whole voice off as a gone model.
    func testAMissingVoiceIsNotAWithdrawnModel() {
        let body = #"{"detail":{"status":"voice_not_found","message":"A voice with that id does not exist."}}"#
        XCTAssertNil(CloudVoiceRejection.classify(statusCode: 404, body: body))
    }

    func testAnEmptyAccountStillWinsOverAModelMarker() {
        let body = #"{"error":{"code":"insufficient_quota","message":"The model does not exist."}}"#
        XCTAssertEqual(CloudVoiceRejection.classify(statusCode: 404, body: body), .outOfCredit)
    }

    func testAWithdrawnModelIsSaidOncePerEpisodeAndPerCloudVoice() {
        var announcer = CloudVoiceFallbackAnnouncer(defaults: defaults)
        let openAI = notice(.modelUnavailable, from: .openAI)
        XCTAssertEqual(openAI.announcementToken, "openAI.modelUnavailable")
        XCTAssertEqual(announcer.lineToSpeak(for: openAI, plainReply: true), openAI.spokenLine)
        XCTAssertNil(announcer.lineToSpeak(for: openAI, plainReply: true))
        XCTAssertNotNil(announcer.lineToSpeak(for: notice(.modelUnavailable, from: .xai), plainReply: true))
    }

    /// What an earlier build stored for this voice still decodes, and the new reason is news.
    func testAnOlderStoredTokenStillDecodes() {
        defaults.set(["openAI.refused"], forKey: CloudVoiceFallbackAnnouncer.defaultsKey)
        var announcer = CloudVoiceFallbackAnnouncer(defaults: defaults)
        XCTAssertNil(announcer.lineToSpeak(for: notice(.refused, from: .openAI), plainReply: true))
        XCTAssertNotNil(announcer.lineToSpeak(for: notice(.modelUnavailable, from: .openAI), plainReply: true))
    }

    func testTheWithdrawnModelLineNeverSaysToCheckTheKey() {
        for nextIsCloud in [false, true] {
            var told = notice(.modelUnavailable, from: .openAI)
            told.nextIsCloud = nextIsCloud
            XCTAssertTrue(told.spokenLine.contains("no longer offers"), "\(nextIsCloud)")
            XCTAssertFalse(told.spokenLine.contains("key"), "\(nextIsCloud)")
            XCTAssertFalse(told.banner.contains("key"), "\(nextIsCloud)")
        }
    }

    // MARK: - Said once

    private func notice(_ rejection: CloudVoiceRejection,
                        from engine: TTSEngine = .elevenLabs) -> CloudVoiceNotice {
        CloudVoiceNotice(engine: engine, rejection: rejection)
    }

    func testARejectionIsSaidOnceAndNotAgain() {
        var announcer = CloudVoiceFallbackAnnouncer(defaults: defaults)
        XCTAssertEqual(announcer.lineToSpeak(for: notice(.outOfCredit), plainReply: true),
                       notice(.outOfCredit).spokenLine)
        XCTAssertNil(announcer.lineToSpeak(for: notice(.outOfCredit), plainReply: true))
    }

    func testItStaysSaidAcrossALaunch() {
        var first = CloudVoiceFallbackAnnouncer(defaults: defaults)
        _ = first.lineToSpeak(for: notice(.outOfCredit), plainReply: true)
        var afterRelaunch = CloudVoiceFallbackAnnouncer(defaults: defaults)
        XCTAssertNil(afterRelaunch.lineToSpeak(for: notice(.outOfCredit), plainReply: true))
    }

    /// What an earlier release stored — a bare reason, for ElevenLabs — still counts as said.
    func testAnEpisodeStoredBeforeThereWereOtherCloudVoicesStillCounts() {
        defaults.set("outOfCredit", forKey: CloudVoiceFallbackAnnouncer.defaultsKey)
        var announcer = CloudVoiceFallbackAnnouncer(defaults: defaults)
        XCTAssertNil(announcer.lineToSpeak(for: notice(.outOfCredit), plainReply: true))
        XCTAssertNotNil(announcer.lineToSpeak(for: notice(.outOfCredit, from: .openAI), plainReply: true))
    }

    func testADifferentReasonIsNews() {
        var announcer = CloudVoiceFallbackAnnouncer(defaults: defaults)
        _ = announcer.lineToSpeak(for: notice(.outOfCredit), plainReply: true)
        XCTAssertEqual(announcer.lineToSpeak(for: notice(.refused), plainReply: true),
                       notice(.refused).spokenLine)
    }

    func testAnAlertIsNeverLengthenedAndTheNextReplyStillCarriesIt() {
        var announcer = CloudVoiceFallbackAnnouncer(defaults: defaults)
        XCTAssertNil(announcer.lineToSpeak(for: notice(.outOfCredit), plainReply: false))
        XCTAssertNotNil(announcer.lineToSpeak(for: notice(.outOfCredit), plainReply: true))
    }

    func testTheCloudVoiceComingBackMakesTheNextRejectionNews() {
        var announcer = CloudVoiceFallbackAnnouncer(defaults: defaults)
        _ = announcer.lineToSpeak(for: notice(.outOfCredit), plainReply: true)
        announcer.episodeEnded()
        XCTAssertNotNil(announcer.lineToSpeak(for: notice(.outOfCredit), plainReply: true))
    }

    // MARK: - One episode per cloud voice

    /// Auto with two cloud voices: the first refuses every reply and the second speaks. The
    /// second speaking must not make the first's refusal news on every reply.
    func testAnotherCloudVoiceSpeakingDoesNotEndThisOnesEpisode() {
        var announcer = CloudVoiceFallbackAnnouncer(defaults: defaults)
        XCTAssertNotNil(announcer.lineToSpeak(for: notice(.refused), plainReply: true))
        announcer.episodeEnded(for: .openAI)
        XCTAssertNil(announcer.lineToSpeak(for: notice(.refused), plainReply: true))
        announcer.episodeEnded(for: .elevenLabs)
        XCTAssertNotNil(announcer.lineToSpeak(for: notice(.refused), plainReply: true))
    }

    func testEachCloudVoicesRejectionIsItsOwnNews() {
        var announcer = CloudVoiceFallbackAnnouncer(defaults: defaults)
        XCTAssertNotNil(announcer.lineToSpeak(for: notice(.refused), plainReply: true))
        XCTAssertNotNil(announcer.lineToSpeak(for: notice(.refused, from: .openAI), plainReply: true))
        XCTAssertNotNil(announcer.lineToSpeak(for: notice(.refused, from: .xai), plainReply: true))
        // And each stays said while the others are told.
        XCTAssertNil(announcer.lineToSpeak(for: notice(.refused), plainReply: true))
        XCTAssertNil(announcer.lineToSpeak(for: notice(.refused, from: .openAI), plainReply: true))
    }

    func testAnnouncementTokensNameTheirCloudVoice() {
        for engine in TTSEngine.cloudVoices {
            for rejection in CloudVoiceRejection.allCases {
                let token = notice(rejection, from: engine).announcementToken
                XCTAssertEqual(CloudVoiceNotice.engine(ofToken: token), engine, token)
            }
        }
        XCTAssertEqual(notice(.refused).announcementToken, "refused", "ElevenLabs keeps the stored form")
        XCTAssertNil(CloudVoiceNotice.engine(ofToken: "unknown"))
    }

    // MARK: - What is said

    func testBothTellingsNameWhereTheVoiceIsChanged() {
        for engine in TTSEngine.cloudVoices {
            for rejection in CloudVoiceRejection.allCases {
                let told = notice(rejection, from: engine)
                XCTAssertTrue(told.spokenLine.contains("Connections"), "\(engine) \(rejection)")
                XCTAssertTrue(told.spokenLine.contains("built-in voice"), "\(engine) \(rejection)")
                XCTAssertTrue(told.banner.contains(SettingsCatalog.category(.connections).title),
                              "\(engine) \(rejection)")
            }
        }
    }

    func testEachTellingNamesTheVendor() throws {
        for engine in TTSEngine.cloudVoices {
            let vendor = try XCTUnwrap(engine.vendorName)
            for rejection in CloudVoiceRejection.allCases {
                for nextIsCloud in [false, true] {
                    var told = notice(rejection, from: engine)
                    told.nextIsCloud = nextIsCloud
                    XCTAssertTrue(told.spokenLine.contains(vendor), "\(engine) \(rejection) \(nextIsCloud)")
                    XCTAssertTrue(told.banner.contains(vendor), "\(engine) \(rejection) \(nextIsCloud)")
                }
            }
        }
    }

    /// The ElevenLabs wording is the one it has always had.
    func testTheElevenLabsWordingIsUnchanged() {
        XCTAssertEqual(notice(.outOfCredit).spokenLine,
                       "By the way, your ElevenLabs credit has run out, so I'm using the built-in voice. You can change voices in the app's Settings, under Connections, then Services and Integrations.")
        XCTAssertEqual(notice(.refused).banner,
                       "ElevenLabs refused the voice request, so replies use the built-in voice. Check the key and voice in Settings › Connections › Services & Integrations.")
    }

    /// With another cloud voice taking over, "the built-in voice" would be untrue.
    func testAnotherCloudVoiceTakingOverIsNotCalledTheBuiltInVoice() {
        for rejection in CloudVoiceRejection.allCases {
            var told = notice(rejection)
            told.nextIsCloud = true
            XCTAssertFalse(told.spokenLine.contains("built-in voice"), "\(rejection)")
            XCTAssertTrue(told.spokenLine.contains("another voice"), "\(rejection)")
            XCTAssertFalse(told.banner.contains("built-in voice"), "\(rejection)")
        }
    }

    func testTheNextEngineDecidesWhetherAnotherCloudVoiceFollows() {
        let chain: [TTSEngine] = [.elevenLabs, .openAI, .kokoro, .system]
        XCTAssertTrue(TextToSpeechService.cloudVoiceFollows(.elevenLabs, in: chain))
        XCTAssertFalse(TextToSpeechService.cloudVoiceFollows(.openAI, in: chain))
        XCTAssertFalse(TextToSpeechService.cloudVoiceFollows(.xai, in: chain), "not in the chain")
    }
}
