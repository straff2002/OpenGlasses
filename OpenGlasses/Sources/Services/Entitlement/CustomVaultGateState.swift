import Foundation

/// What the Custom Vaults screen shows about importing a vault of your own: whether the button
/// works, and the sentence under it when it does not.
///
/// Pure over the capability check, so every state renders in a test without StoreKit, a receipt or
/// a stored code — and so the screen and the importer can never disagree about who may ingest a
/// manual, because both ask the same capability.
enum CustomVaultGateState: Equatable {
    /// Import is available.
    case allowed
    /// Entitled, but this entitlement does not include vaults of your own — the retired one-time
    /// unlock, or a solo-tier code.
    case bundledOnly
    /// Every piece of evidence has lapsed. Installed vaults stay readable and removable.
    case lapsed(Date)
    /// A stored licence code did not verify.
    case unverifiableLicence
    /// No entitlement at all.
    case locked

    static func resolve(_ check: FieldAssistCapabilityCheck) -> CustomVaultGateState {
        switch check {
        case .granted: return .allowed
        case .notIncluded: return .bundledOnly
        case .denied(.expired(let date)): return .lapsed(date)
        case .denied(.unverifiableLicense): return .unverifiableLicence
        case .denied(.noEvidence): return .locked
        }
    }

    /// Resolve straight from the app's entitlement. The one call a screen makes.
    @MainActor
    static func current(_ entitlement: FieldAssistEntitlement = .shared) -> CustomVaultGateState {
        resolve(entitlement.check(.ownVaults))
    }

    var allowsImport: Bool { self == .allowed }

    /// The sentence shown under a disabled import button, or nil when there is nothing to explain.
    var explanation: String? {
        switch self {
        case .allowed: return nil
        case .bundledOnly: return FieldAssistPaywallCopy.bundledVaultsOnly
        case .lapsed: return FieldAssistPaywallCopy.ownVaultsLapsed
        case .unverifiableLicence: return FieldAssistPaywallCopy.unverifiable
        case .locked: return FieldAssistPaywallCopy.ownVaultsLocked
        }
    }
}
