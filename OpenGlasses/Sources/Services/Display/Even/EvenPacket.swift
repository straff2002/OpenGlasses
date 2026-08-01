import Foundation

/// Plan AH — pure codec for the EVEN G2 BLE framing. The protocol is a community
/// reverse-engineered reconstruction: every byte-level choice here is deterministic and
/// unit-tested, but must be **validated against capture logs / hardware** before the
/// transport ships live. No I/O in this file.
///
/// Framing:
/// `[AA] [type] [seq] [len] [pktTotal] [pktSerial] [svcHi] [svcLo] [payload…] [crcLo] [crcHi]`
/// - `len` = payload length + 2 (CRC included) — a single byte, so payload ≤ 253 per packet.
/// - `pktTotal`/`pktSerial` (1-based) fragment a >MTU message; `seq` is constant across
///   the fragments of one message.
/// - CRC-16/CCITT-FALSE (init 0xFFFF, poly 0x1021, no reflection), computed over the
///   **payload only** (the 8-byte header is skipped), emitted **little-endian**.
enum CRC16CCITT {
    static func compute(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }
}

struct EvenPacket: Equatable {
    static let headerByte: UInt8 = 0xAA
    static let headerLength = 8
    /// Rendering packets observed at 204 bytes total → 194 payload bytes.
    static let renderPacketPayloadBudget = 204 - headerLength - 2

    enum PacketType: UInt8 {
        case command = 0x21
        case response = 0x12
    }

    let type: PacketType
    let sequence: UInt8
    let packetTotal: UInt8
    let packetSerial: UInt8
    let service: UInt16
    let payload: [UInt8]

    init(type: PacketType, sequence: UInt8, packetTotal: UInt8 = 1, packetSerial: UInt8 = 1,
         service: UInt16, payload: [UInt8]) {
        self.type = type
        self.sequence = sequence
        self.packetTotal = packetTotal
        self.packetSerial = packetSerial
        self.service = service
        self.payload = payload
    }

    // MARK: - Encode / decode

    func encoded() -> [UInt8] {
        var out: [UInt8] = [
            Self.headerByte,
            type.rawValue,
            sequence,
            UInt8(truncatingIfNeeded: payload.count + 2),
            packetTotal,
            packetSerial,
            UInt8(truncatingIfNeeded: service >> 8),
            UInt8(truncatingIfNeeded: service & 0xFF),
        ]
        out.append(contentsOf: payload)
        let crc = CRC16CCITT.compute(payload)
        out.append(UInt8(truncatingIfNeeded: crc & 0xFF))   // little-endian: low first
        out.append(UInt8(truncatingIfNeeded: crc >> 8))
        return out
    }

    /// Nil on malformed framing or a CRC mismatch — a corrupt packet is dropped, never
    /// half-trusted.
    static func decode(_ bytes: [UInt8]) -> EvenPacket? {
        guard bytes.count >= headerLength + 2, bytes[0] == headerByte,
              let type = PacketType(rawValue: bytes[1]) else { return nil }
        let declaredLength = Int(bytes[3])
        guard declaredLength >= 2, bytes.count == headerLength + declaredLength else { return nil }
        let payload = Array(bytes[headerLength..<(bytes.count - 2)])
        let crc = UInt16(bytes[bytes.count - 2]) | (UInt16(bytes[bytes.count - 1]) << 8)
        guard crc == CRC16CCITT.compute(payload) else { return nil }
        return EvenPacket(type: type, sequence: bytes[2], packetTotal: bytes[4],
                          packetSerial: bytes[5],
                          service: (UInt16(bytes[6]) << 8) | UInt16(bytes[7]),
                          payload: payload)
    }

    // MARK: - Fragmentation

    /// Split `payload` into 1-based fragments sharing `sequence`, each within
    /// `maxPayloadPerPacket`. Empty payload still produces one packet.
    static func fragments(type: PacketType, sequence: UInt8, service: UInt16,
                          payload: [UInt8],
                          maxPayloadPerPacket: Int = renderPacketPayloadBudget) -> [EvenPacket] {
        let budget = max(1, min(maxPayloadPerPacket, 253))
        let chunks: [[UInt8]] = payload.isEmpty
            ? [[]]
            : stride(from: 0, to: payload.count, by: budget).map {
                Array(payload[$0..<min($0 + budget, payload.count)])
            }
        return chunks.enumerated().map { index, chunk in
            EvenPacket(type: type, sequence: sequence,
                       packetTotal: UInt8(truncatingIfNeeded: chunks.count),
                       packetSerial: UInt8(truncatingIfNeeded: index + 1),
                       service: service, payload: chunk)
        }
    }

    /// Reassemble one message from its fragments. Nil unless the set is complete,
    /// same-sequence, same-service, and correctly numbered.
    static func reassemble(_ packets: [EvenPacket]) -> [UInt8]? {
        guard let first = packets.first else { return nil }
        let total = Int(first.packetTotal)
        guard packets.count == total,
              packets.allSatisfy({ $0.sequence == first.sequence && $0.service == first.service
                  && Int($0.packetTotal) == total }) else { return nil }
        let sorted = packets.sorted { $0.packetSerial < $1.packetSerial }
        guard sorted.enumerated().allSatisfy({ Int($1.packetSerial) == $0 + 1 }) else { return nil }
        return sorted.flatMap(\.payload)
    }
}
