import Foundation

/// Reassembles iAP2 link frames out of an arbitrarily chunked byte stream.
///
/// Classic-Bluetooth MFI delivers bytes, not messages: a single frame arrives split across
/// several `InputStream` reads, several frames arrive in one read, and the stream is salted
/// with RFCOMM headers (`41 ef 1d …`) and AT-style modem text (`+CIEV: 5,3\r\n`) that sit
/// between frames. This type turns that into whole frames.
///
/// Resynchronisation is deliberately strict, because `FF 5A` occurs inside binary payloads —
/// a 2,358-frame audio stream makes that certain rather than hypothetical. A candidate frame
/// is only accepted when *all* of the following hold, and a failed candidate costs one byte
/// rather than the whole frame:
///
/// 1. the declared length (big-endian at offset 2, counting from the leading `FF`) is within
///    ``minimumFrameLength``…``maximumFrameLength``;
/// 2. the type byte at offset 4 is `0x40`;
/// 3. the trailing byte is the two's-complement checksum of everything before it.
///
/// The length field is the **whole frame** measured from the sync byte — not a payload
/// length. Reading it as a payload length was the original decoding error, and it is what
/// produced the phantom "trailing bytes" behind every frame.
struct RokidFrameDrain {

    /// Smallest possible frame: prefix (4) + header (7) + a one-byte Caps blob + checksum.
    static let minimumFrameLength = RokidIAP2Packet.prefixBytes
        + RokidIAP2Packet.headerBytesAfterLength + 2

    /// Upper bound for resynchronisation. The glasses cap a write at `iphone_gatt: 500` bytes
    /// and audio chunks at `send_audio_stream_mtu: 3200`, so anything past this is noise that
    /// happens to start with the sync word.
    static let maximumFrameLength = 8_192

    private var pending: [UInt8] = []

    /// Bytes held back because they may be the start of a frame that has not fully arrived.
    var pendingByteCount: Int { pending.count }

    init() {}

    /// Feed one read from the stream and return every frame that completed because of it.
    ///
    /// Incomplete trailing bytes stay buffered, so the caller can simply loop on reads.
    mutating func append(_ chunk: [UInt8]) -> [[UInt8]] {
        guard !chunk.isEmpty else { return [] }
        pending.append(contentsOf: chunk)

        var frames: [[UInt8]] = []
        while true {
            guard let start = firstSyncIndex() else {
                // No sync word. Keep a lone trailing 0xFF: the 0x5A may be in the next read.
                pending = pending.last == RokidIAP2Packet.linkSync[0] ? [RokidIAP2Packet.linkSync[0]] : []
                break
            }
            if start > 0 { pending.removeFirst(start) }

            // Need the length field before the frame can be bounded.
            guard pending.count >= RokidIAP2Packet.prefixBytes else { break }
            let declared = Int(pending[2]) << 8 | Int(pending[3])
            guard declared >= Self.minimumFrameLength, declared <= Self.maximumFrameLength else {
                // A plausible-looking sync word with an impossible length: step past it and
                // rescan, rather than discarding whatever real frame follows.
                pending.removeFirst(1)
                continue
            }
            guard pending.count >= declared else { break }

            let candidate = Array(pending[0..<declared])
            if Self.isFrame(candidate) {
                frames.append(candidate)
                pending.removeFirst(declared)
            } else {
                // False sync: the sync word was payload, not framing.
                pending.removeFirst(1)
            }
        }
        return frames
    }

    /// Drop buffered bytes. Call on disconnect so a stale partial frame cannot prepend the
    /// first frame of the next session.
    mutating func reset() {
        pending.removeAll(keepingCapacity: true)
    }

    /// Whether `frame` is a structurally valid iAP2 link frame.
    static func isFrame(_ frame: [UInt8]) -> Bool {
        guard frame.count >= minimumFrameLength,
              frame[0] == RokidIAP2Packet.linkSync[0],
              frame[1] == RokidIAP2Packet.linkSync[1] else { return false }
        let declared = Int(frame[2]) << 8 | Int(frame[3])
        guard declared == frame.count else { return false }
        guard frame[4] == RokidIAP2Packet.frameType else { return false }
        return RokidIAP2Packet.checksum(Array(frame.dropLast())) == frame[frame.count - 1]
    }

    private func firstSyncIndex() -> Int? {
        guard pending.count >= 2 else { return nil }
        var index = 0
        while index < pending.count - 1 {
            if pending[index] == RokidIAP2Packet.linkSync[0],
               pending[index + 1] == RokidIAP2Packet.linkSync[1] {
                return index
            }
            index += 1
        }
        return nil
    }
}
