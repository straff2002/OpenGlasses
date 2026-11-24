import XCTest
import AVFoundation
@testable import OpenGlasses

/// Plan CU P2 PR2 — the chunker: any capture format in, exact 16 kHz model chunks out, with the
/// context carried, the converter rebuilt on a format change, and audio-clock times.
final class SpeechHopChunkerTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// A mono Float32 buffer of a quiet tone (well above the noise floor, well below full scale).
    private func tone(rate: Double, frames: Int, phase: inout Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                   channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = buffer.floatChannelData![0]
        for i in 0..<frames {
            data[i] = Float(0.05 * sin(phase))
            phase += 2 * Double.pi * 440 / rate
        }
        return buffer
    }

    /// Feed `seconds` of tone at `rate` in buffers of the given (odd) sizes, cycling; arrival times
    /// follow the audio.
    private func feed(_ chunker: SpeechHopChunker, rate: Double, seconds: Double,
                      sizes: [Int], from offset: TimeInterval = 0) -> [SpeechHopChunker.Output] {
        var phase = 0.0
        var fed = 0
        var outputs: [SpeechHopChunker.Output] = []
        var i = 0
        let total = Int(rate * seconds)
        while fed < total {
            let frames = min(sizes[i % sizes.count], total - fed)
            fed += frames
            let arrival = start.addingTimeInterval(offset + Double(fed) / rate)
            outputs.append(chunker.append(tone(rate: rate, frames: frames, phase: &phase),
                                          route: .phone, arrival: arrival))
            i += 1
        }
        return outputs
    }

    func testEveryChunkIsExactlyContextPlusOneHop() {
        let chunker = SpeechHopChunker()
        let chunks = feed(chunker, rate: 16_000, seconds: 2, sizes: [333, 1_777, 1_000, 41])
            .flatMap(\.chunks)
        XCTAssertFalse(chunks.isEmpty)
        for chunk in chunks {
            XCTAssertEqual(chunk.samples.count, 4_160, "64 samples of context, then 4096 new ones")
        }
        // 32 000 samples at 16 kHz: seven whole hops, the remainder still pending.
        XCTAssertEqual(chunks.count, 32_000 / 4_096)
        XCTAssertEqual(SpeechHopChunker.chunkSamples, 4_160)
        XCTAssertEqual(SpeechHopChunker.hopDuration, 0.256, accuracy: 1e-12)
    }

    func testThePhoneMicAndTheHandsFreeLinkBothComeOutAt16kHz() {
        for rate in [48_000.0, 8_000.0] {
            let chunker = SpeechHopChunker()
            let chunks = feed(chunker, rate: rate, seconds: 3, sizes: [1_024, 917, 511])
                .flatMap(\.chunks)
            // Three seconds is 48 000 samples at 16 kHz: 11 whole hops, give or take the
            // converter's filter delay at a chunk boundary.
            let expected = 48_000 / 4_096
            XCTAssertLessThanOrEqual(abs(chunks.count - expected), 1, "at \(rate) Hz: \(chunks.count) chunks")
            XCTAssertTrue(chunks.allSatisfy { $0.samples.count == 4_160 })
            XCTAssertTrue(chunks.allSatisfy { $0.samples.allSatisfy { abs($0) <= 1 } })
            XCTAssertEqual(chunker.converterBuilds, 1, "one format, one converter")
        }
    }

    func testTheContextIsTheLast64SamplesOfThePreviousChunk() {
        let chunker = SpeechHopChunker()
        let chunks = feed(chunker, rate: 16_000, seconds: 1.5, sizes: [700]).flatMap(\.chunks)
        XCTAssertGreaterThanOrEqual(chunks.count, 3)
        XCTAssertEqual(Array(chunks[0].samples[0..<64]), [Float](repeating: 0, count: 64),
                       "zeros at the start of an utterance")
        for (previous, next) in zip(chunks, chunks.dropFirst()) {
            XCTAssertEqual(Array(next.samples[0..<64]), Array(previous.samples.suffix(64)))
        }
        XCTAssertEqual(chunker.currentContext, Array(chunks.last!.samples.suffix(64)))
    }

    func testTimesComeFromTheAudioClockAndOnlyGoForward() {
        let chunker = SpeechHopChunker()
        let outputs = feed(chunker, rate: 16_000, seconds: 2, sizes: [1_000])
        let chunks = outputs.flatMap(\.chunks)
        // The first buffer (1000 samples) arrived at start + 1000/16k: its first sample is `start`.
        let anchor = start
        for (n, chunk) in chunks.enumerated() {
            XCTAssertEqual(chunk.startSample, n * 4_096)
            XCTAssertEqual(chunk.startTime.timeIntervalSince(anchor),
                           Double(chunk.startSample) / 16_000, accuracy: 1e-6,
                           "time is sample position over 16 kHz, not when the chunk was cut")
        }
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            XCTAssertEqual(b.startTime.timeIntervalSince(a.startTime), 0.256, accuracy: 1e-6)
        }
    }

    func testAFormatChangeRebuildsTheConverterAndStartsANewEpoch() {
        let chunker = SpeechHopChunker()
        let before = feed(chunker, rate: 48_000, seconds: 1.2, sizes: [1_024]).flatMap(\.chunks)
        XCTAssertFalse(before.isEmpty)
        XCTAssertTrue(before.allSatisfy { $0.epoch == 0 })

        // The route flips to an 8 kHz hands-free link — and, to prove the clamp, its first buffer
        // claims an arrival before the last chunk ended.
        var phase = 0.0
        let first = chunker.append(tone(rate: 8_000, frames: 256, phase: &phase), route: .glasses,
                                   arrival: start)
        XCTAssertTrue(first.formatChanged)
        XCTAssertEqual(chunker.converterBuilds, 2, "a converter built for 48 kHz turns 8 kHz into garbage")
        XCTAssertEqual(chunker.epoch, 1)

        var after = first.chunks
        for _ in 0..<40 {
            let out = chunker.append(tone(rate: 8_000, frames: 256, phase: &phase), route: .glasses,
                                     arrival: start)
            XCTAssertFalse(out.formatChanged)
            after += out.chunks
        }
        XCTAssertFalse(after.isEmpty)
        XCTAssertTrue(after.allSatisfy { $0.epoch == 1 && $0.route == .glasses })
        XCTAssertEqual(after.first?.startSample, 0, "the partial hop from the old route is gone")
        XCTAssertEqual(Array(after[0].samples[0..<64]), [Float](repeating: 0, count: 64),
                       "and so is its context")
        let lastEnd = before.last!.startTime.addingTimeInterval(SpeechHopChunker.hopDuration)
        XCTAssertGreaterThanOrEqual(after[0].startTime, lastEnd, "time never runs backwards across epochs")
    }

    func testResetForgetsEverything() {
        let chunker = SpeechHopChunker()
        _ = feed(chunker, rate: 48_000, seconds: 0.5, sizes: [1_024])
        _ = feed(chunker, rate: 8_000, seconds: 0.5, sizes: [256])
        XCTAssertEqual(chunker.epoch, 1)
        chunker.reset()
        XCTAssertEqual(chunker.epoch, 0)
        XCTAssertEqual(chunker.converterBuilds, 0)
        XCTAssertEqual(chunker.currentContext, [Float](repeating: 0, count: 64))
        let chunks = feed(chunker, rate: 16_000, seconds: 0.6, sizes: [4_096]).flatMap(\.chunks)
        XCTAssertEqual(chunks.first?.startSample, 0)
        XCTAssertFalse(chunks.isEmpty)
    }

    func testAnEmptyBufferIsIgnored() {
        let chunker = SpeechHopChunker()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let empty = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
        let out = chunker.append(empty, route: .phone, arrival: start)
        XCTAssertTrue(out.chunks.isEmpty)
        XCTAssertFalse(out.formatChanged)
        XCTAssertEqual(chunker.converterBuilds, 0)
    }
}
