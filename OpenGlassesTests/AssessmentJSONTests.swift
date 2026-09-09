import XCTest
@testable import OpenGlasses

/// Tests for `AssessmentJSON` — tolerant object extraction from model text (the local/fallback path)
/// plus the snake_case decode helper used by schema adapters. Pure/headless.
final class AssessmentJSONTests: XCTestCase {

    func testBareObject() {
        let dict = AssessmentJSON.object(fromText: #"{"tier":"ok","confidence":0.9}"#)
        XCTAssertEqual(dict?["tier"] as? String, "ok")
        XCTAssertEqual(dict?["confidence"] as? Double, 0.9)
    }

    func testJSONFencedBlock() {
        let text = """
        Here is the assessment:
        ```json
        {"tier":"critical","summary":"not breathing"}
        ```
        Hope that helps.
        """
        let dict = AssessmentJSON.object(fromText: text)
        XCTAssertEqual(dict?["tier"] as? String, "critical")
        XCTAssertEqual(dict?["summary"] as? String, "not breathing")
    }

    func testPlainFencedBlock() {
        let text = "```\n{\"value\": 42}\n```"
        XCTAssertEqual(AssessmentJSON.object(fromText: text)?["value"] as? Int, 42)
    }

    func testProseWrappedFirstToLastBrace() {
        let text = "The model says { \"tier\": \"caution\" } and nothing else."
        XCTAssertEqual(AssessmentJSON.object(fromText: text)?["tier"] as? String, "caution")
    }

    func testMalformedReturnsNil() {
        XCTAssertNil(AssessmentJSON.object(fromText: "no json here at all"))
        XCTAssertNil(AssessmentJSON.object(fromText: "{ not valid json"))
    }

    func testDecodeHelperHonoursSnakeCaseCodingKeys() throws {
        let json: [String: Any] = [
            "quantity": "temperature", "value": 38.0, "unit": "°F",
            "canonical": 3.33, "canonical_unit": "°C", "confidence": 0.8
        ]
        let reading = try AssessmentJSON.decode(InstrumentReading.self, from: json)
        XCTAssertEqual(reading.quantity, "temperature")
        XCTAssertEqual(reading.value, 38.0, accuracy: 0.0001)
        XCTAssertEqual(reading.unit, "°F")
        XCTAssertEqual(reading.canonicalUnit, "°C")
        XCTAssertEqual(try XCTUnwrap(reading.confidence), 0.8, accuracy: 0.0001)
    }
}
