import Foundation

/// CRC-16/MODBUS, as used by the OEM capture protocol's frame header.
///
/// Written from the published catalogue parameters — reflected polynomial `0xA001`, initial value
/// `0xFFFF`, no final XOR — and pinned by the catalogue's own check value in the tests, rather
/// than transcribed from anyone's implementation (Plan CQ licensing rider; same discipline as
/// `CRC16CCITT` in `EvenPacket`, which is a *different* variant and deliberately not shared).
enum CRC16Modbus {
    static func compute(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1
            }
        }
        return crc
    }
}

/// Plan CQ P4 — one frame of the OEM capture protocol, encode and decode.
///
/// Wire format is a fixed six-byte header followed by the payload:
///
/// ```
/// [0xBC] [command] [len_lo] [len_hi] [crc_lo] [crc_hi] [payload…]
/// ```
///
/// where the length is the payload length little-endian and the CRC is CRC-16/MODBUS over the
/// payload only (not the header), also little-endian.
///
/// **Every byte-level claim here is a community reconstruction and is unverified against
/// hardware.** This type is pure and ships dark: nothing constructs it until Plan CQ P5 adds a
/// transport, which itself only runs once a user pairs one of these devices. Treat a decode
/// failure against a real capture log as evidence the reconstruction is wrong, not as a bug in
/// the caller.
struct CapturePacket: Equatable {

    /// Frame start marker.
    static let sentinel: UInt8 = 0xBC

    /// Header bytes before the payload: sentinel, command, length (2), CRC (2).
    static let headerLength = 6

    /// Largest chunk the transport will carry in one write. Frames longer than this are split
    /// across BLE writes and have to be reassembled from the byte stream — see
    /// ``CaptureFrameAssembler``.
    static let transportChunkSize = 244

    let command: UInt8
    let payload: [UInt8]

    init(command: UInt8, payload: [UInt8] = []) {
        self.command = command
        self.payload = payload
    }

    /// The complete on-wire frame.
    var encoded: [UInt8] {
        let crc = CRC16Modbus.compute(payload)
        let length = UInt16(payload.count)
        var out: [UInt8] = [
            Self.sentinel,
            command,
            UInt8(truncatingIfNeeded: length),
            UInt8(truncatingIfNeeded: length >> 8),
            UInt8(truncatingIfNeeded: crc),
            UInt8(truncatingIfNeeded: crc >> 8),
        ]
        out.append(contentsOf: payload)
        return out
    }

    /// Split an encoded frame into transport-sized writes.
    ///
    /// Fragmentation is a property of the *link*, not the protocol: there are no fragment
    /// indices or continuation flags to key off, just a byte stream chopped at the MTU. That is
    /// why reassembly is a stateful stream reader rather than a `reassemble([Packet])`.
    func chunked(size: Int = CapturePacket.transportChunkSize) -> [[UInt8]] {
        precondition(size > 0, "chunk size must be positive")
        let bytes = encoded
        guard bytes.count > size else { return [bytes] }
        return stride(from: 0, to: bytes.count, by: size).map {
            Array(bytes[$0..<min($0 + size, bytes.count)])
        }
    }

    /// Decode exactly one frame from the start of `bytes`.
    ///
    /// - Returns: the packet and how many bytes it consumed, or nil if `bytes` does not begin
    ///   with a complete, CRC-valid frame. A nil result does **not** distinguish "not yet
    ///   complete" from "corrupt" — ``CaptureFrameAssembler`` makes that distinction, because
    ///   only it knows whether more bytes are coming.
    static func decode(_ bytes: [UInt8]) -> (packet: CapturePacket, consumed: Int)? {
        guard bytes.count >= headerLength, bytes[0] == sentinel else { return nil }
        let length = Int(bytes[2]) | (Int(bytes[3]) << 8)
        let total = headerLength + length
        guard bytes.count >= total else { return nil }
        let payload = Array(bytes[headerLength..<total])
        let crc = UInt16(bytes[4]) | (UInt16(bytes[5]) << 8)
        guard crc == CRC16Modbus.compute(payload) else { return nil }
        return (CapturePacket(command: bytes[1], payload: payload), total)
    }
}

/// Reassembles frames from the transport's byte stream.
///
/// A BLE notification is not a frame. One write can carry a partial frame, several frames, or a
/// frame boundary in the middle of it, so the receive path has to buffer and re-scan rather than
/// parse each notification in isolation.
///
/// Resynchronisation matters as much as parsing: a dropped write leaves a partial frame in the
/// buffer that will never complete, and without a way out the channel is dead for the rest of
/// the session. On a bad sentinel or a failed CRC the assembler discards one byte and rescans
/// for the next sentinel — costly per byte, but bounded, and it recovers.
struct CaptureFrameAssembler {

    /// Bytes received but not yet consumed by a complete frame.
    private(set) var buffer: [UInt8] = []

    /// How many bytes have been discarded during resynchronisation. Exposed so the cost is
    /// measurable rather than invisible — a rising count is the signal that the reconstruction
    /// of the wire format is wrong, or the link is dropping writes.
    private(set) var discardedBytes = 0

    /// Cap on retained bytes, so a stream that never yields a valid frame cannot grow without
    /// bound. Sized to comfortably exceed one maximum-length frame.
    static let maxBufferedBytes = 8 * 1024

    init() {}

    /// Feed one transport write; get back every frame that completed as a result.
    mutating func append(_ chunk: [UInt8]) -> [CapturePacket] {
        buffer.append(contentsOf: chunk)
        var packets: [CapturePacket] = []

        while !buffer.isEmpty {
            if buffer[0] != CapturePacket.sentinel {
                // Not a frame start — drop a byte and look again.
                buffer.removeFirst()
                discardedBytes += 1
                continue
            }
            if let (packet, consumed) = CapturePacket.decode(buffer) {
                packets.append(packet)
                buffer.removeFirst(consumed)
                continue
            }
            // A valid sentinel with no complete frame behind it is either a frame still in
            // flight or a corrupt header. Tell them apart by whether the declared length could
            // still arrive; a header that claims a length we already have has a bad CRC and
            // will never validate, so drop its sentinel and rescan.
            if buffer.count >= CapturePacket.headerLength {
                let declared = Int(buffer[2]) | (Int(buffer[3]) << 8)
                if buffer.count >= CapturePacket.headerLength + declared {
                    buffer.removeFirst()
                    discardedBytes += 1
                    continue
                }
            }
            break  // incomplete — wait for more bytes
        }

        if buffer.count > Self.maxBufferedBytes {
            discardedBytes += buffer.count
            buffer.removeAll(keepingCapacity: true)
        }
        return packets
    }

    /// Drop any partial frame. Call on disconnect so a reconnect starts clean.
    mutating func reset() {
        discardedBytes += buffer.count
        buffer.removeAll(keepingCapacity: true)
    }
}
