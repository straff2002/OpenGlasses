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
    private var stored: [FieldAssistEntitlementEvidence] = []
    private var storedPackProducts: Set<String> = []
    private var storedPersonalOriginalID: UInt64?

    init() {}

    /// Record a single transaction that came back `.verified` and unrevoked, replacing any record.
    func record(productID: String, expiration: Date?) {
        record(products: [(productID, expiration)])
    }

    /// Record every entitling transaction observed this check — a non-consumable beside a
    /// subscription is two pieces of evidence, and the evaluator picks the one that lasts.
    func record(products: [(productID: String, expiration: Date?)]) {
        lock.lock()
        defer { lock.unlock() }
        stored = products.map { .verifiedStoreProduct(productID: $0.productID, expiration: $0.expiration) }
    }

    /// Vault-pack purchases observed verified and unrevoked this check (Plan EG). Kept apart from
    /// the Field Assist evidence: a pack is nothing without the feature and grants no tier.
    func recordPackProducts(_ ids: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        storedPackProducts = ids
    }

    /// The original transaction id of the verified My Manuals subscription (Plan JK §8). Monthly ↔
    /// annual, a lapse and a re-subscribe keep it, so one subscription keeps one addition history;
    /// another Apple ID's subscription has its own. Recorded with the evidence, never persisted.
    func recordPersonalSubscription(originalTransactionID: UInt64?) {
        lock.lock()
        defer { lock.unlock() }
        storedPersonalOriginalID = originalTransactionID
    }

    /// The key the new-manual allowance's history is filed under. Without a verified original
    /// transaction (a test host, a debug grant) it is one stable key per device.
    var personalSubscriptionKey: String {
        lock.lock()
        defer { lock.unlock() }
        return storedPersonalOriginalID.map { "store-\($0)" } ?? "device"
    }

    var packProductIds: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return storedPackProducts
    }

    /// Drop the record — no entitling transaction was found, or it was revoked.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        stored = []
        storedPersonalOriginalID = nil
    }

    /// The first recorded piece, for callers that only ever expected one.
    var currentEvidence: FieldAssistEntitlementEvidence? { allEvidence.first }

    var allEvidence: [FieldAssistEntitlementEvidence] {
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
///
/// A seat-checked code (Plan JS P2) is evidence only while this phone's seat lease is live: the
/// lease is re-verified on every read, like the code, against the phone's own key. Its clock is
/// the seat's (a lease is a time-bounded fact the evaluator does not otherwise see).
struct LiveFieldAssistEntitlementProvider: FieldAssistEntitlementProvider {
    /// What the seat check reads. Injected so tests use ephemeral keys and a fixed clock.
    struct SeatInputs: Sendable {
        var record: @Sendable () -> DeviceSeatRecord? = { DeviceSeatRecord.load() }
        var deviceKeyHash: @Sendable () -> String? = { DeviceSeatKeychainStore.shared.currentKeyHash() }
        var leaseKeys: [String] = DeviceSeatLease.productionPublicKeys
        var now: @Sendable () -> Date = { Date() }
    }

    private let storePurchases: VerifiedStorePurchaseRecorder
    private let licensePublicKeyBase64: String
    private let licenseCode: @Sendable () -> String?
    private let seat: SeatInputs

    init(storePurchases: VerifiedStorePurchaseRecorder = .shared,
         licensePublicKeyBase64: String = LicenseService.productionPublicKeyBase64,
         licenseCode: @escaping @Sendable () -> String? = {
             UserDefaults.standard.string(forKey: LicenseService.storageKey)
         },
         seat: SeatInputs = SeatInputs()) {
        self.storePurchases = storePurchases
        self.licensePublicKeyBase64 = licensePublicKeyBase64
        self.licenseCode = licenseCode
        self.seat = seat
    }

    func evidence() -> FieldAssistEntitlementEvidenceSet {
        var set = FieldAssistEntitlementEvidenceSet()

        set.evidence.append(contentsOf: storePurchases.allEvidence)

        if let raw = licenseCode()?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
           raw != PolicyEnvelope.withheldLicenceCode {
            // An organisation's licence whose lease has run out, or been revoked, is not evidence
            // (Plan CT PR 2b): its content locks, and a renewal puts it back.
            if let payload = try? LicenseService.decode(code: raw, publicKeyBase64: licensePublicKeyBase64) {
                // A seat-checked code without a live lease on this phone grants nothing; the hold
                // says why, and the evaluator words it like a lapse.
                if payload.isSeatChecked,
                   let hold = DeviceSeatGate.hold(for: payload, code: raw, record: seat.record(),
                                                  deviceKeyHash: seat.deviceKeyHash(), keys: seat.leaseKeys,
                                                  now: seat.now()) {
                    set.seatHold = hold
                    return set
                }
                set.evidence.append(.verifiedOrganizationLicense(
                    licenseIDHash: Self.licenseIDHash(for: raw),
                    expiration: payload.expires,
                    tier: payload.resolvedTier,
                    packs: payload.packs ?? []))
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
         clock: @escaping @Sendable () -> Date = { Date() }) {
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
        let (set, now) = read()
        return FieldAssistEntitlementEvaluator.decide(set, now: now)
    }

    /// One read of the provider and the clock, so a caller that needs both a decision and the
    /// capabilities gets them from the same evidence rather than from two reads that could differ.
    private func read() -> (FieldAssistEntitlementEvidenceSet, Date) {
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
        return (set, now)
    }

    /// Every capability the current evidence grants (Plan FS).
    func capabilities() -> Set<FieldAssistCapability> {
        let (set, now) = read()
        return FieldAssistCapability.capabilities(for: set, now: now)
    }

    func manualLimits() -> ManualLimits? {
        let (set, now) = read()
        return ManualLimits.resolve(set, now: now)
    }

    /// Whether the current evidence includes `capability`. **The gate every caller uses** — tiers
    /// describe what a licence is, capabilities decide what the code may do.
    func has(_ capability: FieldAssistCapability) -> Bool {
        capabilities().contains(capability)
    }

    /// The capability gate result, with the reason a screen needs when the answer is no.
    func check(_ capability: FieldAssistCapability) -> FieldAssistCapabilityCheck {
        let (set, now) = read()
        return FieldAssistCapabilityCheck.resolve(
            capability,
            capabilities: FieldAssistCapability.capabilities(for: set, now: now),
            decision: FieldAssistEntitlementEvaluator.decide(set, now: now))
    }

    var isGranted: Bool { decision().isGranted }

    /// Recheck at every evidence boundary: a subscription can expire before a separate
    /// licence, changing vault capabilities without removing every entitlement.
    var nextExpiration: Date? {
        let (set, now) = read()
        return set.evidence.compactMap(\.expiration).filter { $0 > now }.min()
    }

    /// Vault packs every live licence includes (Plan EG).
    func grantedPacks() -> Set<String> {
        lock.lock()
        let provider = storedProvider
        let now = storedClock()
        lock.unlock()
        return FieldAssistEntitlementEvaluator.livePacks(provider.evidence(), now: now)
    }

    /// The tiered gate result. Describes the *licence* — what the entitlement screen reports and
    /// what a licence renewal changes. No gate asks it: a gate asks for a capability.
    func check(atLeast required: FieldAssistTier) -> FieldAssistTierCheck {
        let decision = decision()
        guard decision.isGranted, let held = decision.tier else {
            return .denied(decision.denial ?? .noEvidence)
        }
        return held >= required ? .granted(held) : .insufficientTier(required: required, held: held)
    }

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
