import XCTest
@testable import OpenGlasses

/// Plan LT §4 — what the temple taps' silent standby player does on a pause command. Pure; the
/// service-level wiring is in `MediaTriggerServiceTests`.
final class StandbyClaimPolicyTests: XCTestCase {

    func testKeepPlayingIsTodaysBehaviour() {
        var policy = StandbyClaimPolicy(mode: .keepPlaying)
        for (i, command) in MediaRemoteCommand.allCases.enumerated() {
            XCTAssertEqual(policy.handle(command, at: Double(i)),
                           .init(action: .none, countsAsTap: true), "\(command)")
        }
        XCTAssertFalse(policy.isPaused)
        XCTAssertEqual(policy.resumeDelayElapsed(), .none)
    }

    func testTheDefaultIsKeepPlayingUntilTheDeviceCheck() {
        let key = Config.standbyClaimModeKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(Config.standbyClaimMode, .keepPlaying)
        UserDefaults.standard.set("pauseThenResume", forKey: key)
        XCTAssertEqual(Config.standbyClaimMode, .pauseThenResume)
        UserDefaults.standard.set("nonsense", forKey: key)
        XCTAssertEqual(Config.standbyClaimMode, .keepPlaying)
    }

    func testAPauseOrToggleQuietsThePlayerForThreeSeconds() {
        for command in [MediaRemoteCommand.pause, .togglePlayPause] {
            var policy = StandbyClaimPolicy(mode: .pauseThenResume)
            XCTAssertEqual(policy.handle(command, at: 10),
                           .init(action: .pause(resumeAfter: 3), countsAsTap: true), "\(command)")
            XCTAssertTrue(policy.isPaused)
        }
        XCTAssertEqual(StandbyClaimPolicy.resumeDelay, 3)
        XCTAssertEqual(StandbyClaimPolicy.pairWindow, 0.6)
    }

    func testPlayAndTrackCommandsWhilePlayingChangeNothing() {
        var policy = StandbyClaimPolicy(mode: .pauseThenResume)
        for command in [MediaRemoteCommand.play, .nextTrack, .previousTrack] {
            XCTAssertEqual(policy.handle(command, at: 0), .init(action: .none, countsAsTap: true))
        }
        XCTAssertFalse(policy.isPaused)
    }

    func testTheDelayResumes() {
        var policy = StandbyClaimPolicy(mode: .pauseThenResume)
        _ = policy.handle(.pause, at: 0)
        XCTAssertEqual(policy.resumeDelayElapsed(), .resume)
        XCTAssertFalse(policy.isPaused)
        XCTAssertEqual(policy.resumeDelayElapsed(), .none, "only once")
    }

    /// Whichever comes first: the next command resumes, and is still a tap.
    func testTheNextCommandResumesAndIsATap() {
        for command in MediaRemoteCommand.allCases {
            var policy = StandbyClaimPolicy(mode: .pauseThenResume)
            _ = policy.handle(.pause, at: 0)
            XCTAssertEqual(policy.handle(command, at: 1.0),
                           .init(action: .resume, countsAsTap: true), "\(command)")
            XCTAssertEqual(policy.resumeDelayElapsed(), .none, "the timer then finds nothing")
        }
    }

    /// Some stacks send one press as pause then play.
    func testAPlayInsideThePairWindowIsTheSameTap() {
        var policy = StandbyClaimPolicy(mode: .pauseThenResume)
        _ = policy.handle(.pause, at: 0)
        XCTAssertEqual(policy.handle(.play, at: 0.59), .init(action: .resume, countsAsTap: false))

        var later = StandbyClaimPolicy(mode: .pauseThenResume)
        _ = later.handle(.pause, at: 0)
        XCTAssertEqual(later.handle(.play, at: 0.6), .init(action: .resume, countsAsTap: true),
                       "at the window's edge it is a new tap")

        var toggle = StandbyClaimPolicy(mode: .pauseThenResume)
        _ = toggle.handle(.pause, at: 5)
        XCTAssertEqual(toggle.handle(.togglePlayPause, at: 5.1), .init(action: .resume, countsAsTap: true),
                       "only a play pairs with the pause")
    }

    func testTapsAlternatePauseAndResume() {
        var policy = StandbyClaimPolicy(mode: .pauseThenResume)
        XCTAssertEqual(policy.handle(.pause, at: 0).action, .pause(resumeAfter: 3))
        XCTAssertEqual(policy.handle(.play, at: 1.5).action, .resume)
        XCTAssertEqual(policy.handle(.pause, at: 3).action, .pause(resumeAfter: 3))
    }

    func testResetForgetsAPause() {
        var policy = StandbyClaimPolicy(mode: .pauseThenResume)
        _ = policy.handle(.pause, at: 0)
        policy.reset()
        XCTAssertFalse(policy.isPaused)
        XCTAssertEqual(policy.resumeDelayElapsed(), .none)
        XCTAssertEqual(policy.handle(.pause, at: 0.1).action, .pause(resumeAfter: 3))
    }
}
