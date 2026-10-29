import XCTest
@testable import OpenGlasses

/// `convert_currency` asks Frankfurter first and falls back to AllRatesToday's keyless ECB table
/// when Frankfurter is down. The wearer's sentence is the same whichever source answered.
final class CurrencyToolTests: XCTestCase {

    private var previousMedicalMode: (() -> MedicalEgressGuard.Mode)!

    override func setUp() {
        super.setUp()
        previousMedicalMode = MedicalEgressGuard.currentMode
        MedicalEgressGuard.currentMode = { .off }
        RecordingQueueProtocol.reset()
    }

    override func tearDown() {
        MedicalEgressGuard.currentMode = previousMedicalMode
        RecordingQueueProtocol.reset()
        super.tearDown()
    }

    private var tool: CurrencyTool { CurrencyTool(session: RecordingQueueProtocol.session()) }

    func testFrankfurterAnswersFirst() async throws {
        RecordingQueueProtocol.queue = [
            (200, #"{"base":"USD","date":"2026-10-29","rates":{"EUR":0.5}}"#)
        ]
        let result = try await tool.execute(args: ["amount": 100, "from": "usd", "to": "eur"])
        XCTAssertEqual(result, "100 USD = 50 EUR (rate: 0.5000)")
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 1)
        XCTAssertTrue(RecordingQueueProtocol.requests[0].url.hasPrefix("https://api.frankfurter.dev/"))
    }

    func testFallsBackToAllRatesTodayWhenFrankfurterFails() async throws {
        RecordingQueueProtocol.queue = [
            (503, ""),
            (200, #"{"result":"success","base_code":"USD","date":"2026-10-29","rates":{"EUR":0.8982,"GBP":0.7811}}"#)
        ]
        let result = try await tool.execute(args: ["amount": 100, "from": "USD", "to": "EUR"])
        XCTAssertEqual(result, "100 USD = 89.82 EUR (rate: 0.8982)")
        let urls = RecordingQueueProtocol.requests.map(\.url)
        XCTAssertEqual(urls.count, 2)
        XCTAssertTrue(urls[0].hasPrefix("https://api.frankfurter.dev/"))
        XCTAssertEqual(urls[1], "https://allratestoday.com/api/open/latest/USD")
    }

    func testUnparsableFrankfurterBodyFallsBack() async throws {
        RecordingQueueProtocol.queue = [
            (200, #"{"message":"not found"}"#),
            (200, #"{"result":"success","base_code":"GBP","date":"2026-10-29","rates":{"JPY":195.5}}"#)
        ]
        let result = try await tool.execute(args: ["amount": 2, "from": "GBP", "to": "JPY"])
        XCTAssertEqual(result, "2 GBP = 391 JPY (rate: 195.5000)")
    }

    func testBothSourcesDownKeepsTheOldMessage() async throws {
        RecordingQueueProtocol.queue = [(502, ""), (500, #"{"error":"unavailable"}"#)]
        let result = try await tool.execute(args: ["amount": 5, "from": "USD", "to": "XXX"])
        XCTAssertEqual(result, "Currency conversion service is temporarily unavailable. Check that USD and XXX are valid currency codes.")
        XCTAssertEqual(RecordingQueueProtocol.requests.count, 2)
    }

    func testWholeNumberRateIsRead() async throws {
        RecordingQueueProtocol.queue = [(200, #"{"base":"GBP","date":"2026-10-29","rates":{"JPY":195}}"#)]
        let result = try await tool.execute(args: ["amount": 2, "from": "GBP", "to": "JPY"])
        XCTAssertEqual(result, "2 GBP = 390 JPY (rate: 195.0000)")
    }

    func testCodesAreTrimmedAndUppercased() async throws {
        RecordingQueueProtocol.queue = [(200, #"{"base":"USD","date":"2026-10-29","rates":{"EUR":0.5}}"#)]
        let result = try await tool.execute(args: ["amount": 100, "from": " usd ", "to": "eur\n"])
        XCTAssertEqual(result, "100 USD = 50 EUR (rate: 0.5000)")
        XCTAssertEqual(RecordingQueueProtocol.requests.first?.url,
                       "https://api.frankfurter.dev/v1/latest?base=USD&symbols=EUR")
    }

    /// A malformed code is refused before any request, so it never reaches either host.
    func testMalformedCodeSendsNothing() async throws {
        for bad in ["USD/../x", "US", "EURO", "U$D", "ÉUR"] {
            let result = try await tool.execute(args: ["amount": 1, "from": bad, "to": "EUR"])
            XCTAssertEqual(result, "\"\(bad)\" isn't a currency code. Use a three-letter code such as USD, EUR or GBP.")
        }
        let result = try await tool.execute(args: ["amount": 1, "from": "USD", "to": "EUR&x=1"])
        XCTAssertTrue(result.hasPrefix("\"EUR&x=1\" isn't a currency code."))
        XCTAssertTrue(RecordingQueueProtocol.requests.isEmpty)
    }
}
