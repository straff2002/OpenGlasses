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

    /// All known product identifiers.
    private static let allProductIds: Set<String> = [
        medicalMonthlyId,
        medicalAnnualId
    ]

    /// Subscription group name (must match App Store Connect).
    static let subscriptionGroupId = "medical_compliance"

    // MARK: - Published State

    /// Loaded products from the App Store.
    @Published private(set) var products: [Product] = []

    /// Whether the user has an active Medical Compliance subscription.
    @Published private(set) var isMedicalComplianceActive = false

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
            productId == StoreKitService.medicalAnnualId ? "Annual" : "Monthly"
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
            NSLog("[StoreKit] Loaded %d products", products.count)
        } catch {
            NSLog("[StoreKit] Failed to load products: %@", error.localizedDescription)
        }
    }

    // MARK: - Purchase

    /// Purchase a Medical Compliance subscription.
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
                NSLog("[StoreKit] Medical Compliance subscription activated: %@", product.id)

            case .userCancelled:
                NSLog("[StoreKit] Purchase cancelled by user")

            case .pending:
                NSLog("[StoreKit] Purchase pending (Ask to Buy, etc.)")
                purchaseError = "Purchase is pending approval."

            @unknown default:
                NSLog("[StoreKit] Unknown purchase result")
            }
        } catch {
            purchaseError = "Purchase failed: \(error.localizedDescription)"
            NSLog("[StoreKit] Purchase failed: %@", error.localizedDescription)
        }

        isPurchasing = false
    }

    // MARK: - Subscription Status

    /// Check current subscription entitlements.
    func checkSubscriptionStatus() async {
        var foundActive = false

        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                let isMedical = Self.allProductIds.contains(transaction.productID)
                guard isMedical else { continue }

                if transaction.revocationDate == nil {
                    foundActive = true

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
                }
            }
        }

        isMedicalComplianceActive = foundActive
        if !foundActive {
            subscriptionStatus = nil
        }
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
