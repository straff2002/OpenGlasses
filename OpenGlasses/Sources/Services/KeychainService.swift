import Foundation
import Security

/// Thin wrapper around the iOS Keychain for storing small secrets — provider
/// API keys, auth tokens, and secret-bearing config blobs (e.g. the saved-model
/// list, whose `apiKey` fields would otherwise sit in plaintext UserDefaults and
/// land in unencrypted device backups).
///
/// Items use `kSecClassGenericPassword`, scoped to this device only and readable
/// `AfterFirstUnlock`. That means background LLM/TTS requests can still read keys
/// while the device is locked (after the first post-boot unlock), but the secrets
/// never sync to iCloud and never leave the device in an iTunes/Finder backup.
///
/// This mirrors the Keychain pattern already used by `ConversationEncryptionService`
/// (same `service` identifier, distinct accounts). API-key items intentionally use a
/// looser accessibility class than the conversation key (no `.userPresence`) so they
/// work unattended.
enum KeychainService {

    /// Shared service identifier for all OpenGlasses Keychain items.
    private static let service = "OpenGlasses"

    /// Accessibility: readable after the first unlock following a reboot, this
    /// device only (never backed up, never synced to iCloud).
    private static let accessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    /// Accessibility classes a caller may pick from. `afterFirstUnlock` is the default because
    /// background LLM/TTS requests read their keys unattended. `whenUnlocked` is the stricter
    /// class required for clinical credentials, which are only ever read for a foreground export
    /// and so must not be readable on a locked device.
    enum Accessibility {
        case afterFirstUnlockThisDeviceOnly
        case whenUnlockedThisDeviceOnly

        var attribute: CFString {
            switch self {
            case .afterFirstUnlockThisDeviceOnly: return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            case .whenUnlockedThisDeviceOnly: return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            }
        }
    }

    /// Failures a caller has to tell apart. `unavailable` means protected data is not readable
    /// right now — the item may well exist, so the caller must defer rather than conclude the
    /// secret is absent and act on that.
    enum KeychainError: Error, Equatable {
        case unavailable(OSStatus)
        case readFailed(OSStatus)
        case writeFailed(OSStatus)
        case deleteFailed(OSStatus)
    }

    /// Statuses that mean "the device is locked / the item is not accessible right now" rather
    /// than "there is nothing stored".
    private static func isUnavailable(_ status: OSStatus) -> Bool {
        status == errSecInteractionNotAllowed || status == errSecAuthFailed
    }

    // MARK: - Throwing Data

    /// Read raw data, distinguishing "no item" (`nil`) from "cannot read right now" (throws
    /// `.unavailable`). Prefer this over ``data(for:)`` wherever absence and lock must not be
    /// conflated.
    static func readData(for key: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default:
            throw isUnavailable(status) ? KeychainError.unavailable(status) : KeychainError.readFailed(status)
        }
    }

    /// Store raw data under an explicit accessibility class. Empty data deletes the item.
    static func writeData(_ data: Data, for key: String, accessibility: Accessibility) throws {
        try deleteItem(key)
        guard !data.isEmpty else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility.attribute,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status != errSecSuccess else { return }
        throw isUnavailable(status) ? KeychainError.unavailable(status) : KeychainError.writeFailed(status)
    }

    /// Remove an item, throwing on anything other than success or a missing item.
    static func deleteItem(_ key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status != errSecSuccess, status != errSecItemNotFound else { return }
        throw isUnavailable(status) ? KeychainError.unavailable(status) : KeychainError.deleteFailed(status)
    }

    // MARK: - Data

    /// Read raw data for a key, or `nil` if the item does not exist.
    static func data(for key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                NSLog("[Keychain] read failed for %@: %d", key, Int(status))
            }
            return nil
        }
        return result as? Data
    }

    /// Store raw data for a key. Passing `nil` or empty data deletes the item.
    /// Returns `true` on success (including the delete-on-empty case).
    @discardableResult
    static func setData(_ data: Data?, for key: String) -> Bool {
        // Delete first so a re-set always replaces cleanly (matches the pattern
        // in ConversationEncryptionService and avoids errSecDuplicateItem).
        delete(key)
        guard let data, !data.isEmpty else { return true }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessible,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("[Keychain] write failed for %@: %d", key, Int(status))
        }
        return status == errSecSuccess
    }

    // MARK: - String

    /// Read a UTF-8 string for a key, or `nil` if the item does not exist.
    static func string(for key: String) -> String? {
        guard let data = data(for: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Store a UTF-8 string for a key. Passing `nil` or an empty string deletes
    /// the item (matching the "empty means cleared" semantics of the old
    /// UserDefaults-backed getters). Returns `true` on success.
    @discardableResult
    static func setString(_ value: String?, for key: String) -> Bool {
        guard let value, !value.isEmpty else { return delete(key) }
        return setData(Data(value.utf8), for: key)
    }

    // MARK: - Delete

    /// Remove the item for a key. Returns `true` if it was removed or did not exist.
    @discardableResult
    static func delete(_ key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
