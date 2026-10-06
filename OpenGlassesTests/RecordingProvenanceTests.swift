import AVFoundation
import XCTest
@testable import OpenGlasses

// Plan HQ P1 item 3 — the assistant's voice says what made it once it becomes a file: recording
// metadata, the audio-only gate, and the recorded-job flag.

// MARK: - Recording metadata

final class RecordingProvenanceMetadataTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingProvenance-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testNoClaimWithoutTheAssistantsVoice() {
        XCTAssertTrue(RecordingProvenanceMetadata.items(assistantVoiceMayBeIncluded: false).isEmpty)
        XCTAssertEqual(RecordingProvenanceMetadata.items(assistantVoiceMayBeIncluded: true).count, 2)
    }

    func testAnM4AWithTheVoiceIncludedSaysSo() async throws {
        let url = try await writeSilentFile(fileType: .m4a, extension: "m4a", assistantVoiceMayBeIncluded: true)
        let metadata = try await readBack(url)
        XCTAssertEqual(metadata.description, RecordingProvenanceMetadata.synthesizedSpeechDescription)
        XCTAssertEqual(metadata.software, RecordingProvenanceMetadata.softwareIdentity)
    }

    func testAnMP4WithTheVoiceIncludedSaysSo() async throws {
        let url = try await writeSilentFile(fileType: .mp4, extension: "mp4", assistantVoiceMayBeIncluded: true)
        let metadata = try await readBack(url)
        XCTAssertEqual(metadata.description, RecordingProvenanceMetadata.synthesizedSpeechDescription)
        XCTAssertEqual(metadata.software, RecordingProvenanceMetadata.softwareIdentity)
    }

    func testARecordingWithoutTheVoiceMakesNoClaim() async throws {
        for (type, ext) in [(AVFileType.m4a, "m4a"), (.mp4, "mp4")] {
            let url = try await writeSilentFile(fileType: type, extension: ext, assistantVoiceMayBeIncluded: false)
            let metadata = try await readBack(url)
            XCTAssertNil(metadata.description, ext)
            XCTAssertNil(metadata.software, ext)
        }
    }

    // MARK: Helpers

    /// A quarter-second of silence, written the way the recorders write: AAC, 16 kHz mono, with the
    /// metadata set before `startWriting()`.
    private func writeSilentFile(fileType: AVFileType, extension ext: String,
                                 assistantVoiceMayBeIncluded: Bool) async throws -> URL {
        let url = directory.appendingPathComponent("silence-\(UUID().uuidString).\(ext)")
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48000,
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        RecordingProvenanceMetadata.apply(to: writer, assistantVoiceMayBeIncluded: assistantVoiceMayBeIncluded)
        XCTAssertTrue(writer.startWriting(), "\(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)

        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let frames: AVAudioFrameCount = 1024
        for index in 0..<4 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            let sample = try XCTUnwrap(Self.sampleBuffer(from: buffer, at: CMTime(value: CMTimeValue(Int(frames) * index),
                                                                                   timescale: 16000)))
            var waited = 0
            while !input.isReadyForMoreMediaData, waited < 200 {
                try await Task.sleep(nanoseconds: 5_000_000)
                waited += 1
            }
            XCTAssertTrue(input.append(sample), "\(String(describing: writer.error))")
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        return url
    }

    private static func sampleBuffer(from buffer: AVAudioPCMBuffer, at time: CMTime) -> CMSampleBuffer? {
        var formatDescription: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: buffer.format.streamDescription,
                                       layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                       extensions: nil, formatDescriptionOut: &formatDescription)
        guard let formatDescription else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 16000),
                                        presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                             makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDescription,
                             sampleCount: CMItemCount(buffer.frameLength), sampleTimingEntryCount: 1,
                             sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                             sampleBufferOut: &sample)
        guard let sample else { return nil }
        CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault,
                                                       blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                       flags: 0, bufferList: buffer.audioBufferList)
        return sample
    }

    /// The description and software a player reads back, found by common key whatever key space
    /// the container stored them in.
    private func readBack(_ url: URL) async throws -> (description: String?, software: String?) {
        let asset = AVURLAsset(url: url)
        let items = try await asset.load(.metadata) + asset.load(.commonMetadata)
        func value(_ key: AVMetadataKey) async throws -> String? {
            for item in items where item.commonKey == key {
                if let text = try await item.load(.stringValue) { return text }
            }
            return nil
        }
        return (try await value(.commonKeyDescription), try await value(.commonKeySoftware))
    }
}

// MARK: - The gate on the audio-only path

@MainActor
final class AssistantVoiceGatingTests: XCTestCase {

    private var onSpeaker = true
    private var includeAssistant = false

    private func makeRouter() -> CaptureAudioRouter {
        CaptureAudioRouter(wakeTap: nil, standalone: nil,
                           isPhoneSpeakerOutput: { [weak self] in self?.onSpeaker ?? false },
                           includeAssistantVoice: { [weak self] in self?.includeAssistant ?? false })
    }

    private final class Sink: @unchecked Sendable {
        private(set) var peak: Float = 0
        private(set) var count = 0
        func receive(_ buffer: AVAudioPCMBuffer) {
            count += 1
            let data = buffer.floatChannelData![0]
            for frame in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[frame])) }
        }
    }

    private func loudBuffer() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
        buffer.frameLength = 256
        for frame in 0..<256 { buffer.floatChannelData![0][frame] = 0.8 }
        return buffer
    }

    /// The audio-only recorder's handler silences the assistant on the phone speaker by default,
    /// the same as a video or a stream.
    func testTheAudioRecorderSilencesTheAssistantOnTheSpeaker() {
        let router = makeRouter()
        router.setAssistantSpeaking(true)
        let sink = Sink()
        let handler = AudioRecordingService.gatedConsumer(gate: router) { sink.receive($0) }
        handler(loudBuffer())
        XCTAssertEqual(sink.count, 1, "silenced, never dropped")
        XCTAssertEqual(sink.peak, 0)
        XCTAssertFalse(router.assistantVoiceMayBeIncluded)
    }

    func testOptingInLetsTheAssistantIntoAnAudioRecording() {
        includeAssistant = true
        let router = makeRouter()
        router.setAssistantSpeaking(true)
        let sink = Sink()
        AudioRecordingService.gatedConsumer(gate: router) { sink.receive($0) }(loudBuffer())
        XCTAssertEqual(sink.peak, 0.8, accuracy: 0.001)
        XCTAssertTrue(router.assistantVoiceMayBeIncluded)
    }

    func testRepliesInTheGlassesAndSilenceAreNotGated() {
        onSpeaker = false
        let router = makeRouter()
        router.setAssistantSpeaking(true)
        let sink = Sink()
        let handler = AudioRecordingService.gatedConsumer(gate: router) { sink.receive($0) }
        handler(loudBuffer())
        XCTAssertEqual(sink.peak, 0.8, accuracy: 0.001)
        router.setAssistantSpeaking(false)
        onSpeaker = true
        handler(loudBuffer())
        XCTAssertEqual(sink.count, 2)
        XCTAssertEqual(sink.peak, 0.8, accuracy: 0.001)
    }

    func testWithoutAGateBuffersPassUntouched() {
        let sink = Sink()
        AudioRecordingService.gatedConsumer(gate: nil) { sink.receive($0) }(loudBuffer())
        XCTAssertEqual(sink.peak, 0.8, accuracy: 0.001)
    }

    /// What the video recorder writes into its file's metadata, by mic source.
    func testTheVideoRecordersClaimFollowsItsMicSource() {
        XCTAssertFalse(VideoRecordingService.assistantVoiceMayBeIncluded(audioProvider: nil), "no mic, no claim")
        let router = makeRouter()
        XCTAssertFalse(VideoRecordingService.assistantVoiceMayBeIncluded(audioProvider: router))
        includeAssistant = true
        XCTAssertTrue(VideoRecordingService.assistantVoiceMayBeIncluded(audioProvider: router))
        XCTAssertTrue(VideoRecordingService.assistantVoiceMayBeIncluded(audioProvider: UngatedSource()),
                      "an ungated mic hears the speaker")
    }

    private final class UngatedSource: BroadcastAudioProviding {
        func addAudioBufferConsumer(id: String, handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {}
        func removeAudioBufferConsumer(id: String) {}
    }
}

// MARK: - The recorded job's flag

final class TimelineAssistantVoiceTests: XCTestCase {

    private func timeline(_ events: [(Int64, SessionTimeline.EventKind)]) -> SessionTimeline {
        SessionTimeline(wallStart: 1_800_000_000_000,
                        events: events.map { SessionTimeline.Event(t: SessionTime(milliseconds: $0.0), kind: $0.1) })
    }

    func testNoReplyMeansNoVoice() {
        XCTAssertFalse(timeline([]).assistantVoiceMayBeIncluded)
        XCTAssertFalse(timeline([(100, .turnStarted), (200, .toolCall)]).assistantVoiceMayBeIncluded)
    }

    /// The app notes the silence straight after the reply starts, at the same instant.
    func testEverySilencedReplyMeansNoVoice() {
        XCTAssertFalse(timeline([
            (1_000, .assistantSpeakingBegan), (1_000, .captureSilenced),
            (3_000, .assistantSpeakingEnded), (3_000, .capturePassed),
            (5_000, .assistantSpeakingBegan), (5_000, .captureSilenced),
            (6_000, .assistantSpeakingEnded), (6_000, .capturePassed),
        ]).assistantVoiceMayBeIncluded)
    }

    func testAReplyLetThroughMeansTheVoiceMayBeThere() {
        XCTAssertTrue(timeline([
            (1_000, .assistantSpeakingBegan), (1_000, .captureSilenced),
            (3_000, .assistantSpeakingEnded), (3_000, .capturePassed),
            (5_000, .assistantSpeakingBegan),
            (6_000, .assistantSpeakingEnded),
        ]).assistantVoiceMayBeIncluded)
    }

    func testAReplyStillPlayingAtTheEndCounts() {
        XCTAssertTrue(timeline([(5_000, .assistantSpeakingBegan)]).assistantVoiceMayBeIncluded)
        XCTAssertFalse(timeline([(5_000, .assistantSpeakingBegan), (5_000, .captureSilenced)])
            .assistantVoiceMayBeIncluded)
    }
}
