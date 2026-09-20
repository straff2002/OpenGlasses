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

    /// Legacy Field Assist non-consumable. It is no longer offered, but verified purchases remain
    /// valid so removing the product does not revoke access from existing customers.
    nonisolated static let fieldAssistId = "com.openglasses.field_assist"
    /// Field Assist (solo) monthly and annual auto-renewing subscriptions.
    nonisolated static let fieldAssistMonthlyId = "com.openglasses.field_assist_monthly"
    nonisolated static let fieldAssistAnnualId = "com.openglasses.field_assist_annual"

    /// Every store product that grants the solo tier, including the retired non-consumable so
    /// existing owners continue to pass receipt validation. Teams use signed licences.
    nonisolated static let fieldAssistProductIds: Set<String> = [fieldAssistId, fieldAssistMonthlyId, fieldAssistAnnualId]
    nonisolated static let fieldAssistSubscriptionIds: Set<String> = [fieldAssistMonthlyId, fieldAssistAnnualId]
    /// Products offered for new Field Assist purchases. The legacy non-consumable is deliberately
    /// excluded from catalog loading and therefore cannot appear on the paywall.
    nonisolated static let fieldAssistCatalogProductIds: Set<String> = fieldAssistSubscriptionIds

    /// Medical Compliance subscription products.
    private static let medicalProductIds: Set<String> = [medicalMonthlyId, medicalAnnualId]

    /// All known product identifiers (loaded from the App Store / .storekit).
    private static let allProductIds: Set<String> = medicalProductIds.union(fieldAssistCatalogProductIds)

    /// Subscription group name (must match App Store Connect).
    static let subscriptionGroupId = "medical_compliance"

    // MARK: - Published State

    /// Loaded products from the App Store.
    @Published private(set) var products: [Product] = []

    @Published private(set) var isLoadingProducts = false
    @Published private(set) var catalogError: String?
    @Published private(set) var isRestoring = false
    /// False means unknown, not an absent purchase. Set only after recording verified evidence.
    @Published private(set) var hasCheckedEntitlements = false
    @Published private(set) var restoreMessage: String?

    /// Whether the user has an active Medical Compliance subscription.
    @Published private(set) var isMedicalComplianceActive = false

    /// Whether any store product entitles Field Assist (a live subscription or a grandfathered
    /// legacy non-consumable).
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

    /// Only the StoreKit adapter constructs these from verified, unrevoked transactions.
    struct Entitlement {
        let productID: String
        let expiration: Date?
    }

    private let productLoader: @MainActor (Set<String>) async throws -> [Product]
    private let synchronize: @MainActor () async throws -> Void
    private let entitlementLoader: @MainActor () async -> [Entitlement]
    private var entitlementGeneration = 0

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

    init(startAutomatically: Bool = true,
         productLoader: @escaping @MainActor (Set<String>) async throws -> [Product] = { try await Product.products(for: $0) },
         synchronize: @escaping @MainActor () async throws -> Void = { try await AppStore.sync() },
         entitlementLoader: @escaping @MainActor () async -> [Entitlement] = { await StoreKitService.currentEntitlements() }) {
        self.productLoader = productLoader
        self.synchronize = synchronize
        self.entitlementLoader = entitlementLoader
        if startAutomatically { start() }
    }

    private func start() {
        transactionListener = listenForTransactions()
        // An unavailable catalog must never delay restoring an existing customer's access.
        Task { await checkSubscriptionStatus() }
        Task { await loadProducts() }
    }

    private static func currentEntitlements() async -> [Entitlement] {
        var entitlements: [Entitlement] = []
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.revocationDate == nil {
                entitlements.append(Entitlement(productID: transaction.productID,
                                                expiration: transaction.expirationDate))
            }
        }
        return entitlements
    }

    // MARK: - Load Products

    /// Fetch product metadata from the App Store.
    func loadProducts() async {
        guard !isLoadingProducts else { return }
        isLoadingProducts = true
        catalogError = nil
        defer { isLoadingProducts = false }
        do {
            let loaded = try await productLoader(Self.allProductIds)
            // Keep separately loaded vault products when retrying the feature catalog.
            products = (products.filter { !Self.allProductIds.contains($0.id) } + loaded)
                .sorted { $0.id < $1.id }
            if !Self.fieldAssistCatalogProductIds.isSubset(of: Set(loaded.map(\.id))) {
                catalogError = "Some Field Assist plans are unavailable. Check your connection and App Store sign-in, then retry."
            }
            PrivacyLog.purchase(.catalogLoaded, count: loaded.count)
            let generation = entitlementGeneration
            Task { await refreshRenewalInformation(generation: generation) }
        } catch {
            catalogError = "Unable to load purchases: \(error.localizedDescription)"
            PrivacyLog.purchase(.catalogFailed, error: SafeErrorSummary(error))
        }
    }

    // MARK: - Purchase

    /// Purchase any product in the catalog (a Medical Compliance subscription, or a Field Assist
    /// unlock or subscription); entitlement is re-derived from the receipt afterwards.
    func purchase(_ product: Product) async {
        guard !isPurchasing && !isRestoring else { return }
        isPurchasing = true
        purchaseError = nil
        restoreMessage = nil

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

    /// Check current entitlements for both the Medical Compliance subscription and Field Assist.
    ///
    /// The Field Assist result is recorded as entitlement *evidence* in `VerifiedStorePurchaseRecorder`
    /// — a process-local record of a verified, unrevoked transaction. `Config.fieldAssistPurchased` is
    /// still written, but only as a display mirror. This runs at launch and on every transaction
    /// update, and resolves against the on-device receipt, so it holds offline.
    func checkSubscriptionStatus() async {
        entitlementGeneration += 1
        let generation = entitlementGeneration
        let entitlements = await entitlementLoader()
        // A slower, older read must not overwrite the result of a purchase or restore.
        guard generation == entitlementGeneration else { return }
        let field = entitlements.filter { Self.fieldAssistProductIds.contains($0.productID) }
        let medical = entitlements.first { Self.medicalProductIds.contains($0.productID) }
        let packs = Set(entitlements.map(\.productID).filter { VaultPackManifest.isPackProductId($0) })

        // Commit evidence before publishing UI changes. A missing catalog is not a missing receipt.
        VerifiedStorePurchaseRecorder.shared.record(products: field.map { ($0.productID, $0.expiration) })
        VerifiedStorePurchaseRecorder.shared.recordPackProducts(packs)
        Config.setFieldAssistPurchased(!field.isEmpty)
        isFieldAssistPurchased = !field.isEmpty
        isMedicalComplianceActive = medical != nil
        subscriptionStatus = medical.map { subscriptionInfo(for: $0) }
        fieldAssistSubscription = field.filter { Self.fieldAssistSubscriptionIds.contains($0.productID) }
            .max { ($0.expiration ?? .distantFuture) < ($1.expiration ?? .distantFuture) }
            .map { subscriptionInfo(for: $0) }
        hasCheckedEntitlements = true
        Task { await refreshRenewalInformation(generation: generation) }
    }

    private func subscriptionInfo(for entitlement: Entitlement) -> SubscriptionInfo {
        SubscriptionInfo(productId: entitlement.productID, expirationDate: entitlement.expiration,
                         isInGracePeriod: false, willAutoRenew: true)
    }

    /// Renewal metadata can require a network request; access is already available before it runs.
    private func refreshRenewalInformation(generation: Int) async {
        for info in [subscriptionStatus, fieldAssistSubscription].compactMap({ $0 }) {
            guard let statuses = try? await product(for: info.productId)?.subscription?.status,
                  let status = statuses.first(where: {
                      if case .verified(let transaction) = $0.transaction { return transaction.productID == info.productId }
                      return false
                  }), case .verified(let renewal) = status.renewalInfo else { continue }
            guard generation == entitlementGeneration else { return }
            let updated = SubscriptionInfo(productId: info.productId, expirationDate: info.expirationDate,
                                           isInGracePeriod: status.state == .inGracePeriod,
                                           willAutoRenew: renewal.willAutoRenew)
            if Self.medicalProductIds.contains(info.productId) { subscriptionStatus = updated }
            else { fieldAssistSubscription = updated }
        }
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
    @discardableResult
    func restorePurchases() async -> Bool {
        guard !isRestoring && !isPurchasing else { return false }
        isRestoring = true
        purchaseError = nil
        restoreMessage = nil
        defer { isRestoring = false }
        do {
            try await synchronize()
            await checkSubscriptionStatus()
            restoreMessage = isFieldAssistPurchased
                ? "Field Assist purchases restored."
                : "No active Field Assist purchase was found for this App Store account."
            return true
        } catch {
            purchaseError = "Restore failed: \(error.localizedDescription)"
            return false
        }
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

    /// The Medical Compliance plans only, annual first. `products` holds every product the app
    /// sells, so a paywall that lists it directly shows Field Assist and pack products too.
    var medicalProducts: [Product] {
        let medical = products.filter { Self.medicalProductIds.contains($0.id) }
        return medical.sorted { lhs, _ in lhs.id == Self.medicalAnnualId }
    }

    /// The Field Assist monthly subscription product.
    var fieldAssistMonthlyProduct: Product? {
        products.first { $0.id == Self.fieldAssistMonthlyId }
    }

    /// The Field Assist annual subscription product.
    var fieldAssistAnnualProduct: Product? {
        products.first { $0.id == Self.fieldAssistAnnualId }
    }

    /// Whether the retired perpetual unlock is owned. Kept for grandfathered receipt handling.
    var ownsFieldAssistUnlock: Bool {
        VerifiedStorePurchaseRecorder.shared.allEvidence.contains {
            if case .verifiedStoreProduct(let id, _) = $0 { return id == Self.fieldAssistId }
            return false
        }
    }

    /// Whether the user can access Medical Compliance features.
    /// Requires an active verified subscription in every build configuration.
    var canAccessMedicalCompliance: Bool {
        return isMedicalComplianceActive
    }

    /// Manage subscription in the App Store (opens subscription management).
    func showManageSubscription() async {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }
        try? await AppStore.showManageSubscriptions(in: windowScene)
    }
}
