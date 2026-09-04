import Foundation
import StoreKit

/// Manages in-app purchases using StoreKit 2.
///
/// Products:
/// - `medical_compliance_monthly` — Medical Compliance monthly subscription
/// - `medical_compliance_annual` — Medical Compliance annual subscription (discounted)
///
/// Uses auto-renewable subscriptions because compliance frameworks (HIPAA, GDPR,
/// AU Privacy Act, etc.) change over time — ongoing updates require ongoing revenue.
/// The subscription funds continuous compliance audits, framework updates, and
/// platform-specific export maintenance.
@MainActor
class StoreKitService: ObservableObject {
    static let shared = StoreKitService()

    // MARK: - Product Identifiers

    nonisolated static let medicalMonthlyId = "com.openglasses.medical_compliance_monthly"
    nonisolated static let medicalAnnualId = "com.openglasses.medical_compliance_annual"

    /// Field Assist (solo) — a one-time non-consumable unlock. Complements the license-code path.
    nonisolated static let fieldAssistId = "com.openglasses.field_assist"
    /// Field Assist (solo) — monthly and annual auto-renewing subscriptions beside the one-time unlock.
    nonisolated static let fieldAssistMonthlyId = "com.openglasses.field_assist_monthly"
    nonisolated static let fieldAssistAnnualId = "com.openglasses.field_assist_annual"

    /// Every store product that grants the solo tier. Teams are licensed by signed code, not StoreKit.
    nonisolated static let fieldAssistProductIds: Set<String> = [fieldAssistId, fieldAssistMonthlyId, fieldAssistAnnualId]
    nonisolated static let fieldAssistSubscriptionIds: Set<String> = [fieldAssistMonthlyId, fieldAssistAnnualId]

    /// Medical Compliance subscription products.
    private static let medicalProductIds: Set<String> = [medicalMonthlyId, medicalAnnualId]

    /// All known product identifiers (loaded from the App Store / .storekit).
    private static let allProductIds: Set<String> = medicalProductIds.union(fieldAssistProductIds)

    /// Subscription group name (must match App Store Connect).
    static let subscriptionGroupId = "medical_compliance"

    // MARK: - Published State

    /// Loaded products from the App Store.
    @Published private(set) var products: [Product] = []

    /// Whether the user has an active Medical Compliance subscription.
    @Published private(set) var isMedicalComplianceActive = false

    /// Whether any store product entitles Field Assist (one-time unlock or a live subscription).
    @Published private(set) var isFieldAssistPurchased = false

    /// The Field Assist subscription's renewal state, when the entitlement comes from one.
    @Published private(set) var fieldAssistSubscription: SubscriptionInfo?

    /// The user's current subscription status (for UI display).
    @Published private(set) var subscriptionStatus: SubscriptionInfo?

    /// True while a purchase is in progress.
    @Published var isPurchasing = false

    /// Last purchase error message (if any).
    @Published var purchaseError: String?

    /// Transaction listener task — kept alive for the app's lifetime.
    private var transactionListener: Task<Void, Never>?

    struct SubscriptionInfo {
        let productId: String
        let expirationDate: Date?
        let isInGracePeriod: Bool
        let willAutoRenew: Bool

        var planName: String {
            productId.hasSuffix("annual") ? "Annual" : "Monthly"
        }

        var isExpiringSoon: Bool {
            guard let expiry = expirationDate else { return false }
            return expiry.timeIntervalSinceNow < 7 * 24 * 3600 // within 7 days
        }
    }

    // MARK: - Init

    private init() {
        transactionListener = listenForTransactions()
        Task {
            await loadProducts()
            await checkSubscriptionStatus()
        }
    }

    // MARK: - Load Products

    /// Fetch product metadata from the App Store.
    func loadProducts() async {
        do {
            let loaded = try await Product.products(for: Self.allProductIds)
            // Sort: annual first (better value), then monthly
            products = loaded.sorted { a, _ in a.id == Self.medicalAnnualId }
            PrivacyLog.purchase(.catalogLoaded, count: products.count)
        } catch {
            PrivacyLog.purchase(.catalogFailed, error: SafeErrorSummary(error))
        }
    }

    // MARK: - Purchase

    /// Purchase any product in the catalog (a Medical Compliance subscription, or a Field Assist
    /// unlock or subscription); entitlement is re-derived from the receipt afterwards.
    func purchase(_ product: Product) async {
        isPurchasing = true
        purchaseError = nil

        do {
            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                await checkSubscriptionStatus()
                PrivacyLog.purchase(.activated, product: PrivacyToken(product.id))

            case .userCancelled:
                PrivacyLog.purchase(.cancelled, product: PrivacyToken(product.id))

            case .pending:
                PrivacyLog.purchase(.pending, product: PrivacyToken(product.id))
                purchaseError = "Purchase is pending approval."

            @unknown default:
                PrivacyLog.purchase(.resultUnknown, product: PrivacyToken(product.id))
            }
        } catch {
            purchaseError = "Purchase failed: \(error.localizedDescription)"
            PrivacyLog.purchase(.failed, product: PrivacyToken(product.id),
                                error: SafeErrorSummary(error))
        }

        isPurchasing = false
    }

    // MARK: - Subscription Status

    /// Check current entitlements for both the Medical Compliance subscription and the Field Assist
    /// non-consumable.
    ///
    /// The Field Assist result is recorded as entitlement *evidence* in `VerifiedStorePurchaseRecorder`
    /// — a process-local record of a verified, unrevoked transaction. `Config.fieldAssistPurchased` is
    /// still written, but only as a display mirror. This runs at launch and on every transaction
    /// update, and resolves against the on-device receipt, so it holds offline.
    func checkSubscriptionStatus() async {
        var medicalActive = false
        var fieldProducts: [(productID: String, expiration: Date?)] = []
        var fieldSubscription: SubscriptionInfo?
        var packProducts = Set<String>()

        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                guard transaction.revocationDate == nil else { continue }

                if Self.medicalProductIds.contains(transaction.productID) {
                    medicalActive = true

                    // Get renewal info
                    var willRenew = true
                    var gracePeriod = false
                    if let statuses = try? await product(for: transaction.productID)?.subscription?.status,
                       let status = statuses.first {
                        if case .verified(let renewalInfo) = status.renewalInfo {
                            willRenew = renewalInfo.willAutoRenew
                        }
                        gracePeriod = status.state == .inGracePeriod
                    }

                    subscriptionStatus = SubscriptionInfo(
                        productId: transaction.productID,
                        expirationDate: transaction.expirationDate,
                        isInGracePeriod: gracePeriod,
                        willAutoRenew: willRenew
                    )
                } else if VaultPackManifest.isPackProductId(transaction.productID) {
                    // A vault pack (Plan EG): recorded apart from the feature evidence.
                    packProducts.insert(transaction.productID)
                } else if Self.fieldAssistProductIds.contains(transaction.productID) {
                    fieldProducts.append((transaction.productID, transaction.expirationDate))
                    if Self.fieldAssistSubscriptionIds.contains(transaction.productID) {
                        var willRenew = true
                        var gracePeriod = false
                        if let statuses = try? await product(for: transaction.productID)?.subscription?.status,
                           let status = statuses.first {
                            if case .verified(let renewalInfo) = status.renewalInfo {
                                willRenew = renewalInfo.willAutoRenew
                            }
                            gracePeriod = status.state == .inGracePeriod
                        }
                        let info = SubscriptionInfo(productId: transaction.productID,
                                                    expirationDate: transaction.expirationDate,
                                                    isInGracePeriod: gracePeriod,
                                                    willAutoRenew: willRenew)
                        // Two live subscriptions (an upgrade mid-period): keep the one that lasts.
                        if let existing = fieldSubscription,
                           let a = existing.expirationDate, let b = info.expirationDate, a >= b {
                            // keep existing
                        } else {
                            fieldSubscription = info
                        }
                    }
                }
            }
        }

        isMedicalComplianceActive = medicalActive
        if !medicalActive {
            subscriptionStatus = nil
        }

        let fieldActive = !fieldProducts.isEmpty
        isFieldAssistPurchased = fieldActive
        fieldAssistSubscription = fieldSubscription
        Config.setFieldAssistPurchased(fieldActive)
        // Revocation lands here: clearing the record makes every later gate deny, so nothing new
        // opens. Work already in flight finishes — the gates are entry checks. Every entitling
        // product is recorded; the evaluator prefers the perpetual unlock over a dated subscription.
        if fieldActive {
            VerifiedStorePurchaseRecorder.shared.record(products: fieldProducts)
        } else {
            VerifiedStorePurchaseRecorder.shared.clear()
        }
        VerifiedStorePurchaseRecorder.shared.recordPackProducts(packProducts)
    }

    /// Fetch store metadata for vault packs the catalog lists, so a pack row can show a price and
    /// be bought. Ids come from the signed catalog, never from a hard-coded set.
    func loadPackProducts(ids: Set<String>) async {
        let wanted = ids.filter { VaultPackManifest.isPackProductId($0) }.subtracting(products.map(\.id))
        guard !wanted.isEmpty else { return }
        do {
            let loaded = try await Product.products(for: wanted)
            products.append(contentsOf: loaded)
        } catch {
            PrivacyLog.purchase(.catalogFailed, error: SafeErrorSummary(error))
        }
    }

    /// A loaded product by id (any kind).
    func loadedProduct(id: String) -> Product? {
        products.first { $0.id == id }
    }

    /// Restore purchases (triggers App Store sign-in if needed).
    func restorePurchases() async {
        try? await AppStore.sync()
        await checkSubscriptionStatus()
    }

    // MARK: - Transaction Listener

    /// Listen for transaction updates (renewals, expirations, revocations).
    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result {
                    await transaction.finish()
                    await self?.checkSubscriptionStatus()
                }
            }
        }
    }

    // MARK: - Verification

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let safe):
            return safe
        }
    }

    // MARK: - Helpers

    private func product(for id: String) -> Product? {
        products.first { $0.id == id }
    }

    /// The monthly subscription product.
    var monthlyProduct: Product? {
        products.first { $0.id == Self.medicalMonthlyId }
    }

    /// The annual subscription product.
    var annualProduct: Product? {
        products.first { $0.id == Self.medicalAnnualId }
    }

    /// The Field Assist non-consumable unlock product.
    var fieldAssistProduct: Product? {
        products.first { $0.id == Self.fieldAssistId }
    }

    /// The Field Assist monthly subscription product.
    var fieldAssistMonthlyProduct: Product? {
        products.first { $0.id == Self.fieldAssistMonthlyId }
    }

    /// The Field Assist annual subscription product.
    var fieldAssistAnnualProduct: Product? {
        products.first { $0.id == Self.fieldAssistAnnualId }
    }

    /// Whether the perpetual one-time unlock specifically is owned (as opposed to a subscription).
    var ownsFieldAssistUnlock: Bool {
        VerifiedStorePurchaseRecorder.shared.allEvidence.contains {
            if case .verifiedStoreProduct(let id, _) = $0 { return id == Self.fieldAssistId }
            return false
        }
    }

    /// Whether the user can access Medical Compliance features.
    /// Returns true if subscribed OR if running in debug/TestFlight.
    var canAccessMedicalCompliance: Bool {
        #if DEBUG
        return true // Always available in debug builds for testing
        #else
        return isMedicalComplianceActive
        #endif
    }

    /// Manage subscription in the App Store (opens subscription management).
    func showManageSubscription() async {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }
        try? await AppStore.showManageSubscriptions(in: windowScene)
    }
}
