import Foundation
import CryptoKit
import os.lock

/// The key a phone claims its seat with (Plan JS P2). The private half never leaves the phone:
/// in production it is a Secure Enclave P-256 key, not exportable, and its stored handle is
/// readable only by this phone's Secure Enclave and is kept out of backups.
protocol DeviceSeatKey: Sendable {
    /// X9.63 public key, as the claim sends it.
    var publicKeyX963: Data { get }
    /// ECDSA P-256 over `data`, DER.
    func sign(_ data: Data) throws -> Data
}

protocol DeviceSeatKeyStore: Sendable {
    /// The key this phone already made, if any.
    func existing() -> DeviceSeatKey?
    /// Make a new key, replacing any old one.
    func create() throws -> DeviceSeatKey
    /// Forget the key (the phone left its organisation).
    func remove()
}

extension DeviceSeatKeyStore {
    /// The hash a lease must name, or nil when the phone has no key.
    func currentKeyHash() -> String? {
        existing().map { DeviceSeatLease.deviceKeyHash(publicKeyX963: $0.publicKeyX963) }
    }
}

/// The production store. The Secure Enclave key's opaque handle (`dataRepresentation`, usable only
/// by this phone's Secure Enclave) is kept in the Keychain this-device-only, so it is never in a
/// backup and never synced; a restored or new phone has no key and claims afresh.
///
/// `DeviceSeatService` makes the key on the first claim and removes it on release.
///
/// The public key's hash is cached for the process: the entitlement gate reads it on every
/// decision, and it is derived from the key the Keychain holds, never written anywhere.
final class DeviceSeatKeychainStore: DeviceSeatKeyStore, @unchecked Sendable {
    static let shared = DeviceSeatKeychainStore()

    /// Keychain account for the key handle. Storage identifier: never rename.
    nonisolated static let keychainAccount = "licenceSeatDeviceKey"

    private let cache = OSAllocatedUnfairLock<DeviceSeatKey??>(initialState: nil)

    func existing() -> DeviceSeatKey? {
        if let cached = cache.withLock({ $0 }) { return cached }
        // Only a key found is cached: before the first unlock after a reboot the Keychain reads as
        // empty, and caching that would hold a seat-checked licence locked until the next launch.
        guard let key = load() else { return nil }
        cache.withLock { $0 = .some(key) }
        return key
    }

    func create() throws -> DeviceSeatKey {
        let key: DeviceSeatKey
        let handle: Data
        #if targetEnvironment(simulator)
        // The Simulator has no Secure Enclave. A software key, this-device-only, so seat checks can
        // be exercised there; no build for a device takes this path.
        let software = P256.Signing.PrivateKey()
        key = SoftwareSeatKey(software: software)
        handle = Data("sw:".utf8) + software.rawRepresentation
        #else
        guard SecureEnclave.isAvailable else { throw DeviceSeatKeyError.noSecureEnclave }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                                           .privateKeyUsage, &error) else {
            throw DeviceSeatKeyError.noSecureEnclave
        }
        let enclave = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        key = EnclaveSeatKey(enclave: enclave)
        handle = Data("se:".utf8) + enclave.dataRepresentation
        #endif
        try KeychainService.writeData(handle, for: Self.keychainAccount, accessibility: .afterFirstUnlockThisDeviceOnly)
        cache.withLock { $0 = .some(key) }
        return key
    }

    func remove() {
        try? KeychainService.deleteItem(Self.keychainAccount)
        cache.withLock { $0 = nil }
    }

    private func load() -> DeviceSeatKey? {
        guard let stored = try? KeychainService.readData(for: Self.keychainAccount), stored.count > 3 else { return nil }
        let prefix = String(decoding: stored.prefix(3), as: UTF8.self)
        let body = stored.dropFirst(3)
        switch prefix {
        case "se:":
            return (try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: Data(body))).map(EnclaveSeatKey.init)
        #if targetEnvironment(simulator)
        case "sw:":
            return (try? P256.Signing.PrivateKey(rawRepresentation: Data(body))).map(SoftwareSeatKey.init)
        #endif
        default:
            return nil
        }
    }
}

enum DeviceSeatKeyError: Error { case noSecureEnclave }

private struct EnclaveSeatKey: DeviceSeatKey, @unchecked Sendable {
    let enclave: SecureEnclave.P256.Signing.PrivateKey
    var publicKeyX963: Data { enclave.publicKey.x963Representation }
    func sign(_ data: Data) throws -> Data { try enclave.signature(for: data).derRepresentation }
}

#if targetEnvironment(simulator)
private struct SoftwareSeatKey: DeviceSeatKey, @unchecked Sendable {
    let software: P256.Signing.PrivateKey
    var publicKeyX963: Data { software.publicKey.x963Representation }
    func sign(_ data: Data) throws -> Data { try software.signature(for: data).derRepresentation }
}
#endif
