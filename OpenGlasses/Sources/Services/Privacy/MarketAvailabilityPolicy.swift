import Foundation

/// Plan HP P1 item 6 — the boundary that will make a capability unavailable in one market while
/// the same binary ships everywhere. **Dormant**: every restriction date below is nil, so today
/// every capability is available in every storefront and nothing consults this yet.
///
/// Why it exists now: from 2 December 2027, face recognition and emotion inference are high-risk
/// under the EU AI Act (review §3.1, §3.2), and a business first-aid triage use may be too (§3.3).
/// Unless the company carries a conformity assessment by then, those capabilities must be off on
/// EEA storefronts. Building the boundary dormant and tested means switching it on is filling in
/// one table, not writing new code under a deadline.
///
/// Pure: the storefront, the capability and the date are inputs. `StorefrontReader` is the seam
/// that reads the real storefront.
enum MarketAvailabilityPolicy {

    /// A capability whose availability may one day depend on the market.
    enum Capability: String, CaseIterable, Equatable {
        /// Naming enrolled people from the camera (Annex III 1(a)).
        case faceRecognition
        /// Assistive Social mode's emotional-state inference (Annex III 1(c)).
        case emotionInference
        /// Camera first-aid triage under a business edition (Annex III 5(d), decision pending).
        case firstAidTriageBusiness
    }

    enum Availability: Equatable {
        case available
        /// Not offered on this storefront. The reason is wearer-facing copy.
        case unavailableInRegion(reason: String)
    }

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

    /// From when each capability is unavailable on an EEA storefront; nil means never.
    ///
    /// **All nil in this build — the policy is dormant.** This is the single table to fill in, by a
    /// decision recorded with counsel, before 2 December 2027 (the date Annex III obligations apply
    /// to these uses). A capability whose conformity assessment is in place stays nil.
    static let restrictedInEEAFrom: [Capability: Date?] = [
        .faceRecognition: nil,
        .emotionInference: nil,
        .firstAidTriageBusiness: nil,
    ]

    /// Whether `capability` is available on the storefront `countryCode` at `date`.
    ///
    /// An unknown storefront (nil, or a code this table does not recognise) is treated as
    /// available: the restriction is a market rule, and a phone whose market cannot be read is not
    /// evidence of being in that market. `restrictions` is injectable so a test can switch a
    /// capability on without touching the shipped table.
    static func availability(of capability: Capability,
                             storefront countryCode: String?,
                             at date: Date,
                             restrictions: [Capability: Date?] = restrictedInEEAFrom) -> Availability {
        guard let code = normalised(countryCode), eeaStorefronts.contains(code),
              let from = restrictions[capability] ?? nil, date >= from else {
            return .available
        }
        return .unavailableInRegion(reason: reason(for: capability))
    }

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

    /// Wearer-facing copy for a capability that is not offered here.
    static func reason(for capability: Capability) -> String {
        switch capability {
        case .faceRecognition:
            return String(localized: "Face recognition isn't available in your region.")
        case .emotionInference:
            return String(localized: "Describing how someone seems to feel isn't available in your region.")
        case .firstAidTriageBusiness:
            return String(localized: "Camera first-aid triage isn't available for work use in your region.")
        }
    }
}
