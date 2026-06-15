import XCTest
@testable import OpenGlasses

final class KeychainServiceTests: XCTestCase {

    // A key unlikely to collide with any real secret.
    private let testKey = "test.keychain.roundtrip"

    override func setUp() {
        super.setUp()
        KeychainService.delete(testKey)
    }

    override func tearDown() {
        KeychainService.delete(testKey)
        super.tearDown()
    }

    // MARK: - String round-trip

    func testStringRoundTrip() {
        XCTAssertNil(KeychainService.string(for: testKey))
        XCTAssertTrue(KeychainService.setString("sk-secret-123", for: testKey))
        XCTAssertEqual(KeychainService.string(for: testKey), "sk-secret-123")
    }

    func testOverwriteReplacesValue() {
        KeychainService.setString("first", for: testKey)
        KeychainService.setString("second", for: testKey)
        XCTAssertEqual(KeychainService.string(for: testKey), "second")
    }

    func testEmptyStringDeletesItem() {
        KeychainService.setString("value", for: testKey)
        XCTAssertTrue(KeychainService.setString("", for: testKey))
        XCTAssertNil(KeychainService.string(for: testKey))
    }

    func testNilStringDeletesItem() {
        KeychainService.setString("value", for: testKey)
        XCTAssertTrue(KeychainService.setString(nil, for: testKey))
        XCTAssertNil(KeychainService.string(for: testKey))
    }

    // MARK: - Data round-trip

    func testDataRoundTrip() {
        let payload = Data("{\"k\":\"v\"}".utf8)
        XCTAssertNil(KeychainService.data(for: testKey))
        XCTAssertTrue(KeychainService.setData(payload, for: testKey))
        XCTAssertEqual(KeychainService.data(for: testKey), payload)
    }

    func testEmptyDataDeletesItem() {
        KeychainService.setData(Data("x".utf8), for: testKey)
        XCTAssertTrue(KeychainService.setData(Data(), for: testKey))
        XCTAssertNil(KeychainService.data(for: testKey))
    }

    // MARK: - Delete

    func testDeleteMissingKeySucceeds() {
        XCTAssertTrue(KeychainService.delete(testKey))
    }
}

final class SecretMigrationTests: XCTestCase {

    private let migrationFlagKey = "secretsMigratedToKeychain_v1"
    // A real migratable string secret, exercised end-to-end through Config.
    private let secretKey = "broadcastStreamKey"

    override func setUp() {
        super.setUp()
        resetState()
    }

    override func tearDown() {
        resetState()
        // Leave the flag set so the host app's already-migrated state is respected.
        UserDefaults.standard.set(true, forKey: migrationFlagKey)
        super.tearDown()
    }

    private func resetState() {
        UserDefaults.standard.removeObject(forKey: migrationFlagKey)
        UserDefaults.standard.removeObject(forKey: secretKey)
        KeychainService.delete(secretKey)
    }

    /// A plaintext secret in UserDefaults is copied into the Keychain and then
    /// removed from UserDefaults, and remains readable through the Config getter.
    func testMigrationMovesPlaintextSecretToKeychain() {
        UserDefaults.standard.set("rtmp-stream-key", forKey: secretKey)

        Config.migrateSecretsToKeychainIfNeeded()

        XCTAssertNil(UserDefaults.standard.string(forKey: secretKey),
                     "plaintext copy should be removed from UserDefaults")
        XCTAssertEqual(KeychainService.string(for: secretKey), "rtmp-stream-key",
                       "secret should now live in the Keychain")
        XCTAssertEqual(Config.broadcastStreamKey, "rtmp-stream-key",
                       "Config getter should read the migrated value transparently")
    }

    /// Migration runs only once — re-running after the flag is set is a no-op and
    /// must not clobber a value written through the normal (Keychain) setter.
    func testMigrationIsOneTime() {
        Config.migrateSecretsToKeychainIfNeeded()   // sets the flag, nothing to migrate

        // Simulate a later write via the public setter (goes straight to Keychain),
        // plus a stray plaintext value that a second migration must NOT pick up.
        Config.setBroadcastStreamKey("written-via-setter")
        UserDefaults.standard.set("stale-plaintext", forKey: secretKey)

        Config.migrateSecretsToKeychainIfNeeded()   // flag already set → no-op

        XCTAssertEqual(Config.broadcastStreamKey, "written-via-setter")
        XCTAssertEqual(UserDefaults.standard.string(forKey: secretKey), "stale-plaintext",
                       "a one-time-completed migration should not run again")
    }
}
