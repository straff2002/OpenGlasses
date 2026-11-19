import XCTest
@testable import OpenGlasses

/// A quantity from the model is read without cutting it: a figure that is not a whole number is
/// named as it arrived, so the stock and parts tools can refuse it rather than record 4.25 as 4.
@MainActor
final class QuantityArgumentTests: XCTestCase {

    private func read(_ raw: Any?) -> PartsRequestTool.QuantityArgument {
        PartsRequestTool.quantityArgument(raw)
    }

    private func assertNotWhole(_ raw: Any?, file: StaticString = #filePath, line: UInt = #line) {
        guard case .notWhole = read(raw) else {
            return XCTFail("\(String(describing: raw)) read as \(read(raw))", file: file, line: line)
        }
    }

    func testNothingSentIsAbsent() {
        XCTAssertEqual(read(nil), .absent)
        XCTAssertEqual(read(NSNull()), .absent)
        XCTAssertEqual(read(""), .absent)
        XCTAssertEqual(read("  "), .absent)
    }

    func testWholeNumbersInEveryShapeAreWhole() {
        XCTAssertEqual(read(3), .whole(3))
        XCTAssertEqual(read(3.0), .whole(3))
        XCTAssertEqual(read("4"), .whole(4))
        XCTAssertEqual(read(" 4 "), .whole(4))
        XCTAssertEqual(read("4.0"), .whole(4))
        XCTAssertEqual(read(NSNumber(value: 5)), .whole(5))
        XCTAssertEqual(read(-2), .whole(-2), "the services refuse a negative figure in their own words")
    }

    func testAFractionIsNamedAsItArrived() {
        XCTAssertEqual(read(4.25), .notWhole("4.25"))
        XCTAssertEqual(read(NSNumber(value: 4.25)), .notWhole("4.25"))
        XCTAssertEqual(read("4.25"), .notWhole("4.25"))
        XCTAssertEqual(read(" 4.25 "), .notWhole("4.25"))
        XCTAssertEqual(read("4,25"), .notWhole("4,25"))
    }

    func testWordsBooleansAndAbsurdFiguresAreNotWhole() {
        XCTAssertEqual(read("two"), .notWhole("two"))
        XCTAssertEqual(read(NSNumber(value: true)), .notWhole("true"))
        XCTAssertEqual(read(NSNumber(value: false)), .notWhole("false"))
        assertNotWhole(1e12)
        assertNotWhole(Double.nan)
        assertNotWhole(Double.infinity)
    }

    func testJSONNumbersFromTheWireAreReadTheSameWay() throws {
        let data = Data(#"{"a": 3, "b": 3.0, "c": 4.25, "d": true}"#.utf8)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(read(object["a"]), .whole(3))
        XCTAssertEqual(read(object["b"]), .whole(3))
        XCTAssertEqual(read(object["c"]), .notWhole("4.25"))
        XCTAssertEqual(read(object["d"]), .notWhole("true"))
    }
}
