import Foundation
import XCTest
@testable import OpenGlasses

/// Plan CQ P4 — the pure capture-protocol core.
///
/// The wire format is a community reconstruction, so these tests can only pin what we *believe*
/// it to be — self-consistency, the published CRC vectors, and the behavioural rules that must
/// hold whatever the bytes turn out to be. When hardware arrives, a capture log is the thing
/// that decides whether the reconstruction was right; these tests decide whether our code
/// implements the reconstruction we wrote down.
final class CaptureProtocolTests: XCTestCase {

    // MARK: - CRC-16/MODBUS

    func testCRCMatchesThePublishedCheckValue() {
        // The catalogue's check value for CRC-16/MODBUS: "123456789" → 0x4B37. This is what
        // makes the implementation ours rather than a transcription — it is validated against
        // the published algorithm, not against someone else's code.
        let input = Array("123456789".utf8)
        XCTAssertEqual(CRC16Modbus.compute(input), 0x4B37)
    }

    func testCRCOfEmptyInputIsTheInitialValue() {
        XCTAssertEqual(CRC16Modbus.compute([]), 0xFFFF)
    }

    func testCRCIsOrderSensitive() {
        XCTAssertNotEqual(CRC16Modbus.compute([0x01, 0x02]), CRC16Modbus.compute([0x02, 0x01]))
    }

    // MARK: - Frame encode / decode

    func testHeaderLayoutIsSentinelCommandLengthCRC() {
        let packet = CapturePacket(command: 0x41, payload: [0xAA, 0xBB])
        let bytes = packet.encoded
        let crc = CRC16Modbus.compute([0xAA, 0xBB])

        XCTAssertEqual(bytes[0], 0xBC)
        XCTAssertEqual(bytes[1], 0x41)
        XCTAssertEqual(bytes[2], 0x02, "length low byte")
        XCTAssertEqual(bytes[3], 0x00, "length high byte")
        XCTAssertEqual(bytes[4], UInt8(truncatingIfNeeded: crc), "CRC low byte")
        XCTAssertEqual(bytes[5], UInt8(truncatingIfNeeded: crc >> 8), "CRC high byte")
        XCTAssertEqual(Array(bytes[6...]), [0xAA, 0xBB])
    }

    func testRoundTrip() {
        for payloadLength in [0, 1, 6, 255, 256, 1000] {
            let payload = (0..<payloadLength).map { UInt8($0 % 256) }
            let packet = CapturePacket(command: 0x59, payload: payload)
            guard let (decoded, consumed) = CapturePacket.decode(packet.encoded) else {
                return XCTFail("failed to decode a \(payloadLength)-byte payload")
            }
            XCTAssertEqual(decoded, packet)
            XCTAssertEqual(consumed, packet.encoded.count)
        }
    }

    func testMultiByteLengthIsLittleEndian() {
        // 300 = 0x012C, so low byte 0x2C then high byte 0x01. Getting this backwards would
        // still round-trip through our own decoder, which is why it is asserted directly.
        let packet = CapturePacket(command: 0x41, payload: [UInt8](repeating: 0, count: 300))
        XCTAssertEqual(packet.encoded[2], 0x2C)
        XCTAssertEqual(packet.encoded[3], 0x01)
    }

    func testDecodeRejectsBadSentinelTruncationAndCorruptCRC() {
        let good = CapturePacket(command: 0x41, payload: [0x01, 0x02, 0x03]).encoded

        var badSentinel = good
        badSentinel[0] = 0x00
        XCTAssertNil(CapturePacket.decode(badSentinel))

        XCTAssertNil(CapturePacket.decode(Array(good.dropLast())), "truncated frame")
        XCTAssertNil(CapturePacket.decode([]), "empty input")

        var corrupt = good
        corrupt[corrupt.count - 1] ^= 0xFF
        XCTAssertNil(CapturePacket.decode(corrupt), "payload corruption must fail the CRC")
    }

    func testDecodeIgnoresTrailingBytesAndReportsWhatItConsumed() {
        let packet = CapturePacket(command: 0x73, payload: [0x09])
        let stream = packet.encoded + [0xBC, 0x41, 0x00]
        guard let (decoded, consumed) = CapturePacket.decode(stream) else {
            return XCTFail("expected the leading frame to decode")
        }
        XCTAssertEqual(decoded, packet)
        XCTAssertEqual(consumed, packet.encoded.count)
    }

    // MARK: - Transport chunking

    func testShortFramesAreASingleWrite() {
        let chunks = CapturePacket(command: 0x41, payload: [0x01]).chunked()
        XCTAssertEqual(chunks.count, 1)
    }

    func testLongFramesSplitAtTheTransportCeiling() {
        let packet = CapturePacket(command: 0xFD, payload: [UInt8](repeating: 0x5A, count: 1000))
        let chunks = packet.chunked()
        XCTAssertTrue(chunks.allSatisfy { $0.count <= CapturePacket.transportChunkSize })
        XCTAssertEqual(chunks.flatMap { $0 }, packet.encoded, "chunking must be lossless")
    }

    // MARK: - Stream reassembly

    func testFrameSplitAcrossWritesIsReassembled() {
        // A thumbnail is the realistic case: ~1 KB across five BLE writes.
        let packet = CapturePacket(command: 0xFD, payload: (0..<1024).map { UInt8($0 % 256) })
        var assembler = CaptureFrameAssembler()

        var received: [CapturePacket] = []
        for chunk in packet.chunked() {
            received.append(contentsOf: assembler.append(chunk))
        }

        XCTAssertEqual(received, [packet])
        XCTAssertTrue(assembler.buffer.isEmpty)
        XCTAssertEqual(assembler.discardedBytes, 0)
    }

    func testSeveralFramesInOneWriteAllSurface() {
        let a = CapturePacket(command: 0x73, payload: [])
        let b = CapturePacket(command: 0x59, payload: [0x01, 0x02])
        let c = CapturePacket(command: 0xFD, payload: [0xFF])
        var assembler = CaptureFrameAssembler()

        let packets = assembler.append(a.encoded + b.encoded + c.encoded)

        XCTAssertEqual(packets, [a, b, c])
    }

    func testFrameBoundaryInTheMiddleOfAWrite() {
        let a = CapturePacket(command: 0x73, payload: [0x01])
        let b = CapturePacket(command: 0x59, payload: [0x02, 0x03])
        let stream = a.encoded + b.encoded
        var assembler = CaptureFrameAssembler()

        let first = assembler.append(Array(stream[0..<(a.encoded.count + 2)]))
        XCTAssertEqual(first, [a])
        let second = assembler.append(Array(stream[(a.encoded.count + 2)...]))
        XCTAssertEqual(second, [b])
    }

    func testAssemblerResynchronisesAfterGarbage() {
        // A dropped write leaves bytes that will never form a frame. Without resync the channel
        // is dead for the rest of the session, so recovery is the behaviour under test.
        let good = CapturePacket(command: 0x41, payload: [0x0A, 0x0B])
        var assembler = CaptureFrameAssembler()

        let packets = assembler.append([0x00, 0x11, 0x22] + good.encoded)

        XCTAssertEqual(packets, [good])
        XCTAssertEqual(assembler.discardedBytes, 3, "the cost of resync must be counted, not hidden")
    }

    func testAssemblerRecoversFromACorruptFrameFollowedByAGoodOne() {
        var corrupt = CapturePacket(command: 0x41, payload: [0x01, 0x02, 0x03]).encoded
        corrupt[corrupt.count - 1] ^= 0xFF        // breaks the CRC, length still consistent
        let good = CapturePacket(command: 0x73, payload: [0x07])
        var assembler = CaptureFrameAssembler()

        let packets = assembler.append(corrupt + good.encoded)

        XCTAssertEqual(packets, [good], "a corrupt frame must not swallow the next good one")
        XCTAssertGreaterThan(assembler.discardedBytes, 0)
    }

    func testAssemblerDoesNotGrowWithoutBound() {
        var assembler = CaptureFrameAssembler()
        // A header promising far more than will ever arrive: the buffer must not retain it
        // forever.
        let header: [UInt8] = [0xBC, 0x41, 0xFF, 0xFF, 0x00, 0x00]
        _ = assembler.append(header)
        for _ in 0..<40 {
            _ = assembler.append([UInt8](repeating: 0x00, count: 1000))
        }
        XCTAssertLessThanOrEqual(assembler.buffer.count, CaptureFrameAssembler.maxBufferedBytes)
    }

    func testResetDropsAPartialFrame() {
        var assembler = CaptureFrameAssembler()
        _ = assembler.append(Array(CapturePacket(command: 0x41, payload: [1, 2, 3]).encoded.prefix(4)))
        XCTAssertFalse(assembler.buffer.isEmpty)
        assembler.reset()
        XCTAssertTrue(assembler.buffer.isEmpty)
    }

    // MARK: - Commands

    func testAttestedControlPayloads() {
        XCTAssertEqual(
            CaptureCommand.control(.aiCaptureWithThumbnail).payload,
            [0x02, 0x01, 0x06, 0x02, 0x02, 0x02]
        )
        XCTAssertEqual(CaptureCommand.control(.startMicrophone).payload, [0x02, 0x01, 0x07])
        XCTAssertEqual(CaptureCommand.control(.speakerPlayback).payload, [0x02, 0x01, 0x10])

        for action in [CaptureCommand.ControlAction.aiCaptureWithThumbnail, .startMicrophone, .speakerPlayback] {
            XCTAssertEqual(CaptureCommand.control(action).opcode, 0x41)
        }
        XCTAssertEqual(CaptureCommand.startLivestream.opcode, 0x67)
    }

    func testCommandsEncodeToDecodableFrames() {
        let command = CaptureCommand.control(.aiCaptureWithThumbnail)
        guard let (decoded, _) = CapturePacket.decode(command.packet.encoded) else {
            return XCTFail("a command must produce a decodable frame")
        }
        XCTAssertEqual(decoded.command, command.opcode)
        XCTAssertEqual(decoded.payload, command.payload)
    }

    // MARK: - Inbound notifications

    func testNotificationRouting() {
        XCTAssertEqual(
            CaptureNotification.from(CapturePacket(command: 0x73, payload: [])),
            .captureReady
        )
        XCTAssertEqual(
            CaptureNotification.from(CapturePacket(command: 0xFD, payload: [0x01, 0x02])),
            .thumbnail(Data([0x01, 0x02]))
        )
        XCTAssertEqual(
            CaptureNotification.from(CapturePacket(command: 0x59, payload: [0x03])),
            .microphoneAudio(Data([0x03]))
        )
        XCTAssertEqual(
            CaptureNotification.from(CapturePacket(command: 0x12, payload: [0x04])),
            .unrecognised(opcode: 0x12, payload: [0x04])
        )
    }

    // MARK: - Control replies (the trap)

    func testReadableReplyReportsSuccessAndFailure() {
        let ok = CaptureControlReply.parse([0x01, 0x00, 0x05])
        XCTAssertEqual(ok.status, .ok(workType: 0x05))
        XCTAssertTrue(ok.isConfirmedSuccess)
        XCTAssertFalse(ok.isConfirmedFailure)

        let failed = CaptureControlReply.parse([0x01, 0x03, 0x00])
        XCTAssertEqual(failed.status, .failed(code: 0x03))
        XCTAssertTrue(failed.isConfirmedFailure)
    }

    /// The defect this parser exists to avoid: for these sub-types the device executes the
    /// command and the reply's status fields are never populated, so a non-zero byte in the
    /// error position is a *default*, not a failure. Reporting it as failure makes working
    /// commands look broken — and makes the caller retry them.
    func testSubtypesWithoutStatusFieldsAreNeverReportedAsFailures() {
        for subtype in CaptureControlReply.subtypesWithoutStatusFields {
            // Byte 1 looks exactly like an error code, and must still not be read as one.
            let reply = CaptureControlReply.parse([subtype, 0xFF, 0xFF])
            XCTAssertEqual(reply.status, .unreadable, "sub-type \(subtype) must be unreadable")
            XCTAssertFalse(reply.isConfirmedFailure,
                           "sub-type \(subtype) must never be a confirmed failure")
            XCTAssertFalse(reply.isConfirmedSuccess,
                           "…and must not be manufactured into a success either")
        }
    }

    /// Positive control for the test above: the same bytes on a status-bearing sub-type DO read
    /// as a failure. Without this, the assertion above would pass on a parser that called
    /// everything unreadable.
    func testPositiveControlAStatusBearingSubtypeStillReportsFailure() {
        let statusBearing: UInt8 = 0x01
        XCTAssertFalse(CaptureControlReply.subtypesWithoutStatusFields.contains(statusBearing))
        XCTAssertTrue(CaptureControlReply.parse([statusBearing, 0xFF, 0xFF]).isConfirmedFailure)
    }

    func testTruncatedRepliesAreUnreadableNotFailed() {
        // A truncated reply says nothing about whether the command ran.
        for payload in [[], [0x01], [0x01, 0x00]] as [[UInt8]] {
            let reply = CaptureControlReply.parse(payload)
            XCTAssertEqual(reply.status, .unreadable)
            XCTAssertFalse(reply.isConfirmedFailure)
        }
    }

    func testControlReplyArrivesThroughTheNotificationPath() {
        let packet = CapturePacket(command: 0x41, payload: [0x0A, 0xFF, 0xFF])
        guard case .controlReply(let reply) = CaptureNotification.from(packet) else {
            return XCTFail("a 0x41 frame should route to a control reply")
        }
        XCTAssertEqual(reply.status, .unreadable, "0x0A is one of the known-gap sub-types")
    }
}
