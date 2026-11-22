import XCTest
@testable import OpenGlasses

/// Plan MZ P0 — every CONFIRMED notification decoded, the PARTIAL ones typed but unused, echoes as
/// acknowledgements, and anything else an opcode with nothing kept.
final class SmartRingDecoderTests: XCTestCase {

    private typealias F = RingFixture
    private let driver = SmartRingDriver()

    private func decode(_ bytes: [UInt8]) -> [RingEvent] { driver.decode(bytes) }

    func testActivityExample() {
        XCTAssertEqual(decode(F.activityExample), [.activity(RingActivityReading(
            ringSeconds: 0x6a15_7cfd, steps: 328, distanceUnits: 287, calories: 18))])
    }

    func testActivitySummaryIsTypedButOnlyPartlyUnderstood() {
        let packet = [0x13] + SmartRingPacket.littleEndian(1000) + SmartRingPacket.littleEndian(7)
            + SmartRingPacket.littleEndian(8) + SmartRingPacket.littleEndian(328) + [0, 0, 0]
        XCTAssertEqual(decode(packet), [.activitySummary(RingActivitySummary(
            ringSeconds: 1000, fieldA: 7, fieldB: 8, stepLike: 328))])
    }

    func testBattery() {
        XCTAssertEqual(decode(F.hex("0b37000000000000000000000000000000000000")), [.battery(percent: 55)])
        XCTAssertEqual(decode(F.hex("0b63000000000000000000000000000000000000")), [.battery(percent: 99)])
        XCTAssertEqual(decode(F.packet("0bc8")), [.unknown(opcode: 0x0b)], "over 100 % is not a battery level")
    }

    func testLiveHeartRateReadingsStartEchoStopAndEnd() {
        XCTAssertEqual(decode(F.hex("14bbec146a500000000000000000000000000000")), [.heartRate(bpm: 80)])
        XCTAssertEqual(decode(F.hex("14c0ec146a510000000000000000000000000000")), [.heartRate(bpm: 81)])
        XCTAssertEqual(decode(F.hex("1410ef146a550000000000000000000000000000")), [.heartRate(bpm: 85)])
        XCTAssertEqual(decode(F.packet("14b4")), [.acknowledged(.liveHeartRateStart)])
        XCTAssertEqual(decode(F.packet("15")), [.acknowledged(.liveHeartRateStop)])
        XCTAssertEqual(decode(F.packet("27")), [.liveHeartRateEnded])
    }

    func testOxygenProgressThenResult() {
        XCTAssertEqual(decode(F.packet("2301")), [.acknowledged(.oxygenStart)])
        XCTAssertEqual(decode(F.packet("24")), [.oxygenProgress])
        XCTAssertEqual(decode(F.hex("245e774d63050000000000000000000000000000")), [.oxygenResult(percent: 99)])
        XCTAssertEqual(decode(F.hex("24536c4261050000000000000000000000000000")), [.oxygenResult(percent: 97)])
        XCTAssertEqual(decode(F.packet("2300")), [.acknowledged(.oxygenStop)])
        XCTAssertEqual(decode(F.packet("28")), [.oxygenEnded])
        XCTAssertEqual(decode(F.packet("2302")), [.unknown(opcode: 0x23)], "an unconfirmed mode is not guessed at")
    }

    func testSleepTimelinePacket() {
        XCTAssertEqual(decode(F.hex("11989a176a282828282828282828282828282828")), [.sleep(RingSleepPacket(
            ringSeconds: F.sleepLight0130, minutes: Array(repeating: .light, count: 15)))])
        XCTAssertEqual(decode(F.hex("1124a5176a636363636363636363636363636363")), [.sleep(RingSleepPacket(
            ringSeconds: F.sleepDeep0215, minutes: Array(repeating: .deep, count: 15)))])
        let mixed = decode(F.sleepPacket(at: 60, [0x28, 0x63, 0x00, 0x50] + Array(repeating: 0x28, count: 11)))
        XCTAssertEqual(mixed, [.sleep(RingSleepPacket(
            ringSeconds: 60, minutes: [.light, .deep, .none, .unrecognised] + Array(repeating: .light, count: 11)))])
    }

    func testSleepQueryEchoAndSummary() {
        XCTAssertEqual(decode(F.packet("10")), [.acknowledged(.sleepHistoryQuery)])
        XCTAssertEqual(decode(F.packet("1001020304")), [.acknowledged(.sleepHistoryQuery), .sleepHistorySummary])
    }

    func testStoredHistoryStream() {
        XCTAssertEqual(decode(F.packet("16")), [.acknowledged(.storedHistoryQuery)])
        XCTAssertEqual(decode(F.packet("16f0")), [.storedHistoryHeader])
        XCTAssertEqual(decode(F.packet("16aa0102")), [.storedHistoryMetadata])
        XCTAssertEqual(decode(F.packet("16a0494b")), [.storedHistoryChunk])
        XCTAssertEqual(decode(F.packet("16ff")), [.storedHistoryEnd])
        XCTAssertEqual(decode(F.packet("1601")), [.unknown(opcode: 0x16)])
    }

    func testClenchAndSelfieModeEchoes() {
        XCTAssertEqual(decode(F.hex("0602000000000000000000000000000000000000")), [.clench])
        XCTAssertEqual(decode(F.packet("0601")), [.unknown(opcode: 0x06)])
        XCTAssertEqual(decode(F.packet("0701")), [.acknowledged(.selfieModeOn)])
        XCTAssertEqual(decode(F.packet("0700")), [.acknowledged(.selfieModeOff)])
    }

    /// The status reply carries the ring's address; it is reduced to an acknowledgement.
    func testTheStatusReplyIsOnlyAnAcknowledgement() {
        XCTAssertEqual(decode(F.statusReply), [.acknowledged(.status)])
    }

    func testEveryCommandsEchoAcknowledgesIt() {
        for command in F.allCommands {
            XCTAssertEqual(decode(driver.encode(command)), [.acknowledged(command.kind)], "\(command)")
        }
    }

    func testUndecodedNotificationsKeepOnlyTheirOpcode() {
        for opcode: UInt8 in [0x20, 0xf6, 0x44, 0x48, 0x52, 0x1b, 0x02, 0x0e, 0xff] {
            let packet = [opcode] + (1..<20).map { UInt8($0) }
            XCTAssertEqual(decode(packet), [.unknown(opcode: opcode)], String(format: "%02x", opcode))
        }
    }

    func testWrongLengthsAreMalformedAndNotRead() {
        XCTAssertEqual(decode(Array(F.activityExample.prefix(19))), [.malformed(length: 19)])
        XCTAssertEqual(decode(F.activityExample + [0]), [.malformed(length: 21)])
        XCTAssertEqual(decode([]), [.malformed(length: 0)])
    }
}
