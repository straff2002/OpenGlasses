import Foundation
import StoreKit

/// The introductory offer a paywall states next to a subscription's price, such as
/// "1 week free, then $4.99/month".
///
/// Guideline 3.1.2 asks the purchase screen itself to say how long a trial lasts and what it
/// costs afterwards. Apple's purchase sheet does say so, but only after the wearer taps Subscribe.
/// Before this, the paywalls showed only the regular price and a general note that "any
/// introductory offer applies only to eligible subscribers".
///
/// Built from plain values so the wording can be tested without StoreKit. `init?(product:)` reads
/// a `Product`. The line is shown only for an account StoreKit says is eligible for the offer;
/// the regular price shows either way.
struct SubscriptionOfferTerms: Equatable {

    enum Unit: Equatable { case day, week, month, year }

    struct Period: Equatable {
        let value: Int
        let unit: Unit
    }

    enum Mode: Equatable {
        /// Nothing to pay for `offerPeriod × periodCount`.
        case freeTrial
        /// `offerPrice` each `offerPeriod`, for `periodCount` periods.
        case payAsYouGo
        /// `offerPrice` once, covering `offerPeriod × periodCount`.
        case payUpFront
    }

    let mode: Mode
    let offerPrice: String
    let offerPeriod: Period
    let periodCount: Int
    let regularPrice: String
    let regularPeriod: Period

    /// The sentence the paywall shows, in the locale of `locale`'s calendar.
    func line(locale: Locale = .current) -> String {
        let regular = Self.pricePerPeriod(regularPrice, regularPeriod, locale: locale)
        let count = max(periodCount, 1)
        switch mode {
        case .freeTrial:
            let length = Self.duration(Period(value: offerPeriod.value * count, unit: offerPeriod.unit), locale: locale)
            return String(localized: "\(length) free, then \(regular)")
        case .payAsYouGo:
            let each = Self.pricePerPeriod(offerPrice, offerPeriod, locale: locale)
            let length = Self.duration(Period(value: offerPeriod.value * count, unit: offerPeriod.unit), locale: locale)
            return String(localized: "\(each) for \(length), then \(regular)")
        case .payUpFront:
            let length = Self.duration(Period(value: offerPeriod.value * count, unit: offerPeriod.unit), locale: locale)
            return String(localized: "\(offerPrice) for the first \(length), then \(regular)")
        }
    }

    /// "$4.99/month" for a single period, "$12.99 every 3 months" otherwise.
    static func pricePerPeriod(_ price: String, _ period: Period, locale: Locale = .current) -> String {
        guard period.value == 1 else {
            return String(localized: "\(price) every \(duration(period, locale: locale))")
        }
        switch period.unit {
        case .day: return String(localized: "\(price)/day")
        case .week: return String(localized: "\(price)/week")
        case .month: return String(localized: "\(price)/month")
        case .year: return String(localized: "\(price)/year")
        }
    }

    /// "1 week", "3 days", "2 months": spelled out in full, in the calendar's locale.
    static func duration(_ period: Period, locale: Locale = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let formatter = DateComponentsFormatter()
        formatter.calendar = calendar
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        var components = DateComponents()
        switch period.unit {
        case .day:
            formatter.allowedUnits = [.day]
            components.day = period.value
        case .week:
            formatter.allowedUnits = [.weekOfMonth]
            components.weekOfMonth = period.value
        case .month:
            formatter.allowedUnits = [.month]
            components.month = period.value
        case .year:
            formatter.allowedUnits = [.year]
            components.year = period.value
        }
        return formatter.string(from: components) ?? "\(period.value)"
    }
}

extension SubscriptionOfferTerms {

    /// The offer on `product`, or nil when it is not a subscription or has no introductory offer.
    /// It does not check eligibility; `StoreKitService.introOfferEligibleIds` does that.
    init?(product: Product) {
        guard let subscription = product.subscription,
              let offer = subscription.introductoryOffer else { return nil }
        let mode: Mode
        switch offer.paymentMode {
        case .freeTrial: mode = .freeTrial
        case .payAsYouGo: mode = .payAsYouGo
        case .payUpFront: mode = .payUpFront
        default: return nil
        }
        self.init(mode: mode,
                  offerPrice: offer.displayPrice,
                  offerPeriod: Period(offer.period),
                  periodCount: offer.periodCount,
                  regularPrice: product.displayPrice,
                  regularPeriod: Period(subscription.subscriptionPeriod))
    }
}

private extension SubscriptionOfferTerms.Period {
    init(_ period: Product.SubscriptionPeriod) {
        let unit: SubscriptionOfferTerms.Unit
        switch period.unit {
        case .day: unit = .day
        case .week: unit = .week
        case .month: unit = .month
        case .year: unit = .year
        @unknown default: unit = .month
        }
        self.init(value: period.value, unit: unit)
    }
}
