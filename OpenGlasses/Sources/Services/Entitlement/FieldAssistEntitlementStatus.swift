import Foundation

/// What the Field Assist settings screen shows about the entitlement — derived from a decision and
/// a clock, nothing else, so every state renders in a test without StoreKit or a stored code.
struct FieldAssistEntitlementStatus: Equatable {

    enum Warning: Equatable {
        /// The granted tier lapses within `threshold` days (30 or 7); `daysRemaining` is the
        /// whole-day count left, never negative.
        case expiring(daysRemaining: Int, threshold: Int)
    }

    struct Grant: Equatable {
        let tier: FieldAssistTier
        let source: FieldAssistEntitlementDecision.Source
        let expiresAt: Date?
        let warning: Warning?

        var sourceLabel: String {
            switch source {
            case .storeProduct(let productID):
                return StoreKitService.fieldAssistSubscriptionIds.contains(productID) ? "App Store subscription" : "In-app purchase"
            case .organizationLicense: return "Organisation licence"
            #if DEBUG
            case .internalDeveloper: return "Internal build"
            #endif
            }
        }
    }

    enum State: Equatable {
        case none
        case unverifiableLicense
        case expired(Date)
        case granted(Grant)
    }

    /// Days before expiry at which the screen starts warning. Thirty gives an administrator time to
    /// renew before technicians lose access in the field; seven is the last call.
    static let warningThresholdsDays = [30, 7]

    static func make(decision: FieldAssistEntitlementDecision, now: Date = Date()) -> State {
        guard decision.isGranted, let tier = decision.tier, let source = decision.source else {
            switch decision.denial {
            case .expired(let date): return .expired(date)
            case .unverifiableLicense: return .unverifiableLicense
            case .noEvidence, nil: return .none
            }
        }
        var warning: Warning?
        if let expiresAt = decision.expiresAt {
            let seconds = expiresAt.timeIntervalSince(now)
            let days = max(0, Int(seconds / 86_400))
            if let threshold = warningThresholdsDays.sorted().first(where: { days <= $0 }) {
                warning = .expiring(daysRemaining: days, threshold: threshold)
            }
        }
        return .granted(Grant(tier: tier, source: source, expiresAt: decision.expiresAt, warning: warning))
    }
}

/// Every sentence the paywall and licence surfaces show, in one place so a test can assert none of
/// them steers a consumer to buy outside the App Store. App Store Review Guideline 3.1.3(c) allows
/// an organisation-sold licence to unlock access; it does not allow the app to advertise that path
/// as a way around in-app purchase. The copy therefore describes licence *entry*, never licence
/// *purchase*.
enum FieldAssistPaywallCopy {
    static let locked = "Field Assist is locked"
    static let lockedDetail = "Unlock the solo tier with a one-time purchase or a subscription, or enter the licence code your organisation issued."
    static let licenseHeader = "Organisation Licence"
    static let licenseFooter = "Enter the code your organisation issued. Codes are signed and validated on-device — no network required."
    static let purchaseHeader = "Solo — In-App Purchase"
    static let purchaseFooter = "One-time unlock or subscription, on this Apple ID. Solo covers the bundled vaults, guided procedures, domain calculators, session log, and expert escalation."
    static let purchased = "Unlocked with a one-time purchase"
    static let teamOnly = "Your own vaults and manuals, and audited PDF export, are team capabilities. Your purchase covers the bundled vaults; a team licence from your organisation unlocks the rest."
    static let renewLicense = "This licence has expired. Enter a renewal code from your administrator."
    static let unverifiable = "The stored licence code did not verify. Re-enter it, or ask your administrator for a new code."
    static let subscriptionLapsed = "Your Field Assist subscription has lapsed. Manage it in your App Store subscriptions."
    static let manageSubscription = "Manage Subscription"
    static let seatsNote = "Seats are recorded for your records; this device does not enforce them."

    static func expiring(_ warning: FieldAssistEntitlementStatus.Warning) -> String {
        switch warning {
        case .expiring(let days, _):
            switch days {
            case 0: return "Expires today. Renew now to keep Field Assist available in the field."
            case 1: return "Expires tomorrow. Renew now to keep Field Assist available in the field."
            default: return "Expires in \(days) days. Renew before then to keep Field Assist available in the field."
            }
        }
    }

    /// Every static string, for the copy guard test.
    static var all: [String] {
        [locked, lockedDetail, licenseHeader, licenseFooter, purchaseHeader, purchaseFooter, purchased,
         teamOnly, renewLicense, unverifiable, subscriptionLapsed, manageSubscription, seatsNote,
         expiring(.expiring(daysRemaining: 0, threshold: 7)),
         expiring(.expiring(daysRemaining: 1, threshold: 7)),
         expiring(.expiring(daysRemaining: 12, threshold: 30))]
    }
}
