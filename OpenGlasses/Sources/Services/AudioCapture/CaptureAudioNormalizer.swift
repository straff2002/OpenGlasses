import AVFoundation
import Foundation

/// Compares two audio formats the way the consumers downstream of capture actually compare them:
/// by stream description, which is what `CMAudioFormatDescription` is built from and what an
/// `AVAssetWriterInput` locks itself to.
enum CaptureAudioFormatMatch {

    /// Whether two formats describe the same stream — same rate, layout, packing and width.
    ///
    /// Deliberately stricter than "same sample rate and channel count": interleaved and
    /// non-interleaved float32 at 48 kHz mono are the same audio and two different
    /// `AudioStreamBasicDescription`s, and it is the description that decides whether an asset
    /// writer accepts the next sample buffer.
    static func matches(_ lhs: AudioStreamBasicDescription, _ rhs: AudioStreamBasicDescription) -> Bool {
        lhs.mSampleRate == rhs.mSampleRate
            && lhs.mFormatID == rhs.mFormatID
            && lhs.mFormatFlags == rhs.mFormatFlags
            && lhs.mBytesPerPacket == rhs.mBytesPerPacket
            && lhs.mFramesPerPacket == rhs.mFramesPerPacket
            && lhs.mBytesPerFrame == rhs.mBytesPerFrame
            && lhs.mChannelsPerFrame == rhs.mChannelsPerFrame
            && lhs.mBitsPerChannel == rhs.mBitsPerChannel
    }

    static func matches(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        matches(lhs.streamDescription.pointee, rhs.streamDescription.pointee)
    }
}

/// Holds capture audio to one format for the life of a capture, whatever source is feeding it.
///
/// The two mic sources behind `CaptureAudioRouter` are two separate `AVAudioEngine`s, and each
/// takes its tap format from `inputNode.outputFormat(forBus: 0)` — whatever the route happens to be
/// when *that* engine starts. Handing over mid-capture can therefore change the sample rate,
/// channel count or packing under consumers that cannot survive it:
///
///  - `AVAssetWriterInput` locks its audio format to the first sample buffer it is given. The next
///    buffer that disagrees is rejected and the whole `AVAssetWriter` moves to `.failed` — which
///    takes the *video* track down with it. The recording does not lose its audio, it dies, and
///    `finishWriting` then has no file to hand back. That is the device symptom this exists for:
///    enable the always-on listener a minute into a recording and the recording ends a second later.
///  - The broadcast's audio PTS runs off a sample-count clock read at `buffer.format.sampleRate`,
///    so a rate change shifts A/V sync for the rest of the session.
///
/// So the first buffer of a capture fixes the canonical format and every later buffer is converted
/// into it. Buffers that already match — the entire steady state, and every capture that never sees
/// a handover — are passed through untouched, so nothing is resampled that doesn't have to be.
///
/// A conversion that fails yields silence of the right duration rather than `nil`: dropping the
/// slot would shift the broadcast's sample clock permanently, and passing the original through
/// would be the format change all over again.
final class CaptureAudioNormalizer: @unchecked Sendable {

    /// `NSLock` rather than `OSAllocatedUnfairLock` because the guarded work has to *return* an
    /// `AVAudioPCMBuffer`, and `withLock` constrains its result to `Sendable`. Contention is
    /// negligible either way: one audio thread calls `normalize`, and only a capture ending calls
    /// `reset` from the main actor.
    private let lock = NSLock()

    private var canonical: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var convertingFrom: AVAudioFormat?
    private var conversionFailures = 0

    /// The format consumers are currently being fed, or nil before this capture's first buffer.
    var canonicalFormat: AVAudioFormat? {
        lock.lock()
        defer { lock.unlock() }
        return canonical
    }

    /// How many buffers this capture could not convert (diagnostics only).
    var conversionFailureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return conversionFailures
    }

    /// Forget the canonical format. Called when a capture ends so the next one adopts the route it
    /// actually starts on, rather than one fixed by a recording that finished an hour ago.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        canonical = nil
        converter = nil
        convertingFrom = nil
        conversionFailures = 0
    }

    /// Called from the audio render thread. Returns the buffer consumers should see: the input
    /// itself when it already matches the canonical format, a converted copy when it doesn't.
    func normalize(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }

        guard let canonical else {
            canonical = buffer.format
            return buffer
        }
        if CaptureAudioFormatMatch.matches(buffer.format, canonical) { return buffer }

        if converter == nil || !(convertingFrom.map { CaptureAudioFormatMatch.matches($0, buffer.format) } ?? false) {
            converter = AVAudioConverter(from: buffer.format, to: canonical)
            convertingFrom = buffer.format
        }
        guard let converter,
              let converted = Self.convert(buffer, with: converter, to: canonical) else {
            conversionFailures += 1
            return Self.silence(matching: buffer, in: canonical)
        }
        return converted
    }

    // MARK: - Conversion

    private static func convert(_ buffer: AVAudioPCMBuffer,
                                with converter: AVAudioConverter,
                                to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0, buffer.format.sampleRate > 0 else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        // Headroom: a resampler's output length for a given input block is not exactly the ratio.
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            // One block of input per call. Claiming `.haveData` forever makes a resampling
            // converter spin; `.noDataNow` is how it is told this block is all there is.
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }

        switch status {
        case .haveData, .inputRanDry:
            return output.frameLength > 0 ? output : nil
        case .endOfStream, .error:
            if let error { NSLog("[CaptureAudio] Conversion failed: %@", error.localizedDescription) }
            return nil
        @unknown default:
            return nil
        }
    }

    /// Silence in `format` lasting as long as `buffer` did — the duration is what the broadcast's
    /// sample clock and the writer's timeline care about.
    private static func silence(matching buffer: AVAudioPCMBuffer, in format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sourceRate = buffer.format.sampleRate > 0 ? buffer.format.sampleRate : format.sampleRate
        let ratio = format.sampleRate / sourceRate
        let frames = AVAudioFrameCount(max(1, (Double(buffer.frameLength) * ratio).rounded()))
        guard let silent = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        silent.frameLength = frames
        // Zero the whole buffer list rather than a typed channel pointer: the canonical format
        // follows the hardware route and a Bluetooth link does not always hand us float32.
        let list = UnsafeMutableAudioBufferListPointer(silent.mutableAudioBufferList)
        for audioBuffer in list {
            guard let data = audioBuffer.mData else { continue }
            memset(data, 0, Int(audioBuffer.mDataByteSize))
        }
        return silent
    }
}
