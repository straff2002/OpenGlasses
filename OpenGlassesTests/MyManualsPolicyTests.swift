import StoreKit
import StoreKitTest
import XCTest
@testable import OpenGlasses

@MainActor
final class MyManualsPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 100)
    private func personal(_ expiry: Date? = nil) -> FieldAssistEntitlementEvidence {
        .verifiedStoreProduct(productID: StoreKitService.myManualsMonthlyId, expiration: expiry)
    }

    func testUploadIsVisibleBeforePersonalPurchaseAndNeverRequiresFieldAssist() {
        for owned in [false, true] {
            let page = MyManualsPagePolicy(restricted: false, medical: false, ownsManuals: owned)
            XCTAssertTrue(page.showsUpload)
            XCTAssertEqual(page.requiresPurchase, !owned)
        }
        XCTAssertFalse(MyManualsPagePolicy(restricted: true, medical: false, ownsManuals: true).showsUpload)
        XCTAssertFalse(MyManualsPagePolicy(restricted: false, medical: true, ownsManuals: true).showsUpload)
    }

    func testPersonalSubscriptionManagesManualsWithFieldAssistSwitchedOff() {
        let previous = EntitlementTestScope.grant(tier: .personal)
        let field = UserDefaults.standard.object(forKey: "fieldAssistEnabled")
        defer {
            EntitlementTestScope.restore(previous)
            UserDefaults.standard.set(field, forKey: "fieldAssistEnabled")
        }
        UserDefaults.standard.set(false, forKey: "fieldAssistEnabled")
        XCTAssertTrue(PersonalManualLibrary.canManage)
        XCTAssertFalse(Config.fieldAssistActive)
        XCTAssertFalse(FieldAssistEntitlement.shared.has(.fieldWork))
        XCTAssertEqual(StoreKitService.myManualsCatalogProductIds,
                       [StoreKitService.myManualsMonthlyId])
    }

    func testSubscriptionsGrantIndependentAccessAndExpireIndependently() {
        let professional = FieldAssistEntitlementEvidence.verifiedStoreProduct(
            productID: StoreKitService.fieldAssistMonthlyId, expiration: now.addingTimeInterval(100))
        let personal = personal(now.addingTimeInterval(50))
        let previous = FieldAssistEntitlement.shared.provider
        let previousClock = FieldAssistEntitlement.shared.clock
        defer { FieldAssistEntitlement.shared.provider = previous; FieldAssistEntitlement.shared.clock = previousClock }
        FieldAssistEntitlement.shared.provider = StubEntitlementProvider(.init(evidence: [professional]))
        FieldAssistEntitlement.shared.clock = { Date(timeIntervalSince1970: 100) }
        XCTAssertTrue(FieldAssistEntitlement.shared.has(.ownVaults))
        XCTAssertFalse(PersonalManualLibrary.canManage)
        FieldAssistEntitlement.shared.provider = StubEntitlementProvider(.init(evidence: [personal]))
        XCTAssertTrue(PersonalManualLibrary.canManage)
        XCTAssertFalse(FieldAssistEntitlement.shared.has(.ownVaults))
        XCTAssertFalse(CustomVaultGateState.current().allowsImport)
        FieldAssistEntitlement.shared.provider = StubEntitlementProvider(.init(evidence: [personal, professional]))
        XCTAssertTrue(PersonalManualLibrary.canManage)
        XCTAssertTrue(CustomVaultGateState.current().allowsImport)
        XCTAssertEqual(FieldAssistEntitlement.shared.manualLimits(), .personal)
        FieldAssistEntitlement.shared.clock = { Date(timeIntervalSince1970: 150) }
        XCTAssertFalse(PersonalManualLibrary.canManage)
        XCTAssertTrue(CustomVaultGateState.current().allowsImport)
        FieldAssistEntitlement.shared.provider = StubEntitlementProvider(.init(evidence: [personal]))
        FieldAssistEntitlement.shared.clock = { Date(timeIntervalSince1970: 100) }
        XCTAssertTrue(PersonalManualLibrary.canManage)
        XCTAssertFalse(FieldAssistEntitlement.shared.has(.fieldWork))
    }

    func testStoreKeepsBothSubscriptionStatusesAndPersonalDoesNotSetFieldPurchase() async {
        let previous = VerifiedStorePurchaseRecorder.shared.allEvidence
        defer { VerifiedStorePurchaseRecorder.shared.record(products: previous.compactMap {
            if case .verifiedStoreProduct(let id, let expiry) = $0 { return (id, expiry) }; return nil
        }) }
        let personalOnly = StoreKitService(startAutomatically: false, entitlementLoader: {
            [.init(productID: StoreKitService.myManualsMonthlyId, expiration: nil)]
        })
        await personalOnly.checkSubscriptionStatus()
        XCTAssertFalse(personalOnly.isFieldAssistPurchased)
        XCTAssertNotNil(personalOnly.myManualsSubscription)
        XCTAssertNil(personalOnly.fieldAssistSubscription)
        let both = StoreKitService(startAutomatically: false, entitlementLoader: {
            [.init(productID: StoreKitService.myManualsMonthlyId, expiration: nil),
             .init(productID: StoreKitService.fieldAssistMonthlyId, expiration: nil)]
        })
        await both.checkSubscriptionStatus()
        XCTAssertTrue(both.isFieldAssistPurchased)
        XCTAssertNotNil(both.myManualsSubscription)
        XCTAssertNotNil(both.fieldAssistSubscription)
        XCTAssertEqual(VerifiedStorePurchaseRecorder.shared.allEvidence.count, 2)
    }

    func testUnavailablePersonalCatalogIsReportedInsteadOfSubscriptionManagementFallback() async {
        var requested = Set<String>()
        let store = StoreKitService(startAutomatically: false, productLoader: { ids in requested = ids; return [] })
        await store.loadProducts()
        XCTAssertTrue(StoreKitService.myManualsCatalogProductIds.isSubset(of: requested))
        XCTAssertNotNil(store.myManualsCatalogError)
        XCTAssertTrue(store.myManualsProducts.isEmpty)
    }

    func testPersonalEvidenceAndMixedLimits() {
        XCTAssertEqual(FieldAssistCapability.capabilities(for: personal()), [.personalManuals])
        XCTAssertEqual(personal().tier, .personal)
        XCTAssertLessThan(FieldAssistTier.personal, .solo)
        let legacy = FieldAssistEntitlementEvidence.verifiedStoreProduct(productID: StoreKitService.fieldAssistId, expiration: nil)
        XCTAssertEqual(ManualLimits.resolve(.init(evidence: [personal(), legacy]), now: now), .personal)
        let lapsed = FieldAssistEntitlementEvidence.verifiedStoreProduct(productID: StoreKitService.fieldAssistAnnualId, expiration: now)
        XCTAssertEqual(ManualLimits.resolve(.init(evidence: [personal(), lapsed]), now: now), .personal)
        let team = FieldAssistEntitlementEvidence.verifiedOrganizationLicense(licenseIDHash: "team", expiration: nil, tier: .team)
        XCTAssertEqual(ManualLimits.resolve(.init(evidence: [personal(), team]), now: now), .personal)
        XCTAssertTrue(FieldAssistCapability.capabilities(for: .init(evidence: [personal(now)]), now: now).isEmpty)
        XCTAssertFalse(VaultPackAccess.isUnlocked(productId: "pack", licensePack: "pack", purchasedProducts: ["pack"],
                                                 licensedPacks: [], capabilities: [.ownVaults]))
    }

    func testPersonalModeNeverStartsAJobOrShowsAnUpsellShortcut() {
        for enabled in [true, false] {
            for restricted in [true, false] {
                let input = FieldAssistMode.Inputs(switchOn: enabled, entitled: false, entitlementChecked: true,
                                                   restricted: restricted, personalManuals: true)
                XCTAssertFalse(FieldAssistMode.isOn(input))
                XCTAssertEqual(ModesTabPresentation.resolve(input), restricted ? .hidden : .modes(shortcut: nil))
            }
        }
    }

    func testQuotaCountsReplacementsAndDowngradesWithoutDeletingOrBlockingCleanup() {
        let limits = ManualLimits(manuals: 5, pagesPerManual: 100, totalPages: 300)
        let held = (0..<5).map { ManualQuota.Item(id: "\($0)", pages: 20) }
        XCTAssertEqual(ManualQuota.decide(limits: limits, held: held, adding: [.init(id: "six", pages: 20)]),
                       .wouldExceed(measure: .manuals, held: 5, adding: 1, limit: 5))
        XCTAssertEqual(ManualQuota.decide(limits: limits, held: held, replacing: ["0"], adding: [held[0]]), .allowed)
        let over = held + [.init(id: "six", pages: 20)]
        XCTAssertEqual(ManualQuota.decide(limits: limits, held: over, replacing: ["0"], adding: [held[0]]), .allowed)
        XCTAssertEqual(ManualQuota.decide(limits: limits, held: over, replacing: ["six"], adding: []), .allowed)
        XCTAssertEqual(ManualQuota.decide(limits: limits, held: held, replacing: ["0"], adding: [.init(id: "0", pages: 101)]),
                       .wouldExceed(measure: .pagesPerManual, held: 20, adding: 81, limit: 100))
        XCTAssertEqual(ManualQuota.decide(limits: .init(manuals: 5, pagesPerManual: 200, totalPages: 100),
                                          held: held, replacing: ["0"], adding: [.init(id: "0", pages: 21)]),
                       .wouldExceed(measure: .totalPages, held: 100, adding: 1, limit: 100))
        XCTAssertEqual(ManualQuota.decide(limits: limits, held: [.init(id: "old", pages: nil)], adding: []), .unavailable)
    }

    func testMeasuredWorkshopSetFitsAndBothPageCeilingsAreEnforced() {
        let repair = ManualQuota.Item(id: "repair", pages: 7_595)
        let wiring = (0..<4).map { ManualQuota.Item(id: "wiring-\($0)", pages: 466) }
        XCTAssertEqual(ManualQuota.decide(limits: .personal, held: [], adding: [repair] + wiring), .allowed)
        XCTAssertEqual(ManualQuota.decide(limits: .personal, held: [], adding: [.init(id: "oversized", pages: 8_001)]),
                       .wouldExceed(measure: .pagesPerManual, held: 0, adding: 8_001, limit: 8_000))
        XCTAssertEqual(ManualQuota.decide(limits: .personal, held: [repair], adding: [.init(id: "second", pages: 2_406)]),
                       .wouldExceed(measure: .totalPages, held: 7_595, adding: 2_406, limit: 10_000))
    }

    func testSessionAndMedicalContextsNeverFallBackToLibrary() {
        for restricted in [true, false] {
            XCTAssertEqual(ManualSource.resolve(fieldActive: true, restricted: restricted, medical: false,
                                                sessionAvailable: false, ownManuals: true, libraryAvailable: true),
                           .denied("Start a Field Assist session to use its manuals."))
        }
        XCTAssertEqual(ManualSource.resolve(fieldActive: false, restricted: false, medical: false,
                                            sessionAvailable: false, ownManuals: true, libraryAvailable: true), .library)
        guard case .denied = ManualSource.resolve(fieldActive: false, restricted: false, medical: true,
                                                  sessionAvailable: false, ownManuals: true, libraryAvailable: true)
        else { return XCTFail("medical context admitted personal content") }
    }

    func testLocalModelsReceiveManualToolsOnlyForAnAvailableLibrary() {
        let manualTools = ["manual_lookup", "table_lookup", "manual_figure", "show_source"]
        XCTAssertTrue(LLMService.localToolNames(registered: manualTools, offlineHandoff: false).isEmpty)
        XCTAssertEqual(LLMService.localToolNames(registered: manualTools, offlineHandoff: true, libraryHasManuals: true), manualTools)
        XCTAssertEqual(AppleOnDeviceToolSet.priorityNames(registered: manualTools, fieldAssistActive: false,
            offlineHandoff: true, libraryHasManuals: true), ["table_lookup", "manual_figure", "show_source"])
    }

    func testLibraryAnswerSwitchDoesNotDisableProfessionalManualTools() {
        let old = EntitlementTestScope.grant()
        let field = UserDefaults.standard.object(forKey: "fieldAssistEnabled")
        let answers = Config.myManualsEnabled
        defer {
            EntitlementTestScope.restore(old)
            if let field { UserDefaults.standard.set(field, forKey: "fieldAssistEnabled") }
            else { UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled") }
            Config.myManualsEnabled = answers
        }
        Config.myManualsEnabled = false
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        XCTAssertFalse(AIFeatureGate.isToolDisabled("manual_lookup"))
        UserDefaults.standard.set(false, forKey: "fieldAssistEnabled")
        XCTAssertEqual(AIFeatureGate.disabledFeature(forTool: "manual_lookup"), .myManuals)
    }

    func testStoreRefreshRecognisesPersonalWithoutProfessionalPurchase() async {
        let previous = VerifiedStorePurchaseRecorder.shared.allEvidence
        defer {
            VerifiedStorePurchaseRecorder.shared.record(products: previous.compactMap {
                if case .verifiedStoreProduct(let id, let expiry) = $0 { return (id, expiry) }
                return nil
            })
        }
        let store = StoreKitService(startAutomatically: false, entitlementLoader: {
            [.init(productID: StoreKitService.myManualsAnnualId, expiration: Date().addingTimeInterval(86_400))]
        })
        await store.checkSubscriptionStatus()
        XCTAssertEqual(VerifiedStorePurchaseRecorder.shared.allEvidence.first?.tier, .personal)
        XCTAssertNotNil(store.myManualsSubscription)
        XCTAssertNil(store.fieldAssistSubscription)
    }
}


@MainActor
final class MyManualsStoreKitCatalogTests: XCTestCase {
    func testLocalCatalogLoadsTheOfferedPersonalMonthlyProduct() async throws {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else {
            throw XCTSkip("StoreKit integration requires Xcode's app-host test launch; the direct resource runner has no StoreKit app identity.")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let session = try SKTestSession(contentsOf: root.appendingPathComponent("OpenGlasses/MedicalCompliance.storekit"))
        session.disableDialogs = true
        defer { session.resetToDefaultState() }
        let store = StoreKitService(startAutomatically: false)
        await store.loadProducts()
        XCTAssertNil(store.myManualsCatalogError)
        XCTAssertEqual(store.myManualsProducts.map(\.id), [StoreKitService.myManualsMonthlyId])
        let personal = try XCTUnwrap(store.myManualsProducts.first)
        XCTAssertGreaterThan(personal.price, 0)
        let field = try XCTUnwrap(store.products.first { $0.id == StoreKitService.fieldAssistMonthlyId })
        // Plan NH decision 7: one ladder — Standard, then My Manuals, then Field Assist solo — so
        // moving up or down prorates. Level 1 is the highest in StoreKit.
        XCTAssertEqual(personal.subscription?.subscriptionGroupID, field.subscription?.subscriptionGroupID)
        let personalLevel = try XCTUnwrap(personal.subscription?.groupLevel)
        let fieldLevel = try XCTUnwrap(field.subscription?.groupLevel)
        XCTAssertLessThan(fieldLevel, personalLevel, "Field Assist sits above My Manuals")
    }

    /// Plan NH: Standard loads with the catalog, monthly and annual, with no free trial (decision
    /// 13), at the bottom of the same ladder. Medical Compliance stays a group of its own.
    func testLocalCatalogLoadsStandardAtTheBottomOfTheLadderWithNoTrial() async throws {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else {
            throw XCTSkip("StoreKit integration requires Xcode's app-host test launch; the direct resource runner has no StoreKit app identity.")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let session = try SKTestSession(contentsOf: root.appendingPathComponent("OpenGlasses/MedicalCompliance.storekit"))
        session.disableDialogs = true
        defer { session.resetToDefaultState() }
        let store = StoreKitService(startAutomatically: false)
        await store.loadProducts()
        XCTAssertNil(store.standardCatalogError)
        XCTAssertEqual(store.standardProducts.map(\.id),
                       [StoreKitService.standardMonthlyId, StoreKitService.standardAnnualId])
        for product in store.standardProducts {
            XCTAssertGreaterThan(product.price, 0, product.id)
            XCTAssertNil(product.subscription?.introductoryOffer, "\(product.id): no free trial on Standard")
        }
        let standard = try XCTUnwrap(store.standardProducts.first)
        let personal = try XCTUnwrap(store.myManualsProducts.first)
        let medical = try XCTUnwrap(store.products.first { $0.id == StoreKitService.medicalMonthlyId })
        XCTAssertEqual(standard.subscription?.subscriptionGroupID, personal.subscription?.subscriptionGroupID)
        XCTAssertNotEqual(standard.subscription?.subscriptionGroupID, medical.subscription?.subscriptionGroupID)
        let standardLevel = try XCTUnwrap(standard.subscription?.groupLevel)
        let personalLevel = try XCTUnwrap(personal.subscription?.groupLevel)
        XCTAssertGreaterThan(standardLevel, personalLevel, "Standard is the lowest level")
    }
}
