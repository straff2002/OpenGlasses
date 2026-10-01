import XCTest
@testable import OpenGlasses

/// Plan GU §3 — the end-of-conversation hand-back order.
@MainActor
final class TurnAudioReleaseSequenceTests: XCTestCase {

    private func deps(_ log: Box<[String]>, announces: Bool) -> TurnAudioRelease.Deps {
        TurnAudioRelease.Deps(
            playDisconnectTone: { log.value.append("tone") },
            announceResumingMedia: {
                guard announces else { return false }
                log.value.append("announce")
                return true
            },
            settle: { log.value.append("settle") },
            stopRecognizerAndEngine: { log.value.append("stopEngine") },
            handBack: { log.value.append("deactivate") },
            rearm: { log.value.append("rearm") },
            stayReleased: { log.value.append("stayReleased") })
    }

    func testTheFullOrderWithMediaToAnnounce() async {
        let log = Box<[String]>([])
        await TurnAudioRelease.run(deps(log, announces: true), rearm: true)
        XCTAssertEqual(log.value, ["tone", "announce", "stopEngine", "deactivate", "rearm"])
    }

    func testAnnouncementBeforeDeactivate() async {
        let log = Box<[String]>([])
        await TurnAudioRelease.run(deps(log, announces: true), rearm: true)
        XCTAssertLessThan(log.value.firstIndex(of: "announce")!, log.value.firstIndex(of: "deactivate")!,
                          "the announcement no longer re-pauses the app it names")
        XCTAssertLessThan(log.value.firstIndex(of: "tone")!, log.value.firstIndex(of: "announce")!)
    }

    func testEngineStoppedBeforeDeactivate() async {
        let log = Box<[String]>([])
        await TurnAudioRelease.run(deps(log, announces: false), rearm: true)
        XCTAssertLessThan(log.value.firstIndex(of: "stopEngine")!, log.value.firstIndex(of: "deactivate")!,
                          "deactivating with running I/O fails")
    }

    func testWithNothingToAnnounceTheToneIsGivenTimeToFinish() async {
        let log = Box<[String]>([])
        await TurnAudioRelease.run(deps(log, announces: false), rearm: true)
        XCTAssertEqual(log.value, ["tone", "settle", "stopEngine", "deactivate", "rearm"])
        XCTAssertGreaterThanOrEqual(TurnAudioRelease.toneSettleSeconds, 0.24, "the disconnect tone's length")
    }

    func testSkipMeansNoReactivation() async {
        let log = Box<[String]>([])
        await TurnAudioRelease.run(deps(log, announces: false), rearm: false)
        XCTAssertFalse(log.value.contains("rearm"))
        XCTAssertEqual(log.value.last, "stayReleased")
        XCTAssertTrue(log.value.contains("deactivate"), "the hand-back still happens")
    }
}
