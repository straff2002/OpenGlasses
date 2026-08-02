import XCTest
@testable import OpenGlasses

// MARK: - ChoiceDetector (Plan CG P1)

final class ChoiceDetectorTests: XCTestCase {

    // Positive: lettered list lines
    func testLetteredListDetects() {
        let reply = """
        There are a few good options nearby:
        A) Riverside walk
        B) Museum loop
        C) Coffee first
        """
        let choices = ChoiceDetector.detect(in: reply)
        XCTAssertEqual(choices.map(\.spokenForm), ["Riverside walk", "Museum loop", "Coffee first"])
    }

    func testLetteredDotMarkersDetect() {
        let reply = "Pick one:\nA. Window seat\nB. Aisle seat"
        XCTAssertEqual(ChoiceDetector.detect(in: reply).count, 2)
    }

    // Positive: inline lettered
    func testInlineLetteredDetects() {
        let reply = "You could visit A) Sydney, B) Melbourne, or C) Perth."
        let choices = ChoiceDetector.detect(in: reply)
        XCTAssertEqual(choices.map(\.spokenForm), ["Sydney", "Melbourne", "Perth"])
    }

    // Inline connector residue is trimmed even without commas
    func testInlineLetteredOrConnectorTrims() {
        let reply = "Options are A) tea or B) coffee."
        let choices = ChoiceDetector.detect(in: reply)
        XCTAssertEqual(choices.map(\.spokenForm), ["tea", "coffee"])
    }

    // Positive: numbered list WITH a choice cue
    func testNumberedListWithCueDetects() {
        let reply = """
        Which would you prefer?
        1. The fast route via the motorway
        2. The scenic route along the coast
        """
        XCTAssertEqual(ChoiceDetector.detect(in: reply).count, 2)
    }

    // Positive: tail question
    func testTailOrQuestionDetects() {
        let reply = "I found three cafés. Would you like the closest, the cheapest, or the best rated?"
        let choices = ChoiceDetector.detect(in: reply)
        XCTAssertEqual(choices.count, 3)
        XCTAssertEqual(choices.last?.spokenForm, "the best rated")
    }

    // Negative: numbered steps without a cue are instructions, not choices
    func testRecipeStepsDoNotDetect() {
        let reply = """
        Here's how to make it:
        1. Preheat the oven to 180 degrees
        2. Mix the flour and butter
        3. Bake for 25 minutes
        """
        XCTAssertTrue(ChoiceDetector.detect(in: reply).isEmpty)
    }

    // Negative: ordinal prose
    func testOrdinalProseDoesNotDetect() {
        let reply = "First, preheat the oven. Second, mix the batter. Finally, bake it."
        XCTAssertTrue(ChoiceDetector.detect(in: reply).isEmpty)
    }

    // Negative: code fences never match
    func testCodeFenceDoesNotDetect() {
        let reply = """
        Here's the enum:
        ```
        A) case one
        B) case two
        ```
        """
        XCTAssertTrue(ChoiceDetector.detect(in: reply).isEmpty)
    }

    // Negative: long enumerated items read as prose
    func testLongItemsDoNotDetect() {
        let longA = String(repeating: "very ", count: 20) + "long option text"
        let reply = "A) \(longA)\nB) \(longA)"
        XCTAssertTrue(ChoiceDetector.detect(in: reply).isEmpty)
    }

    // Negative: a single item is not a choice
    func testSingleItemDoesNotDetect() {
        XCTAssertTrue(ChoiceDetector.detect(in: "A) Only one option").isEmpty)
    }

    // Negative: non-sequential letters are references, not an enumeration
    func testNonSequentialLettersDoNotDetect() {
        let reply = "B) something\nD) something else"
        XCTAssertTrue(ChoiceDetector.detect(in: reply).isEmpty)
    }

    // Negative: plain statement with "or" but no interrogative lead
    func testPlainOrSentenceDoesNotDetect() {
        let reply = "You can pay by card or cash at the counter."
        XCTAssertTrue(ChoiceDetector.detect(in: reply).isEmpty)
    }

    // Negative: address-like numbered content
    func testTimesAndAddressesDoNotDetect() {
        let reply = "Your meetings: 1. 30pm standup then 2. 15pm review"
        XCTAssertTrue(ChoiceDetector.detect(in: reply).isEmpty)
    }

    // Cap: more than five options renders nothing rather than a wall of buttons
    func testMoreThanFiveDoesNotDetect() {
        let reply = (0..<6).map { "\(Character(UnicodeScalar(65 + $0)!))) Option \($0)" }.joined(separator: "\n")
        XCTAssertTrue(ChoiceDetector.detect(in: reply).isEmpty)
    }

    // Labels condense; spoken form stays complete
    func testLabelCondensesLongOption() {
        let option = "Take the number twelve bus from the central station stop"
        let reply = "A) \(option)\nB) Walk instead"
        let first = ChoiceDetector.detect(in: reply).first
        XCTAssertEqual(first?.spokenForm, option)
        XCTAssertLessThanOrEqual(first?.label.count ?? 0, HUDTextShaper.maxTitleLength + 1) // +1 for ellipsis
    }
}

// MARK: - DwellTracker (Plan CG P1)

final class DwellTrackerTests: XCTestCase {

    private let centered = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)

    func testSteadyBoxFiresAfterDwell() {
        var tracker = DwellTracker()
        var fired: CGRect?
        for tick in 0...21 {
            if case .fired(let box) = tracker.process(boxes: [centered], at: Double(tick) * 0.1) {
                fired = box
            }
        }
        XCTAssertEqual(fired, centered)
    }

    func testProgressReportsBeforeFiring() {
        var tracker = DwellTracker()
        _ = tracker.process(boxes: [centered], at: 0)
        let event = tracker.process(boxes: [centered], at: 1.0)
        guard case .tracking(let progress) = event else { return XCTFail("expected tracking, got \(event)") }
        XCTAssertEqual(progress, 0.5, accuracy: 0.01)
    }

    func testJitteringBoxKeepsClock() {
        var tracker = DwellTracker()
        var didFire = false
        for tick in 0...21 {
            let jitter = CGFloat(tick % 2) * 0.02  // small drift, IoU stays high
            let box = centered.offsetBy(dx: jitter, dy: 0)
            if case .fired = tracker.process(boxes: [box], at: Double(tick) * 0.1) { didFire = true }
        }
        XCTAssertTrue(didFire)
    }

    func testReplacedObjectResetsClock() {
        var tracker = DwellTracker()
        for tick in 0...15 { _ = tracker.process(boxes: [centered], at: Double(tick) * 0.1) }
        // A different object appears in the center: no fire, clock restarts.
        let other = CGRect(x: 0.45, y: 0.45, width: 0.05, height: 0.05)  // low IoU vs tracked
        let event = tracker.process(boxes: [other], at: 1.6)
        XCTAssertEqual(event, .tracking(progress: 0))
    }

    func testOffCenterBoxIsIgnored() {
        var tracker = DwellTracker()
        let corner = CGRect(x: 0.0, y: 0.0, width: 0.1, height: 0.1)
        let event = tracker.process(boxes: [corner], at: 0)
        XCTAssertEqual(event, .idle)
    }

    func testBriefDropoutSurvivesGrace() {
        var tracker = DwellTracker()
        _ = tracker.process(boxes: [centered], at: 0)
        _ = tracker.process(boxes: [centered], at: 0.5)
        // Detector flickers for 0.3 s (< grace) …
        _ = tracker.process(boxes: [], at: 0.8)
        // … then the same box returns; the clock was never reset.
        var didFire = false
        for tick in 9...21 {
            if case .fired = tracker.process(boxes: [centered], at: Double(tick) * 0.1) { didFire = true }
        }
        XCTAssertTrue(didFire)
    }

    func testLongDropoutResets() {
        var tracker = DwellTracker()
        _ = tracker.process(boxes: [centered], at: 0)
        _ = tracker.process(boxes: [], at: 1.0)  // > grace
        let event = tracker.process(boxes: [centered], at: 1.1)
        XCTAssertEqual(event, .tracking(progress: 0))
    }

    func testCooldownBlocksImmediateRefire() {
        var tracker = DwellTracker()
        for tick in 0...21 { _ = tracker.process(boxes: [centered], at: Double(tick) * 0.1) }
        let event = tracker.process(boxes: [centered], at: 2.2)
        XCTAssertEqual(event, .coolingDown)
        // After cooldown, tracking starts fresh.
        let after = tracker.process(boxes: [centered], at: 7.0)
        XCTAssertEqual(after, .tracking(progress: 0))
    }

    func testLargestCenteredBoxWins() {
        var tracker = DwellTracker()
        let small = CGRect(x: 0.45, y: 0.45, width: 0.05, height: 0.05)
        let large = CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3)
        _ = tracker.process(boxes: [small, large], at: 0)
        // The tracked object is the large one: continuing with only `large` keeps the clock.
        let event = tracker.process(boxes: [large], at: 1.0)
        guard case .tracking(let progress) = event, progress > 0 else {
            return XCTFail("expected continued track of largest box")
        }
    }
}

// MARK: - BadgeFieldParser (Plan CG P1)

final class BadgeFieldParserTests: XCTestCase {

    /// Classic layout: big name, title under it, org at the bottom, ribbon role.
    private func classicBadge() -> [RecognizedTextLine] {
        [
            RecognizedTextLine("ACME DEVCON 2026", boundingBox: CGRect(x: 0.1, y: 0.85, width: 0.8, height: 0.05)),
            RecognizedTextLine("JANE O'BRIEN-SMITH", boundingBox: CGRect(x: 0.1, y: 0.6, width: 0.8, height: 0.12)),
            RecognizedTextLine("Senior Software Engineer", boundingBox: CGRect(x: 0.1, y: 0.45, width: 0.7, height: 0.05)),
            RecognizedTextLine("Initech Systems Inc.", boundingBox: CGRect(x: 0.1, y: 0.3, width: 0.6, height: 0.06)),
            RecognizedTextLine("ATTENDEE", boundingBox: CGRect(x: 0.3, y: 0.1, width: 0.4, height: 0.04)),
        ]
    }

    func testClassicBadgeParses() {
        let fields = BadgeFieldParser.parse(classicBadge())
        XCTAssertEqual(fields.name, "Jane O'Brien-Smith")
        XCTAssertEqual(fields.title, "Senior Software Engineer")
        XCTAssertEqual(fields.organization, "Initech Systems Inc.")
        XCTAssertTrue(fields.isAcceptable)
    }

    func testRibbonWordIsNeverTheName() {
        let lines = [
            RecognizedTextLine("SPEAKER", boundingBox: CGRect(x: 0.2, y: 0.7, width: 0.6, height: 0.15)),
            RecognizedTextLine("Sam Taylor", boundingBox: CGRect(x: 0.2, y: 0.5, width: 0.6, height: 0.08)),
        ]
        XCTAssertEqual(BadgeFieldParser.parse(lines).name, "Sam Taylor")
    }

    func testBoothNumbersAndUrlsAreIgnored() {
        let lines = [
            RecognizedTextLine("4217", boundingBox: CGRect(x: 0.4, y: 0.8, width: 0.2, height: 0.1)),
            RecognizedTextLine("www.initech.example", boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.05)),
            RecognizedTextLine("Ada Lovelace", boundingBox: CGRect(x: 0.2, y: 0.5, width: 0.6, height: 0.09)),
        ]
        let fields = BadgeFieldParser.parse(lines)
        XCTAssertEqual(fields.name, "Ada Lovelace")
        XCTAssertNil(fields.organization)
    }

    func testEmptyInputYieldsNothing() {
        let fields = BadgeFieldParser.parse([])
        XCTAssertNil(fields.name)
        XCTAssertFalse(fields.isAcceptable)
        XCTAssertEqual(fields.confidence, 0)
    }

    func testNoNameShapedLineIsNotAcceptable() {
        let lines = [
            RecognizedTextLine("Initech Systems Inc.", boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.6, height: 0.1)),
            RecognizedTextLine("Hall 3 Entrance", boundingBox: CGRect(x: 0.1, y: 0.3, width: 0.6, height: 0.05)),
        ]
        XCTAssertFalse(BadgeFieldParser.parse(lines).isAcceptable)
    }

    func testTitleKeywordDoesNotBecomeName() {
        // "Marketing Director" is name-shaped (two capitalized tokens) but is a title.
        let lines = [
            RecognizedTextLine("Marketing Director", boundingBox: CGRect(x: 0.1, y: 0.6, width: 0.7, height: 0.1)),
            RecognizedTextLine("Kim Park", boundingBox: CGRect(x: 0.1, y: 0.45, width: 0.5, height: 0.08)),
        ]
        let fields = BadgeFieldParser.parse(lines)
        XCTAssertEqual(fields.name, "Kim Park")
        XCTAssertEqual(fields.title, "Marketing Director")
    }

    func testLowConfidenceOCRLowersAcceptance() {
        let lines = [
            RecognizedTextLine("Jane Doe", boundingBox: CGRect(x: 0.1, y: 0.6, width: 0.6, height: 0.1), confidence: 0.3),
        ]
        XCTAssertFalse(BadgeFieldParser.parse(lines).isAcceptable)
    }

    func testMixedCaseNameIsPreserved() {
        let lines = [
            RecognizedTextLine("Ludwig van Beethoven", boundingBox: CGRect(x: 0.1, y: 0.6, width: 0.7, height: 0.1)),
        ]
        // Not all-caps input: left exactly as printed.
        XCTAssertEqual(BadgeFieldParser.parse(lines).name, "Ludwig van Beethoven")
    }
}

// MARK: - BadgePayloadParser (Plan CG — badge QR payloads)

final class BadgePayloadParserTests: XCTestCase {

    func testVCardParsesAllFields() {
        let payload = """
        BEGIN:VCARD
        VERSION:3.0
        FN:Jane O'Brien-Smith
        N:O'Brien-Smith;Jane;;;
        ORG:Initech Systems Inc.;Platform Team
        TITLE:Senior Software Engineer
        TEL;TYPE=CELL:+64211234567
        EMAIL:jane@initech.example
        URL:https://initech.example
        END:VCARD
        """
        let contact = BadgePayloadParser.parse(payload)
        XCTAssertEqual(contact?.name, "Jane O'Brien-Smith")
        XCTAssertEqual(contact?.organization, "Initech Systems Inc.")
        XCTAssertEqual(contact?.title, "Senior Software Engineer")
        XCTAssertEqual(contact?.phone, "+64211234567")
        XCTAssertEqual(contact?.email, "jane@initech.example")
        XCTAssertEqual(contact?.website, "https://initech.example")
    }

    func testVCardNFallbackReordersName() {
        let payload = "BEGIN:VCARD\nN:Park;Kim;;;\nEND:VCARD"
        XCTAssertEqual(BadgePayloadParser.parse(payload)?.name, "Kim Park")
    }

    func testVCardFoldedLineUnfolds() {
        let payload = "BEGIN:VCARD\nFN:Jane\n Smith\nEND:VCARD"
        XCTAssertEqual(BadgePayloadParser.parse(payload)?.name, "JaneSmith")
    }

    func testMeCardParses() {
        let payload = "MECARD:N:Doe,John;ORG:Acme Corp;TEL:+15550100;EMAIL:john@acme.example;;"
        let contact = BadgePayloadParser.parse(payload)
        XCTAssertEqual(contact?.name, "John Doe")
        XCTAssertEqual(contact?.organization, "Acme Corp")
        XCTAssertEqual(contact?.phone, "+15550100")
        XCTAssertEqual(contact?.email, "john@acme.example")
    }

    func testBareURLBecomesWebsiteOnly() {
        let contact = BadgePayloadParser.parse("https://example.com/profile/jane")
        XCTAssertEqual(contact?.website, "https://example.com/profile/jane")
        XCTAssertNil(contact?.name)
    }

    func testOpaqueLeadScanBlobYieldsNothing() {
        XCTAssertNil(BadgePayloadParser.parse("TKT-88213-AZQ"))
        XCTAssertNil(BadgePayloadParser.parse(""))
    }

    func testMergePayloadWinsOverOCR() {
        let ocr = BadgeFields(name: "Jane Q'Brlen-Smlth",  // classic OCR mangling
                              title: nil, organization: "lnitech", confidence: 0.6)
        let qr = BadgeContact(name: "Jane O'Brien-Smith", organization: "Initech Systems Inc.")
        let merged = BadgeContact.merged(ocr: ocr, payload: qr)
        XCTAssertEqual(merged.name, "Jane O'Brien-Smith")
        XCTAssertEqual(merged.organization, "Initech Systems Inc.")
    }

    func testMergeOCRFillsPayloadGaps() {
        let ocr = BadgeFields(name: "Kim Park", title: "Marketing Director",
                              organization: nil, confidence: 0.7)
        let qr = BadgeContact(phone: "+15550100")
        let merged = BadgeContact.merged(ocr: ocr, payload: qr)
        XCTAssertEqual(merged.name, "Kim Park")
        XCTAssertEqual(merged.title, "Marketing Director")
        XCTAssertEqual(merged.phone, "+15550100")
    }

    func testMergeRejectedOCRContributesNothing() {
        let merged = BadgeContact.merged(ocr: nil, payload: BadgeContact(name: "Sam Taylor"))
        XCTAssertEqual(merged.name, "Sam Taylor")
        XCTAssertNil(merged.organization)
    }
}
