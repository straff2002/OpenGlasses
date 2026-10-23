import Foundation
import XCTest
@testable import OpenGlasses

/// The recovered Caps / iAP2 encoding, pinned against frames captured from real glasses.
///
/// Each `captured…` constant below is a verbatim frame from an Apple PacketLogger HCI
/// capture of a live phone↔Rokid-Glasses session. They are the acceptance test for the
/// whole encoding: if a future edit changes a length, a varint, the nested-object framing
/// or the checksum, one of these stops matching byte-for-byte.
final class RokidCapsCodecTests: XCTestCase {

    // MARK: - Captured frames

    /// `Med / UnSync_Count` — payload-less method, so the nested object has one member and
    /// its tags read `S` alone. Frame length 0x32 = 50.
    static let capturedUnSyncCount = hex(
        "ff5a003240f7e3ea7100010000002605047575534f81209301034d6564"
        + "000000140501530c556e53796e635f436f756e74b5")

    /// `Ai / Ai_Heartbeat` — JSON payload as a string, nested tags `SS`. Frame length
    /// 0x3e = 62.
    static let capturedHeartbeat = hex(
        "ff5a003e40f8e7ea6000010000003205047575534f8120940102416900000021"
        + "050253530c41695f4865617274626561740b7b22636f756e74223a367d03")

    /// `Dev / Dev_GlassBrightness` — bare integer payload, so the nested tags are `Si`
    /// (signed LEB128) rather than `SS`. Frame length 0x3b = 59.
    static let capturedBrightness = hex(
        "ff5a003b40ab83ea1400010000002f05047575534f8120af0203446576000000"
        + "1d05025369134465765f476c6173734272696768746e6573730241")

    /// `Ai / TTS_AudioFinished` — three-member nested object, tags `SSS`. Frame length
    /// 0x4b = 75.
    static let capturedAudioFinished = hex(
        "ff5a004b407aa3ea1500010000003f05047575534f8120b2010241690000002e"
        + "0503535353115454535f417564696f46696e697368656404747275650d7b2276"
        + "657273696f6e223a317df7")

    // MARK: - Encoding matches the device

    func testPayloadlessMethodReproducesCapturedFrame() {
        let frame = RokidIAP2Packet.encodeCommand(
            sequence: 147,
            channel: "Med",
            method: "UnSync_Count",
            payload: nil,
            timestampMicroseconds: 4_158_909_041)
        XCTAssertEqual(frame, Self.capturedUnSyncCount)
    }

    func testJSONPayloadReproducesCapturedFrame() {
        let frame = RokidIAP2Packet.encodeCommand(
            sequence: 148,
            channel: "Ai",
            method: "Ai_Heartbeat",
            payload: .string(#"{"count":6}"#),
            timestampMicroseconds: 4_175_948_384)
        XCTAssertEqual(frame, Self.capturedHeartbeat)
    }

    func testIntegerPayloadReproducesCapturedFrame() {
        let frame = RokidIAP2Packet.encodeCommand(
            sequence: 303,
            channel: "Dev",
            method: "Dev_GlassBrightness",
            payload: .int32(2),
            timestampMicroseconds: 2_877_549_076)
        XCTAssertEqual(frame, Self.capturedBrightness)
    }

    func testThreeMemberPayloadReproducesCapturedFrame() {
        // TTS_AudioFinished carries (method, "true", {"version":1}) — no single-payload
        // form covers it, so it is built as a raw tuple.
        let caps: [RokidCapsValue] = [
            .uint32(RokidIAP2Packet.commandRoute),
            .uint32(178),
            .string("Ai"),
            .object([
                .string("TTS_AudioFinished"),
                .string("true"),
                .string(#"{"version":1}"#),
            ]),
        ]
        let frame = RokidIAP2Packet.encode(caps: caps, timestampMicroseconds: 2_057_562_645)
        XCTAssertEqual(frame, Self.capturedAudioFinished)
    }

    // MARK: - Decoding the device's own frames

    func testDecodesCapturedFrames() throws {
        let heartbeat = try XCTUnwrap(RokidIAP2Packet.decode(Self.capturedHeartbeat))
        XCTAssertEqual(heartbeat.route, RokidIAP2Packet.commandRoute)
        XCTAssertEqual(try XCTUnwrap(heartbeat.sequence), 148)
        XCTAssertEqual(heartbeat.timestampMicroseconds, 4_175_948_384)

        let brightness = try XCTUnwrap(RokidIAP2Packet.decode(Self.capturedBrightness))
        XCTAssertEqual(try XCTUnwrap(brightness.sequence), 303)
        guard case .object(let members) = try XCTUnwrap(brightness.caps.last) else {
            return XCTFail("expected a nested object")
        }
        XCTAssertEqual(members, [.string("Dev_GlassBrightness"), .int32(2)])
    }

    func testRoundTripThroughCapsCodec() throws {
        let caps: [RokidCapsValue] = [
            .uint32(4097),
            .uint32(548),
            .string("Sys"),
            .object([.string("Sys_Cloud_Server_Status"), .string(#"{"status":0}"#)]),
        ]
        var offset = 0
        let blob = RokidCapsCodec.encode(caps)
        XCTAssertEqual(try RokidCapsCodec.decode(blob, offset: &offset), caps)
        XCTAssertEqual(offset, blob.count, "the declared total covers the whole blob")
    }

    func testSignedAndUnsignedVarintsRoundTrip() throws {
        // The audio-play descriptor observed on the wire is `ifuu`: (negative id, float,
        // channels, sample rate). Negative values exercise signed LEB128.
        let caps: [RokidCapsValue] = [.int32(-3), .float(1.0), .uint32(1), .uint32(16_000)]
        var offset = 0
        XCTAssertEqual(try RokidCapsCodec.decode(RokidCapsCodec.encode(caps), offset: &offset), caps)
    }

    func testLEB128UsesOneByteForSmallIntegers() {
        // 4097 encodes as `81 20` and 148 as `94 01` — the two-byte forms seen in every
        // captured command tuple.
        // Each blob is 4 (total) + 1 (version) + 1 (count) + 1 (tag) + varint.
        XCTAssertEqual(RokidCapsCodec.encode([.uint32(4097)]), Self.hex("000000090501758120"))
        XCTAssertEqual(RokidCapsCodec.encode([.uint32(148)]), Self.hex("000000090501759401"))
        XCTAssertEqual(RokidCapsCodec.encode([.uint32(1)]), Self.hex("0000000805017501"))
    }

    func testSignedLEB128UsesOneByteForNegativeSingleDigits() {
        XCTAssertEqual(RokidCapsCodec.encode([.int32(-3)]), Self.hex("000000080501697d"))
    }

    func testStringLengthPrefixCountsBytesNotCharacters() {
        XCTAssertEqual(RokidCapsCodec.encode([.string("Ai")]), Self.hex("0000000a050153024169"))
        XCTAssertEqual(RokidCapsCodec.encode([.string("")]), Self.hex("0000000805015300"))
    }

    // MARK: - Refusals

    func testRejectsCorruptedChecksum() {
        var corrupted = Self.capturedHeartbeat
        corrupted[corrupted.count - 1] ^= 0xFF
        XCTAssertNil(RokidIAP2Packet.decode(corrupted), "the checksum is load-bearing")
    }

    func testRejectsWrongLength() {
        var declared = RokidCapsCodec.encode([.string("Ai")])
        declared[3] = declared[3] &+ 1   // claim one more byte than exists
        var offset = 0
        XCTAssertThrowsError(try RokidCapsCodec.decode(declared, offset: &offset)) { error in
            guard case RokidCapsCodec.DecodeError.lengthMismatch = error else {
                return XCTFail("expected lengthMismatch, got \(error)")
            }
        }
    }

    func testRejectsUnsupportedVersion() {
        var bytes = RokidCapsCodec.encode([.string("Ai")])
        bytes[4] = 6
        var offset = 0
        XCTAssertThrowsError(try RokidCapsCodec.decode(bytes, offset: &offset)) { error in
            guard case RokidCapsCodec.DecodeError.unsupportedVersion(6) = error else {
                return XCTFail("expected unsupportedVersion, got \(error)")
            }
        }
    }

    // MARK: - Command bridge

    func testCommandBridgeReproducesCapturedFrameAndDecodes() {
        let command = RokidCommand(cmd: "Ai", key: "Ai_Heartbeat", param: #"{"count":6}"#)
        let frame = command.encoded(sequence: 148, timestampMicroseconds: 4_175_948_384)
        XCTAssertEqual(frame, Self.capturedHeartbeat)
        XCTAssertEqual(RokidWireCodec.decode(frame), command)
    }

    // MARK: - The glasses' side of the conversation

    /// A reply: route `0x1002`, shape `uuO` — the sequence echoes the request's (147 here
    /// answers the captured `Med/UnSync_Count` request, which also carried 147) and there is
    /// no channel string, because the route already identifies the addressee.
    static let capturedReply = hex(
        "ff5a006440e4f7ea3e000100000058050375754f822093010000004b050253530c556e"
        + "53796e635f436f756e74357b22617564696f223a302c22766964656f223a312c2270"
        + "696374757265223a322c22696e74657276616c5f7265636f7264223a307d90")

    /// A notification: route `0x1003`, shape `uSO` — no sequence at all, because nobody
    /// asked. Also the only three-member non-JSON object observed (`SfS`).
    static let capturedNotification = hex(
        "ff5a003a40e6f7ea6600010000002e050375534f832002416900000020050353665307"
        + "4b6579446f776e0000c0400a7b2274797065223a317df4")

    /// An event: route `0x2001`, shape `uuSO`, but the second `u` is a millisecond clock
    /// (94342 here), not a small per-connection counter.
    static let capturedEvent = hex(
        "ff5a0032405afceaf500010000002605047575534f814086e105024169000000140501"
        + "530c41695f54616b6550686f746f5a")

    /// A photo chunk: route `0x2002`, shape `uB`. This is the first of 198 consecutive
/// 480-byte chunks; it opens with `RIFF….WEBP`, so the transfer is an image.
/// Its `B` length prefix is a **varint** (`e0 03` = 480), not a big-endian `u32`.

    static let capturedPhotoChunk = hex(
        "ff5a01f8405bfcea2d0001000001ec050275428240e003524946467e70010057"
        + "454250565038580a000000200000003704009f05004943435018020000000002"
        + "1800000000021000006d6e74725247422058595a200000000000000000000000"
        + "0061637370000000000000000000000000000000000000000000000000000000"
        + "010000f6d6000100000000d32d00000000000000000000000000000000000000"
        + "0000000000000000000000000000000000000000000000000000000000000000"
        + "0964657363000000f0000000747258595a00000164000000146758595a000001"
        + "78000000146258595a0000018c0000001472545243000001a000000028675452"
        + "43000001a00000002862545243000001a00000002877747074000001c8000000"
        + "1463707274000001dc0000003c6d6c756300000000000000010000000c656e55"
        + "53000000580000001c0073005200470042000000000000000000000000000000"
        + "0000000000000000000000000000000000000000000000000000000000000000"
        + "0000000000000000000000000000000000000000000000000000000000000000"
        + "0058595a200000000000006fa2000038f50000039058595a2000000000000062"
        + "990000b785000018da58595a2000000000000024a000000f840000b6cf706172"
        + "610000000000040000000266660000f2a700000d590000c6")

    /// An audio chunk: route `0x3002`, shape `uBuk`. The payload opens with `OggS`,
/// so inbound audio is Ogg/Opus; outbound chunks carry `ID3`/`Lavf` MP3 instead.

    static let capturedAudioChunk = hex(
        "ff5a004f40e8f7ea4f00010000004305047542756b82602f4f67675300020000"
        + "0000000000000000070000000000b9fc70b901134f7075734865616401010000"
        + "803e000000000003d3c9dead9634d3")

    func testDecodesReplyAndEchoesRequestSequence() throws {
        guard case .reply(let route, let sequence, let method, let payload)? =
            RokidCapsMessage.decode(Self.capturedReply) else {
            return XCTFail("expected a reply")
        }
        XCTAssertEqual(route, RokidCapsRoute.reply.rawValue)
        XCTAssertEqual(sequence, 147)
        XCTAssertEqual(method, "UnSync_Count")
        XCTAssertEqual(payload, .string(#"{"audio":0,"video":1,"picture":2,"interval_record":0}"#))
    }

    func testDecodesNotificationWithChannelAndNoSequence() throws {
        let message = try XCTUnwrap(RokidCapsMessage.decode(Self.capturedNotification))
        XCTAssertEqual(message.channel, "Ai")
        XCTAssertEqual(message.method, "KeyDown")
        // `SfS`: the second member is a float, so there is no text payload to hand back.
        XCTAssertNil(message.textPayload)
    }

    func testDecodesEventAsNotification() throws {
        let message = try XCTUnwrap(RokidCapsMessage.decode(Self.capturedEvent))
        XCTAssertEqual(message.channel, "Ai")
        XCTAssertEqual(message.method, "Ai_TakePhoto")
        XCTAssertEqual(message.textPayload, nil, "an `S` object carries the method only")
    }

    func testClassifiesRequestFromTheWire() throws {
        guard case .request(let route, let sequence, let channel, let method, let payload)? =
            RokidCapsMessage.decode(Self.capturedHeartbeat) else {
            return XCTFail("expected a request")
        }
        XCTAssertEqual(route, RokidCapsRoute.request.rawValue)
        XCTAssertEqual(sequence, 148)
        XCTAssertEqual(channel, "Ai")
        XCTAssertEqual(method, "Ai_Heartbeat")
        XCTAssertEqual(payload, .string(#"{"count":6}"#))
    }

    func testAudioFramesAreNotClassifiedAsMessages() {
        // `uuSOuu` (playback descriptor) and bare `uu` (stop) carry no method name, so the
        // classifier declines them rather than inventing one.
        let stop = RokidIAP2Packet.encode(
            caps: [.uint32(RokidCapsRoute.audioStop.rawValue), .uint32(3)],
            timestampMicroseconds: 0)
        XCTAssertNil(RokidCapsMessage.decode(stop))
    }

    // MARK: - Binary and audio transfers

    func testBinaryLengthIsAVarint() {
        // 3 bytes: 4 (total) + 1 (version) + 1 (count) + 1 (tag `B`) + 1 (length) + 3.
        XCTAssertEqual(RokidCapsCodec.encode([.binary(Data([0x01, 0x02, 0x03]))]),
                       Self.hex("0000000b05014203010203"))
        // 480 needs two varint bytes, and the whole blob grows by one.
        let wide = RokidCapsCodec.encode([.binary(Data(repeating: 0xAA, count: 480))])
        XCTAssertEqual(Array(wide.prefix(10)), Self.hex("000001e9050142e003aa"))
    }

    func testBinaryRoundTripsThroughCapsCodec() throws {
        let payload = Data((0..<300).map { UInt8($0 & 0xFF) })
        var offset = 0
        let decoded = try RokidCapsCodec.decode(
            RokidCapsCodec.encode([.binary(payload)]), offset: &offset)
        XCTAssertEqual(decoded, [.binary(payload)])
    }

    func testPhotoChunkReproducesCapturedFrame() throws {
        let captured = try XCTUnwrap(RokidMediaTransfer.decode(Self.capturedPhotoChunk))
        guard case .binaryChunk(let route, let data) = captured else {
            return XCTFail("expected a binary chunk")
        }
        XCTAssertEqual(route, RokidCapsRoute.photo.rawValue)
        XCTAssertEqual(data.count, 480)
        XCTAssertEqual(Array(data.prefix(4)), Array("RIFF".utf8))
        XCTAssertEqual(Array(data[8..<12]), Array("WEBP".utf8))
        // The frame is byte-exact, which is the real assertion: it pins the varint length
        // prefix, the tag order and the checksum all at once.
        XCTAssertEqual(
            RokidIAP2Packet.encodeBinary(route: route, data: data,
                                         timestampMicroseconds: 1_543_301_677),
            Self.capturedPhotoChunk)
    }

    func testAudioChunkDecodesWithoutInventingAMessage() throws {
        let captured = try XCTUnwrap(RokidMediaTransfer.decode(Self.capturedAudioChunk))
        guard case .audioChunk(let route, let data) = captured else {
            return XCTFail("expected an audio chunk")
        }
        XCTAssertEqual(route, RokidCapsRoute.audioData.rawValue)
        XCTAssertEqual(Array(data.prefix(4)), Array("OggS".utf8))
        XCTAssertNil(RokidCapsMessage.decode(Self.capturedAudioChunk),
                     "an audio chunk carries no method name")
    }

    func testNotificationDecodesEvenThoughItHasNoSequence() throws {
        // `uSO` has no numeric second member, which used to make the whole frame
        // undecodable; the stage is asserted here so a regression is loud.
        let frame = try XCTUnwrap(RokidIAP2Packet.decode(Self.capturedNotification))
        XCTAssertNil(frame.sequence)
        XCTAssertEqual(frame.route, RokidCapsRoute.notification.rawValue)
    }

    // MARK: - The frame's session id

    func testDefaultSessionIDMatchesTheFirstCapture() {
        let frame = RokidIAP2Packet.encodeCommand(
            sequence: 1,
            channel: "Dev",
            method: "Dev_GlassBrightness",
            payload: .int32(5),
            timestampMicroseconds: 1_000
        )
        XCTAssertEqual(frame[9], 0x00)
        XCTAssertEqual(frame[10], 0x01)
        XCTAssertEqual(RokidIAP2Packet.sessionID(of: frame), 0x0001)
    }

    func testSessionIDRoundTripsAndStaysOutOfTheChecksumBlindSpot() {
        // The second capture carries 0x0008 in 1,003 of 1,012 frames, so the field tracks the
        // connection rather than the format. It must survive encoding, decoding and the checksum.
        for session: UInt16 in [0x0001, 0x0008, 0x1234] {
            let frame = RokidIAP2Packet.encode(
                caps: [.uint32(RokidCapsRoute.request.rawValue), .uint32(7), .string("Sys")],
                timestampMicroseconds: 2_000,
                sessionID: session
            )
            XCTAssertEqual(RokidIAP2Packet.sessionID(of: frame), session)
            XCTAssertEqual(
                RokidIAP2Packet.checksum(Array(frame.dropLast())),
                frame[frame.count - 1],
                "the session id is inside the checksummed range"
            )
            let decoded = RokidIAP2Packet.decode(frame)
            XCTAssertNotNil(
                decoded,
                "decode rejected a well-formed frame carrying session 0x"
                    + String(session, radix: 16)
                    + ": "
                    + frame.map { String(format: "%02x", $0) }.joined()
            )
            XCTAssertEqual(
                decoded?.sessionID,
                session,
                "the decoder reports the session id rather than gating on it"
            )
        }
    }

    func testSessionIDIsNilForRuntFrames() {
        XCTAssertNil(RokidIAP2Packet.sessionID(of: []))
        XCTAssertNil(RokidIAP2Packet.sessionID(of: [0xFF, 0x5A, 0x00, 0x0D, 0x40, 0, 0, 0, 0]))
    }

    // MARK: - Helpers

    private static func hex(_ string: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            bytes.append(UInt8(string[index..<next], radix: 16) ?? 0xEE)
            index = next
        }
        return bytes
    }
}
