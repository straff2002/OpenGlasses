import XCTest
@testable import OpenGlasses

/// Plan HX P0 — a lost glasses link is heard, once, and only when the wearer did not cause it.
///
/// Both halves are failures. Silence leaves a wearer with the phone in a pocket talking to glasses
/// that have gone. A tone for every time they take the glasses off or press Disconnect teaches
/// them to stop listening for it.
final class GlassesLinkCuePolicyTests: XCTestCase {

    private typealias Policy = GlassesLinkCuePolicy

    private func use(_ link: GlassesConnectionPhase = .connected,
                     stoodDown reason: GlassesUse.StandDownReason? = nil) -> GlassesUse {
        var use = GlassesUse()
        use.linkChanged(link)
        if let reason { use.standDown(reason) }
        return use
    }

    // MARK: - The table

    func testALinkLostWhileWornIsHeard() {
        XCTAssertEqual(Policy.onLoss(cause: .linkLost, wasWorn: true, standDownActive: false), .lost)
    }

    /// Glasses that do not report worn are treated as worn: the failure being fixed is silence.
    func testALinkLostWhileWornIsUnknownIsHeard() {
        XCTAssertEqual(Policy.onLoss(cause: .linkLost, wasWorn: nil, standDownActive: false), .lost)
    }

    func testALinkLostAfterTheGlassesWereTakenOffIsSilent() {
        XCTAssertEqual(Policy.onLoss(cause: .linkLost, wasWorn: false, standDownActive: false), .none)
    }

    func testALinkLostDuringAStandDownIsSilent() {
        XCTAssertEqual(Policy.onLoss(cause: .linkLost, wasWorn: true, standDownActive: true), .none)
        XCTAssertEqual(Policy.onLoss(cause: .linkLost, wasWorn: nil, standDownActive: true), .none)
    }

    /// Whatever the worn reading: the wearer did it and knows.
    func testEveryCauseButALostLinkIsSilent() {
        for cause: Policy.Cause in [.userDisconnected, .doffedStandDown, .appTerminating] {
            for worn: Bool? in [true, false, nil] {
                XCTAssertEqual(Policy.onLoss(cause: cause, wasWorn: worn, standDownActive: false), .none,
                               "\(cause), worn \(String(describing: worn))")
            }
        }
    }

    func testARestoreAfterAPlayedLostCueSaysSo() {
        XCTAssertEqual(Policy.onRestore(lostCueWasPlayed: true), .restored)
    }

    /// The first connection at launch, a resume after Disconnect, a pair lifted out of its case.
    func testAColdConnectAddsNothingToTheConnectTone() {
        XCTAssertEqual(Policy.onRestore(lostCueWasPlayed: false), .none)
    }

    func testTheLinesAreTheOnesVoiceOverIsGiven() {
        XCTAssertEqual(Policy.voiceOverLine(for: .lost), "Glasses disconnected")
        XCTAssertEqual(Policy.voiceOverLine(for: .restored), "Glasses connected")
        XCTAssertNil(Policy.voiceOverLine(for: .none))
    }

    // MARK: - The cause, read off `GlassesUse`

    func testALinkThatLeavesConnectedUnaskedIsALostLink() {
        for after: GlassesConnectionPhase in [.addedDisconnected, .connecting] {
            XCTAssertEqual(Policy.cause(from: use(), to: use(after)), .linkLost, "\(after)")
        }
    }

    func testTheWearersDisconnectIsTheirs() {
        XCTAssertEqual(Policy.cause(from: use(), to: use(stoodDown: .user)), .userDisconnected)
    }

    func testTheAppsOwnStandDownIsNotALostLink() {
        XCTAssertEqual(Policy.cause(from: use(), to: use(stoodDown: .automatic)), .doffedStandDown)
    }

    /// Registration gone and nothing listed: the glasses were removed from the app, by hand.
    func testGlassesNoLongerAddedWereRemovedNotLost() {
        XCTAssertEqual(Policy.cause(from: use(), to: use(.noGlassesAdded)), .userDisconnected)
    }

    func testNothingIsLostWhenTheLinkWasNotUp() {
        for before: GlassesConnectionPhase in [.noGlassesAdded, .addedDisconnected, .connecting] {
            for after: GlassesConnectionPhase in [.noGlassesAdded, .addedDisconnected, .connecting, .connected] {
                XCTAssertNil(Policy.cause(from: use(before), to: use(after)), "\(before) → \(after)")
            }
        }
    }

    func testNothingIsLostWhileTheGlassesStayInUseOrStayPaused() {
        XCTAssertNil(Policy.cause(from: use(), to: use()))
        XCTAssertNil(Policy.cause(from: use(stoodDown: .user), to: use(stoodDown: .user)))
        XCTAssertNil(Policy.cause(from: use(stoodDown: .automatic), to: use(stoodDown: .user)),
                     "already out of use: a stronger stand-down is not a second loss")
        XCTAssertNil(Policy.cause(from: use(stoodDown: .user), to: use()), "a resume is not a loss")
    }

    /// The link going under a stand-down is still a lost link; what makes it silent is the
    /// stand-down, which `onLoss` is told about separately.
    func testALinkLostUnderAStandDownIsALostLinkWithTheStandDownActive() {
        let before = use(stoodDown: .user)
        XCTAssertEqual(Policy.cause(from: before, to: use(.addedDisconnected)), .linkLost)
        var ledger = Policy.Ledger()
        XCTAssertEqual(ledger.noteLoss(from: before, to: use(.addedDisconnected), wasWorn: true), .none)
        XCTAssertFalse(ledger.appOwnsLossCue)
    }

    // MARK: - The ledger

    func testAnOwedCueIsTheAppsFromTheMomentItIsDecided() {
        var ledger = Policy.Ledger()
        XCTAssertFalse(ledger.appOwnsLossCue)

        XCTAssertEqual(ledger.noteLoss(from: use(), to: use(.addedDisconnected), wasWorn: true), .lost)
        XCTAssertEqual(ledger.lostCue, .owed)
        XCTAssertTrue(ledger.appOwnsLossCue, "VoiceOver's own line is withheld while the cue waits")

        XCTAssertTrue(ledger.noteLostCuePlayed())
        XCTAssertEqual(ledger.lostCue, .played)
        XCTAssertTrue(ledger.appOwnsLossCue)
    }

    func testAPlayedLostCueEarnsTheRestoredLineOnce() {
        var ledger = Policy.Ledger()
        ledger.noteLoss(from: use(), to: use(.addedDisconnected), wasWorn: nil)
        ledger.noteLostCuePlayed()

        XCTAssertEqual(ledger.noteRestore(), .restored)
        XCTAssertEqual(ledger.lostCue, .none)
        XCTAssertEqual(ledger.noteRestore(), .none, "the next connection is an ordinary one")
    }

    /// The glasses came back before the cue was heard. Saying they had gone would now be false,
    /// and saying they are back answers a question nobody was asked.
    func testACueStillOwedAtRestoreIsDroppedAndTheRestoreIsOrdinary() {
        var ledger = Policy.Ledger()
        ledger.noteLoss(from: use(), to: use(.connecting), wasWorn: true)

        XCTAssertEqual(ledger.noteRestore(), .none)
        XCTAssertFalse(ledger.noteLostCuePlayed(), "nothing is owed any more")
        XCTAssertEqual(ledger.lostCue, .none)
    }

    func testASilentLossLeavesTheLineToVoiceOver() {
        var ledger = Policy.Ledger()
        XCTAssertEqual(ledger.noteLoss(from: use(), to: use(stoodDown: .user), wasWorn: true), .none)
        XCTAssertFalse(ledger.appOwnsLossCue)
        XCTAssertEqual(ledger.noteLoss(from: use(), to: use(.addedDisconnected), wasWorn: false), .none)
        XCTAssertFalse(ledger.appOwnsLossCue)
        XCTAssertEqual(ledger.noteRestore(), .none)
    }

    /// A heard loss, a reconnection, then the wearer's own Disconnect: the earlier cue must not
    /// keep VoiceOver quiet about the later, silent one.
    func testASilentLossAfterAHeardOneClearsTheRecord() {
        var ledger = Policy.Ledger()
        ledger.noteLoss(from: use(), to: use(.addedDisconnected), wasWorn: true)
        ledger.noteLostCuePlayed()
        ledger.noteLoss(from: use(), to: use(stoodDown: .user), wasWorn: true)
        XCTAssertFalse(ledger.appOwnsLossCue)
    }

    func testAChangeThatIsNotALossLeavesTheRecordAlone() {
        var ledger = Policy.Ledger()
        ledger.noteLoss(from: use(), to: use(.addedDisconnected), wasWorn: true)
        XCTAssertEqual(ledger.noteLoss(from: use(.addedDisconnected), to: use(.connecting), wasWorn: nil), .none)
        XCTAssertEqual(ledger.lostCue, .owed)
    }

    // MARK: - Delivery

    private func route(speaking: Bool = false, announcing: Bool = false) -> AudibleLifecyclePolicy.SpeechRoute {
        .init(assistantSpeaking: speaking, voiceOverAnnouncing: announcing)
    }

    func testAnOwedCuePlaysOnAFreeRoute() {
        XCTAssertEqual(Policy.delivery(stillOwed: true, route: route(), waited: 0), .play)
    }

    func testAnOwedCueWaitsForTheAssistantAndForVoiceOver() {
        XCTAssertEqual(Policy.delivery(stillOwed: true, route: route(speaking: true), waited: 0), .wait)
        XCTAssertEqual(Policy.delivery(stillOwed: true, route: route(announcing: true), waited: 3), .wait)
    }

    /// The same bound the session's own loss notice has: a long answer cannot bury the fact.
    func testAnOwedCueIsNotHeldBackForEver() {
        let bound = AudibleLifecyclePolicy.maxQueuedWait
        XCTAssertEqual(Policy.delivery(stillOwed: true, route: route(speaking: true),
                                       waited: bound - Policy.pollSeconds), .wait)
        XCTAssertEqual(Policy.delivery(stillOwed: true, route: route(speaking: true), waited: bound), .play)
    }

    func testACueNoLongerOwedIsDropped() {
        XCTAssertEqual(Policy.delivery(stillOwed: false, route: route(), waited: 0), .drop)
        XCTAssertEqual(Policy.delivery(stillOwed: false, route: route(speaking: true), waited: 60), .drop)
    }

    // MARK: - Worn, remembered past the link

    private func snapshot(worn: Bool?) -> GlassesConnectionSnapshot {
        var s = GlassesConnectionSnapshot(registration: .registered)
        s.apply(.devices(["a"]))
        s.apply(.deviceState(id: "a", GlassesDeviceState(link: .connected, worn: worn)))
        return s
    }

    /// By the time the app hears the link has gone, the live reading is nil by rule. The question
    /// "had they taken the glasses off?" needs the last one taken while the link was up.
    func testTheLastWornReadingOutlivesTheLink() {
        for worn: Bool? in [true, false, nil] {
            var s = snapshot(worn: worn)
            XCTAssertEqual(s.lastLiveWorn, worn)

            s.apply(.deviceState(id: "a", GlassesDeviceState(link: .disconnected, worn: nil)))
            XCTAssertNil(s.liveWorn)
            XCTAssertEqual(s.lastLiveWorn, worn, "kept: \(String(describing: worn))")
        }
    }

    func testTheRememberedReadingSurvivesTheDeviceLeavingTheList() {
        var s = snapshot(worn: false)
        s.apply(.devices([]))
        XCTAssertEqual(s.lastLiveWorn, false)
    }

    /// While the link is up it follows the device, including back to "does not say".
    func testTheRememberedReadingFollowsTheLinkWhileItIsUp() {
        var s = snapshot(worn: false)
        s.apply(.deviceState(id: "a", GlassesDeviceState(link: .connected, worn: true)))
        XCTAssertEqual(s.lastLiveWorn, true)
        s.apply(.deviceState(id: "a", GlassesDeviceState(link: .connected, worn: nil)))
        XCTAssertNil(s.lastLiveWorn)
    }

    /// A new connection starts from its own reading, not from the last one's.
    func testANewConnectionReplacesTheRememberedReading() {
        var s = snapshot(worn: false)
        s.apply(.deviceState(id: "a", GlassesDeviceState(link: .disconnected)))
        s.apply(.deviceState(id: "a", GlassesDeviceState(link: .connected, worn: nil)))
        XCTAssertNil(s.lastLiveWorn)
    }

    /// The whole path a pair shut in its case takes: off the face, then the link goes.
    func testGlassesTakenOffThenAwayAreSilentAndGlassesWornThenAwayAreHeard() {
        var doffed = snapshot(worn: true)
        doffed.apply(.deviceState(id: "a", GlassesDeviceState(link: .connected, worn: false)))
        doffed.apply(.deviceState(id: "a", GlassesDeviceState(link: .disconnected)))
        var ledger = Policy.Ledger()
        XCTAssertEqual(ledger.noteLoss(from: use(), to: use(doffed.phase), wasWorn: doffed.lastLiveWorn), .none)

        var worn = snapshot(worn: true)
        worn.apply(.deviceState(id: "a", GlassesDeviceState(link: .disconnected)))
        XCTAssertEqual(ledger.noteLoss(from: use(), to: use(worn.phase), wasWorn: worn.lastLiveWorn), .lost)
    }
}
