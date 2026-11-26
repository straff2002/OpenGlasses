import XCTest
@testable import OpenGlasses

/// The MFi session carries bare Caps blobs both ways (`RokidMFIFraming`), its writes leave through
/// a queue (`RokidWriteQueue`), and it opens on the protocol the glasses answer on. These pin each
/// rule with the property the glasses actually check, so a regression fails here rather than as a
/// silent session on hardware.
final class RokidRawCapsTests: XCTestCase {

    /// Every captured shape, as link frames: requests, replies, notifications, events, media.
    private static let capturedFrames: [[UInt8]] = [
        RokidCapsCodecTests.capturedUnSyncCount,
        RokidCapsCodecTests.capturedHeartbeat,
        RokidCapsCodecTests.capturedBrightness,
        RokidCapsCodecTests.capturedAudioFinished,
        RokidCapsCodecTests.capturedReply,
        RokidCapsCodecTests.capturedNotification,
        RokidCapsCodecTests.capturedEvent,
        RokidCapsCodecTests.capturedPhotoChunk,
        RokidCapsCodecTests.capturedAudioChunk,
    ]

    private static func blob(_ frame: [UInt8]) throws -> [UInt8] {
        try XCTUnwrap(RokidMFIPayload.rawCapsPayload(from: frame), "fixture is not a link frame")
    }

    private static func command(sequence: UInt32 = 3, method: String = "Dev_GetGlassInfo") -> [UInt8] {
        RokidIAP2Packet.encodeCommand(
            sequence: sequence,
            channel: "Dev",
            method: method,
            payload: nil,
            timestampMicroseconds: 1_000
        )
    }

    // MARK: - What a write puts on the session

    func testTransportStartsOnRawCaps() {
        XCTAssertEqual(RokidMFIProtocol.framing, .rawCaps)
    }

    /// The glasses' parser wants a big-endian total that matches the bytes, then 0x05 at byte 4.
    func testRawCapsWriteIsWhatTheGlassesParserAccepts() throws {
        let frame = Self.command()
        let wire = RokidMFIPayload.payload(for: frame, framing: .rawCaps)

        XCTAssertEqual(wire.count, frame.count - RokidMFIPayload.envelopeOverhead)
        XCTAssertEqual(RokidMFIPayload.envelopeOverhead, 12)
        XCTAssertEqual(wire[4], RokidCapsCodec.version)
        let total = Int(wire[0]) << 24 | Int(wire[1]) << 16 | Int(wire[2]) << 8 | Int(wire[3])
        XCTAssertEqual(total, wire.count)
        XCTAssertEqual(wire[5], 4, "a command is the four-member uuSO tuple")
        XCTAssertTrue(RokidCapsDrain.isBlob(wire))
    }

    /// Why a framed write ends the session: byte 4 is the link type, not the Caps version.
    func testFramedWriteFailsTheGlassesParser() {
        let frame = Self.command()
        XCTAssertEqual(RokidMFIPayload.payload(for: frame, framing: .framed), frame)
        XCTAssertEqual(frame[4], RokidIAP2Packet.frameType)
        XCTAssertNotEqual(frame[4], RokidCapsCodec.version)
        XCTAssertFalse(RokidCapsDrain.isBlob(frame))
    }

    // MARK: - Protocol choice

    func testSessionPrefersTheProtocolTheGlassesAnswerOn() {
        XCTAssertEqual(RokidMFIProtocol.strings.first, "com.rokid.global.aiglasses")
        XCTAssertEqual(RokidMFIProtocol.ids["com.rokid.global.aiglasses"], 195)
        XCTAssertEqual(RokidMFIProtocol.ids["com.rokid.aiglasses"], 194)
    }

    func testEveryProtocolHasAnID() {
        for name in RokidMFIProtocol.strings {
            XCTAssertNotNil(RokidMFIProtocol.ids[name], "\(name) has no EAP protocol id")
        }
        XCTAssertEqual(Set(RokidMFIProtocol.ids.keys), Set(RokidMFIProtocol.strings))
    }

    // MARK: - Reading bare blobs

    func testDecodersReadABareBlobAsTheyReadItsFrame() throws {
        for frame in Self.capturedFrames {
            let blob = try Self.blob(frame)
            XCTAssertEqual(RokidMFIPayload.caps(in: blob), RokidMFIPayload.caps(in: frame))
            XCTAssertNotNil(RokidMFIPayload.caps(in: blob))
            XCTAssertEqual(RokidCapsMessage.decode(blob), RokidCapsMessage.decode(frame))
            XCTAssertEqual(RokidMediaTransfer.decode(blob), RokidMediaTransfer.decode(frame))
        }
    }

    func testABareReplyDecodesToItsMethod() throws {
        let blob = try Self.blob(RokidCapsCodecTests.capturedReply)
        guard case .reply = try XCTUnwrap(RokidCapsMessage.decode(blob)) else {
            return XCTFail("a captured reply must stay a reply without its envelope")
        }
    }

    func testABarePhotoChunkKeepsItsBytes() throws {
        let blob = try Self.blob(RokidCapsCodecTests.capturedPhotoChunk)
        let transfer = try XCTUnwrap(RokidMediaTransfer.decode(blob))
        XCTAssertEqual(transfer, RokidMediaTransfer.decode(RokidCapsCodecTests.capturedPhotoChunk))
        XCTAssertFalse(transfer.data.isEmpty)
    }

    func testCapsInRejectsWhatIsNeitherShape() throws {
        XCTAssertNil(RokidMFIPayload.caps(in: []))
        XCTAssertNil(RokidMFIPayload.caps(in: [0x00, 0x00, 0x00, 0x06, 0x05]))
        let blob = try Self.blob(RokidCapsCodecTests.capturedReply)
        XCTAssertNil(RokidMFIPayload.caps(in: blob + [0x00]), "a trailing byte is not one blob")
        XCTAssertNil(RokidMFIPayload.caps(in: Array(blob.dropLast())))
        // A well-formed blob whose first member is not a route is not a message.
        XCTAssertNil(RokidMFIPayload.caps(in: RokidCapsCodec.encode([.string("x"), .uint32(1)])))
    }

    // MARK: - Splitting the session's reads

    func testDrainSplitsBlobsAtEveryReadBoundary() throws {
        let blobs = try Self.capturedFrames.map(Self.blob)
        let stream = blobs.flatMap { $0 }
        for cut in [1, 2, 3, 5, 7, 64, 500, stream.count] {
            var drain = RokidCapsDrain()
            var out: [[UInt8]] = []
            var index = 0
            while index < stream.count {
                let end = min(index + cut, stream.count)
                out += drain.append(Array(stream[index..<end]))
                index = end
            }
            XCTAssertEqual(out, blobs, "reads of \(cut) bytes")
            XCTAssertEqual(drain.pendingByteCount, 0)
            XCTAssertEqual(drain.discardedByteCount, 0)
        }
    }

    func testDrainHoldsAPartialBlobUntilItCompletes() throws {
        let blob = try Self.blob(RokidCapsCodecTests.capturedReply)
        var drain = RokidCapsDrain()
        XCTAssertEqual(drain.append(Array(blob.prefix(3))), [])
        XCTAssertEqual(drain.pendingByteCount, 3)
        XCTAssertEqual(drain.append(Array(blob.dropFirst(3).dropLast())), [])
        XCTAssertEqual(drain.append([blob[blob.count - 1]]), [blob])
        XCTAssertEqual(drain.pendingByteCount, 0)
    }

    func testDrainDropsAndCountsAHeaderThatCannotStartABlob() throws {
        let blob = try Self.blob(RokidCapsCodecTests.capturedReply)
        var drain = RokidCapsDrain()
        // A link frame where a blob should be: 0x40 at byte 4.
        let frame = RokidCapsCodecTests.capturedReply
        XCTAssertEqual(drain.append(frame), [])
        XCTAssertEqual(drain.discardedByteCount, frame.count)
        XCTAssertEqual(drain.pendingByteCount, 0)
        // The next read starts afresh.
        XCTAssertEqual(drain.append(blob), [blob])
    }

    func testDrainRejectsImpossibleTotals() {
        var tooSmall = RokidCapsDrain()
        XCTAssertEqual(tooSmall.append([0x00, 0x00, 0x00, 0x05, 0x05, 0x00]), [])
        XCTAssertEqual(tooSmall.discardedByteCount, 6)

        let tooLarge = RokidCapsDrain.maximumBlobLength + 1
        let header: [UInt8] = [
            UInt8(truncatingIfNeeded: tooLarge >> 24), UInt8(truncatingIfNeeded: tooLarge >> 16),
            UInt8(truncatingIfNeeded: tooLarge >> 8), UInt8(truncatingIfNeeded: tooLarge), 0x05,
        ]
        XCTAssertNil(RokidCapsDrain.declaredLength(of: header, at: 0))
        XCTAssertEqual(RokidCapsDrain.declaredLength(of: [0x00, 0x00, 0x00, 0x06, 0x05], at: 0), 6)
    }

    func testDrainResetDropsAPartialBlob() throws {
        let blob = try Self.blob(RokidCapsCodecTests.capturedReply)
        var drain = RokidCapsDrain()
        _ = drain.append(Array(blob.prefix(8)))
        drain.reset()
        XCTAssertEqual(drain.pendingByteCount, 0)
        XCTAssertEqual(drain.append(blob), [blob])
    }

    // MARK: - The write queue

    /// A stand-in for `OutputStream`: takes up to `step` bytes a call, records them, and can be
    /// told to have no room or to fail.
    private final class FakeStream {
        var step: Int
        var room = Int.max
        var fail = false
        private(set) var written: [UInt8] = []
        private(set) var calls = 0

        init(step: Int) { self.step = step }

        func write(_ base: UnsafePointer<UInt8>, _ count: Int) -> Int {
            calls += 1
            if fail { return -1 }
            let taken = min(count, step, room)
            guard taken > 0 else { return 0 }
            written += UnsafeBufferPointer(start: base, count: taken)
            room -= taken
            return taken
        }
    }

    func testQueueSendsWritesWholeAndInOrder() {
        let first = Self.command(sequence: 1)
        let second = Self.command(sequence: 2, method: "Dev_GetBattery")
        var queue = RokidWriteQueue()
        XCTAssertTrue(queue.enqueue(first))
        XCTAssertTrue(queue.enqueue(second))
        XCTAssertEqual(queue.queuedByteCount, first.count + second.count)

        let stream = FakeStream(step: 7)
        XCTAssertEqual(queue.drain(stream.write), .empty)
        XCTAssertEqual(stream.written, first + second)
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.queuedByteCount, 0)
    }

    func testAFullStreamPausesTheQueueWithoutLosingBytes() {
        let write = Self.command()
        var queue = RokidWriteQueue()
        queue.enqueue(write)

        let stream = FakeStream(step: 10)
        stream.room = 15
        XCTAssertEqual(queue.drain(stream.write), .blocked)
        XCTAssertEqual(stream.written, Array(write.prefix(15)))
        XCTAssertEqual(queue.queuedByteCount, write.count - 15)
        XCTAssertEqual(queue.head.map { Array($0) }, Array(write.dropFirst(15)))

        // The stream reports space again.
        stream.room = .max
        XCTAssertEqual(queue.drain(stream.write), .empty)
        XCTAssertEqual(stream.written, write)
    }

    func testAStreamErrorKeepsTheUnsentBytes() {
        let write = Self.command()
        var queue = RokidWriteQueue()
        queue.enqueue(write)
        let stream = FakeStream(step: 4)
        stream.fail = true
        XCTAssertEqual(queue.drain(stream.write), .failed)
        XCTAssertEqual(queue.queuedByteCount, write.count)
    }

    func testQueueRefusesAWriteThatWouldOverflowIt() {
        var queue = RokidWriteQueue(capacity: 10)
        XCTAssertTrue(queue.enqueue(Array(repeating: 1, count: 8)))
        XCTAssertFalse(queue.enqueue(Array(repeating: 2, count: 3)))
        XCTAssertEqual(queue.queuedByteCount, 8, "a refused write queues nothing")
        XCTAssertTrue(queue.enqueue([3, 3]))
    }

    func testQueueTakesAnOversizedWriteWhenEmpty() {
        var queue = RokidWriteQueue(capacity: 4)
        XCTAssertTrue(queue.enqueue(Array(repeating: 9, count: 20)))
        XCTAssertFalse(queue.enqueue([1]))
    }

    func testConsumeNeverReachesIntoTheNextWrite() {
        var queue = RokidWriteQueue()
        queue.enqueue([1, 2, 3])
        queue.enqueue([4, 5])
        queue.consume(100)
        XCTAssertEqual(queue.head.map { Array($0) }, [4, 5])
        XCTAssertEqual(queue.queuedByteCount, 2)
    }

    func testEmptyWritesAndRemoveAll() {
        var queue = RokidWriteQueue()
        XCTAssertTrue(queue.enqueue([]))
        XCTAssertTrue(queue.isEmpty)
        queue.enqueue([1, 2, 3])
        queue.consume(1)
        queue.removeAll()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(queue.head)
        XCTAssertEqual(queue.queuedByteCount, 0)
        XCTAssertEqual(queue.drain { _, _ in XCTFail("nothing to write"); return 0 }, .empty)
    }
}
