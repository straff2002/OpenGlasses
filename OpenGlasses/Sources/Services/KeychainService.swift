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
