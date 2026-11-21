import AVFoundation
import XCTest
@testable import OpenGlasses

/// Plan MO §6, "Our own voice is not a caption": every caption consumer goes through the capture
/// router's assistant-voice decision with "Include Assistant Voice" treated as off.
@MainActor
final class CaptionAudioGateTests: XCTestCase {

    private var onSpeaker = true
    private var includeAssistant = false

    private func makeRouter() -> CaptureAudioRouter {
        CaptureAudioRouter(wakeTap: nil, standalone: nil,
                           isPhoneSpeakerOutput: { [weak self] in self?.onSpeaker ?? false },
                           includeAssistantVoice: { [weak self] in self?.includeAssistant ?? false })
    }

    private final class Sink: @unchecked Sendable {
        private(set) var buffers: [AVAudioPCMBuffer] = []
        func receive(_ buffer: AVAudioPCMBuffer) { buffers.append(buffer) }
        var peak: Float {
            buffers.map { buffer in
                (0..<Int(buffer.frameLength)).map { abs(buffer.floatChannelData![0][$0]) }.max() ?? 0
            }.max() ?? 0
        }
    }

    private func loudBuffer() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
        buffer.frameLength = 256
        for frame in 0..<256 { buffer.floatChannelData![0][frame] = 0.8 }
        return buffer
    }

    /// The caption path's own handler, as `AmbientCaptionService` registers it.
    private func captionHandler(_ router: CaptureAudioRouter, _ sink: Sink) -> @Sendable (AVAudioPCMBuffer) -> Void {
        AmbientCaptionService.captionAudioConsumer(gate: router.captionGate) { sink.receive($0) }
    }

    func testTheAssistantOnThePhoneSpeakerReachesCaptionsAsSilence() {
        let router = makeRouter()
        router.setAssistantSpeaking(true)
        let sink = Sink()
        let input = loudBuffer()
        captionHandler(router, sink)(input)
        XCTAssertEqual(sink.buffers.count, 1, "silenced, never dropped")
        let out = sink.buffers[0]
        XCTAssertEqual(out.frameLength, input.frameLength)
        XCTAssertEqual(out.format, input.format)
        XCTAssertTrue((0..<Int(out.frameLength)).allSatisfy { out.floatChannelData![0][$0] == 0 },
                      "every sample zero")
        XCTAssertFalse(out === input, "a fresh silent buffer, not the mic's rewritten")
        XCTAssertEqual(input.floatChannelData![0][0], 0.8, accuracy: 0.001, "the mic's buffer is untouched")
    }

    /// The setting is for an audience following a stream; it can't let the assistant into captions.
    func testIncludeAssistantVoiceCannotLetTheAssistantIntoCaptions() {
        includeAssistant = true
        let router = makeRouter()
        router.setAssistantSpeaking(true)
        let captions = Sink()
        captionHandler(router, captions)(loudBuffer())
        XCTAssertEqual(captions.peak, 0)
        XCTAssertFalse(router.captionGate.assistantVoiceMayBeIncluded)

        let recording = Sink()
        AudioRecordingService.gatedConsumer(gate: router) { recording.receive($0) }(loudBuffer())
        XCTAssertEqual(recording.peak, 0.8, accuracy: 0.001, "the recording still honours the setting")
        XCTAssertTrue(router.assistantVoiceMayBeIncluded)
    }

    func testCaptionsPassUntouchedOtherwise() {
        let router = makeRouter()
        let sink = Sink()
        let handler = captionHandler(router, sink)
        let quiet = loudBuffer()
        handler(quiet)
        XCTAssertTrue(sink.buffers.last === quiet, "nobody speaking: the mic's own buffer")

        onSpeaker = false
        router.setAssistantSpeaking(true)
        handler(loudBuffer())
        XCTAssertEqual(sink.peak, 0.8, accuracy: 0.001, "replies in the glasses never reach the mic")

        router.setAssistantSpeaking(false)
        onSpeaker = true
        handler(loudBuffer())
        XCTAssertEqual(sink.buffers.count, 3)
        XCTAssertEqual(sink.buffers.last.map { $0.floatChannelData![0][0] }, 0.8)
    }

    func testTheGateLiftsWhenTheAssistantStops() {
        let router = makeRouter()
        let sink = Sink()
        let handler = captionHandler(router, sink)
        router.setAssistantSpeaking(true)
        handler(loudBuffer())
        router.setAssistantSpeaking(false)
        handler(loudBuffer())
        XCTAssertEqual(sink.buffers.first.map { $0.floatChannelData![0][0] }, 0)
        XCTAssertEqual(sink.buffers.last.map { $0.floatChannelData![0][0] }, 0.8)
    }

    func testTheRoutersCaptionDecisionMatchesItsGate() {
        includeAssistant = true
        let router = makeRouter()
        router.setAssistantSpeaking(true)
        let out = router.captionGatedBuffer(loudBuffer())
        XCTAssertEqual(out.floatChannelData![0][0], 0)
    }

    /// The pure rule is unchanged: the caption path asks it with the setting off.
    func testTheDecisionStaysPure() {
        XCTAssertEqual(AssistantAudioGate.decide(ttsSpeaking: true, ttsOnPhoneSpeaker: true, includeAssistantVoice: false), .silence)
        XCTAssertEqual(AssistantAudioGate.decide(ttsSpeaking: true, ttsOnPhoneSpeaker: true, includeAssistantVoice: true), .pass)
    }

    func testWithoutAGateCaptionsPass() {
        let sink = Sink()
        AmbientCaptionService.captionAudioConsumer(gate: nil) { sink.receive($0) }(loudBuffer())
        XCTAssertEqual(sink.peak, 0.8, accuracy: 0.001)
    }

    // MARK: - Wiring, read from the source

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// Every caption path registers through the one gated helper, so a fifth path can't take raw
    /// buffers by accident.
    func testEveryCaptionConsumerGoesThroughTheGate() throws {
        let text = try source("OpenGlasses/Sources/Services/AmbientCaptionService.swift")
        XCTAssertEqual(text.components(separatedBy: "addAudioBufferConsumer(").count - 1, 1,
                       "only addCaptionAudioConsumer registers with the listener")
        XCTAssertEqual(text.components(separatedBy: "addCaptionAudioConsumer {").count - 1, 5,
                       "the five caption paths: recogniser, long-form analyzer, cloud and on-device "
                       + "translation, diarized")
        XCTAssertTrue(text.contains("handler: Self.captionAudioConsumer(gate: assistantVoiceGate, append: append)"))
        XCTAssertFalse(text.contains("id: \"ambient_captions\") {"))
    }

    func testAppStateWiresTheCaptionGate() throws {
        let text = try source("OpenGlasses/Sources/App/OpenGlassesApp.swift")
        XCTAssertTrue(text.contains("ambientCaptions.assistantVoiceGate = captureAudioRouter.captionGate"))
    }
}
