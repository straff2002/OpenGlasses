import XCTest
@testable import OpenGlasses

/// Tests the pure capture→action parsers (business card / receipt / event flyer).
final class CaptureParsersTests: XCTestCase {

    func testBusinessCard() {
        let text = """
        Jane Smith
        Acme Robotics Inc
        Senior Engineer
        jane.smith@acme.com
        +1 (415) 555-0199
        """
        let card = CaptureParsers.parseBusinessCard(text)
        XCTAssertEqual(card.name, "Jane Smith")
        XCTAssertEqual(card.email, "jane.smith@acme.com")
        XCTAssertTrue(card.company?.contains("Acme") ?? false)
        XCTAssertTrue(card.phone?.contains("415") ?? false)
    }

    func testReceiptPrefersTotalLine() {
        let text = """
        Corner Cafe
        Latte 4.50
        Muffin 3.25
        Subtotal 7.75
        Total 8.50
        03/14/2026
        """
        let r = CaptureParsers.parseReceipt(text)
        XCTAssertEqual(r.merchant, "Corner Cafe")
        XCTAssertEqual(r.total, "8.50")
        XCTAssertEqual(r.date, "03/14/2026")
    }

    func testReceiptFallsBackToLargestAmount() {
        let text = "Shop\nItem A 2.00\nItem B 19.99\nThanks"
        let r = CaptureParsers.parseReceipt(text)
        XCTAssertEqual(r.total, "19.99")
    }

    func testEventFlyerNumericDate() {
        let text = """
        Spring Tech Meetup
        Join us 04/22/2026 at the Innovation Hub
        123 Main Street
        """
        let e = CaptureParsers.parseEvent(text)
        XCTAssertEqual(e.title, "Spring Tech Meetup")
        XCTAssertEqual(e.date, "04/22/2026")
        XCTAssertNotNil(e.location)
    }

    func testEventFlyerMonthNameDate() {
        let e = CaptureParsers.parseEvent("Charity Gala\nSaturday, March 9 — Grand Ballroom")
        XCTAssertEqual(e.title, "Charity Gala")
        XCTAssertTrue(e.date?.lowercased().contains("mar") ?? false, "Got: \(e.date ?? "nil")")
    }
}
