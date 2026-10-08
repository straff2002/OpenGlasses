import AVFoundation

/// Constructs `AVAudioFormat` values without force-unwrapping.
///
/// `AVAudioFormat`'s initializer is failable: it returns `nil` for parameter combinations the
/// OS can't represent. In practice this bites on unexpected native input formats from some
/// Bluetooth / iOS LE-Audio mic routes — exactly the routes these glasses use — where a
/// force-unwrap (`AVAudioFormat(...)!`) becomes a hard crash mid-call. This helper turns that
/// failure into a typed `AudioSessionError.invalidFormat(context:)` the caller can handle.
enum AudioFormatFactory {
    /// A PCM `AVAudioFormat`, or throw `AudioSessionError.invalidFormat(context:)`.
    ///
    /// - Parameter context: names the role (e.g. "playback", "capture resampling") for the
    ///   thrown error and any logging — purely diagnostic.
    static func pcm(
        _ commonFormat: AVAudioCommonFormat,
        sampleRate: Double,
        channels: AVAudioChannelCount,
        interleaved: Bool,
        context: String
    ) throws -> AVAudioFormat {
        // Guard the obviously-degenerate inputs up front: AVAudioFormat asserts (rather than
        // returning nil) on a zero channel count, so we must not reach its initializer with one.
        guard sampleRate > 0, channels > 0,
              let format = AVAudioFormat(
                commonFormat: commonFormat,
                sampleRate: sampleRate,
                channels: channels,
                interleaved: interleaved
              )
        else {
            throw AudioSessionError.invalidFormat(context: context)
        }
        return format
    }

    /// Whether a node's reported format can carry a tap.
    ///
    /// `AVAudioNode.installTap(onBus:bufferSize:format:block:)` raises an Objective-C exception
    /// — not a Swift error, so no `catch` sees it — when handed a 0 Hz / 0-channel format. That
    /// is exactly what `inputNode.outputFormat(forBus: 0)` reports while the input is unavailable:
    /// backgrounded behind another app that holds the microphone, a Bluetooth route mid-change,
    /// or a session never activated for recording (TestFlight build 463, "in background with
    /// Meta AI open"). Check before installing; refuse with an error the caller can roll back.
    static func isUsableTapFormat(_ format: AVAudioFormat) -> Bool {
        isUsableTapFormat(sampleRate: format.sampleRate, channelCount: format.channelCount)
    }

    static func isUsableTapFormat(sampleRate: Double, channelCount: AVAudioChannelCount) -> Bool {
        sampleRate > 0 && channelCount > 0
    }
}
