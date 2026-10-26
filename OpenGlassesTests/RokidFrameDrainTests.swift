import Foundation
import XCTest
@testable import OpenGlasses

/// Stream reassembly for the MFi transport.
///
/// This is the half of `RokidMFITransport` that can be tested without hardware: Classic MFi
/// delivers bytes, not messages, and the stream is salted with RFCOMM headers, AT modem text
/// and — critically — `FF 5A` sync words that occur inside binary payloads. A drain that
/// resynchronises on the first `FF 5A` it sees would corrupt every audio and photo chunk.
final class RokidFrameDrainTests: XCTestCase {

    // MARK: - Fixtures

    /// A frame built by the real encoder, so these tests exercise the shipping bytes.
    private static func commandFrame(
        sequence: UInt32 = 148,
        method: String = "Ai_Heartbeat",
        payload: RokidCapsValue? = .string(#"{"count":6}"#)
    ) -> [UInt8] {
        RokidIAP2Packet.encodeCommand(
            sequence: sequence,
            channel: "Ai",
            method: method,
            payload: payload,
            timestampMicroseconds: 4_175_948_384
        )
    }

    /// A verbatim frame from the PacketLogger capture — proves the drain accepts device bytes.
    private static var capturedFrame: [UInt8] { RokidCapsCodecTests.capturedHeartbeat }

    /// Counts non-overlapping `FF 5A` occurrences.
    private static func syncWordCount(_ bytes: [UInt8]) -> Int {
        guard bytes.count >= 2 else { return 0 }
        var count = 0
        var index = 0
        while index < bytes.count - 1 {
            if bytes[index] == 0xFF, bytes[index + 1] == 0x5A {
                count += 1
                index += 2
            } else {
                index += 1
            }
        }
        return count
    }

    // MARK: - The happy path

    func testWholeFrameInOneChunk() {
        var drain = RokidFrameDrain()
        let frame = Self.commandFrame()
        XCTAssertEqual(drain.append(frame), [frame])
        XCTAssertEqual(drain.pendingByteCount, 0)
    }

    func testCapturedDeviceFrameIsAccepted() {
        let frame = Self.capturedFrame
        XCTAssertTrue(RokidFrameDrain.isFrame(frame), "the drain must accept real device bytes")
        var drain = RokidFrameDrain()
        XCTAssertEqual(drain.append(frame), [frame])
    }

    func testTwoFramesInOneChunk() {
        let first = Self.commandFrame(sequence: 1)
        let second = Self.commandFrame(sequence: 2)
        var drain = RokidFrameDrain()
        XCTAssertEqual(drain.append(first + second), [first, second])
    }

    // MARK: - Fragmentation

    func testFrameSplitByteByByte() {
        var drain = RokidFrameDrain()
        let frame = Self.commandFrame()
        var collected: [[UInt8]] = []

        for (index, byte) in frame.enumerated() {
            let emitted = drain.append([byte])
            collected.append(contentsOf: emitted)
            if index < frame.count - 1 {
                XCTAssertTrue(emitted.isEmpty, "emitted a frame at byte \(index) of \(frame.count)")
                XCTAssertGreaterThan(drain.pendingByteCount, 0)
            }
        }

        XCTAssertEqual(collected, [frame])
        XCTAssertEqual(drain.pendingByteCount, 0)
    }

    func testTruncatedFrameIsBufferedThenCompleted() {
        var drain = RokidFrameDrain()
        let frame = Self.commandFrame()
        let cut = 10

        XCTAssertTrue(drain.append(Array(frame[0..<cut])).isEmpty)
        XCTAssertEqual(drain.pendingByteCount, cut)
        XCTAssertEqual(drain.append(Array(frame[cut...])), [frame])
        XCTAssertEqual(drain.pendingByteCount, 0)
    }

    /// A read can end between the two sync bytes; the `FF` must not be discarded.
    func testSplitSyncWordIsReassembled() {
        var drain = RokidFrameDrain()
        let frame = Self.commandFrame()

        XCTAssertTrue(drain.append([0x11, 0x22, frame[0]]).isEmpty)
        XCTAssertEqual(drain.pendingByteCount, 1)
        XCTAssertEqual(drain.append(Array(frame[1...])), [frame])
    }

    // MARK: - Resynchronisation

    func testLeadingTransportNoiseIsDropped() {
        // `41 ef 1d` is the RFCOMM UIH header, then the AT command the capture opens with.
        let noise = [UInt8]([0x41, 0xEF, 0x1D]) + Array("\r\n+CIEV: 5,3\r\n".utf8)
        let frame = Self.commandFrame()
        var drain = RokidFrameDrain()
        XCTAssertEqual(drain.append(noise + frame), [frame])
    }

    /// Sync words inside binary payloads are payload, not framing.
    func testFrameContainingSyncWordsIsEmittedIntact() {
        let payload = Data([0xFF, 0x5A, 0x00, 0x20, 0xFF, 0x5A, 0x00, 0x20])
        let frame = RokidIAP2Packet.encodeBinary(
            route: RokidCapsRoute.photo.rawValue,
            data: payload,
            timestampMicroseconds: 1_543_301_677
        )
        XCTAssertGreaterThan(Self.syncWordCount(frame), 1, "fixture must embed a false sync")

        var drain = RokidFrameDrain()
        XCTAssertEqual(drain.append(frame), [frame])
    }

    /// A false sync *ahead* of the real frame cannot be resolved until enough bytes arrive,
    /// because its declared length is a promise about the future. The real frame must still
    /// come out, one trivial byte-skip later.
    func testFalseSyncInNoiseStillYieldsTheRealFrame() {
        let frame = Self.commandFrame()
        let falseSync: [UInt8] = [0xFF, 0x5A, 0x00, 0x40] // claims a 64-byte frame
        let filler = [UInt8](repeating: 0x00, count: 40)

        var drain = RokidFrameDrain()
        let emitted = drain.append(falseSync + frame + filler)
        XCTAssertEqual(emitted, [frame])
    }

    func testBadChecksumIsRejected() {
        var frame = Self.commandFrame()
        frame[frame.count - 1] ^= 0xFF

        XCTAssertFalse(RokidFrameDrain.isFrame(frame))
        var drain = RokidFrameDrain()
        XCTAssertTrue(drain.append(frame).isEmpty)
    }

    func testWrongFrameTypeIsRejected() {
        var frame = Self.commandFrame()
        frame[4] = 0x41 // only 0x40 is a link frame
        XCTAssertFalse(RokidFrameDrain.isFrame(frame))
        var drain = RokidFrameDrain()
        XCTAssertTrue(drain.append(frame).isEmpty)
    }

    func testLengthFieldMustMatchTheFrame() {
        var frame = Self.commandFrame()
        frame[3] = 0x00 // declares a shorter frame than it is
        XCTAssertFalse(RokidFrameDrain.isFrame(frame))
    }

    func testImpossibleLengthIsSkippedNotBuffered() {
        // 0x0001 is a valid length field but below any real frame; the drain must step past.
        let frame = Self.commandFrame()
        var drain = RokidFrameDrain()
        XCTAssertEqual(drain.append([0xFF, 0x5A, 0x00, 0x01] + frame), [frame])
    }

    func testResetDropsBufferedBytes() {
        var drain = RokidFrameDrain()
        XCTAssertTrue(drain.append(Array(Self.commandFrame()[0..<12])).isEmpty)
        XCTAssertGreaterThan(drain.pendingByteCount, 0)

        drain.reset()
        XCTAssertEqual(drain.pendingByteCount, 0)
        XCTAssertEqual(drain.append(Self.commandFrame()), [Self.commandFrame()])
    }

    // MARK: - Framing mode

    func testFramedModeWritesTheWholeFrame() {
        let frame = Self.commandFrame()
        XCTAssertEqual(RokidMFIPayload.payload(for: frame, framing: .framed), frame)
    }

    func testRawCapsModeWritesOnlyTheBlob() throws {
        let caps: [RokidCapsValue] = [
            .uint32(RokidCapsRoute.request.rawValue),
            .uint32(7),
            .string("Dev"),
            .object([.string("Dev_GlassBrightness"), .int32(4)]),
        ]
        let frame = RokidIAP2Packet.encode(caps: caps, timestampMicroseconds: 42)

        let stripped = RokidMFIPayload.payload(for: frame, framing: .rawCaps)
        XCTAssertEqual(stripped, RokidCapsCodec.encode(caps))
        XCTAssertEqual(try XCTUnwrap(RokidMFIPayload.rawCapsPayload(from: frame)),
                       RokidCapsCodec.encode(caps))
    }

    func testRawCapsModeLeavesNonFramesAlone() {
        let junk: [UInt8] = [0x01, 0x02, 0x03, 0x04]
        XCTAssertEqual(RokidMFIPayload.payload(for: junk, framing: .rawCaps), junk)
    }

    func testRawCapsPayloadRejectsIncompleteInput() {
        XCTAssertNil(RokidMFIPayload.rawCapsPayload(from: []))
        XCTAssertNil(RokidMFIPayload.rawCapsPayload(from: [0xFF]))
        XCTAssertNil(RokidMFIPayload.rawCapsPayload(from: [0xFF, 0x5A, 0x00]))
        XCTAssertNil(RokidMFIPayload.rawCapsPayload(from: Array(Self.commandFrame().dropLast())))
    }

    // MARK: - Route coverage

    /// Every route the codec names must survive the drain, not just the request shape.
    func testEveryRouteShapeSurvivesTheDrain() {
        let frames: [[UInt8]] = [
            Self.capturedFrame,
            RokidCapsCodecTests.capturedUnSyncCount,
            RokidCapsCodecTests.capturedReply,
            RokidCapsCodecTests.capturedNotification,
            RokidCapsCodecTests.capturedEvent,
            RokidCapsCodecTests.capturedPhotoChunk,
            RokidCapsCodecTests.capturedAudioChunk,
        ]
        var drain = RokidFrameDrain()
        XCTAssertEqual(drain.append(frames.flatMap { $0 }), frames)
        XCTAssertEqual(drain.pendingByteCount, 0)
    }
}
