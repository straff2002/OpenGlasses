import XCTest
@testable import OpenGlasses

/// Build 799: "the voltage shows me 125 V", written by speech recognition as "show me", opened an
/// unrelated vent-length table and sent a glasses photo. A "show me" with an instrument or quantity
/// before it and a number straight after is a reading; every other "show me" is still a request.
final class ShowMeReadoutTests: XCTestCase {

    func testAMetersReadingIsAReadout() {
        let readouts = [
            "I missed voltage on the igniter and the voltage show me 125 V",
            "the meter shows me 3.2 amps",
            "the meter's showing me about 120",
            "it show me 125v",
            "manometer showed me 0.28",
            "the clamp show me like 4.5 A",
        ]
        for turn in readouts {
            XCTAssertTrue(ShowMeReadout.isReadout(turn), turn)
        }
    }

    func testARequestToSeeSomethingIsNot() {
        let requests = [
            "show me the page",
            "show me page 47",
            "show me 47",
            "can you show me 47",
            "please show me table 8",
            "show me the wiring diagram on page 52",
            "the manual should show me the wiring",
            "show me what the meter says",
            "the voltage is 125",
        ]
        for turn in requests {
            XCTAssertFalse(ShowMeReadout.isReadout(turn), turn)
        }
    }

    func testANumberWithAUnitGluedOnCounts() {
        for word in ["125", "3.2", "1,200", "125v", "40psi", "0.28"] {
            XCTAssertTrue(ShowMeReadout.isNumberWithUnit(word), word)
        }
        for word in ["page", "v125", "table8x", "125voltsabc"] {
            XCTAssertFalse(ShowMeReadout.isNumberWithUnit(word), word)
        }
    }

    // MARK: - Where it is used

    func testTheTurnIsAReadingSoNoPageOpens() {
        let turn = "I missed voltage on the igniter and the voltage show me 125 V"
        XCTAssertEqual(ManualTurnClassifier.classify(turn), .reading)
        XCTAssertEqual(FigureAutoOpenPolicy.decide(turnKind: .reading, passageKind: .captioned, tokenHits: []),
                       .none(reason: .reading), "a reading puts no page on the phone")
        XCTAssertEqual(ManualTurnClassifier.classify("show me page 47"), .showMe)
        XCTAssertEqual(ManualTurnClassifier.classify("show me the page"), .showMe)
    }

    func testTheReadingTakesNoPhoto() {
        XCTAssertEqual(VisionIntentDetector.classify("the voltage show me 125 V"), .textOnly)
        XCTAssertEqual(VisionIntentDetector.classify("show me the page"), .vision, "a request still looks")
        XCTAssertEqual(VisionIntentDetector.classify("the meter show me 125 V, what is this"), .vision,
                       "another camera phrase in the same turn still looks")
    }
}
