import XCTest
@testable import OpenGlasses

/// Plan BG P2 — the wake-word / tap-to-talk conversation-start choreography. The load-bearing
/// invariant these tests lock: the audio session + engine come up BEFORE we mark ourselves
/// listening (marking early left the shared engine dead on tap-to-talk and forced
/// TranscriptionService onto its fragile fallback engine).
@MainActor
final class ConversationStartSequenceTests: XCTestCase {

    private struct EngineError: Error {}

    private func recordingDeps(into log: Box<[String]>, engineFails: Bool = false) -> ConversationStartSequence.Deps {
        ConversationStartSequence.Deps(
            beginConversation: { log.value.append("beginConversation") },
            configureAudioSession: { log.value.append("configureAudioSession") },
            ensureAudioEngineRunning: {
                log.value.append("ensureAudioEngineRunning")
                if engineFails { throw EngineError() }
            },
            markListening: { log.value.append("markListening") },
            snapshotNowPlaying: { log.value.append("snapshotNowPlaying") },
            pauseOtherAudio: { log.value.append("pauseOtherAudio") },
            handOffMic: { log.value.append("handOffMic") },
            playAcknowledgmentTone: { log.value.append("playAcknowledgmentTone") },
            startRecording: { log.value.append("startRecording") },
            updateLiveActivity: { log.value.append("updateLiveActivity") }
        )
    }

    private static let expectedOrder = [
        "beginConversation",
        "configureAudioSession",
        "ensureAudioEngineRunning",
        "markListening",
        "snapshotNowPlaying",
        "pauseOtherAudio",
        "handOffMic",
        "playAcknowledgmentTone",
        "startRecording",
        "updateLiveActivity",
    ]

    func testRunsStagesInExactOrder() async {
        let log = Box<[String]>([])
        await ConversationStartSequence.run(recordingDeps(into: log))
        XCTAssertEqual(log.value, Self.expectedOrder)
    }

    /// The regression this seam exists to lock: the audio session + engine are brought up
    /// strictly before `markListening` (and the now-playing snapshot happens before the pause).
    func testEngineIsEnsuredBeforeListeningIsMarked() async {
        let log = Box<[String]>([])
        await ConversationStartSequence.run(recordingDeps(into: log))
        let engineAt = log.value.firstIndex(of: "ensureAudioEngineRunning")
        let listeningAt = log.value.firstIndex(of: "markListening")
        let snapshotAt = log.value.firstIndex(of: "snapshotNowPlaying")
        let pauseAt = log.value.firstIndex(of: "pauseOtherAudio")
        XCTAssertNotNil(engineAt)
        XCTAssertNotNil(listeningAt)
        XCTAssertLessThan(engineAt!, listeningAt!, "engine must be alive before we mark ourselves listening")
        XCTAssertLessThan(snapshotAt!, pauseAt!, "snapshot what's playing before pausing it")
    }

    /// An engine failure must not abort the start — transcription has its own fallback engine,
    /// so the sequence still marks listening and starts recording.
    func testEngineFailureStillCompletesTheSequence() async {
        let log = Box<[String]>([])
        await ConversationStartSequence.run(recordingDeps(into: log, engineFails: true))
        XCTAssertEqual(log.value, Self.expectedOrder,
                       "a throwing engine bring-up is swallowed; every later stage still runs")
    }

    /// Plan GU §2: the route switch comes after the pause (which asks for the conversation mic)
    /// and strictly before the tone — the tone means "talk now" on a mic that is live.
    func testMicHandOffPrecedesTheToneAndFollowsThePause() async {
        let log = Box<[String]>([])
        await ConversationStartSequence.run(recordingDeps(into: log))
        let pauseAt = log.value.firstIndex(of: "pauseOtherAudio")!
        let handOffAt = log.value.firstIndex(of: "handOffMic")!
        let toneAt = log.value.firstIndex(of: "playAcknowledgmentTone")!
        let recordAt = log.value.firstIndex(of: "startRecording")!
        XCTAssertLessThan(pauseAt, handOffAt)
        XCTAssertLessThan(handOffAt, toneAt, "never a tone before the mic is live")
        XCTAssertLessThan(handOffAt, recordAt, "dictation attaches only after the hand-off")
    }
}
