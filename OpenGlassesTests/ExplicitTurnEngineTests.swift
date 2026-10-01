import XCTest
import AVFoundation
@testable import OpenGlasses

/// Plan GU §2 — push-to-talk and listening-off turns use the shared engine, and leave nothing
/// running: after a turn ends with no listener wanted, no engine runs and no lease is held.
///
/// Driven through `WakeWordService`'s seams: the consumer-engine start, the recognizer start, the
/// cleanup and the graph are substituted (a simulator has no microphone route), and the session
/// coordinator is a fresh one over a fake session — never the shared one.
@MainActor
final class ExplicitTurnEngineTests: XCTestCase {

    private final class FakeSession: AudioSessionConforming, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
        var currentRoutePortTypes: [AVAudioSession.Port] = []
        private func record(_ s: String) { lock.lock(); _calls.append(s); lock.unlock() }
        func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                         options: AVAudioSession.CategoryOptions) throws { record("setCategory") }
        func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
            record(active ? "activate" : (options.contains(.notifyOthersOnDeactivation) ? "deactivateNotify" : "deactivate"))
        }
        func overrideOutputAudioPort(_ port: AVAudioSession.PortOverride) throws {}
        func setPreferredSampleRate(_ sampleRate: Double) throws {}
        func setPreferredIOBufferDuration(_ duration: TimeInterval) throws {}
    }

    private final class Harness {
        var graph = ListenerGraphSnapshot()
        var calls: [String] = []
        let session = FakeSession()
        lazy var coordinator = AudioSessionCoordinator(session: session)

        @MainActor
        func install(on service: WakeWordService, silentMode: Bool, listeningEnabled: Bool) {
            let coordinator = self.coordinator
            service.sessionCoordinator = { coordinator }
            service.turnListeningOverride = { (silentMode: silentMode, listeningEnabled: listeningEnabled) }
            service.consumerEngineStartOverride = { [weak self, weak service] in
                guard let self, let service else { return }
                self.calls.append("consumerEngine")
                // What the real path does: configure (lease) and start an engine with its tap, no
                // recognition task.
                service.sessionLease = coordinator.assumeOwnership(.wakeWord)
                self.graph = ListenerGraphSnapshot(engineRunning: true, tapInstalled: true, recognition: .none)
            }
            service.permissionOverride = { true }
            service.recognizerAvailabilityOverride = { true }
            service.audioSessionConfigureOverride = { [weak service] in
                service?.sessionLease = coordinator.assumeOwnership(.wakeWord)
            }
            service.startRecognitionOverride = { [weak self] in
                self?.calls.append("startRecognition")
                self?.graph = ListenerGraphSnapshot(engineRunning: true, tapInstalled: true, recognition: .running)
            }
            service.cleanupAudioEngineOverride = { [weak self] in
                self?.calls.append("cleanup")
                self?.graph = ListenerGraphSnapshot()
            }
            service.graphSnapshotOverride = { [weak self] in self?.graph ?? ListenerGraphSnapshot() }
        }
    }

    func testAPushToTalkTurnUsesTheSharedConsumerEngineAndLeavesNothing() async throws {
        let service = WakeWordService()
        let harness = Harness()
        harness.install(on: service, silentMode: true, listeningEnabled: true)

        try await service.ensureAudioEngineRunning()
        XCTAssertEqual(harness.calls, ["consumerEngine"], "the shared engine, never the dedicated fallback")
        XCTAssertFalse(harness.calls.contains("startRecognition"), "push-to-talk never runs the wake recognizer")
        XCTAssertTrue(harness.graph.engineRunning)
        XCTAssertNotNil(service.sessionLease)

        // The turn ends; push-to-talk wants no listener.
        await TurnAudioRelease.run(.init(
            playDisconnectTone: {},
            announceResumingMedia: { false },
            settle: {},
            stopRecognizerAndEngine: { service.stopConversationEngine(listenerWanted: false) },
            handBack: { await service.handBackConversationAudio() },
            rearm: { XCTFail("push-to-talk does not re-arm here") },
            stayReleased: { service.ensureReleasedAfterTurn() }), rearm: false)

        XCTAssertFalse(harness.graph.engineRunning, "no engine runs after the turn")
        XCTAssertNil(service.sessionLease, "no lease held")
        XCTAssertNil(harness.coordinator.currentOwner)
        XCTAssertEqual(harness.session.calls, ["deactivateNotify"],
                       "handed back with notify, so the paused app resumes")
        XCTAssertFalse(service.isListening)
    }

    func testAListeningOffTurnIsTheSame() async throws {
        let service = WakeWordService()
        let harness = Harness()
        harness.install(on: service, silentMode: false, listeningEnabled: false)

        try await service.ensureAudioEngineRunning()
        XCTAssertEqual(harness.calls, ["consumerEngine"])
        await service.endConversationAudio(listenerWanted: false)
        service.ensureReleasedAfterTurn()
        XCTAssertFalse(harness.graph.engineRunning)
        XCTAssertNil(service.sessionLease)
        XCTAssertNil(harness.coordinator.currentOwner)
    }

    func testWithWakeWordOnTheTurnRidesTheListenersEngine() async throws {
        let service = WakeWordService()
        let harness = Harness()
        harness.install(on: service, silentMode: false, listeningEnabled: true)

        try await service.ensureAudioEngineRunning()
        XCTAssertEqual(harness.calls, ["startRecognition"], "the listener's engine, recognizer then paused")
        XCTAssertEqual(service.deliberatePause, .sharedEngine)
        XCTAssertNil(service.recognitionTask)

        // A follow-up reuses the running engine and starts nothing new.
        harness.calls.removeAll()
        try await service.ensureAudioEngineRunning()
        XCTAssertTrue(harness.calls.isEmpty)
    }

    func testTheSourceRule() {
        XCTAssertEqual(TurnEngineOwnership.source(engineRunning: true, silentMode: true, listeningEnabled: false),
                       .reuseRunning)
        XCTAssertEqual(TurnEngineOwnership.source(engineRunning: false, silentMode: true, listeningEnabled: true),
                       .consumerEngineForTurn)
        XCTAssertEqual(TurnEngineOwnership.source(engineRunning: false, silentMode: false, listeningEnabled: false),
                       .consumerEngineForTurn)
        XCTAssertEqual(TurnEngineOwnership.source(engineRunning: false, silentMode: false, listeningEnabled: true),
                       .wakeListener)
    }

    func testTheEndOfTurnStopsWheneverNoListenerIsWantedAndNobodyElseIsOnTheTap() {
        var ownership = TurnEngineOwnership()
        ownership.noteStarted(.consumerEngineForTurn)
        XCTAssertTrue(ownership.startedForTurn)
        XCTAssertTrue(ownership.endTurn(listenerWanted: false, consumersActive: false))
        XCTAssertFalse(ownership.startedForTurn)

        var withConsumers = TurnEngineOwnership()
        withConsumers.noteStarted(.consumerEngineForTurn)
        XCTAssertFalse(withConsumers.endTurn(listenerWanted: false, consumersActive: true),
                       "a recording keeps its engine")

        var inherited = TurnEngineOwnership()
        inherited.noteStarted(.reuseRunning)
        XCTAssertFalse(inherited.startedForTurn)
        XCTAssertTrue(inherited.endTurn(listenerWanted: false, consumersActive: false),
                      "whoever started it, nothing is left hot")
    }
}
