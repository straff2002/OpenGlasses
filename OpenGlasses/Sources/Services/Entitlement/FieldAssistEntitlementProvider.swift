import Foundation
import CryptoKit

/// Supplies the evidence an entitlement decision is made from. Injected, so tests state the access
/// condition explicitly instead of writing a global preference and hoping the gate reads it.
protocol FieldAssistEntitlementProvider: Sendable {
    func evidence() -> FieldAssistEntitlementEvidenceSet
}

/// Process-local record of the StoreKit entitlement the app last verified.
///
/// Deliberately not persisted. `StoreKitService` re-derives it from `Transaction.currentEntitlements`
/// at launch and on every transaction update, which resolves against the on-device receipt and so
/// works offline; a boolean written to disk would instead be a forgeable mirror of a past check.
///
/// Revocation is observed here: `clear()` makes every later decision deny, so no new premium resource
/// opens. An operation already in flight is allowed to finish — the gates are checked at entry.
final class VerifiedStorePurchaseRecorder: @unchecked Sendable {
    static let shared = VerifiedStorePurchaseRecorder()

    private let lock = NSLock()
    private var stored: FieldAssistEntitlementEvidence?

    init() {}

    /// Record a transaction that came back `.verified` and unrevoked.
    func record(productID: String, expiration: Date?) {
        lock.lock()
        defer { lock.unlock() }
        stored = .verifiedStoreProduct(productID: productID, expiration: expiration)
    }

    /// Drop the record — no entitling transaction was found, or it was revoked.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        stored = nil
    }

    var currentEvidence: FieldAssistEntitlementEvidence? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// The production provider: a verified StoreKit transaction observed this process, plus the stored
/// organization license code re-verified at read time.
///
/// The license *code* is the evidence, not the cached "valid" flag — the signature and feature claim
/// are re-checked on every read, and the signed expiry claim is handed to the evaluator rather than
/// applied here, so the clock lives in one place.
struct LiveFieldAssistEntitlementProvider: FieldAssistEntitlementProvider {
    private let storePurchases: VerifiedStorePurchaseRecorder
    private let licensePublicKeyBase64: String
    private let licenseCode: @Sendable () -> String?

    init(storePurchases: VerifiedStorePurchaseRecorder = .shared,
         licensePublicKeyBase64: String = LicenseService.productionPublicKeyBase64,
         licenseCode: @escaping @Sendable () -> String? = {
             UserDefaults.standard.string(forKey: LicenseService.storageKey)
         }) {
        self.storePurchases = storePurchases
        self.licensePublicKeyBase64 = licensePublicKeyBase64
        self.licenseCode = licenseCode
    }

    func evidence() -> FieldAssistEntitlementEvidenceSet {
        var set = FieldAssistEntitlementEvidenceSet()

        if let purchase = storePurchases.currentEvidence {
            set.evidence.append(purchase)
        }

        if let raw = licenseCode()?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            if let payload = try? LicenseService.decode(code: raw, publicKeyBase64: licensePublicKeyBase64) {
                set.evidence.append(.verifiedOrganizationLicense(
                    licenseIDHash: Self.licenseIDHash(for: raw),
                    expiration: payload.expires))
            } else {
                set.hasUnverifiableLicense = true
            }
        }

        return set
    }

    /// Stable short identifier for a code: the first 16 hex characters of its SHA-256. Hashed so a
    /// decision, a log line, or a support screenshot never carries a redistributable license code.
    static func licenseIDHash(for code: String) -> String {
        let digest = SHA256.hash(data: Data(code.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }
}

/// The app's entitlement access point. Holds the injected provider and clock behind a lock so the
/// synchronous gates (`Config`, `VaultRegistry`, tools) can ask from any isolation domain.
final class FieldAssistEntitlement: @unchecked Sendable {
    static let shared = FieldAssistEntitlement()

    /// Preference key the removed developer-unlock toggle wrote. Kept only so the migration can
    /// delete it; nothing reads it for a decision.
    static let legacyDeveloperUnlockKey = "fieldAssistDeveloperUnlocked"

    private let lock = NSLock()
    private var storedProvider: FieldAssistEntitlementProvider
    private var storedClock: @Sendable () -> Date
    #if DEBUG
    private var internalGrant = false
    #endif

    init(provider: FieldAssistEntitlementProvider = LiveFieldAssistEntitlementProvider(),
         clock: @escaping @Sendable () -> Date = Date.init) {
        self.storedProvider = provider
        self.storedClock = clock
    }

    var provider: FieldAssistEntitlementProvider {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedProvider
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storedProvider = newValue
        }
    }

    var clock: @Sendable () -> Date {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedClock
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storedClock = newValue
        }
    }

    /// Evaluate the current evidence. Cheap enough for a gate: one lock, one defaults read, one
    /// signature check.
    func decision() -> FieldAssistEntitlementDecision {
        lock.lock()
        let provider = storedProvider
        let now = storedClock()
        #if DEBUG
        let grantInternal = internalGrant
        #endif
        lock.unlock()

        var set = provider.evidence()
        #if DEBUG
        if grantInternal { set.evidence.append(.internalDeveloper) }
        #endif
        return FieldAssistEntitlementEvaluator.decide(set, now: now)
    }

    var isGranted: Bool { decision().isGranted }

    /// Delete the preference key the removed developer toggle wrote.
    ///
    /// Safe to run on every launch and idempotent: it removes exactly one key and touches no receipt,
    /// license code, or other setting, so a legitimate purchase or license cannot be revoked by it.
    static func removeLegacyPreferenceKeys(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: legacyDeveloperUnlockKey)
    }
}

#if DEBUG
extension FieldAssistEntitlement {
    /// In-memory internal grant for development and demos. Never persisted, so it dies with the
    /// process, and the evidence case it produces does not exist in a Release compilation.
    func setInternalDeveloperGrant(_ granted: Bool) {
        lock.lock()
        defer { lock.unlock() }
        internalGrant = granted
    }
}
#endif
