import Foundation
import AVFoundation

/// Plan CU P2 PR2 — the half of the acoustic detector that needs no model: captured buffers of any
/// format in, exact model-sized chunks of 16 kHz mono out. Headless-testable; the detector calls
/// it under its lock on the render thread.
///
/// - **Resampling.** Every buffer goes through an `AVAudioConverter` to 16 kHz mono Float32. The
///   converter is rebuilt whenever a buffer's format differs from the last one's: routes flip
///   between the phone's 48 kHz mic and an 8 or 16 kHz hands-free link as a matter of course, and
///   a converter built for the old format turns the new one into garbage. The same change starts a
///   new **epoch**: the partial hop, the context and the learned input level all belong to audio
///   that is gone, and a consumer seeing a new epoch drops its streaming state.
/// - **Gain.** `MicInputGain` normalises each converted buffer per route before anything scores
///   it, so one threshold pair means the same thing on every mic (the CU P2 rider).
/// - **Chunks.** Exactly `hopSamples` new samples each, prefixed by the last `contextSamples` of
///   the previous chunk (zeros at the start of an epoch), which is the model's input shape.
/// - **Audio-clock time.** A chunk's time is its sample position mapped onto the epoch's anchor,
///   never the moment the model got round to it: under load the consumer runs late, and a stamp
///   taken there would report the wearer stopping later than they did.
///
/// Allocation is bounded: one array per emitted chunk (every 256 ms), and a converter output
/// buffer that only grows when a larger input buffer arrives.
final class SpeechHopChunker {

    static let sampleRate: Double = 16_000
    /// New samples per chunk: 256 ms at 16 kHz, the model's hop.
    static let hopSamples = 4_096
    /// Samples carried from the previous chunk into the front of the next.
    static let contextSamples = 64
    static let chunkSamples = contextSamples + hopSamples
    static let hopDuration: TimeInterval = Double(hopSamples) / sampleRate

    struct Chunk {
        /// `contextSamples` from the previous chunk, then `hopSamples` new ones, gain applied.
        let samples: [Float]
        /// The first new sample's position, in 16 kHz samples since the epoch began.
        let startSample: Int
        /// Which run of one input format this chunk belongs to. Changes on every format change.
        let epoch: Int
        /// The first new sample's audio-clock time: the epoch's anchor + `startSample` / 16 kHz.
        let startTime: Date
        let route: MicRoute
    }

    struct Output {
        var chunks: [Chunk] = []
        /// The buffer's format differed from the previous buffer's, mid-utterance.
        var formatChanged = false
    }

    private(set) var epoch = 0
    /// How many converters have been built since the last `reset()` — for tests and diagnostics.
    private(set) var converterBuilds = 0

    private let outputFormat: AVAudioFormat
    private var inputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var outputBuffer: AVAudioPCMBuffer?
    private var pending: [Float] = []
    private var context: [Float]
    /// 16 kHz samples already emitted into chunks this epoch.
    private var emittedSamples = 0
    /// Audio-clock time of sample 0 of this epoch.
    private var anchor: Date?
    /// End of the last chunk emitted, so a new epoch's anchor never runs time backwards.
    private var lastChunkEnd: Date?
    private var gain = MicInputGain()

    init() {
        // Non-interleaved mono Float32 at 16 kHz cannot fail to describe.
        outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
                                     channels: 1, interleaved: false)!
        context = [Float](repeating: 0, count: Self.contextSamples)
        pending.reserveCapacity(Self.hopSamples * 2)
    }

    /// The last `contextSamples` of the most recent chunk — what the next chunk will start with.
    var currentContext: [Float] { context }

    /// A new utterance: nothing survives, including the learned levels.
    func reset() {
        inputFormat = nil
        converter = nil
        converterBuilds = 0
        epoch = 0
        lastChunkEnd = nil
        gain.forgetAll()
        startEpoch()
    }

    /// One captured buffer. `arrival` is when it reached the tap — the end of its audio, give or
    /// take the I/O buffer — and anchors the epoch when it is the epoch's first.
    func append(_ buffer: AVAudioPCMBuffer, route: MicRoute, arrival: Date) -> Output {
        var output = Output()
        let format = buffer.format
        guard buffer.frameLength > 0, format.sampleRate > 0, format.channelCount > 0 else { return output }

        if let inputFormat, inputFormat != format {
            // A route change mid-utterance. The converter, the partial hop, the context and the
            // level estimate all describe the old format; the epoch tells the consumer to drop its
            // streaming state too, which is garbage at another sample rate.
            epoch += 1
            gain.forgetAll()
            startEpoch()
            converter = nil
            output.formatChanged = true
        }
        if converter == nil || inputFormat == nil {
            inputFormat = format
            converter = AVAudioConverter(from: format, to: outputFormat)
            converterBuilds += 1
        }
        guard let converter else { return output }

        if anchor == nil {
            let captured = Double(buffer.frameLength) / format.sampleRate
            var start = arrival.addingTimeInterval(-captured)
            if let lastChunkEnd, start < lastChunkEnd { start = lastChunkEnd }
            anchor = start
        }

        guard let converted = convert(buffer, with: converter) else { return output }
        let count = Int(converted.frameLength)
        guard count > 0, let channel = converted.floatChannelData?[0] else { return output }

        var sumSquares: Float = 0
        for i in 0..<count { sumSquares += channel[i] * channel[i] }
        let rms = (sumSquares / Float(count)).squareRoot()
        let applied = gain.gain(forHopRMS: rms, route: route)
        for i in 0..<count {
            pending.append(min(max(channel[i] * applied, -1), 1))
        }

        while pending.count >= Self.hopSamples {
            output.chunks.append(emitChunk(route: route))
        }
        return output
    }

    // MARK: - Private

    private func startEpoch() {
        pending.removeAll(keepingCapacity: true)
        for i in 0..<context.count { context[i] = 0 }
        emittedSamples = 0
        anchor = nil
    }

    private func emitChunk(route: MicRoute) -> Chunk {
        var samples = [Float]()
        samples.reserveCapacity(Self.chunkSamples)
        samples.append(contentsOf: context)
        samples.append(contentsOf: pending[0..<Self.hopSamples])
        let tail = Self.hopSamples - Self.contextSamples
        for i in 0..<Self.contextSamples { context[i] = pending[tail + i] }
        pending.removeFirst(Self.hopSamples)

        let startSample = emittedSamples
        emittedSamples += Self.hopSamples
        let anchor = self.anchor ?? Date()
        let startTime = anchor.addingTimeInterval(Double(startSample) / Self.sampleRate)
        lastChunkEnd = startTime.addingTimeInterval(Self.hopDuration)
        return Chunk(samples: samples, startSample: startSample, epoch: epoch,
                     startTime: startTime, route: route)
    }

    /// Streaming conversion: the buffer is offered once and then `.noDataNow`, so the converter
    /// keeps its filter state across buffers rather than flushing at each one.
    private func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let ratio = Self.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        if outputBuffer == nil || outputBuffer!.frameCapacity < capacity {
            outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
        }
        guard let out = outputBuffer else { return nil }
        out.frameLength = 0
        var offered = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if offered {
                inputStatus.pointee = .noDataNow
                return nil
            }
            offered = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil else { return nil }
        return out
    }
}
