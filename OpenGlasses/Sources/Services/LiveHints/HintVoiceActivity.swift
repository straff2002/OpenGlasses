import AVFoundation
import Foundation

/// Whether anyone near the phone is speaking, from the mic's level (Plan MO §6): what the
/// speak-when-quiet policy hears, so a hint waits for quiet and stops when someone talks over it.
///
/// It reads the **ungated** level: the caption gate silences the assistant's own voice on the phone
/// speaker for the recogniser, but a person talking over a hint must still be heard.
///
/// Pure hysteresis over levels in dBFS: speech starts on the first buffer at or above `onLevel`
/// (one buffer is 20–100 ms, inside the plan's ~200 ms stop), and ends once the level has stayed
/// below `offLevel` for `hangover`, so the gaps between words are not taken for quiet.
struct HintVoiceActivityDetector: Equatable, Sendable {
    static let onLevel: Float = -38
    static let offLevel: Float = -46
    static let hangover: TimeInterval = 0.25

    private(set) var isSpeaking = false
    private var quietSince: Date?

    /// One level reading. Returns the new state when it changed, nil otherwise.
    mutating func feed(levelDB: Float, at now: Date) -> Bool? {
        if levelDB >= Self.onLevel {
            quietSince = nil
            guard !isSpeaking else { return nil }
            isSpeaking = true
            return true
        }
        guard isSpeaking else { return nil }
        guard levelDB < Self.offLevel else {
            quietSince = nil
            return nil
        }
        let since = quietSince ?? now
        quietSince = since
        guard now.timeIntervalSince(since) >= Self.hangover - HintLimits.timeTolerance else { return nil }
        isSpeaking = false
        quietSince = nil
        return false
    }

    /// The RMS level of a run of samples in dBFS, floored at -120.
    static func levelDB(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return -120 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        let rms = (sum / Float(samples.count)).squareRoot()
        guard rms > 0 else { return -120 }
        return max(-120, 20 * log10(rms))
    }
}

/// Feeds `HintVoiceActivityDetector` from mic buffers on the audio thread, and hops to the main
/// actor only on a change: a few times a sentence, never per buffer.
final class HintMicLevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var detector = HintVoiceActivityDetector()
    private let onChange: @MainActor @Sendable (Bool) -> Void

    init(onChange: @escaping @MainActor @Sendable (Bool) -> Void) {
        self.onChange = onChange
    }

    /// Called from the audio thread with a raw (ungated) buffer.
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let level = HintVoiceActivityDetector.levelDB(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        lock.lock()
        let change = detector.feed(levelDB: level, at: Date())
        lock.unlock()
        guard let change else { return }
        let onChange = self.onChange
        Task { @MainActor in onChange(change) }
    }
}
