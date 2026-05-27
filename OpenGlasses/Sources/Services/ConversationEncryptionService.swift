import Foundation
import CryptoKit
import LocalAuthentication
import Security

/// Encrypts and decrypts conversation data using ChaCha20-Poly1305.
/// The symmetric key is stored in the Keychain, protected by biometric access control.
///
/// When enabled, conversations are encrypted on save and decrypted only after
/// Face ID / Touch ID / device passcode authentication succeeds.
actor ConversationEncryptionService {

    static let shared = ConversationEncryptionService()

    // Keychain identifiers
    private let keychainAccount = "com.openglasses.conversation-key"
    private let keychainService = "OpenGlasses"

    /// Whether encryption is currently active (check Config, not the key presence).
    nonisolated var isEnabled: Bool {
        Config.conversationEncryptionEnabled
    }

    // MARK: - Encrypt / Decrypt

    /// Encrypt raw data using ChaCha20-Poly1305.
    func encrypt(_ plaintext: Data) throws -> Data {
        let key = try getOrCreateKey()
        let sealedBox = try ChaChaPoly.seal(plaintext, using: key)
        // combined = nonce + ciphertext + tag
        return sealedBox.combined
    }

    /// Decrypt data. Requires biometric auth since the key is access-controlled.
    func decrypt(_ ciphertext: Data) throws -> Data {
        let key = try retrieveKey()
        let sealedBox = try ChaChaPoly.SealedBox(combined: ciphertext)
        return try ChaChaPoly.open(sealedBox, using: key)
    }

    /// Check if we can authenticate (Face ID / Touch ID available).
    nonisolated func canAuthenticate() -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    /// Prompt for biometric/passcode authentication.
    func authenticate(reason: String = "Unlock your conversations") async throws -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"
        return try await context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: reason
        )
    }

    // MARK: - Key Management

    /// Get existing key or create a new one.
    private func getOrCreateKey() throws -> SymmetricKey {
        if let existing = try? retrieveKey() {
            return existing
        }
        return try createAndStoreKey()
    }

    /// Create a new symmetric key and store it in Keychain with biometric protection.
    private func createAndStoreKey() throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }

        // Access control: require biometric OR device passcode
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,  // Face ID, Touch ID, or device passcode
            nil
        ) else {
            throw EncryptionError.keychainError("Failed to create access control")
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrService as String: keychainService,
            kSecValueData as String: keyData,
            kSecAttrAccessControl as String: accessControl,
        ]

        // Delete any existing key first
        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw EncryptionError.keychainError("Failed to store key: \(status)")
        }

        NSLog("[Encryption] Created new ChaCha20-Poly1305 key in Keychain")
        return key
    }

    /// Retrieve the symmetric key from Keychain. Triggers biometric prompt.
    private func retrieveKey() throws -> SymmetricKey {
        let context = LAContext()
        context.localizedReason = "Access encrypted conversations"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let keyData = result as? Data else {
            if status == errSecItemNotFound {
                throw EncryptionError.keyNotFound
            }
            throw EncryptionError.keychainError("Failed to retrieve key: \(status)")
        }

        return SymmetricKey(data: keyData)
    }

    /// Delete the encryption key (used when disabling encryption).
    func deleteKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrService as String: keychainService,
        ]
        SecItemDelete(query as CFDictionary)
        NSLog("[Encryption] Deleted encryption key from Keychain")
    }

    // MARK: - Migration Helpers

    /// Encrypt an existing plaintext conversations file in-place.
    func encryptFile(at url: URL) throws {
        let plaintext = try Data(contentsOf: url)
        let encrypted = try encrypt(plaintext)

        // Write with a magic header so we know it's encrypted
        var output = Data("OGENC1".utf8) // 6-byte magic header
        output.append(encrypted)
        try output.write(to: url, options: .atomic)
        NSLog("[Encryption] Encrypted file at %@", url.lastPathComponent)
    }

    /// Decrypt an encrypted file and return the plaintext data.
    func decryptFile(at url: URL) throws -> Data {
        let raw = try Data(contentsOf: url)

        // Check for magic header
        guard raw.count > 6 else {
            throw EncryptionError.invalidData
        }
        let header = String(data: raw.prefix(6), encoding: .utf8)
        guard header == "OGENC1" else {
            // Not encrypted — return as-is (plaintext)
            return raw
        }

        let ciphertext = raw.dropFirst(6)
        return try decrypt(Data(ciphertext))
    }

    /// Check if a file is encrypted (has the magic header).
    nonisolated func isFileEncrypted(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count > 6 else {
            return false
        }
        return String(data: data.prefix(6), encoding: .utf8) == "OGENC1"
    }
}

// MARK: - Errors

enum EncryptionError: LocalizedError {
    case keyNotFound
    case keychainError(String)
    case invalidData
    case authenticationFailed

    var errorDescription: String? {
        switch self {
        case .keyNotFound: return "Encryption key not found — re-enable encryption in Settings"
        case .keychainError(let msg): return "Keychain error: \(msg)"
        case .invalidData: return "Encrypted data is corrupted"
        case .authenticationFailed: return "Authentication failed"
        }
    }
}
