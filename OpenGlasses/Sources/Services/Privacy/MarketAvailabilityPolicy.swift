import Foundation

/// Plan HP P1 item 6 — the storefront facts a region rule is decided from: which App Store
/// storefronts are in the EEA.
///
/// This used to carry a per-capability table and an availability answer as well, armed by Plan HS
/// P1 item 1 so face recognition would be unavailable on EEA storefronts from 2 December 2027, the
/// day the EU AI Act's Annex III obligations apply. Face recognition was removed from the app on
/// 2026-11-13, and with it the only row that was ever armed. The other rows (Social mode, business
/// first-aid triage) were never armed and nothing consulted them, so the table and the answer went
/// too: a dormant gate nothing asks is not a control. What stays is the part that is true today
/// and tested — the EEA list, and the support report's storefront line. A future region rule
/// adds its row and its consumer together.
///
/// Pure: the storefront is an input. `StorefrontReader` is the seam that reads the real one.
enum MarketAvailabilityPolicy {

    /// The EU's 27 member states plus Iceland, Liechtenstein and Norway, as ISO 3166-1 alpha-2
    /// codes. Greece is `GR` (ISO), not the `EL` the EU uses in its own documents. Switzerland and
    /// the United Kingdom are deliberately absent: neither is in the EEA.
    static let eeaStorefronts: Set<String> = [
        // EU 27
        "AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR", "DE", "GR", "HU", "IE",
        "IT", "LV", "LT", "LU", "MT", "NL", "PL", "PT", "RO", "SK", "SI", "ES", "SE",
        // EEA EFTA
        "IS", "LI", "NO",
    ]

    /// Whether a storefront is in the EEA. Case-insensitive; nil and unknown codes are not.
    static func isEEA(_ countryCode: String?) -> Bool {
        guard let code = normalised(countryCode) else { return false }
        return eeaStorefronts.contains(code)
    }

    private static func normalised(_ countryCode: String?) -> String? {
        guard let trimmed = countryCode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
