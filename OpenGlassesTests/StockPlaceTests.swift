import XCTest
@testable import OpenGlasses

/// Plan MK P0 — a stock list's place: a kind from a closed list, its family, and an unknown kind
/// read as van.
final class StockPlaceTests: XCTestCase {

    func testEveryKindHasItsFamily() {
        XCTAssertEqual(StockPlace.Kind.allCases, [.van, .truck, .store, .warehouse, .stock])
        XCTAssertEqual(StockPlace.Kind.van.family, .vehicle)
        XCTAssertEqual(StockPlace.Kind.truck.family, .vehicle)
        XCTAssertEqual(StockPlace.Kind.store.family, .premises)
        XCTAssertEqual(StockPlace.Kind.warehouse.family, .premises)
        XCTAssertEqual(StockPlace.Kind.stock.family, .premises, "the neutral kind takes the premises steps")
    }

    func testTheRawValuesAreTheContract() {
        XCTAssertEqual(StockPlace.Kind.allCases.map(\.rawValue), ["van", "truck", "store", "warehouse", "stock"])
    }

    func testVanIsTheDefault() {
        XCTAssertEqual(StockPlace.Kind.default, .van)
        XCTAssertEqual(StockPlace().kind, .van)
        XCTAssertEqual(StockPlace().family, .vehicle)
    }

    func testTheStrictParseRefusesAnUnknownKind() {
        XCTAssertEqual(StockPlace.Kind(strict: "store"), .store)
        XCTAssertEqual(StockPlace.Kind(strict: "  Warehouse \n"), .warehouse, "spaces and case are forgiven")
        XCTAssertNil(StockPlace.Kind(strict: "cellar"))
        XCTAssertNil(StockPlace.Kind(strict: ""))
        XCTAssertNil(StockPlace.Kind(strict: nil))
    }

    func testTheLenientReadTakesAnUnknownKindAsVan() {
        XCTAssertEqual(StockPlace.Kind(lenient: "truck"), .truck)
        XCTAssertEqual(StockPlace.Kind(lenient: "boat"), .van)
        XCTAssertEqual(StockPlace.Kind(lenient: nil), .van)
    }

    func testAKindRoundTripsAndAnUnknownOneDecodesAsVan() throws {
        for kind in StockPlace.Kind.allCases {
            let data = try JSONEncoder().encode([kind])
            XCTAssertEqual(String(data: data, encoding: .utf8), "[\"\(kind.rawValue)\"]")
            XCTAssertEqual(try JSONDecoder().decode([StockPlace.Kind].self, from: data), [kind])
        }
        let newer = Data(#"["boat"]"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode([StockPlace.Kind].self, from: newer), [.van],
                       "a kind from a newer build never makes a list unreadable")
    }

    func testAPlaceRoundTripsWithItsName() throws {
        let place = StockPlace(kind: .store, name: "Main street store")
        let decoded = try JSONDecoder().decode(StockPlace.self, from: JSONEncoder().encode(place))
        XCTAssertEqual(decoded, place)
        XCTAssertEqual(decoded.wording, StockPlaceWording(.store))
    }

    // MARK: On the list's identity

    func testAListStoredBeforePlacesDecodesAsVan() throws {
        let older = Data(#"{"id":"v4","name":"Truck 4"}"#.utf8)
        let van = try JSONDecoder().decode(VanIdentity.self, from: older)
        XCTAssertEqual(van, VanIdentity(id: "v4", name: "Truck 4"))
        XCTAssertNil(van.place)
        XCTAssertNil(van.checkVaultID)
        XCTAssertEqual(van.stockPlace, StockPlace(kind: .van, name: "Truck 4"))
    }

    func testAListsPlaceAndBookRoundTrip() throws {
        let van = VanIdentity(id: "s1", name: "Main street store", place: .store, checkVaultID: "vault-9")
        XCTAssertEqual(try JSONDecoder().decode(VanIdentity.self, from: JSONEncoder().encode(van)), van)
        XCTAssertEqual(van.stockPlace.kind, .store)
    }

    func testAnUnknownStoredPlaceReadsAsVan() throws {
        let newer = Data(#"{"id":"s1","name":"Bar","place":"boat"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(VanIdentity.self, from: newer).place, .van)
    }

    func testAnUnnamedListHasNoNameInItsPlace() {
        XCTAssertNil(VanIdentity(id: "s1", name: "", place: .stock).stockPlace.name)
    }
}
