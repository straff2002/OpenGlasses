import XCTest
@testable import OpenGlasses

/// Guideline 3.1.2: the purchase screen states how long an introductory offer lasts and what the
/// subscription costs afterwards. These pin the wording the three paywalls show.
final class SubscriptionOfferTermsTests: XCTestCase {

    private let en = Locale(identifier: "en_US")

    private func terms(_ mode: SubscriptionOfferTerms.Mode,
                       offerPrice: String = "$0.00",
                       offer: SubscriptionOfferTerms.Period,
                       count: Int = 1,
                       regular: SubscriptionOfferTerms.Period = .init(value: 1, unit: .month)) -> SubscriptionOfferTerms {
        SubscriptionOfferTerms(mode: mode, offerPrice: offerPrice, offerPeriod: offer, periodCount: count,
                               regularPrice: "$4.99", regularPeriod: regular)
    }

    func testAOneWeekFreeTrialStatesItsLengthAndThePriceAfter() {
        XCTAssertEqual(terms(.freeTrial, offer: .init(value: 1, unit: .week)).line(locale: en),
                       "1 week free, then $4.99/month")
    }

    func testTrialLengthMultipliesByThePeriodCount() {
        XCTAssertEqual(terms(.freeTrial, offer: .init(value: 1, unit: .week), count: 2).line(locale: en),
                       "2 weeks free, then $4.99/month")
        XCTAssertEqual(terms(.freeTrial, offer: .init(value: 3, unit: .day)).line(locale: en),
                       "3 days free, then $4.99/month")
    }

    func testPayAsYouGoStatesTheOfferPricePerPeriodAndHowLong() {
        XCTAssertEqual(terms(.payAsYouGo, offerPrice: "$0.99", offer: .init(value: 1, unit: .month), count: 3)
                        .line(locale: en),
                       "$0.99/month for 3 months, then $4.99/month")
    }

    func testPayUpFrontStatesTheOnePriceAndWhatItCovers() {
        XCTAssertEqual(terms(.payUpFront, offerPrice: "$9.99", offer: .init(value: 6, unit: .month),
                             regular: .init(value: 1, unit: .year))
                        .line(locale: en),
                       "$9.99 for the first 6 months, then $4.99/year")
    }

    func testARenewalLongerThanOneUnitSaysEvery() {
        XCTAssertEqual(SubscriptionOfferTerms.pricePerPeriod("$12.99", .init(value: 3, unit: .month), locale: en),
                       "$12.99 every 3 months")
    }

    func testAZeroPeriodCountIsReadAsOnePeriod() {
        XCTAssertEqual(terms(.freeTrial, offer: .init(value: 1, unit: .week), count: 0).line(locale: en),
                       "1 week free, then $4.99/month")
    }
}
