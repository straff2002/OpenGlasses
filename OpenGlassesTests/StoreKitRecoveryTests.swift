import XCTest
import StoreKit
@testable import OpenGlasses

@MainActor
final class StoreKitRecoveryTests: XCTestCase {
    private var previousEvidence: [FieldAssistEntitlementEvidence] = []
    private var previousPacks: Set<String> = []
    private var previousMirror: Any?

    override func setUp() {
        super.setUp()
        previousEvidence = VerifiedStorePurchaseRecorder.shared.allEvidence
        previousPacks = VerifiedStorePurchaseRecorder.shared.packProductIds
        previousMirror = UserDefaults.standard.object(forKey: "fieldAssistPurchased")
    }

    override func tearDown() {
        VerifiedStorePurchaseRecorder.shared.record(products: previousEvidence.compactMap {
            if case .verifiedStoreProduct(let id, let expiration) = $0 { return (id, expiration) }
            return nil
        })
        VerifiedStorePurchaseRecorder.shared.recordPackProducts(previousPacks)
        if let previousMirror { UserDefaults.standard.set(previousMirror, forKey: "fieldAssistPurchased") }
        else { UserDefaults.standard.removeObject(forKey: "fieldAssistPurchased") }
        super.tearDown()
    }

    private enum Offline: LocalizedError {
        case unavailable
        var errorDescription: String? { "Test connection unavailable" }
    }

    func testCatalogFailureCanBeRetriedAndEmptyResultIsExplained() async {
        var attempts = 0
        let store = StoreKitService(startAutomatically: false, productLoader: { _ in
            attempts += 1
            if attempts == 1 { throw Offline.unavailable }
            return []
        }, entitlementLoader: { [] })
        await store.loadProducts()
        XCTAssertTrue(store.catalogError?.contains("Test connection unavailable") == true)
        XCTAssertFalse(store.isLoadingProducts)
        await store.loadProducts()
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(store.catalogError?.contains("plans are unavailable") == true)
        XCTAssertFalse(store.isLoadingProducts)
    }

    func testLegacyPurchaseUnlocksWhileCatalogIsStillLoading() async {
        var finishLoading: CheckedContinuation<[Product], Error>?
        let store = StoreKitService(startAutomatically: false, productLoader: { _ in
            try await withCheckedThrowingContinuation { finishLoading = $0 }
        }, entitlementLoader: {
            [.init(productID: StoreKitService.fieldAssistId, expiration: nil)]
        })
        XCTAssertFalse(store.hasCheckedEntitlements, "Unknown must not be treated as a confirmed missing purchase")
        let loading = Task { await store.loadProducts() }
        while finishLoading == nil { await Task.yield() }
        await store.checkSubscriptionStatus()
        XCTAssertTrue(store.isLoadingProducts)
        XCTAssertTrue(store.hasCheckedEntitlements)
        XCTAssertTrue(store.isFieldAssistPurchased)
        XCTAssertTrue(store.ownsFieldAssistUnlock)
        let decision = FieldAssistEntitlementEvaluator.decide(
            LiveFieldAssistEntitlementProvider(licenseCode: { nil }).evidence())
        XCTAssertTrue(decision.isGranted)
        XCTAssertNil(decision.expiresAt)
        finishLoading?.resume(returning: [])
        await loading.value
    }

    func testFailedRestoreReportsErrorWithoutClearingVerifiedPurchase() async {
        let store = StoreKitService(startAutomatically: false,
            synchronize: { throw Offline.unavailable }, entitlementLoader: {
                [.init(productID: StoreKitService.fieldAssistId, expiration: nil)]
            })
        await store.checkSubscriptionStatus()
        let restored = await store.restorePurchases()
        XCTAssertFalse(restored)
        XCTAssertTrue(store.purchaseError?.contains("Restore failed") == true)
        XCTAssertTrue(store.isFieldAssistPurchased)
        XCTAssertTrue(store.ownsFieldAssistUnlock)
        XCTAssertNil(store.restoreMessage)
        XCTAssertFalse(store.isRestoring)
    }

    func testSuccessfulRestoreRefreshesAccessAndClearsPreviousError() async {
        var failSync = true
        var entitlements: [StoreKitService.Entitlement] = []
        let store = StoreKitService(startAutomatically: false, synchronize: {
            if failSync { throw Offline.unavailable }
            entitlements = [.init(productID: StoreKitService.fieldAssistId, expiration: nil)]
        }, entitlementLoader: { entitlements })
        _ = await store.restorePurchases()
        failSync = false
        let restored = await store.restorePurchases()
        XCTAssertTrue(restored)
        XCTAssertNil(store.purchaseError)
        XCTAssertTrue(store.isFieldAssistPurchased)
        XCTAssertEqual(store.restoreMessage, "Field Assist purchases restored.")
        XCTAssertFalse(store.isRestoring)
    }

    func testEmptyRestoreIsDistinctFromFailure() async {
        let store = StoreKitService(startAutomatically: false, synchronize: {}, entitlementLoader: { [] })
        let restored = await store.restorePurchases()
        XCTAssertTrue(restored)
        XCTAssertTrue(store.hasCheckedEntitlements)
        XCTAssertFalse(store.isFieldAssistPurchased)
        XCTAssertNil(store.purchaseError)
        XCTAssertTrue(store.restoreMessage?.contains("No active Field Assist purchase") == true)
    }

    func testAbsentEntitlementClearsPreviouslyVerifiedPurchase() async {
        var entitlements: [StoreKitService.Entitlement] = [
            .init(productID: StoreKitService.fieldAssistId, expiration: nil)
        ]
        let store = StoreKitService(startAutomatically: false, entitlementLoader: { entitlements })
        await store.checkSubscriptionStatus()
        XCTAssertTrue(store.ownsFieldAssistUnlock)
        entitlements = []
        await store.checkSubscriptionStatus()
        XCTAssertFalse(store.isFieldAssistPurchased)
        XCTAssertFalse(store.ownsFieldAssistUnlock)
        XCTAssertTrue(store.hasCheckedEntitlements)
    }

    func testRepeatedRestoreDoesNotStartAnotherSync() async {
        var finishSync: CheckedContinuation<Void, Never>?
        var syncCount = 0
        let store = StoreKitService(startAutomatically: false, synchronize: {
            syncCount += 1
            await withCheckedContinuation { finishSync = $0 }
        }, entitlementLoader: { [] })
        let first = Task { await store.restorePurchases() }
        while finishSync == nil { await Task.yield() }
        XCTAssertTrue(store.isRestoring)
        let second = await store.restorePurchases()
        XCTAssertFalse(second)
        XCTAssertEqual(syncCount, 1)
        finishSync?.resume()
        let restored = await first.value
        XCTAssertTrue(restored)
        XCTAssertFalse(store.isRestoring)
    }

    func testOlderEntitlementReadCannotOverwriteNewerPurchase() async {
        var finishFirstRead: CheckedContinuation<[StoreKitService.Entitlement], Never>?
        var reads = 0
        let store = StoreKitService(startAutomatically: false, entitlementLoader: {
            reads += 1
            if reads == 1 {
                return await withCheckedContinuation { finishFirstRead = $0 }
            }
            return [.init(productID: StoreKitService.fieldAssistId, expiration: nil)]
        })
        let first = Task { await store.checkSubscriptionStatus() }
        while finishFirstRead == nil { await Task.yield() }
        await store.checkSubscriptionStatus()
        finishFirstRead?.resume(returning: [])
        await first.value
        XCTAssertTrue(store.isFieldAssistPurchased)
        XCTAssertTrue(store.ownsFieldAssistUnlock)
    }
}
