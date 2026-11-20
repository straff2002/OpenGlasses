import Security
import XCTest
@testable import OpenGlasses

/// Plan MM P2 — the connection to the business's own stock system: one device-only Keychain item
/// per system holding the key and every choice, the administrator's passcode on a managed phone,
/// the profile's keys, and the erasures (Remove, leaving the organisation, the office route).
@MainActor
final class StockSystemConnectionTests: XCTestCase {

    private typealias C = StockSystemConnectionSamples
    private var memory: MemoryStockSystemStorage!
    private var directory: URL!

    override func setUp() async throws {
        PolicyEnvelope.clear()
        memory = MemoryStockSystemStorage()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("StockSystemConnectionTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        PolicyEnvelope.clear()
        try? FileManager.default.removeItem(at: directory)
    }

    private func store(licensed: Bool = true) -> StockSystemConnectionStore {
        StockSystemConnectionStore(storage: memory.storage, connectorIDs: ["square"], licensed: { licensed })
    }

    private func service(_ connection: StockSystemConnectionStore) -> StockSystemService {
        StockSystemService(connection: connection, store: StockSystemSnapshotStore(directory: directory, connectorIDs: ["square"]),
                           medicalBlocks: { _ in false }, placeName: { nil }, makeConnector: { _, _, _ in nil })
    }

    // MARK: - One item: the key and the choices

    func testTheKeyAndItsChoicesRoundTripInOneItem() throws {
        let connection = store()
        let key = C.key()
        try connection.pasteKey(key, environment: .sandbox, administrator: false, hasSandbox: true)
        try connection.chooseLocations([C.main, C.van, C.main])
        try connection.setSendingBack(true)
        try connection.setReason(.waste)

        XCTAssertEqual(memory.items.keys.sorted(), ["stockSystemConnection.square"])
        let reread = store()
        let record = try XCTUnwrap(reread.record)
        XCTAssertEqual(record.key, key)
        XCTAssertEqual(record.environment, .sandbox)
        XCTAssertEqual(record.locationIDs, [C.main.id, C.van.id], "each location once")
        XCTAssertEqual(record.locations.first?.name, "Main Street")
        XCTAssertTrue(reread.sendingBack)
        XCTAssertEqual(reread.reason, .waste)
        XCTAssertNil(record.externalUserID, "kept for a system with jobs; unused by one without")
        XCTAssertEqual(reread.authorityConnection, StockSystemConnection(connectorID: "square", locationIDs: [C.main.id, C.van.id]))
        XCTAssertEqual(StockAuthority.resolve(officeRoute: reread.officeRoute, connection: reread.authorityConnection),
                       .system(connectorID: "square", locationIDs: [C.main.id, C.van.id]))
    }

    func testSendingBackIsOffUntilSomeoneTurnsItOn() throws {
        let connection = store()
        try connection.pasteKey(C.key(), environment: .production, administrator: false, hasSandbox: true)
        XCTAssertFalse(connection.sendingBack)
        XCTAssertNil(connection.reason)
    }

    func testANewKeyKeepsTheChoicesAndAnotherAccountStartsAgain() throws {
        let connection = store()
        try connection.pasteKey(C.key("a"), environment: .production, administrator: false, hasSandbox: true)
        let first = try XCTUnwrap(connection.record?.generation)
        try connection.chooseLocations([C.main])
        try connection.pasteKey(C.key("b"), environment: .production, administrator: false, hasSandbox: true)
        XCTAssertEqual(connection.record?.locationIDs, [C.main.id])
        XCTAssertNotEqual(connection.record?.generation, first, "a new key is a new generation")
        try connection.pasteKey(C.key("c"), environment: .sandbox, administrator: false, hasSandbox: true)
        XCTAssertEqual(connection.record?.locationIDs, [], "a sandbox is another account")
        XCTAssertThrowsError(try connection.pasteKey(C.key(), environment: .sandbox, administrator: false, hasSandbox: false)) {
            XCTAssertEqual($0 as? StockSystemConnectionError, .noSandbox)
        }
    }

    func testAKeyIsCheckedAndNeverDescribed() throws {
        let connection = store()
        for bad in ["", "two words", "line\nbreak"] {
            XCTAssertThrowsError(try connection.pasteKey(bad, environment: .production, administrator: false, hasSandbox: true)) {
                XCTAssertEqual($0 as? StockSystemConnectionError, .badKey)
            }
        }
        let key = C.key()
        try connection.pasteKey(key, environment: .production, administrator: false, hasSandbox: true)
        let record = try XCTUnwrap(connection.record)
        var dumped = ""
        dump(record, to: &dumped)
        for text in [String(describing: record), String(reflecting: record), dumped] {
            XCTAssertFalse(text.contains(key), text)
        }
        XCTAssertEqual(connection.keyEnding, String(key.suffix(4)))
    }

    func testAManagedPhoneNeedsTheAdministratorToPasteAKey() throws {
        PolicyEnvelope.install(.init(), organizationName: "Managed firm")
        let connection = store()
        XCTAssertThrowsError(try connection.pasteKey(C.key(), environment: .production, administrator: false, hasSandbox: true)) {
            XCTAssertEqual($0 as? StockSystemConnectionError, .notAllowed)
        }
        XCTAssertTrue(memory.items.isEmpty)
        try connection.pasteKey(C.key(), environment: .production, administrator: true, hasSandbox: true)
        XCTAssertNotNil(connection.record)
    }

    func testAnUnlicensedPhoneConnectsNothing() {
        let connection = store(licensed: false)
        XCTAssertThrowsError(try connection.pasteKey(C.key(), environment: .production, administrator: true, hasSandbox: true))
        XCTAssertFalse(connection.isRunning)
    }

    // MARK: - The profile

    func testTheProfileSetsAndLocksTheChoicesButNeverTheKey() throws {
        let connection = store()
        try connection.pasteKey(C.key(), environment: .production, administrator: false, hasSandbox: true)
        var result = ProfileApplier.Result()
        result.owned[.stockSystemSendBack] = .bool(true)
        result.owned[.stockSystemAdjustmentReason] = .string("waste")
        result.owned[.stockSystemConnector] = .string("square")
        PolicyEnvelope.install(result, organizationName: "Locked firm")
        XCTAssertTrue(connection.sendingBack)
        XCTAssertEqual(connection.reason, .waste)
        XCTAssertEqual(connection.selectedConnectorID, "square")
        XCTAssertThrowsError(try connection.setSendingBack(false)) { XCTAssertEqual($0 as? StockSystemConnectionError, .locked) }
        XCTAssertThrowsError(try connection.setReason(.damage)) { XCTAssertEqual($0 as? StockSystemConnectionError, .locked) }
        XCTAssertThrowsError(try connection.select("square")) { XCTAssertEqual($0 as? StockSystemConnectionError, .locked) }
        XCTAssertFalse(memory.items.values.contains { String(decoding: $0, as: UTF8.self).contains("\"sendingBack\":true") },
                       "the profile's value is read over the stored one, never written into it")

        result.owned[.stockSystemEnabled] = .bool(false)
        PolicyEnvelope.install(result, organizationName: "Locked firm")
        XCTAssertFalse(connection.isRunning, "a profile can switch the connection off")
        XCTAssertNil(connection.authorityConnection)
    }

    func testTheProfileKeysAreOwnedAndChecked() {
        XCTAssertEqual(SettingKey.stockSystemEnabled.kind, .profileOwned(.bool))
        XCTAssertEqual(SettingKey.stockSystemSendBack.kind, .profileOwned(.bool))
        XCTAssertEqual(SettingKey.stockSystemConnector.kind, .profileOwned(.string))
        XCTAssertEqual(SettingKey.stockSystemAdjustmentReason.kind, .profileOwned(.string))
        XCTAssertNil(SettingKey.stockSystemConnector.contentProblem(.string("square"), resolvableVaultIds: []))
        XCTAssertNotNil(SettingKey.stockSystemConnector.contentProblem(.string("simpro"), resolvableVaultIds: []),
                        "a system this build does not offer is a named drop")
        XCTAssertNil(SettingKey.stockSystemAdjustmentReason.contentProblem(.string("waste"), resolvableVaultIds: []))
        XCTAssertNotNil(SettingKey.stockSystemAdjustmentReason.contentProblem(.string("sale"), resolvableVaultIds: []))
        for key in [SettingKey.stockSystemEnabled, .stockSystemConnector, .stockSystemSendBack, .stockSystemAdjustmentReason] {
            XCTAssertNotEqual(key.ownedDescription, key.rawValue, "\(key.rawValue) reads as words on the review sheet")
        }
        // No profile key can carry a stock system's key or name its Keychain item.
        let settable = Set(SettingKey.allCases.map(\.rawValue))
        for id in StockSystemAdapterRegistry.connectorIDs {
            XCTAssertFalse(settable.contains(StockSystemConnectionStore.keychainAccount(id)))
        }
        XCTAssertFalse(settable.contains { $0.hasPrefix(StockSystemConnectionStore.keychainAccountPrefix) })
    }

    // MARK: - Erasing

    func testRemoveErasesTheKeyTheChoicesAndTheSnapshot() throws {
        let connection = store()
        let service = service(connection)
        try connection.pasteKey(C.key(), environment: .production, administrator: false, hasSandbox: true)
        try connection.chooseLocations([C.main])
        XCTAssertTrue(service.store.replace(C.snapshot()))
        service.remove()
        XCTAssertTrue(memory.items.isEmpty)
        XCTAssertNil(connection.record)
        XCTAssertNil(service.snapshot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.store.currentURL("square").path))
    }

    func testLeavingTheOrganisationErasesEveryConnection() throws {
        let connection = store()
        let service = service(connection)
        try connection.pasteKey(C.key(), environment: .production, administrator: false, hasSandbox: true)
        XCTAssertTrue(service.store.replace(C.snapshot()))
        service.removeAll()
        XCTAssertTrue(memory.items.isEmpty)
        XCTAssertTrue(service.store.snapshots.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.store.folder.path))
    }

    func testTheOfficeRouteErasesTheKeyAndRetiresTheSnapshot() throws {
        let connection = store()
        let service = service(connection)
        try connection.pasteKey(C.key(), environment: .production, administrator: false, hasSandbox: true)
        try connection.chooseLocations([C.main])
        XCTAssertTrue(service.store.replace(C.snapshot()))

        var result = ProfileApplier.Result()
        result.ceilings[.organizationFieldServiceRoute] = .string("office")
        PolicyEnvelope.install(result, organizationName: "Office firm")
        XCTAssertFalse(connection.isRunning)
        XCTAssertThrowsError(try connection.pasteKey(C.key(), environment: .production, administrator: true, hasSandbox: true))
        service.enforceRoute()
        XCTAssertTrue(memory.items.isEmpty)
        XCTAssertNil(service.snapshot)
        XCTAssertEqual(StockAuthority.resolve(officeRoute: connection.officeRoute, connection: connection.authorityConnection), .phone)
    }

    func testAnEraseTheLockedPhoneRefusesIsRetriedAndNeverReadMeanwhile() throws {
        let connection = store()
        try connection.pasteKey(C.key(), environment: .production, administrator: false, hasSandbox: true)
        memory.eraseFails = true
        XCTAssertThrowsError(try connection.remove("square"))
        XCTAssertNil(connection.record, "the connection stops at once")
        XCTAssertNotNil(connection.problem)
        XCTAssertEqual(memory.pendingErase, ["square"])
        XCTAssertFalse(memory.items.isEmpty)

        // The next launch, still locked: the item is not read back.
        XCTAssertNil(store().record)
        // Unlocked: the erase finishes.
        memory.eraseFails = false
        XCTAssertNil(store().record)
        XCTAssertTrue(memory.items.isEmpty)
        XCTAssertEqual(memory.pendingErase, [])
    }

    // MARK: - The real Keychain

    /// The item is written to the Keychain as `…AfterFirstUnlockThisDeviceOnly`, so it never reaches
    /// a backup or another device, and the diagnostics redactor knows the key while it is there.
    func testTheKeychainItemIsDeviceOnlyAndKnownToTheRedactor() throws {
        let id = "stocktest\(UInt32.random(in: 0...UInt32.max))"
        let account = StockSystemConnectionStore.keychainAccount(id)
        defer {
            try? KeychainService.deleteItem(account)
            UserDefaults.standard.removeObject(forKey: StockSystemConnectionStore.selectedConnectorKey)
            UserDefaults.standard.removeObject(forKey: StockSystemConnectionStore.pendingEraseKey)
        }
        let connection = StockSystemConnectionStore(connectorIDs: [id], licensed: { true })
        try connection.select(id)
        let key = C.key("k")
        try connection.pasteKey(key, environment: .production, administrator: false, hasSandbox: false)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainService.storageService,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertNotEqual(attributes[kSecAttrSynchronizable as String] as? Bool, true)
        XCTAssertEqual(StockSystemConnectionStore.knownKeys(connectorIDs: [id]), [key])

        try connection.remove(id)
        XCTAssertNil(try KeychainService.readData(for: account))
        XCTAssertEqual(StockSystemConnectionStore.knownKeys(connectorIDs: [id]), [])
    }

    /// The key stored for an offered system is one of the app's known secrets, so a support report
    /// or a diagnostics export masks it wherever it turns up.
    func testAStoredKeyIsMaskedInDiagnostics() throws {
        let account = StockSystemConnectionStore.keychainAccount("square")
        let existing = try KeychainService.readData(for: account)
        defer {
            if let existing {
                try? KeychainService.upsertDataAtomically(existing, for: account, accessibility: .afterFirstUnlockThisDeviceOnly)
            } else {
                try? KeychainService.deleteItem(account)
            }
        }
        let key = C.key("d")
        let record = StockSystemConnectionRecord(connectorID: "square", key: key, environment: .production)
        try KeychainService.upsertDataAtomically(try JSONEncoder().encode(record), for: account,
                                                 accessibility: .afterFirstUnlockThisDeviceOnly)
        XCTAssertTrue(Config.knownSecretValues.contains(key))
        let (redacted, _) = DiagnosticsRedactor.redact("pull failed with \(key) in the line", extraSecrets: Config.knownSecretValues)
        XCTAssertFalse(redacted.contains(key))
    }

    // MARK: - What the key needs

    func testTheKeysPermissionsComeFromTheAdapter() {
        let adapter = SquareStockAdapter()
        XCTAssertEqual(StockSystemKeyPermissions.reading(adapter), ["MERCHANT_PROFILE_READ", "ITEMS_READ", "INVENTORY_READ"])
        XCTAssertEqual(StockSystemKeyPermissions.sendingBack(adapter), ["INVENTORY_WRITE"])
        XCTAssertEqual(StockSystemAdapterRegistry.connectorIDs, ["square"], "Square only; Simpro is not offered")
        XCTAssertFalse(C.square.keySteps.isEmpty)
    }
}
