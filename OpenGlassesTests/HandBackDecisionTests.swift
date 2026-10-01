import XCTest
import AVFoundation
@testable import OpenGlasses

/// Plan GU §3 — when the end of a conversation may deactivate the session (the only call that tells
/// Podcasts or Music to resume), and the coordinator applying it over a fake session.
final class HandBackDecisionTests: XCTestCase {

    // MARK: - Decision

    func testWakeWordOrDictationAloneDeactivates() {
        XCTAssertEqual(HandBackDecision.decide(owner: .wakeWord, coexisting: [], sharedConsumersActive: false),
                       .deactivate)
        XCTAssertEqual(HandBackDecision.decide(owner: .transcription, coexisting: [], sharedConsumersActive: false),
                       .deactivate)
        XCTAssertEqual(HandBackDecision.decide(owner: nil, coexisting: [], sharedConsumersActive: false),
                       .deactivate, "push-to-talk's late reply: nobody holds a lease")
    }

    func testARealtimeOwnerDefersTheDeactivate() {
        for owner in [AudioSessionOwner.geminiLive, .openAIRealtime, .expertCall, .liveTranslation, .captureAudio] {
            XCTAssertEqual(HandBackDecision.decide(owner: owner, coexisting: [], sharedConsumersActive: false),
                           .leaveToOwner(owner))
        }
    }

    func testALiveTTSRiderDefersTheDeactivate() {
        XCTAssertEqual(HandBackDecision.decide(owner: .wakeWord, coexisting: [.textToSpeech],
                                               sharedConsumersActive: false),
                       .reconfigureInPlace(.coexistingRider(.textToSpeech)))
        XCTAssertEqual(HandBackDecision.decide(owner: .wakeWord, coexisting: [.mediaTrigger],
                                               sharedConsumersActive: false),
                       .reconfigureInPlace(.coexistingRider(.mediaTrigger)),
                       "the temple-tap claim's silent loop would die with the session")
    }

    func testSharedConsumersKeepTheSessionRunning() {
        XCTAssertEqual(HandBackDecision.decide(owner: .wakeWord, coexisting: [], sharedConsumersActive: true),
                       .reconfigureInPlace(.sharedConsumers))
    }

    // MARK: - Coordinator

    private final class FakeSession: AudioSessionConforming, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
        var currentRoutePortTypes: [AVAudioSession.Port] = []
        private func record(_ s: String) { lock.lock(); _calls.append(s); lock.unlock() }
        func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                         options: AVAudioSession.CategoryOptions) throws { record("setCategory") }
        func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
            record("setActive(\(active),notify=\(options.contains(.notifyOthersOnDeactivation)))")
        }
        func overrideOutputAudioPort(_ port: AVAudioSession.PortOverride) throws {}
        func setPreferredSampleRate(_ sampleRate: Double) throws {}
        func setPreferredIOBufferDuration(_ duration: TimeInterval) throws {}
    }

    func testHandBackDeactivatesWithNotifyAndFreesTheLedger() async {
        let fake = FakeSession()
        let coordinator = AudioSessionCoordinator(session: fake)
        let lease = coordinator.assumeOwnership(.wakeWord)
        let decision = await coordinator.handBack(lease, sharedConsumersActive: false)
        XCTAssertEqual(decision, .deactivate)
        XCTAssertEqual(fake.calls, ["setActive(false,notify=true)"])
        XCTAssertNil(coordinator.currentOwner, "no lease held after the hand-back")
    }

    func testHandBackLeavesARealtimeSessionAlone() async {
        let fake = FakeSession()
        let coordinator = AudioSessionCoordinator(session: fake)
        let ours = coordinator.assumeOwnership(.wakeWord)
        _ = coordinator.assumeOwnership(.geminiLive)
        let decision = await coordinator.handBack(ours, sharedConsumersActive: false)
        XCTAssertEqual(decision, .leaveToOwner(.geminiLive))
        XCTAssertTrue(fake.calls.isEmpty, "never deactivates a live session out from under it")
        XCTAssertEqual(coordinator.currentOwner, .geminiLive)
    }

    func testHandBackDefersToALiveTTSRider() async {
        let fake = FakeSession()
        let coordinator = AudioSessionCoordinator(session: fake)
        let lease = coordinator.assumeOwnership(.wakeWord)
        let token = coordinator.beginCoexisting(.textToSpeech)
        let decision = await coordinator.handBack(lease, sharedConsumersActive: false)
        XCTAssertEqual(decision, .reconfigureInPlace(.coexistingRider(.textToSpeech)))
        XCTAssertTrue(fake.calls.isEmpty)
        XCTAssertEqual(coordinator.currentOwner, .wakeWord, "the lease is kept for the rider's owner")
        coordinator.endCoexisting(token)
    }
}
