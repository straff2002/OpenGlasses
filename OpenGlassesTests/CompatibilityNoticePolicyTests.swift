import MWDATCore
import XCTest
@testable import OpenGlasses

/// Plan HX P1 — an update requirement the glasses report is said once per process, at link time,
/// and only for the two readings that ask the wearer to do something.
final class CompatibilityNoticePolicyTests: XCTestCase {

    private typealias Policy = CompatibilityNoticePolicy

    private let firmware = DATCompatibilityMessage.message(for: GlassesCompatibility.deviceUpdateRequired)!
    private let appUpdate = DATCompatibilityMessage.appUpdateRequired

    // MARK: - Which readings ask anything

    func testOnlyTheTwoUpdateRequirementsHaveANotice() {
        XCTAssertEqual(Policy.notice(for: .deviceUpdateRequired), firmware)
        XCTAssertEqual(Policy.notice(for: .sdkUpdateRequired), appUpdate)
        XCTAssertNil(Policy.notice(for: .compatible))
        XCTAssertNil(Policy.notice(for: .undefined))
        XCTAssertNil(Policy.notice(for: nil), "glasses that are away ask nothing")
    }

    func testTheTwoRequirementsReadDifferently() {
        XCTAssertNotEqual(firmware, appUpdate)
        XCTAssertTrue(firmware.localizedCaseInsensitiveContains("glasses"))
        XCTAssertTrue(appUpdate.localizedCaseInsensitiveContains("App Store"))
    }

    /// The SDK's value is mapped once, at the link source, and worded once.
    func testTheSDKsCompatibilityMapsCaseForCaseAndReadsTheSame() {
        XCTAssertEqual(WearablesGlassesLinkSource.map(Compatibility.undefined), .undefined)
        XCTAssertEqual(WearablesGlassesLinkSource.map(Compatibility.compatible), .compatible)
        XCTAssertEqual(WearablesGlassesLinkSource.map(Compatibility.deviceUpdateRequired), .deviceUpdateRequired)
        XCTAssertEqual(WearablesGlassesLinkSource.map(Compatibility.sdkUpdateRequired), .sdkUpdateRequired)
        XCTAssertEqual(Compatibility.allCases.count, GlassesCompatibility.allCases.count,
                       "the SDK grew a compatibility case: decide what it means before it reads as undefined")
        for sdk in Compatibility.allCases {
            XCTAssertEqual(DATCompatibilityMessage.message(for: sdk),
                           DATCompatibilityMessage.message(for: WearablesGlassesLinkSource.map(sdk)))
        }
    }

    // MARK: - On screen while it is true (Plan HX follow-up)

    func testARequirementStandsOnScreenWhileItIsTheConnectedReading() {
        XCTAssertEqual(Policy.standing(for: .deviceUpdateRequired), .stands(firmware))
        XCTAssertEqual(Policy.standing(for: .sdkUpdateRequired), .stands(appUpdate))
    }

    func testItIsWithdrawnWhenTheGlassesAreCompatibleHaveNotSaidOrHaveGone() {
        XCTAssertEqual(Policy.standing(for: .compatible), .withdrawn, "the glasses were updated")
        XCTAssertEqual(Policy.standing(for: .undefined), .withdrawn)
        XCTAssertEqual(Policy.standing(for: nil), .withdrawn, "the link went")
    }

    /// Standing is the reading and nothing else. Speaking is once per process; the two are
    /// decided apart, so a sentence already said is still shown at the next connection.
    func testStandingDoesNotDependOnWhatHasBeenSaid() {
        var ledger = Policy.Ledger()
        XCTAssertEqual(ledger.note(.deviceUpdateRequired), .announce(firmware))
        ledger.noteSaid(firmware)
        _ = ledger.note(nil)
        XCTAssertEqual(ledger.note(.deviceUpdateRequired), .nothing, "not said again")
        XCTAssertEqual(Policy.standing(for: .deviceUpdateRequired), .stands(firmware), "shown again")
    }

    /// The two ways it used to be lost while still true: the camera's per-cycle clear of the
    /// glasses' notices, and any other glasses notice replacing it. It has its own source.
    func testTheCamerasClearAndOtherGlassesNoticesLeaveItStanding() {
        let update = AppNotice(text: firmware, severity: .warning, source: .glassesUpdate, postedAt: 0)
        var held = NoticePolicy.merge([], with: update)
        held = NoticePolicy.merge(held, with: AppNotice(text: "Glasses are out of reach",
                                                        severity: .advisory, source: .glasses, postedAt: 1))
        XCTAssertTrue(held.contains(update), "another glasses notice replaced it")
        held = NoticePolicy.clearing(held, source: .glasses)
        XCTAssertEqual(held, [update], "the camera's clear took it")
        held = NoticePolicy.clearing(held, source: .camera)
        XCTAssertEqual(held, [update])
        XCTAssertEqual(NoticePolicy.clearing(held, source: .glassesUpdate), [], "its own withdrawal")
    }

    /// A later requirement replaces the earlier one rather than queueing behind it.
    func testADifferentRequirementReplacesTheOneOnScreen() {
        var held = NoticePolicy.merge([], with: AppNotice(text: firmware, severity: .warning,
                                                          source: .glassesUpdate, postedAt: 0))
        held = NoticePolicy.merge(held, with: AppNotice(text: appUpdate, severity: .warning,
                                                        source: .glassesUpdate, postedAt: 1))
        XCTAssertEqual(held.map(\.text), [appUpdate])
    }

    // MARK: - Once per process

    func testARequirementIsAnnouncedOnTheFirstConnectedReading() {
        var ledger = Policy.Ledger()
        XCTAssertEqual(ledger.note(.deviceUpdateRequired), .announce(firmware))
        XCTAssertTrue(ledger.isOwed(firmware))
    }

    func testCompatibleUndefinedAndAwaySayNothing() {
        var ledger = Policy.Ledger()
        XCTAssertEqual(ledger.note(nil), .nothing)
        XCTAssertEqual(ledger.note(.undefined), .nothing)
        XCTAssertEqual(ledger.note(.compatible), .nothing)
        XCTAssertNil(ledger.owed)
        XCTAssertTrue(ledger.said.isEmpty)
    }

    func testTheSameReadingAgainWhileOwedIsNotAnnouncedTwice() {
        var ledger = Policy.Ledger()
        XCTAssertEqual(ledger.note(.sdkUpdateRequired), .announce(appUpdate))
        XCTAssertEqual(ledger.note(.sdkUpdateRequired), .nothing)
        XCTAssertTrue(ledger.isOwed(appUpdate), "still waiting to be said")
    }

    func testOnceSaidItIsNotSaidAgainHoweverOftenTheGlassesReconnect() {
        var ledger = Policy.Ledger()
        XCTAssertEqual(ledger.note(.deviceUpdateRequired), .announce(firmware))
        XCTAssertTrue(ledger.noteSaid(firmware))
        XCTAssertFalse(ledger.isOwed(firmware))

        for _ in 0..<3 {
            XCTAssertEqual(ledger.note(nil), .nothing)                    // the link drops
            XCTAssertEqual(ledger.note(.undefined), .nothing)             // back, not said yet
            XCTAssertEqual(ledger.note(.deviceUpdateRequired), .nothing)  // and says it again
        }
        XCTAssertNil(ledger.owed)
    }

    func testADifferentRequirementIsItsOwnSentence() {
        var ledger = Policy.Ledger()
        XCTAssertEqual(ledger.note(.deviceUpdateRequired), .announce(firmware))
        ledger.noteSaid(firmware)
        XCTAssertEqual(ledger.note(.sdkUpdateRequired), .announce(appUpdate))
        ledger.noteSaid(appUpdate)
        XCTAssertEqual(ledger.note(.deviceUpdateRequired), .nothing)
        XCTAssertEqual(ledger.note(.sdkUpdateRequired), .nothing)
    }

    // MARK: - Only while connected, and only while true

    func testTheLinkGoingBeforeItIsSaidDropsItAndTheNextConnectionSaysIt() {
        var ledger = Policy.Ledger()
        XCTAssertEqual(ledger.note(.deviceUpdateRequired), .announce(firmware))
        XCTAssertEqual(ledger.note(nil), .nothing)
        XCTAssertFalse(ledger.isOwed(firmware), "nobody is connected to say it about")
        XCTAssertFalse(ledger.noteSaid(firmware), "a sentence no longer owed is not recorded as said")
        XCTAssertTrue(ledger.said.isEmpty)

        XCTAssertEqual(ledger.note(.deviceUpdateRequired), .announce(firmware),
                       "it was never heard, so the next connection says it")
    }

    func testTheRequirementLiftingBeforeItIsSaidDropsIt() {
        var ledger = Policy.Ledger()
        XCTAssertEqual(ledger.note(.deviceUpdateRequired), .announce(firmware))
        XCTAssertEqual(ledger.note(.compatible), .nothing)
        XCTAssertFalse(ledger.isOwed(firmware))
    }

    func testAChangedRequirementReplacesTheOneStillWaiting() {
        var ledger = Policy.Ledger()
        XCTAssertEqual(ledger.note(.deviceUpdateRequired), .announce(firmware))
        XCTAssertEqual(ledger.note(.sdkUpdateRequired), .announce(appUpdate))
        XCTAssertFalse(ledger.isOwed(firmware))
        XCTAssertTrue(ledger.isOwed(appUpdate))
    }

    func testASentenceThatWasNeverPlayedIsForgottenSoItCanBeSaidLater() {
        var ledger = Policy.Ledger()
        XCTAssertEqual(ledger.note(.sdkUpdateRequired), .announce(appUpdate))
        ledger.noteSaid(appUpdate)
        ledger.noteNotHeard(appUpdate)
        XCTAssertEqual(ledger.note(nil), .nothing)
        XCTAssertEqual(ledger.note(.sdkUpdateRequired), .announce(appUpdate))
    }

    // MARK: - One record for both speakers

    /// A build the glasses refuse reaches the camera's own notice with the same sentence.
    func testTheCameraDoesNotRepeatWhatTheLinkAlreadySaidOrIsAboutToSay() {
        var ledger = Policy.Ledger()
        XCTAssertEqual(ledger.note(.sdkUpdateRequired), .announce(appUpdate))
        XCTAssertFalse(ledger.claim(appUpdate), "waiting to be said at link time")
        ledger.noteSaid(appUpdate)
        XCTAssertFalse(ledger.claim(appUpdate), "said at link time")
    }

    func testTheLinkDoesNotRepeatWhatTheCameraSaid() {
        var ledger = Policy.Ledger()
        XCTAssertTrue(ledger.claim(appUpdate), "the camera met the refusal first")
        XCTAssertFalse(ledger.claim(appUpdate), "and says it once itself")
        XCTAssertEqual(ledger.note(.sdkUpdateRequired), .nothing)
    }

    func testTheCamerasOtherNoticesAreSaidOnceEach() {
        var ledger = Policy.Ledger()
        let companion = DATCompatibilityMessage.message(for: .datAppOnTheGlassesUpdateRequired)!
        XCTAssertTrue(ledger.claim(companion))
        XCTAssertFalse(ledger.claim(companion))
        XCTAssertEqual(ledger.note(.deviceUpdateRequired), .announce(firmware),
                       "a different sentence is still owed")
    }

    // MARK: - Delivery

    func testAnOwedSentenceWaitsForSpeechAndThenGoes() {
        let free = AudibleLifecyclePolicy.SpeechRoute()
        XCTAssertEqual(Policy.delivery(stillOwed: true, route: free), .play)
        XCTAssertEqual(Policy.delivery(
            stillOwed: true, route: .init(assistantSpeaking: true)), .wait)
        XCTAssertEqual(Policy.delivery(
            stillOwed: true, route: .init(voiceOverAnnouncing: true)), .wait)
    }

    func testASentenceNoLongerOwedIsDroppedWhateverTheRoute() {
        XCTAssertEqual(Policy.delivery(stillOwed: false, route: .init()), .drop)
        XCTAssertEqual(Policy.delivery(stillOwed: false, route: .init(assistantSpeaking: true)), .drop)
    }

    func testItSettlesPastTheConnectionsOwnAudioHandOff() {
        // The hand-off to the glasses runs two and a half seconds after the link and stands aside
        // for anything speaking.
        XCTAssertGreaterThan(Policy.settleSeconds, 2.5)
    }

    func testOnlyPlaybackCountsAsHavingBeenTold() {
        XCTAssertTrue(Policy.wasHeard(.completed))
        XCTAssertTrue(Policy.wasHeard(.interrupted(by: .bargeIn)))
        XCTAssertTrue(Policy.wasHeard(.interrupted(by: .newUtterance)))
        XCTAssertFalse(Policy.wasHeard(.suppressed(reason: .noRoute)))
        XCTAssertFalse(Policy.wasHeard(.suppressed(reason: .silentMode)))
        XCTAssertFalse(Policy.wasHeard(.failed(reason: "engine")))
    }
}
