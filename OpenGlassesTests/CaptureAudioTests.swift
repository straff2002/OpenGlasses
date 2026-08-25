import AVFoundation
import XCTest
@testable import OpenGlasses

/// Plan CZ — capture audio independent of the always-on listener.
///
/// Everything here runs headless: the arbiter and the gate are pure, and the router is exercised
/// against fake sources. No `AVAudioEngine` is constructed and no `.shared` service is touched.
final class AudioSourceArbiterTests: XCTestCase {

    func testNothingRunsWhenNothingIsCapturing() {
        XCTAssertEqual(
            AudioSourceArbiter.source(for: CaptureAudioConditions(wakeListening: false, captureActive: false)),
            .none)
        // A running listener alone is not a reason to attach: the listener has its own consumers.
        XCTAssertEqual(
            AudioSourceArbiter.source(for: CaptureAudioConditions(wakeListening: true, captureActive: false)),
            .none)
    }

    func testSharedTapWinsWhileListening() {
        XCTAssertEqual(
            AudioSourceArbiter.source(for: CaptureAudioConditions(wakeListening: true, captureActive: true)),
            .wakeTap)
    }

    func testStandaloneOnlyRunsInTheGap() {
        XCTAssertEqual(
            AudioSourceArbiter.source(for: CaptureAudioConditions(wakeListening: false, captureActive: true)),
            .standalone)
    }

    func testStartingACaptureWhileListeningAttachesToTheSharedTap() {
        var arbiter = AudioSourceArbiter()
        let commands = arbiter.apply(CaptureAudioConditions(wakeListening: true, captureActive: true))
        XCTAssertEqual(commands, [.attachToWakeTap])
        XCTAssertEqual(arbiter.source, .wakeTap)
    }

    func testStartingACaptureWithListeningOffStartsTheStandaloneEngine() {
        var arbiter = AudioSourceArbiter()
        let commands = arbiter.apply(CaptureAudioConditions(wakeListening: false, captureActive: true))
        XCTAssertEqual(commands, [.startStandalone])
        XCTAssertEqual(arbiter.source, .standalone)
    }

    func testListeningOffMidCaptureHandsOverDetachFirst() {
        var arbiter = AudioSourceArbiter()
        _ = arbiter.apply(CaptureAudioConditions(wakeListening: true, captureActive: true))
        let commands = arbiter.apply(CaptureAudioConditions(wakeListening: false, captureActive: true))
        // Order matters: the old source must be gone before the new one comes up, or the handover
        // briefly runs two input taps on the same route.
        XCTAssertEqual(commands, [.detachFromWakeTap, .startStandalone])
        XCTAssertEqual(arbiter.source, .standalone)
    }

    func testListeningBackOnMidCaptureHandsBack() {
        var arbiter = AudioSourceArbiter()
        _ = arbiter.apply(CaptureAudioConditions(wakeListening: false, captureActive: true))
        let commands = arbiter.apply(CaptureAudioConditions(wakeListening: true, captureActive: true))
        XCTAssertEqual(commands, [.stopStandalone, .attachToWakeTap])
        XCTAssertEqual(arbiter.source, .wakeTap)
    }

    func testCaptureEndingStopsWhicheverSourceWasRunning() {
        var standaloneCase = AudioSourceArbiter()
        _ = standaloneCase.apply(CaptureAudioConditions(wakeListening: false, captureActive: true))
        XCTAssertEqual(
            standaloneCase.apply(CaptureAudioConditions(wakeListening: false, captureActive: false)),
            [.stopStandalone])

        var tapCase = AudioSourceArbiter()
        _ = tapCase.apply(CaptureAudioConditions(wakeListening: true, captureActive: true))
        XCTAssertEqual(
            tapCase.apply(CaptureAudioConditions(wakeListening: true, captureActive: false)),
            [.detachFromWakeTap])
    }

    func testReapplyingTheSameConditionsIsANoOp() {
        var arbiter = AudioSourceArbiter()
        _ = arbiter.apply(CaptureAudioConditions(wakeListening: true, captureActive: true))
        for _ in 0..<5 {
            XCTAssertEqual(arbiter.apply(CaptureAudioConditions(wakeListening: true, captureActive: true)), [])
        }
        XCTAssertEqual(arbiter.source, .wakeTap)
    }

    func testResetDetachesWhateverIsAttached() {
        var arbiter = AudioSourceArbiter()
        _ = arbiter.apply(CaptureAudioConditions(wakeListening: false, captureActive: true))
        XCTAssertEqual(arbiter.reset(), [.stopStandalone])
        XCTAssertEqual(arbiter.source, .none)
        XCTAssertEqual(arbiter.reset(), [])
    }

    func testTwoSourcesAreNeverAttachedAtOnce() {
        // Walk every conditions transition and assert the command stream never attaches without
        // first detaching — the invariant the whole type exists for.
        let all = [
            CaptureAudioConditions(wakeListening: false, captureActive: false),
            CaptureAudioConditions(wakeListening: true, captureActive: false),
            CaptureAudioConditions(wakeListening: false, captureActive: true),
            CaptureAudioConditions(wakeListening: true, captureActive: true)
        ]
        for from in all {
            for to in all {
                var arbiter = AudioSourceArbiter()
                _ = arbiter.apply(from)
                let commands = arbiter.apply(to)
                let attaches = commands.filter { $0 == .attachToWakeTap || $0 == .startStandalone }
                XCTAssertLessThanOrEqual(attaches.count, 1, "\(from) → \(to)")
                if let attachIndex = commands.firstIndex(where: { attaches.contains($0) }),
                   let detachIndex = commands.firstIndex(where: {
                       $0 == .detachFromWakeTap || $0 == .stopStandalone
                   }) {
                    XCTAssertLessThan(detachIndex, attachIndex, "\(from) → \(to)")
                }
            }
        }
    }
}

final class AssistantAudioGateTests: XCTestCase {

    func testSilencesTheAssistantOnTheSpeakerByDefault() {
        XCTAssertEqual(
            AssistantAudioGate.decide(ttsSpeaking: true, ttsOnPhoneSpeaker: true, includeAssistantVoice: false),
            .silence)
    }

    func testRepliesInTheGlassesAreNeverGated() {
        // Nothing reaches the mic, so gating would blank real audio for no benefit — this is the
        // common case and it must stay untouched.
        XCTAssertEqual(
            AssistantAudioGate.decide(ttsSpeaking: true, ttsOnPhoneSpeaker: false, includeAssistantVoice: false),
            .pass)
    }

    func testSilenceIsNotAppliedWhenNothingIsSpeaking() {
        XCTAssertEqual(
            AssistantAudioGate.decide(ttsSpeaking: false, ttsOnPhoneSpeaker: true, includeAssistantVoice: false),
            .pass)
    }

    func testOptingInLetsTheAudienceHearTheAssistant() {
        XCTAssertEqual(
            AssistantAudioGate.decide(ttsSpeaking: true, ttsOnPhoneSpeaker: true, includeAssistantVoice: true),
            .pass)
    }

    func testEveryCombinationIsTotal() {
        for speaking in [true, false] {
            for speaker in [true, false] {
                for include in [true, false] {
                    let decision = AssistantAudioGate.decide(
                        ttsSpeaking: speaking, ttsOnPhoneSpeaker: speaker, includeAssistantVoice: include)
                    XCTAssertEqual(decision == .silence, speaking && speaker && !include)
                }
            }
        }
    }
}

final class CaptureAudioSilencerTests: XCTestCase {

    private func buffer(sampleRate: Double = 48_000, channels: AVAudioChannelCount = 1, frames: AVAudioFrameCount = 512) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let data = buffer.floatChannelData![channel]
            for frame in 0..<Int(frames) { data[frame] = 0.5 }
        }
        return buffer
    }

    func testSilenceKeepsShapeAndZeroesSamples() {
        let source = buffer()
        let silent = CaptureAudioSilencer.silence(like: source)
        XCTAssertNotNil(silent)
        guard let silent else { return }
        // Same shape: a dropped or resized buffer would shift the broadcast's sample-count clock.
        XCTAssertEqual(silent.frameLength, source.frameLength)
        XCTAssertEqual(silent.format.sampleRate, source.format.sampleRate)
        XCTAssertEqual(silent.format.channelCount, source.format.channelCount)
        let data = silent.floatChannelData![0]
        for frame in 0..<Int(silent.frameLength) {
            XCTAssertEqual(data[frame], 0)
        }
    }

    func testSilenceDoesNotMutateTheSourceBuffer() {
        let source = buffer()
        _ = CaptureAudioSilencer.silence(like: source)
        XCTAssertEqual(source.floatChannelData![0][0], 0.5)
    }

    func testStereoIsSilencedOnEveryChannel() {
        let source = buffer(channels: 2)
        let silent = CaptureAudioSilencer.silence(like: source)!
        for channel in 0..<2 {
            XCTAssertEqual(silent.floatChannelData![channel][0], 0)
        }
    }
}

// MARK: - Router

/// A stand-in for the shared wake-word tap: records registrations and can push buffers.
@MainActor
private final class FakeTapSource: BroadcastAudioProviding {
    private(set) var consumerIds: [String] = []
    private var handlers: [String: @Sendable (AVAudioPCMBuffer) -> Void] = [:]
    var isAttached: Bool { !handlers.isEmpty }

    func addAudioBufferConsumer(id: String, handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        consumerIds.append(id)
        handlers[id] = handler
    }

    func removeAudioBufferConsumer(id: String) {
        handlers.removeValue(forKey: id)
    }

    func push(_ buffer: AVAudioPCMBuffer) {
        for handler in handlers.values { handler(buffer) }
    }
}

@MainActor
private final class FakeStandaloneEngine: CaptureAudioEngineProviding {
    private(set) var isRunning = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var startError: Error?
    private var handlers: [String: @Sendable (AVAudioPCMBuffer) -> Void] = [:]
    var isAttached: Bool { !handlers.isEmpty }

    func start() async throws {
        startCount += 1
        if let startError { throw startError }
        isRunning = true
    }

    func stop() {
        stopCount += 1
        isRunning = false
    }

    func addAudioBufferConsumer(id: String, handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        handlers[id] = handler
    }

    func removeAudioBufferConsumer(id: String) {
        handlers.removeValue(forKey: id)
    }

    func push(_ buffer: AVAudioPCMBuffer) {
        for handler in handlers.values { handler(buffer) }
    }
}

@MainActor
final class CaptureAudioRouterTests: XCTestCase {

    private var tap: FakeTapSource!
    private var standalone: FakeStandaloneEngine!
    private var onSpeaker = false
    private var includeAssistant = false

    private func makeRouter() -> CaptureAudioRouter {
        tap = FakeTapSource()
        standalone = FakeStandaloneEngine()
        return CaptureAudioRouter(
            wakeTap: tap,
            standalone: standalone,
            isPhoneSpeakerOutput: { [weak self] in self?.onSpeaker ?? false },
            includeAssistantVoice: { [weak self] in self?.includeAssistant ?? false }
        )
    }

    /// A recorder-like consumer: counts buffers and remembers the peak sample it saw.
    private final class Sink: @unchecked Sendable {
        private(set) var count = 0
        private(set) var peak: Float = 0
        func receive(_ buffer: AVAudioPCMBuffer) {
            count += 1
            let data = buffer.floatChannelData![0]
            for frame in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[frame])) }
        }
    }

    private func loudBuffer() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
        buffer.frameLength = 256
        let data = buffer.floatChannelData![0]
        for frame in 0..<256 { data[frame] = 0.8 }
        return buffer
    }

    func testNoSourceRunsUntilAConsumerRegisters() async {
        let router = makeRouter()
        router.setWakeListening(true)
        await router.settleForTesting()
        XCTAssertEqual(router.activeSource, .none)
        XCTAssertFalse(tap.isAttached)
        XCTAssertEqual(standalone.startCount, 0)
    }

    func testCaptureWithListeningOnRidesTheSharedTap() async {
        let router = makeRouter()
        router.setWakeListening(true)
        router.addAudioBufferConsumer(id: "broadcast") { _ in }
        await router.settleForTesting()
        XCTAssertEqual(router.activeSource, .wakeTap)
        XCTAssertTrue(tap.isAttached)
        XCTAssertEqual(standalone.startCount, 0)
    }

    func testCaptureWithListeningOffStartsTheStandaloneEngine() async {
        let router = makeRouter()
        router.addAudioBufferConsumer(id: "broadcast") { _ in }
        await router.settleForTesting()
        XCTAssertEqual(router.activeSource, .standalone)
        XCTAssertTrue(standalone.isRunning)
        XCTAssertFalse(tap.isAttached)
    }

    func testConsumersKeepReceivingAcrossAListeningHandover() async {
        // The defect this plan exists for: turning listening off mid-stream used to stop the
        // buffers dead. The consumer registered here must never notice the swap.
        let router = makeRouter()
        let sink = Sink()
        router.setWakeListening(true)
        router.addAudioBufferConsumer(id: "broadcast") { sink.receive($0) }
        await router.settleForTesting()

        tap.push(loudBuffer())
        XCTAssertEqual(sink.count, 1)

        router.setWakeListening(false)
        await router.settleForTesting()
        XCTAssertEqual(router.activeSource, .standalone)
        XCTAssertFalse(tap.isAttached, "the shared tap must be released before the engine comes up")

        standalone.push(loudBuffer())
        XCTAssertEqual(sink.count, 2, "buffers must keep arriving from the new source")

        router.setWakeListening(true)
        await router.settleForTesting()
        XCTAssertEqual(router.activeSource, .wakeTap)
        XCTAssertEqual(standalone.stopCount, 1)
        tap.push(loudBuffer())
        XCTAssertEqual(sink.count, 3)
    }

    func testLastConsumerLeavingStopsTheEngine() async {
        let router = makeRouter()
        router.addAudioBufferConsumer(id: "broadcast") { _ in }
        router.addAudioBufferConsumer(id: "recording") { _ in }
        await router.settleForTesting()
        XCTAssertEqual(standalone.startCount, 1)

        router.removeAudioBufferConsumer(id: "broadcast")
        await router.settleForTesting()
        XCTAssertEqual(router.activeSource, .standalone, "the recording is still capturing")
        XCTAssertEqual(standalone.stopCount, 0)

        router.removeAudioBufferConsumer(id: "recording")
        await router.settleForTesting()
        XCTAssertEqual(router.activeSource, .none)
        XCTAssertEqual(standalone.stopCount, 1)
        XCTAssertFalse(standalone.isAttached)
    }

    func testAFailedEngineStartDetachesItsRegistration() async {
        let router = makeRouter()
        standalone.startError = StandaloneMicTapError.microphonePermissionDenied
        router.addAudioBufferConsumer(id: "broadcast") { _ in }
        await router.settleForTesting()
        XCTAssertFalse(standalone.isRunning)
        XCTAssertFalse(standalone.isAttached)
    }

    func testAssistantOnTheSpeakerIsSilencedNotDropped() async {
        let router = makeRouter()
        let sink = Sink()
        router.setWakeListening(true)
        router.addAudioBufferConsumer(id: "broadcast") { sink.receive($0) }
        await router.settleForTesting()

        onSpeaker = true
        router.setAssistantSpeaking(true)
        tap.push(loudBuffer())
        // The buffer still arrives (the broadcast's clock counts samples, so a drop would shift
        // A/V sync) but carries no signal.
        XCTAssertEqual(sink.count, 1)
        XCTAssertEqual(sink.peak, 0)

        router.setAssistantSpeaking(false)
        tap.push(loudBuffer())
        XCTAssertEqual(sink.count, 2)
        XCTAssertEqual(sink.peak, 0.8, accuracy: 0.0001)
    }

    func testAssistantInTheGlassesIsNotSilenced() async {
        let router = makeRouter()
        let sink = Sink()
        router.setWakeListening(true)
        router.addAudioBufferConsumer(id: "broadcast") { sink.receive($0) }
        await router.settleForTesting()

        onSpeaker = false
        router.setAssistantSpeaking(true)
        tap.push(loudBuffer())
        XCTAssertEqual(sink.peak, 0.8, accuracy: 0.0001)
    }

    func testOptingInPassesTheAssistantThrough() async {
        let router = makeRouter()
        let sink = Sink()
        router.setWakeListening(true)
        router.addAudioBufferConsumer(id: "broadcast") { sink.receive($0) }
        await router.settleForTesting()

        onSpeaker = true
        includeAssistant = true
        router.setAssistantSpeaking(true)
        tap.push(loudBuffer())
        XCTAssertEqual(sink.peak, 0.8, accuracy: 0.0001)
    }

    func testSettingChangeMidSpeechIsPickedUpOnRefresh() async {
        let router = makeRouter()
        let sink = Sink()
        router.setWakeListening(true)
        router.addAudioBufferConsumer(id: "broadcast") { sink.receive($0) }
        await router.settleForTesting()

        onSpeaker = true
        router.setAssistantSpeaking(true)
        includeAssistant = true
        router.refreshAssistantGate()
        tap.push(loudBuffer())
        XCTAssertEqual(sink.peak, 0.8, accuracy: 0.0001)
    }

    func testShutdownReleasesEverySource() async {
        let router = makeRouter()
        router.addAudioBufferConsumer(id: "broadcast") { _ in }
        await router.settleForTesting()
        router.shutdown()
        await router.settleForTesting()
        XCTAssertEqual(router.activeSource, .none)
        XCTAssertEqual(standalone.stopCount, 1)
    }

    func testRouterRegistersUnderASingleIdOnItsSource() async {
        // One registration per source, whatever the consumer count — the router owns the fan-out.
        let router = makeRouter()
        router.setWakeListening(true)
        router.addAudioBufferConsumer(id: "broadcast") { _ in }
        router.addAudioBufferConsumer(id: "recording") { _ in }
        await router.settleForTesting()
        XCTAssertEqual(tap.consumerIds, [CaptureAudioRouter.sourceConsumerId])
    }
}
