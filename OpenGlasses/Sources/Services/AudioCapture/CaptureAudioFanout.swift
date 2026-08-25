import AVFoundation
import Foundation
import os.lock

/// Lock-guarded fan-out box read from the Core Audio render thread.
///
/// Same discipline as the always-on listener's tap box: the render thread must never touch
/// `@MainActor` storage, so the main actor publishes the consumer set (and the gate decision) into
/// this box under a lock, and the tap reads one consistent snapshot per buffer. A torn read of a
/// dictionary of closures on the app's hottest thread is an `EXC_BAD_ACCESS`, not a glitch.
final class CaptureAudioFanout: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    private struct State {
        var consumers: [@Sendable (AVAudioPCMBuffer) -> Void] = []
        /// When true, consumers receive a zero-filled buffer of the same shape instead of the real
        /// one (see `AssistantAudioGate`).
        var silenced = false
    }

    /// Publish the current consumer set. Called from the main actor.
    func setConsumers(_ consumers: [@Sendable (AVAudioPCMBuffer) -> Void]) {
        lock.withLock { $0.consumers = consumers }
    }

    /// Publish the current gate decision. Called from the main actor.
    func setSilenced(_ silenced: Bool) {
        lock.withLock { $0.silenced = silenced }
    }

    /// Whether anything is registered — cheap enough to ask from the render thread.
    var isEmpty: Bool {
        lock.withLock { $0.consumers.isEmpty }
    }

    /// Called from the audio thread: fan one buffer out to every consumer from a single snapshot.
    func dispatch(_ buffer: AVAudioPCMBuffer) {
        let snapshot = lock.withLock { $0 }
        guard !snapshot.consumers.isEmpty else { return }
        // A gated buffer is replaced with a fresh silent one rather than a cached, reused buffer:
        // consumers may hold onto it past this call (the broadcast path hops to the main actor with
        // it before appending), so a shared mutable buffer would be rewritten under them. The
        // allocation only happens while the assistant is actually speaking out of the phone
        // speaker — a bounded, uncommon state, not the steady path.
        let outgoing = snapshot.silenced ? (CaptureAudioSilencer.silence(like: buffer) ?? buffer) : buffer
        for consumer in snapshot.consumers { consumer(outgoing) }
    }
}

/// Builds a zero-filled buffer matching another buffer's format and length.
enum CaptureAudioSilencer {
    /// A silent buffer with `buffer`'s format and frame length, or `nil` if allocation fails.
    ///
    /// Zeroes the whole audio buffer list rather than a typed channel pointer, so it is correct for
    /// float and integer formats alike (the tap's format follows the hardware route, and a
    /// Bluetooth link does not always hand us float32).
    static func silence(like buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let silent = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength > 0 ? buffer.frameLength : 1) else {
            return nil
        }
        silent.frameLength = buffer.frameLength
        let list = UnsafeMutableAudioBufferListPointer(silent.mutableAudioBufferList)
        for audioBuffer in list {
            guard let data = audioBuffer.mData else { continue }
            memset(data, 0, Int(audioBuffer.mDataByteSize))
        }
        return silent
    }
}
