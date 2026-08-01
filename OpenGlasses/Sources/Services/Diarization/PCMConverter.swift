import AVFoundation
import Foundation

/// Converts captured float32 PCM into the **linear16 mono** bytes Deepgram's streaming API
/// expects (`encoding=linear16`). The numeric core (downmix + clamp + Int16 scaling) is pure
/// and unit-tested on synthetic sample arrays; the `AVAudioPCMBuffer` overload just adapts a
/// live buffer onto it.
enum PCMConverter {

    /// Downmix per-channel float samples to a single mono channel by averaging across channels.
    /// `channels` is `[channel][frame]`; returns one `[frame]` array.
    static func downmixToMono(_ channels: [[Float]]) -> [Float] {
        guard let first = channels.first else { return [] }
        guard channels.count > 1 else { return first }
        let frameCount = channels.map(\.count).min() ?? 0
        var mono = [Float](repeating: 0, count: frameCount)
        for ch in channels {
            for i in 0..<frameCount { mono[i] += ch[i] }
        }
        let scale = 1 / Float(channels.count)
        for i in 0..<frameCount { mono[i] *= scale }
        return mono
    }

    /// Encode mono float samples (`-1...1`) as little-endian signed 16-bit PCM. Samples are
    /// clamped to the valid range so over-unity values can't wrap on conversion.
    static func linear16(fromMono samples: [Float]) -> Data {
        var out = [Int16](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            let clamped = max(-1, min(1, samples[i]))
            out[i] = Int16(clamped * Float(Int16.max))
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Convenience: downmix then encode.
    static func linear16Mono(fromChannels channels: [[Float]]) -> Data {
        linear16(fromMono: downmixToMono(channels))
    }

    /// Linear-interpolation resample of mono float samples. Speech-STT quality is fine with
    /// linear interpolation for the downsampling this app does (48 k → 16 k); equal rates pass
    /// through untouched. Pure and unit-tested (Plan BY P2 — the Gemini wire is fixed at 16 kHz,
    /// unlike Deepgram's rate-parameterised URL).
    static func resample(_ samples: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        guard sourceRate > 0, targetRate > 0, !samples.isEmpty else { return [] }
        guard sourceRate != targetRate else { return samples }
        let ratio = sourceRate / targetRate
        let outCount = Int((Double(samples.count) / ratio).rounded(.down))
        guard outCount > 0 else { return [] }
        var out = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let position = Double(i) * ratio
            let index = Int(position)
            let fraction = Float(position - Double(index))
            let next = min(index + 1, samples.count - 1)
            out[i] = samples[index] * (1 - fraction) + samples[next] * fraction
        }
        return out
    }

    /// Adapt a live buffer to linear16 mono bytes at `targetRate` (downmix → resample → encode).
    static func linear16Mono(from buffer: AVAudioPCMBuffer, resampledTo targetRate: Double) -> Data {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, let floatChannels = buffer.floatChannelData else { return Data() }
        let channelCount = Int(buffer.format.channelCount)
        let channels: [[Float]] = (0..<channelCount).map { ch in
            Array(UnsafeBufferPointer(start: floatChannels[ch], count: frameCount))
        }
        let mono = downmixToMono(channels)
        return linear16(fromMono: resample(mono, from: buffer.format.sampleRate, to: targetRate))
    }

    /// Adapt a live `AVAudioPCMBuffer` (float32, any channel count) to linear16 mono bytes.
    /// Returns empty `Data` for a non-float or empty buffer.
    static func linear16Mono(from buffer: AVAudioPCMBuffer) -> Data {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, let floatChannels = buffer.floatChannelData else { return Data() }
        let channelCount = Int(buffer.format.channelCount)
        let channels: [[Float]] = (0..<channelCount).map { ch in
            Array(UnsafeBufferPointer(start: floatChannels[ch], count: frameCount))
        }
        return linear16Mono(fromChannels: channels)
    }
}
