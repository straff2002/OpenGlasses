import Foundation

/// Where the clinic's Microsoft 365 keeps its data, said once at sign-in (Plan NK §3, Decision 4).
/// A tenant provisioned in Canada keeps its files at rest in Canada; any other country, or none
/// given, is a plain notice. **It never blocks:** the rows are inventory-only, so this is a
/// disclosure, not a prohibition. Pure.
enum TenantCountryNotice: Equatable, Sendable {
    case none
    /// The organisation's two-letter country, or nil when Graph gave none.
    case notice(country: String?)

    static let expectedCountry = "CA"

    init(countryLetterCode: String?) {
        let code = countryLetterCode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if code == Self.expectedCountry {
            self = .none
        } else {
            self = .notice(country: code.flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    /// Never true: the notice is shown, and the connection goes ahead.
    var blocks: Bool { false }

    /// The notice in the app's language; nil for Canada.
    var sentence: String? {
        switch self {
        case .none:
            return nil
        case .notice(let country?):
            let name = Locale.current.localizedString(forRegionCode: country) ?? country
            return String(localized: "Your clinic's Microsoft 365 is set up in \(name), so the stock rows may be stored outside Canada. They carry no patient details. You can carry on, or ask your administrator about a Canadian tenant.",
                          comment: "Notice when the clinic's Microsoft 365 tenant is not provisioned in Canada; the placeholder is the country's name.")
        case .notice(nil):
            return String(localized: "Microsoft 365 didn't say which country your clinic's account is set up in, so the stock rows may be stored outside Canada. They carry no patient details. You can carry on.",
                          comment: "Notice when the clinic's Microsoft 365 tenant country is unknown.")
        }
    }
}
