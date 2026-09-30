import XCTest
@testable import OpenGlasses

/// Plan GJ P0: every assignable action against every conversation state, the Agent Mode gate,
/// the glasses-camera-only photo rule, and the earcon every outcome carries.
final class TempleActionResolverTests: XCTestCase {

    private let allActivities: [TempleContext.Activity] = [
        .standby, .listening, .thinking, .speaking, .liveSession, .busy,
    ]

    private func context(_ activity: TempleContext.Activity,
                         camera: Bool = true,
                         agentMode: Bool = true,
                         agent: Bool = true,
                         micMuted: Bool = false,
                         liveMicMuted: Bool = false,
                         recording: Bool = false,
                         digest: Bool = true,
                         quickActions: Set<String> = ["qa"]) -> TempleContext {
        TempleContext(activity: activity, agentModeEnabled: agentMode, agentAvailable: agent,
                      micMuted: micMuted, liveMicMuted: liveMicMuted, recording: recording,
                      glassesCameraReady: camera, digestEnabled: digest,
                      quickActionIDs: quickActions)
    }

    private func resolve(_ action: TempleAction, _ context: TempleContext) -> TempleOutcome {
        TempleActionResolver.resolve(action: action, context: context)
    }

    // MARK: - Start talking

    func testStartTalking() {
        XCTAssertEqual(resolve(.startTalking, context(.standby)), .run(.startListening))
        XCTAssertEqual(resolve(.startTalking, context(.speaking)), .run(.interruptAndListen))
        XCTAssertEqual(resolve(.startTalking, context(.listening)), .ignored(.alreadyListening))
        XCTAssertEqual(resolve(.startTalking, context(.liveSession)), .ignored(.alreadyListening))
        XCTAssertEqual(resolve(.startTalking, context(.thinking)), .ignored(.busy))
        XCTAssertEqual(resolve(.startTalking, context(.busy)), .ignored(.busy))
    }

    // MARK: - Hang up

    func testHangUp() {
        XCTAssertEqual(resolve(.hangUp, context(.standby)), .ignored(.nothingToEnd))
        for activity: TempleContext.Activity in [.listening, .thinking, .speaking] {
            XCTAssertEqual(resolve(.hangUp, context(activity)), .run(.endConversation), "\(activity)")
        }
        XCTAssertEqual(resolve(.hangUp, context(.liveSession)), .run(.endLiveSession))
        XCTAssertEqual(resolve(.hangUp, context(.busy)), .ignored(.busy))
    }

    func testHangUpInStandbyGetsASoftTone() {
        XCTAssertEqual(TempleEarcon.for(resolve(.hangUp, context(.standby))), .refused)
        XCTAssertNil(TempleIgnoreReason.nothingToEnd.spokenLine)
    }

    // MARK: - Mute

    func testMuteToggles() {
        XCTAssertEqual(resolve(.mute, context(.standby)), .run(.setMicMuted(true)))
        XCTAssertEqual(resolve(.mute, context(.standby, micMuted: true)), .run(.setMicMuted(false)))
        XCTAssertEqual(resolve(.mute, context(.liveSession)), .run(.setLiveMicMuted(true)))
        XCTAssertEqual(resolve(.mute, context(.liveSession, liveMicMuted: true)), .run(.setLiveMicMuted(false)))
        for activity: TempleContext.Activity in [.listening, .thinking, .speaking] {
            XCTAssertEqual(resolve(.mute, context(activity)), .run(.muteAndEndConversation), "\(activity)")
        }
        XCTAssertEqual(resolve(.mute, context(.busy)), .ignored(.busy))
    }

    // MARK: - Photos

    func testPhotoDescribeOnlyInStandbyAndOnlyFromTheGlasses() {
        XCTAssertEqual(resolve(.photoDescribe, context(.standby)), .run(.photoDescribe))
        XCTAssertEqual(resolve(.photoDescribe, context(.standby, camera: false)), .ignored(.noGlassesCamera))
        for activity in allActivities where activity != .standby {
            XCTAssertEqual(resolve(.photoDescribe, context(activity)), .ignored(.busy), "\(activity)")
        }
    }

    func testPhotoToCameraRollNeedsTheGlassesCamera() {
        for activity in allActivities where activity != .busy {
            XCTAssertEqual(resolve(.photoToCameraRoll, context(activity)), .run(.photoToCameraRoll))
            XCTAssertEqual(resolve(.photoToCameraRoll, context(activity, camera: false)),
                           .ignored(.noGlassesCamera))
        }
        XCTAssertEqual(resolve(.photoToCameraRoll, context(.busy)), .ignored(.busy))
    }

    func testNoGlassesCameraRefusalSaysSo() {
        // From a pocket, a refusal must be audible and specific, never a silent phone shot.
        XCTAssertNotNil(TempleIgnoreReason.noGlassesCamera.spokenLine)
    }

    // MARK: - Digest, recording, Quick Actions

    func testReadDigest() {
        XCTAssertEqual(resolve(.readDigest, context(.standby)), .run(.readDigest))
        XCTAssertEqual(resolve(.readDigest, context(.standby, digest: false)), .ignored(.digestOff))
        XCTAssertEqual(resolve(.readDigest, context(.speaking)), .ignored(.busy))
    }

    func testToggleRecording() {
        XCTAssertEqual(resolve(.toggleRecording, context(.standby)), .run(.toggleRecording(starting: true)))
        XCTAssertEqual(resolve(.toggleRecording, context(.liveSession, recording: true)),
                       .run(.toggleRecording(starting: false)))
        // Starting needs the glasses camera; stopping never does.
        XCTAssertEqual(resolve(.toggleRecording, context(.standby, camera: false)), .ignored(.noGlassesCamera))
        XCTAssertEqual(resolve(.toggleRecording, context(.standby, camera: false, recording: true)),
                       .run(.toggleRecording(starting: false)))
        XCTAssertEqual(resolve(.toggleRecording, context(.busy)), .ignored(.busy))
    }

    func testQuickAction() {
        XCTAssertEqual(resolve(.quickAction("qa"), context(.standby)), .run(.quickAction("qa")))
        XCTAssertEqual(resolve(.quickAction("gone"), context(.standby)), .ignored(.quickActionMissing))
        XCTAssertEqual(resolve(.quickAction("qa"), context(.listening)), .ignored(.busy))
    }

    func testNothingIsIgnoredEverywhere() {
        for activity in allActivities {
            XCTAssertEqual(resolve(.nothing, context(activity)), .ignored(.unassigned))
        }
    }

    // MARK: - Agent gate

    func testAskAgentNeedsAgentMode() {
        XCTAssertEqual(resolve(.askAgent, context(.standby)), .run(.askAgent))
        XCTAssertEqual(resolve(.askAgent, context(.standby, agentMode: false, agent: false)),
                       .ignored(.agentModeOff))
        XCTAssertEqual(resolve(.askAgent, context(.standby, agentMode: true, agent: false)),
                       .ignored(.agentNotConfigured))
        // Agent Mode off wins over every other state — the gate is checked first.
        for activity in allActivities {
            XCTAssertEqual(resolve(.askAgent, context(activity, agentMode: false)), .ignored(.agentModeOff))
        }
        XCTAssertEqual(resolve(.askAgent, context(.speaking)), .ignored(.busy))
        XCTAssertTrue(TempleAction.askAgent.requiresAgentMode)
        XCTAssertEqual(TempleAction.builtIns.filter(\.requiresAgentMode), [.askAgent])
    }

    // MARK: - Map lookup and earcons

    func testResolveByGestureUsesTheMap() {
        let map = TempleGestureMap.defaults
        XCTAssertEqual(TempleActionResolver.resolve(gesture: .one, map: map, context: context(.standby)),
                       .run(.startListening))
        XCTAssertEqual(TempleActionResolver.resolve(gesture: .two, map: map, context: context(.speaking)),
                       .run(.endConversation))
        XCTAssertEqual(TempleActionResolver.resolve(gesture: .three, map: map, context: context(.liveSession)),
                       .run(.setLiveMicMuted(true)))
    }

    func testEveryOutcomeIsAudible() {
        // Every run outcome either plays an earcon or triggers an action with its own cue, and
        // every refusal plays the refusal tone.
        let actions = TempleAction.builtIns + [.quickAction("qa"), .quickAction("gone")]
        for action in actions {
            for activity in allActivities {
                for camera in [true, false] {
                    let outcome = resolve(action, context(activity, camera: camera))
                    let earcon = TempleEarcon.for(outcome)
                    switch outcome {
                    case .ignored:
                        XCTAssertEqual(earcon, .refused)
                    case .run(let effect):
                        if earcon == .ownCue {
                            XCTAssertTrue([.startListening, .askAgent, .endConversation].contains(effect),
                                          "\(effect) has no cue of its own")
                        } else {
                            XCTAssertFalse(earcon.tones.isEmpty)
                        }
                    }
                }
            }
        }
    }

    func testMuteEarconsDiffer() {
        XCTAssertEqual(TempleEarcon.for(.run(.setMicMuted(true))), .muted)
        XCTAssertEqual(TempleEarcon.for(.run(.setMicMuted(false))), .unmuted)
        XCTAssertNotEqual(TempleEarcon.muted.tones.map(\.frequency), TempleEarcon.unmuted.tones.map(\.frequency))
    }
}
