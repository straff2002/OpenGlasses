import XCTest
@testable import OpenGlasses

/// Plan MZ §7 — how the Bluetooth transport recognises a ring, without CoreBluetooth: by
/// advertised name or by the company identifier, never by an address.
final class RingScanMatchTests: XCTestCase {

    private let driver = SmartRingDriver()
    private let id = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
    /// The invented address the fixtures use, never a real ring's.
    private let address: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06]

    func testARingIsRecognisedByItsAdvertisedName() {
        let advertisement = RingAdvertisement(localName: "SMART_RING", serviceUUIDs: ["FEF5"], manufacturerData: nil)
        let candidate = RingScanMatch.candidate(id: id, advertisement: advertisement, driver: driver)
        XCTAssertEqual(candidate, RingCandidate(id: id, displayName: RingScanMatch.displayName, heldByAnotherApp: false))
    }

    func testARingIsRecognisedByItsCompanyIdentifier() {
        let advertisement = RingAdvertisement(localName: nil, serviceUUIDs: [],
                                              manufacturerData: [0x4A, 0x59] + address)
        XCTAssertNotNil(RingScanMatch.candidate(id: id, advertisement: advertisement, driver: driver))
    }

    func testAnAddressAloneIsNeverAMatch() {
        // The same address bytes under another company identifier, and on their own.
        let otherCompany = RingAdvertisement(localName: "Headphones", serviceUUIDs: ["FEF5"],
                                             manufacturerData: [0x4C, 0x00] + address)
        XCTAssertNil(RingScanMatch.candidate(id: id, advertisement: otherCompany, driver: driver))
        let addressOnly = RingAdvertisement(localName: nil, serviceUUIDs: [], manufacturerData: address)
        XCTAssertNil(RingScanMatch.candidate(id: id, advertisement: addressOnly, driver: driver))
        let tooShort = RingAdvertisement(localName: nil, serviceUUIDs: [], manufacturerData: [0x4A])
        XCTAssertNil(RingScanMatch.candidate(id: id, advertisement: tooShort, driver: driver))
    }

    func testANameThatOnlyLooksLikeTheRingIsNotOne() {
        for name in ["SMART_RING2", "smart_ring", "SMART RING", ""] {
            let advertisement = RingAdvertisement(localName: name, serviceUUIDs: [], manufacturerData: nil)
            XCTAssertNil(RingScanMatch.candidate(id: id, advertisement: advertisement, driver: driver), name)
        }
    }

    func testTheAdvertisementIsReadFromCoreBluetoothsKeys() {
        let data: [String: Any] = [
            RingScanMatch.localNameKey: "SMART_RING",
            RingScanMatch.manufacturerDataKey: Data([0x4A, 0x59] + address),
            RingScanMatch.serviceUUIDsKey: ["FEF5"],
        ]
        let advertisement = RingScanMatch.advertisement(from: data, peripheralName: nil)
        XCTAssertEqual(advertisement.localName, "SMART_RING")
        XCTAssertEqual(advertisement.companyID, 0x594A)
        XCTAssertEqual(advertisement.serviceUUIDs, ["FEF5"])

        let unnamed = RingScanMatch.advertisement(from: [:], peripheralName: "SMART_RING")
        XCTAssertEqual(unnamed.localName, "SMART_RING", "the peripheral's own name stands in")
    }

    /// The candidate a scan hands on carries no address: only the phone's identifier, a generic
    /// name and whether another app holds the ring.
    func testACandidateCarriesNoAddressAndNoVendorName() {
        let held = RingScanMatch.connectedCandidate(id: id)
        XCTAssertTrue(held.heldByAnotherApp)
        let fields = Mirror(reflecting: held).children.compactMap(\.label)
        XCTAssertEqual(fields, ["id", "displayName", "heldByAnotherApp"])
        XCTAssertFalse(held.displayName.contains("SMART_RING"))
    }

    /// The transport keeps its own central and never touches the display's.
    func testTheTransportHasItsOwnCentral() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "OpenGlasses/Sources/Services/Ring/RingBLETransport.swift"), encoding: .utf8)
        XCTAssertTrue(source.hasPrefix("#if !AVENKIN_PHONE_ONLY"), "the ring's Bluetooth stays out of the store build")
        XCTAssertTrue(source.contains("CBCentralManager(delegate: self"))
        XCTAssertFalse(source.contains("EvenBLETransport."), "never shares the display's central")
        XCTAssertFalse(source.contains("restoreIdentifier"), "no state restoration in v1 (decision 3)")
    }
}
