import Foundation

/// One packet of the `SMART_RING` protocol: exactly 20 bytes, the first the command or response
/// id, the rest fields and zero padding. There is no length header and no checksum, and integers
/// are little-endian. A packet of any other length is refused rather than padded or cut.
struct SmartRingPacket: Equatable, Sendable {

    static let length = 20

    let bytes: [UInt8]

    /// A received packet. Nil unless it is exactly `length` bytes.
    init?(bytes: [UInt8]) {
        guard bytes.count == Self.length else { return nil }
        self.bytes = bytes
    }

    /// A packet to send: `opcode`, then `payload` from byte 1, then zero padding. A payload longer
    /// than 19 bytes is a programming error.
    init(opcode: UInt8, payload: [UInt8] = []) {
        precondition(payload.count < Self.length, "a packet holds 19 payload bytes")
        bytes = [opcode] + payload + Array(repeating: 0, count: Self.length - 1 - payload.count)
    }

    var opcode: UInt8 { bytes[0] }

    subscript(_ index: Int) -> UInt8 { bytes[index] }

    /// The little-endian u32 at `offset` (bytes `offset` … `offset + 3`).
    func uint32(at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * UInt32($1)) }
    }

    /// Whether every byte from `offset` to the end is zero.
    func isZero(from offset: Int) -> Bool {
        bytes[offset...].allSatisfy { $0 == 0 }
    }

    /// A value as four little-endian bytes.
    static func littleEndian(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * UInt32($0))) }
    }
}
