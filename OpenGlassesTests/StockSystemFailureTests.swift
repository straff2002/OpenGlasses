import XCTest
@testable import OpenGlasses

/// Plan MM P1 — the common failure categories: which stop retrying, which back off, and the
/// sentence for each, worded with the system's name and never with the system's own text.
final class StockSystemFailureTests: XCTestCase {

    private let endpoint = StockSystemEndpoint(.post, "/v1/adjustments", purpose: .write, scope: "stock:write")

    private static let all: [StockSystemFailure] = [
        .unauthorized(.expired), .unauthorized(.revoked), .unauthorized(.invalid), .missingScope("stock:write"),
        .rateLimited(retryAfter: 5), .rateLimited(retryAfter: nil), .server(status: 502),
        .rejected(code: "BAD_QUANTITY", field: "quantity"), .rejected(code: nil, field: nil), .notFound,
        .malformedResponse, .tooLarge, .unreachable,
    ]

    func testCredentialAndRequestProblemsStopAndTheRestBackOff() {
        for failure in Self.all {
            XCTAssertNotEqual(failure.isTerminal, failure.isRetryable, "\(failure)")
        }
        for terminal: StockSystemFailure in [.unauthorized(.expired), .unauthorized(.revoked), .unauthorized(.invalid),
                                             .missingScope("x"), .rejected(code: nil, field: nil), .notFound, .tooLarge] {
            XCTAssertTrue(terminal.isTerminal, "\(terminal)")
        }
        for retryable: StockSystemFailure in [.rateLimited(retryAfter: nil), .server(status: 500), .malformedResponse, .unreachable] {
            XCTAssertTrue(retryable.isRetryable, "\(retryable)")
        }
    }

    func testEverySentenceNamesTheSystemAndSaysWhatHappensOrWhatToFix() {
        for failure in Self.all {
            let sentence = failure.sentence(system: "Fixture Till")
            XCTAssertTrue(sentence.contains("Fixture Till"), sentence)
            XCTAssertTrue(sentence.hasSuffix("."), sentence)
            if failure.isTerminal, failure != .rejected(code: nil, field: nil),
               failure != .rejected(code: "BAD_QUANTITY", field: "quantity") {
                XCTAssertTrue(sentence.contains(StockSystemFailure.settingsPath), "a terminal failure says where to fix it: \(sentence)")
            }
        }
        XCTAssertEqual(StockSystemFailure.missingScope("stock:write").sentence(system: "Fixture Till"),
                       "The Fixture Till key can't do this without the stock:write permission. Make a key that has it and "
                       + "paste it in Settings › Field Assist › Stock system.")
        XCTAssertEqual(StockSystemFailure.rejected(code: "BAD_QUANTITY", field: "quantity").sentence(system: "Fixture Till"),
                       "Fixture Till refused the request (BAD_QUANTITY on quantity). Nothing more is sent until someone checks "
                       + "it in Fixture Till.")
        XCTAssertEqual(StockSystemFailure.rateLimited(retryAfter: 9).sentence(system: "Fixture Till"),
                       "Fixture Till is limiting requests. The phone will wait and try again.")
    }

    func testARejectionKeepsOnlyShortPlainWords() {
        XCTAssertEqual(StockSystemFailure.rejected(systemCode: "INVALID_VALUE", systemField: "changes[0].quantity"),
                       .rejected(code: "INVALID_VALUE", field: "changes[0].quantity"))
        XCTAssertEqual(StockSystemFailure.rejected(systemCode: "The quantity you sent is wrong", systemField: "a\nb"),
                       .rejected(code: nil, field: nil), "free text is never kept")
        XCTAssertEqual(StockSystemFailure.rejected(systemCode: String(repeating: "A", count: 49), systemField: nil),
                       .rejected(code: nil, field: nil))
        XCTAssertEqual(StockSystemFailure.rejected(systemCode: " CODE ", systemField: ""), .rejected(code: "CODE", field: nil))
    }

    func testAStatusAloneMapsToItsCategory() {
        XCTAssertNil(StockSystemFailure.forStatus(200, endpoint: endpoint))
        XCTAssertNil(StockSystemFailure.forStatus(204, endpoint: endpoint))
        XCTAssertEqual(StockSystemFailure.forStatus(401, endpoint: endpoint), .unauthorized(.invalid))
        XCTAssertEqual(StockSystemFailure.forStatus(403, endpoint: endpoint), .missingScope("stock:write"))
        XCTAssertEqual(StockSystemFailure.forStatus(404, endpoint: endpoint), .notFound)
        XCTAssertEqual(StockSystemFailure.forStatus(413, endpoint: endpoint), .tooLarge)
        XCTAssertEqual(StockSystemFailure.forStatus(429, endpoint: endpoint, retryAfter: 4), .rateLimited(retryAfter: 4))
        XCTAssertEqual(StockSystemFailure.forStatus(500, endpoint: endpoint), .server(status: 500))
        XCTAssertEqual(StockSystemFailure.forStatus(422, endpoint: endpoint), .rejected(code: nil, field: nil))
        XCTAssertEqual(StockSystemFailure.forStatus(302, endpoint: endpoint), .malformedResponse)
    }

    func testRetryAfterIsWholeSecondsUpToADay() {
        func retry(_ value: String?) -> TimeInterval? {
            StockSystemFailure.retryAfter(StockSystemResponse(status: 429, body: Data(),
                                                              headers: value.map { ["Retry-After": $0] } ?? [:]))
        }
        XCTAssertEqual(retry("30"), 30)
        XCTAssertEqual(retry(" 0 "), 0)
        XCTAssertEqual(retry("86400"), 86_400)
        XCTAssertNil(retry("86401"))
        XCTAssertNil(retry("-5"))
        XCTAssertNil(retry("1.5"))
        XCTAssertNil(retry("Fri, 20 Nov 2026 10:00:00 GMT"), "a date is left to the caller's own back-off")
        XCTAssertNil(retry(nil))
    }

    func testCodesAreStable() {
        XCTAssertEqual(Self.all.map(\.code), [
            "unauthorized_expired", "unauthorized_revoked", "unauthorized_invalid", "missing_scope", "rate_limited",
            "rate_limited", "server", "rejected", "rejected", "not_found", "malformed_response", "too_large", "unreachable",
        ])
    }
}
