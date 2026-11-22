import XCTest
@testable import OpenGlasses

/// Plan MZ P0 — every command's bytes against the protocol notes' own examples, the 20-byte frame,
/// and recognising the ring without reading its address.
final class SmartRingPacketTests: XCTestCase {

    private typealias F = RingFixture
    private let driver = SmartRingDriver()

    private func encoded(_ command: RingCommand) -> [UInt8] { driver.encode(command) }

    // MARK: - The frame

    func testAPacketIsTwentyBytesOfOpcodeFieldsAndZeroPadding() {
        let packet = SmartRingPacket(opcode: 0x04, payload: [0x0a])
        XCTAssertEqual(packet.bytes.count, 20)
        XCTAssertEqual(packet.opcode, 0x04)
        XCTAssertEqual(packet[1], 0x0a)
        XCTAssertTrue(packet.isZero(from: 2))
    }

    func testOtherLengthsAreRefused() {
        XCTAssertNil(SmartRingPacket(bytes: Array(repeating: 0, count: 19)))
        XCTAssertNil(SmartRingPacket(bytes: Array(repeating: 0, count: 21)))
        XCTAssertNil(SmartRingPacket(bytes: []))
        XCTAssertNotNil(SmartRingPacket(bytes: Array(repeating: 0, count: 20)))
    }

    func testIntegersAreLittleEndian() throws {
        let packet = try XCTUnwrap(SmartRingPacket(bytes: F.activityExample))
        XCTAssertEqual(packet.uint32(at: 5), 328)
        XCTAssertEqual(SmartRingPacket.littleEndian(10_000), [0x10, 0x27, 0x00, 0x00])
        XCTAssertEqual(SmartRingPacket.littleEndian(0x6a15_dc9e), [0x9e, 0xdc, 0x15, 0x6a])
    }

    // MARK: - Commands against the published examples

    func testTimeSyncMatchesTheExample() {
        let sync = RingTimeSync(ringSeconds: 0x6a15_dc9e, offsetSeconds: -4 * 3600)
        XCTAssertEqual(encoded(.timeSync(sync)), F.hex("019edc156afc0000000000000000000000000000"))
    }

    func testLocaleIsAsciiAtBytesOneToFive() {
        XCTAssertEqual(encoded(.locale("en-US")), F.hex("21656e2d55530000000000000000000000000000"))
        XCTAssertEqual(encoded(.locale("en-ÜS")), F.packet("21656e2d5300"), "non-ASCII is dropped, not mangled")
    }

    func testStatusQuery() {
        XCTAssertEqual(encoded(.status), F.packet("0c"))
    }

    func testStepGoal() {
        XCTAssertEqual(encoded(.stepGoal(10_000)), F.hex("1a10270000000000000000000000000000000000"))
        XCTAssertEqual(encoded(.stepGoal(-5)), F.packet("1a"), "a negative goal is zero, never wrapped")
    }

    func testHeartRateScheduleMatchesTheThreeObservedForms() {
        XCTAssertEqual(encoded(.heartRateSchedule(.off)), F.hex("190000173b001e02000000000000000000000000"))
        XCTAssertEqual(encoded(.heartRateSchedule(.every(minutes: 30))),
                       F.hex("190000173b011e02000000000000000000000000"))
        XCTAssertEqual(encoded(.heartRateSchedule(.every(minutes: 10))),
                       F.hex("190000173b010a02000000000000000000000000"))
        XCTAssertEqual(RingHeartRateSchedule.recommended, .every(minutes: 30))
    }

    func testLiveHeartRateStartAndStop() {
        XCTAssertEqual(encoded(.liveHeartRateStart), F.hex("14b4000000000000000000000000000000000000"))
        XCTAssertEqual(encoded(.liveHeartRateStop), F.hex("1500000000000000000000000000000000000000"))
    }

    func testOxygenStartAndStop() {
        XCTAssertEqual(encoded(.oxygenStart), F.hex("2301000000000000000000000000000000000000"))
        XCTAssertEqual(encoded(.oxygenStop), F.hex("2300000000000000000000000000000000000000"))
    }

    func testHistoryQueries() {
        XCTAssertEqual(encoded(.sleepHistoryQuery), F.hex("1000000000000000000000000000000000000000"))
        XCTAssertEqual(encoded(.storedHistoryQuery), F.hex("1600000000000000000000000000000000000000"))
    }

    func testSelfieModeAndFindRing() {
        XCTAssertEqual(encoded(.selfieMode(on: true)), F.hex("0701000000000000000000000000000000000000"))
        XCTAssertEqual(encoded(.selfieMode(on: false)), F.hex("0700000000000000000000000000000000000000"))
        XCTAssertEqual(encoded(.findRing), F.hex("040a000000000000000000000000000000000000"))
    }

    /// The body profile (`02`, Plan MZ risk 1) and factory reset (`0e`) are not in the vocabulary.
    func testNoCommandIsTheBodyProfileOrAFactoryReset() {
        for command in F.allCommands {
            let bytes = encoded(command)
            XCTAssertEqual(bytes.count, 20, "\(command)")
            XCTAssertFalse([0x02, 0x0e].contains(bytes[0]), "\(command) must never be sent")
        }
    }

    // MARK: - Identity

    func testTheDriverDeclaresItsGattRolesAndCapabilities() {
        XCTAssertEqual(driver.gatt.service, "56FF")
        XCTAssertEqual(driver.gatt.write, "33F3")
        XCTAssertTrue(driver.gatt.writeWithResponse)
        XCTAssertEqual(driver.gatt.notify, "33F4")
        XCTAssertEqual(driver.gatt.batteryService, "180F")
        XCTAssertEqual(driver.gatt.batteryLevel, "2A19")
        XCTAssertEqual(driver.advertisedService, "FEF5")
        XCTAssertEqual(driver.capabilities, Set(RingCapability.allCases))
    }

    func testARingIsRecognisedByNameOrCompanyIdentifierNeverByAddress() {
        let byName = RingAdvertisement(localName: "SMART_RING", serviceUUIDs: ["FEF5"], manufacturerData: nil)
        // Company id 0x594A little-endian, then the invented address.
        let byCompany = RingAdvertisement(localName: nil, serviceUUIDs: ["FEF5"],
                                          manufacturerData: F.hex("4a59 010203040506 7a003a001600"))
        let stranger = RingAdvertisement(localName: "SOMETHING_ELSE", serviceUUIDs: ["FEF5"],
                                         manufacturerData: F.hex("0100 010203040506"))
        let tooShort = RingAdvertisement(localName: nil, serviceUUIDs: [], manufacturerData: [0x4a])
        XCTAssertTrue(driver.recognises(byName))
        XCTAssertTrue(driver.recognises(byCompany))
        XCTAssertFalse(driver.recognises(stranger), "the address after the company id is never matched")
        XCTAssertFalse(driver.recognises(tooShort))
    }
}
