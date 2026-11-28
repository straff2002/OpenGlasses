import Foundation

/// The MFi session's outgoing writes, in the order they were sent.
///
/// An `OutputStream` takes what it has room for, which can be part of a write or nothing at all.
/// Writing straight from the caller, as the transport first did, has two faults. A full stream
/// returns 0, which read as a failed write and dropped the command. And two callers (a command and
/// a long photo or audio send) could interleave their bytes, which the glasses would parse as a
/// corrupt blob. Instead every write joins this queue whole, and the stream thread drains it from
/// the front only while the stream says it has space. A write that goes out in pieces finishes
/// before the next one starts.
///
/// Pure value type: the transport holds it under its lock and the tests drive it directly.
struct RokidWriteQueue {

    /// Room for any burst the probe or a backend makes, while a stalled session that keeps being
    /// written to fails fast instead of growing without bound.
    static let defaultCapacity = 1 << 20

    /// Most bytes held at once. One write larger than this is still taken when the queue is
    /// empty, or it could never be sent.
    let capacity: Int

    private var writes: [[UInt8]] = []
    /// How much of `writes[0]` has already gone out.
    private var headOffset = 0

    /// Bytes still to go, across every queued write.
    private(set) var queuedByteCount = 0

    init(capacity: Int = RokidWriteQueue.defaultCapacity) {
        self.capacity = capacity
    }

    var isEmpty: Bool { writes.isEmpty }

    /// Queue one write. Returns false, and queues nothing, when it would push the queue past
    /// ``capacity``. An empty write is accepted and dropped.
    @discardableResult
    mutating func enqueue(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return true }
        if !writes.isEmpty, queuedByteCount + bytes.count > capacity { return false }
        writes.append(bytes)
        queuedByteCount += bytes.count
        return true
    }

    /// The part of the oldest write that has not gone out yet, or `nil` when nothing is queued.
    var head: ArraySlice<UInt8>? {
        guard let first = writes.first else { return nil }
        return first[headOffset...]
    }

    /// Record that the stream took `count` bytes of ``head``. A count past the end of the head is
    /// clamped to it, so a stray value can never eat into the next write.
    mutating func consume(_ count: Int) {
        guard count > 0, let first = writes.first else { return }
        let taken = min(count, first.count - headOffset)
        headOffset += taken
        queuedByteCount -= taken
        if headOffset == first.count {
            writes.removeFirst()
            headOffset = 0
        }
    }

    /// Drop everything, as a closing session must: queued bytes belong to the session that queued
    /// them and mean nothing to the next one.
    mutating func removeAll() {
        writes.removeAll()
        headOffset = 0
        queuedByteCount = 0
    }

    /// What one call to ``drain(_:)`` ended on.
    enum DrainOutcome: Equatable {
        /// Everything queued went out.
        case empty
        /// The stream took no more for now. Drain again when it reports space.
        case blocked
        /// The stream reported an error. The queue keeps the unsent bytes.
        case failed
    }

    /// Hand the stream as much as it takes, oldest write first.
    ///
    /// `write` gets a pointer and a length, like `OutputStream.write(_:maxLength:)`, and returns
    /// what that does: the bytes taken, 0 for no room, or a negative number for an error.
    mutating func drain(_ write: (UnsafePointer<UInt8>, Int) -> Int) -> DrainOutcome {
        while let slice = head {
            let written = slice.withUnsafeBufferPointer { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return write(base, buffer.count)
            }
            if written < 0 { return .failed }
            if written == 0 { return .blocked }
            consume(written)
        }
        return .empty
    }
}
