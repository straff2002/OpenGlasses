import Foundation
import StoreKit

/// Plan HP P1 item 6 — which App Store storefront this install came through, as an ISO 3166-1
/// alpha-2 code. The seam `MarketAvailabilityPolicy` will read; today its only reader is the
/// support report, which prints it as one line.
///
/// A storefront is the account's App Store country, not where the phone is: it says which market
/// the app was distributed in, which is the question the policy asks, and it is not the wearer's
/// location. It is a country code, not personal data, and it never goes into a log.
protocol StorefrontReader: Sendable {
    /// The storefront's country as ISO 3166-1 alpha-2, or nil when it cannot be read.
    func countryCode() async -> String?
}

/// Reads StoreKit 2's `Storefront.current`.
///
/// StoreKit reports the country as ISO 3166-1 **alpha-3** ("FRA"); the policy and the support
/// report use alpha-2 ("FR"). Every EEA storefront is mapped, plus the neighbours a test names, so
/// the conversion can never make an EEA storefront look foreign. A code outside the table is
/// passed through upper-cased: it can only be a non-EEA storefront, which the policy treats as
/// available either way.
struct StoreKitStorefrontReader: StorefrontReader {

    func countryCode() async -> String? {
        guard let code = await Storefront.current?.countryCode else { return nil }
        return Self.alpha2(fromStoreKit: code)
    }

    static func alpha2(fromStoreKit code: String) -> String? {
        let upper = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !upper.isEmpty else { return nil }
        if upper.count == 2 { return upper }
        return alpha3ToAlpha2[upper] ?? upper
    }

    /// The EEA in full, then the non-EEA neighbours and large storefronts most often confused with it.
    static let alpha3ToAlpha2: [String: String] = [
        // EU 27
        "AUT": "AT", "BEL": "BE", "BGR": "BG", "HRV": "HR", "CYP": "CY", "CZE": "CZ", "DNK": "DK",
        "EST": "EE", "FIN": "FI", "FRA": "FR", "DEU": "DE", "GRC": "GR", "HUN": "HU", "IRL": "IE",
        "ITA": "IT", "LVA": "LV", "LTU": "LT", "LUX": "LU", "MLT": "MT", "NLD": "NL", "POL": "PL",
        "PRT": "PT", "ROU": "RO", "SVK": "SK", "SVN": "SI", "ESP": "ES", "SWE": "SE",
        // EEA EFTA
        "ISL": "IS", "LIE": "LI", "NOR": "NO",
        // Not EEA
        "GBR": "GB", "CHE": "CH", "USA": "US", "CAN": "CA", "AUS": "AU", "NZL": "NZ", "JPN": "JP",
        "TUR": "TR", "UKR": "UA", "SRB": "RS", "ALB": "AL", "MKD": "MK", "MNE": "ME", "BIH": "BA",
        "MDA": "MD", "GEO": "GE", "ARM": "AM", "BLR": "BY", "RUS": "RU",
    ]
}

extension MarketAvailabilityPolicy {
    /// The support report's line for the storefront. Unknown is said, not omitted, so a report
    /// with no line is never mistaken for one from a build that could not read it.
    static func supportReportLine(storefront countryCode: String?) -> String {
        "App Store region: \(countryCode ?? "unknown")"
    }
}
