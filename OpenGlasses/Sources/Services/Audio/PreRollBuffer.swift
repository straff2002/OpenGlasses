import Foundation

/// Plan GU §5 — the last `capacity` mono samples, preallocated, overwritten continuously.
///
/// The speech gate opens a beat after the first syllable; the pre-roll is what lets the recognizer
/// still hear it. Written on the render thread, so `write` never allocates: the storage is sized
/// once. Held in memory only — never logged, never persisted.
///
/// Every sample carries an implicit sequence number (`framesWritten` counts them), which is how the
/// hand-over to live recognition is proved to lose and double nothing.
struct PreRollBuffer {
    let capacity: Int
    private var storage: [Float]
    private var writeIndex = 0
    private(set) var count = 0
    /// Sequence number of the next sample to be written.
    private(set) var framesWritten: UInt64 = 0

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
        storage = [Float](repeating: 0, count: self.capacity)
    }

    init(seconds: TimeInterval, sampleRate: Double) {
        self.init(capacity: Int((seconds * sampleRate).rounded(.up)))
    }

    mutating func write(_ samples: UnsafeBufferPointer<Float>) {
        guard !samples.isEmpty else { return }
        framesWritten &+= UInt64(samples.count)
        // Only the newest `capacity` samples can survive; skip straight to them.
        let keep = min(samples.count, capacity)
        let start = samples.count - keep
        var index = writeIndex
        let cap = capacity
        storage.withUnsafeMutableBufferPointer { dest in
            for i in 0..<keep {
                dest[index] = samples[start + i]
                index += 1
                if index == cap { index = 0 }
            }
        }
        writeIndex = index
        count = min(count + keep, capacity)
    }

    mutating func write(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { write($0) }
    }

    /// What is held, oldest first, and the sequence number of its first sample.
    func contents() -> (samples: [Float], firstSequence: UInt64) {
        var out = [Float]()
        out.reserveCapacity(count)
        var index = (writeIndex - count + capacity) % capacity
        for _ in 0..<count {
            out.append(storage[index])
            index += 1
            if index == capacity { index = 0 }
        }
        return (out, framesWritten - UInt64(count))
    }

    /// Forget what is held (the sequence keeps counting).
    mutating func clear() {
        count = 0
        writeIndex = 0
    }
}

/// Plan GU §5 — where each tap buffer goes while the speech gate is in use: into the pre-roll while
/// no recognizer is attached, straight to the recognizer once one is. `attach()` drains the
/// pre-roll and switches to live in one step, so — as long as it runs under the same lock as
/// `route` (it does: `WakeTapState`) — no sample is lost or delivered twice.
struct GatedTapRouter {
    enum Delivery: Equatable {
        /// Kept in the pre-roll.
        case buffered
        /// Hand to the attached recognizer.
        case live
    }

    private(set) var preRoll: PreRollBuffer
    private(set) var attached = false

    init(preRoll: PreRollBuffer) { self.preRoll = preRoll }

    mutating func route(_ samples: UnsafeBufferPointer<Float>) -> Delivery {
        if attached { return .live }
        preRoll.write(samples)
        return .buffered
    }

    mutating func route(_ samples: [Float]) -> Delivery {
        samples.withUnsafeBufferPointer { route($0) }
    }

    /// Attach a recognizer: returns the pre-roll to replay into it first, oldest first.
    mutating func attach() -> (samples: [Float], firstSequence: UInt64) {
        let held = preRoll.contents()
        preRoll.clear()
        attached = true
        return held
    }

    /// The recognizer closed: back to buffering.
    mutating func detach() {
        attached = false
        preRoll.clear()
    }
}
