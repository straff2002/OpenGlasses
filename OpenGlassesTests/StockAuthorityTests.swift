import XCTest
@testable import OpenGlasses

/// Plan MM P0 — who holds the count: the office route, then the phone's connection, then the phone.
final class StockAuthorityTests: XCTestCase {

    private let connection = StockSystemConnection(connectorID: "sample-system", locationIDs: ["L1", "L2"])

    func testTheOfficeRouteBeatsTheConnection() {
        XCTAssertEqual(StockAuthority.resolve(officeRoute: true, connection: connection), .phone)
        XCTAssertEqual(StockAuthority.resolve(officeRoute: true, connection: nil), .phone)
    }

    func testTheConnectionBeatsThePhone() {
        XCTAssertEqual(StockAuthority.resolve(officeRoute: false, connection: connection),
                       .system(connectorID: "sample-system", locationIDs: ["L1", "L2"]))
        XCTAssertEqual(StockAuthority.resolve(officeRoute: false, connection: nil), .phone)
    }

    func testAConnectionWithNoLocationOrConnectorAnswersForNothing() {
        XCTAssertEqual(StockAuthority.resolve(officeRoute: false,
                                              connection: .init(connectorID: "sample-system", locationIDs: [])), .phone)
        XCTAssertEqual(StockAuthority.resolve(officeRoute: false,
                                              connection: .init(connectorID: "sample-system", locationIDs: [" ", ""])), .phone)
        XCTAssertEqual(StockAuthority.resolve(officeRoute: false,
                                              connection: .init(connectorID: "  ", locationIDs: ["L1"])), .phone)
        // Repeated and padded location ids are cleaned, in order.
        XCTAssertEqual(StockAuthority.resolve(officeRoute: false,
                                              connection: .init(connectorID: "sample-system", locationIDs: [" L2", "L1", "L2"])),
                       .system(connectorID: "sample-system", locationIDs: ["L2", "L1"]))
    }

    /// The phone's list stops counting while a system holds the place, and counts again when the
    /// connection goes.
    func testThePhonesListBecomesThePreviousListAndComesBack() {
        let connected = StockAuthority.resolve(officeRoute: false, connection: connection)
        XCTAssertEqual(connected.phoneList, .previous)
        XCTAssertEqual(connected.locationIDs, ["L1", "L2"])

        let removed = StockAuthority.resolve(officeRoute: false, connection: nil)
        XCTAssertEqual(removed.phoneList, .counting)
        XCTAssertEqual(removed.locationIDs, [])

        let routedToOffice = StockAuthority.resolve(officeRoute: true, connection: connection)
        XCTAssertEqual(routedToOffice.phoneList, .counting)
    }

    /// Exactly one list counts for a place, whatever the inputs.
    func testNoListIsEverBoth() {
        let connections: [StockSystemConnection?] = [nil, connection, .init(connectorID: "x", locationIDs: [])]
        for office in [false, true] {
            for connection in connections {
                let authority = StockAuthority.resolve(officeRoute: office, connection: connection)
                XCTAssertEqual(authority.isSystem, authority.phoneList == .previous)
                XCTAssertEqual(authority.isSystem, !authority.locationIDs.isEmpty)
            }
        }
    }
}
