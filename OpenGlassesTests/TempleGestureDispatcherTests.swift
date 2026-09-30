import XCTest
@testable import OpenGlasses

/// Plan GJ P1: the dispatcher over a fake app — assignment lookup, resolution against the app's
/// state, earcon before effect, spoken refusals, and test mode running nothing.
@MainActor
final class TempleGestureDispatcherTests: XCTestCase {

    private final class FakeApp: TempleActionPerforming {
        var context = TempleContext(activity: .standby, glassesCameraReady: true)
        var effects: [TempleEffect] = []
        var earcons: [TempleEarcon] = []
        var lines: [String] = []
        /// Order of calls, to prove the earcon precedes the effect.
        var log: [String] = []

        func templeContext() -> TempleContext { context }
        func performTempleEffect(_ effect: TempleEffect) async {
            effects.append(effect)
            log.append("effect")
        }
        func playTempleEarcon(_ earcon: TempleEarcon) {
            earcons.append(earcon)
            log.append("earcon")
        }
        func announceTempleLine(_ line: String) async {
            lines.append(line)
            log.append("line")
        }
    }

    private var app = FakeApp()
    private var map = TempleGestureMap.defaults

    override func setUp() {
        super.setUp()
        app = FakeApp()
        map = .defaults
    }

    private func makeDispatcher() -> TempleGestureDispatcher {
        TempleGestureDispatcher(performer: app, loadMap: { [unowned self] in self.map },
                                now: { Date(timeIntervalSince1970: 0) })
    }

    func testOneTapInStandbyStartsListening() async {
        let dispatcher = makeDispatcher()
        let outcome = await dispatcher.handle(.one, command: .togglePlayPause)
        XCTAssertEqual(outcome, .run(.startListening))
        XCTAssertEqual(app.effects, [.startListening])
        XCTAssertEqual(app.earcons, [.ownCue])
    }

    func testTwoTapsWhileSpeakingHangsUp() async {
        app.context.activity = .speaking
        let dispatcher = makeDispatcher()
        await dispatcher.handle(.two, command: .nextTrack)
        XCTAssertEqual(app.effects, [.endConversation])
    }

    func testThreeTapsInLiveSessionMutesTheSessionMic() async {
        app.context.activity = .liveSession
        let dispatcher = makeDispatcher()
        await dispatcher.handle(.three, command: .previousTrack)
        XCTAssertEqual(app.effects, [.setLiveMicMuted(true)])
        XCTAssertEqual(app.earcons, [.muted])
        XCTAssertEqual(app.log, ["earcon", "effect"])
    }

    func testRemappedTapFollowsTheMap() async {
        map.one = .photoToCameraRoll
        let dispatcher = makeDispatcher()
        await dispatcher.handle(.one, command: .play)
        XCTAssertEqual(app.effects, [.photoToCameraRoll])
        XCTAssertEqual(dispatcher.lastDetection?.action, .photoToCameraRoll)
        XCTAssertEqual(dispatcher.lastDetection?.command, .play)
    }

    func testRefusalWithAReasonIsSpokenAndRunsNothing() async {
        map.one = .photoDescribe
        app.context.glassesCameraReady = false
        let dispatcher = makeDispatcher()
        let outcome = await dispatcher.handle(.one, command: .togglePlayPause)
        XCTAssertEqual(outcome, .ignored(.noGlassesCamera))
        XCTAssertTrue(app.effects.isEmpty)
        XCTAssertEqual(app.earcons, [.refused])
        XCTAssertEqual(app.lines, [TempleIgnoreReason.noGlassesCamera.spokenLine!])
    }

    func testHangUpInStandbyIsAToneOnly() async {
        let dispatcher = makeDispatcher()
        let outcome = await dispatcher.handle(.two, command: .nextTrack)
        XCTAssertEqual(outcome, .ignored(.nothingToEnd))
        XCTAssertEqual(app.earcons, [.refused])
        XCTAssertTrue(app.lines.isEmpty)
        XCTAssertTrue(app.effects.isEmpty)
    }

    func testAskAgentWithAgentModeOffIsRefused() async {
        map.one = .askAgent
        app.context.agentModeEnabled = false
        let dispatcher = makeDispatcher()
        let outcome = await dispatcher.handle(.one, command: .togglePlayPause)
        XCTAssertEqual(outcome, .ignored(.agentModeOff))
        XCTAssertTrue(app.effects.isEmpty)
    }

    func testTestModeAnnouncesAndRunsNothing() async {
        let dispatcher = makeDispatcher()
        dispatcher.testMode = true
        let outcome = await dispatcher.handle(.two, command: .nextTrack)
        XCTAssertNil(outcome)
        XCTAssertTrue(app.effects.isEmpty)
        XCTAssertEqual(app.lines.count, 1)
        XCTAssertEqual(app.lines.first,
                       TempleGestureDispatcher.testLine(gesture: .two, command: .nextTrack, action: .hangUp))
        XCTAssertEqual(dispatcher.lastDetection?.gesture, .two)
        XCTAssertNil(dispatcher.lastDetection?.outcome)
    }

    func testTestLineNamesTheRawCommand() {
        let line = TempleGestureDispatcher.testLine(gesture: .one, command: .pause, action: .nothing)
        XCTAssertTrue(line.contains(MediaRemoteCommand.pause.spokenName))
        XCTAssertTrue(line.contains(TempleGesture.one.displayName))
    }

    func testNoPerformerDoesNothing() async {
        let dispatcher = TempleGestureDispatcher(performer: nil, loadMap: { .defaults })
        let outcome = await dispatcher.handle(.one, command: .togglePlayPause)
        XCTAssertNil(outcome)
    }

    func testLogTokensNeverCarryAQuickActionId() {
        XCTAssertEqual(TempleGestureDispatcher.logToken(.run(.quickAction("secret-id"))), "quickAction")
        XCTAssertEqual(TempleGestureDispatcher.logToken(.ignored(.busy)), "ignored.busy")
    }
}
