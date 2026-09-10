import Foundation
import CryptoKit
import Security

/// A class of data whose bytes are sealed under a key scoped to that class alone, so destroying
/// the key makes every copy of those bytes unreadable — including the copies this app cannot
/// reach: a flash snapshot, an existing backup, a file already synced somewhere.
///
/// The membership of this enum is deliberately small, and it is the honest part. A scoped key is
/// only worth having where the data is *actually sealed under it*; a key that exists beside
/// plaintext is a control that looks like protection and provides none. Two classes qualify today:
///
/// - `conversationContent` — sealed by `ConversationEncryptionService` when the wearer turns
///   conversation encryption on, under a key held behind user presence.
/// - `faces` — the enrolled biometric templates, sealed here.
///
/// Clinical transcripts are **not** here, and the reason is a product decision rather than an
/// oversight: they are written as plain `.txt` into a folder the wearer opens in Files and shares
/// from, which is what the recording screen promises. Sealing them would break that. So a clinical
/// transcript is removed logically only, and `docs/plans/ET-iso27701-privacy.md` says so instead
/// of implying a guarantee the bytes do not carry.
enum ErasableClass: String, CaseIterable, Codable, Sendable {
    case conversationContent
    case faces
}

/// What an erasure actually achieved. The distinction is the whole of W03.5.
enum ErasureCoverage: Equatable {
    /// The bytes were sealed under a key that has now been destroyed. A copy in a snapshot, in an
    /// existing backup, or on a disk this app never saw is ciphertext nobody can open.
    case cryptographic
    /// The file was unlinked and nothing more. iOS's own per-file encryption still applies, but
    /// its key belongs to the device rather than to this app, so a copy that left the container
    /// is not reached — and here is why that is the best available answer for this class.
    case logicalOnly(String)

    var isCryptographic: Bool { self == .cryptographic }

    var rendered: String {
        switch self {
        case .cryptographic: return "cryptographic"
        case .logicalOnly(let reason): return "logical only — \(reason)"
        }
    }
}

/// Where a scoped key lives. Behind a protocol so a headless test does not need the Keychain, and
/// so a keyring that cannot reach its store degrades to plaintext rather than losing the data.
protocol ScopedKeyStore: AnyObject {
    func key(for erasable: ErasableClass) -> SymmetricKey?
    func createKey(for erasable: ErasableClass) -> SymmetricKey?
    @discardableResult func destroyKey(for erasable: ErasableClass) -> Bool
}

/// The production store.
///
/// `afterFirstUnlockThisDeviceOnly` on purpose: the files these keys open are themselves protected
/// to first unlock or better, so a stricter key class would only add a way for a background write
/// to fail; and `ThisDeviceOnly` keeps the key out of an iCloud keychain, which is the copy an
/// erasure could not reach.
final class KeychainScopedKeyStore: ScopedKeyStore {
    private let service = "OpenGlasses.ScopedKey"

    func key(for erasable: ErasableClass) -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: erasable.rawValue,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return SymmetricKey(data: data)
    }

    func createKey(for erasable: ErasableClass) -> SymmetricKey? {
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: erasable.rawValue,
        ] as CFDictionary)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: erasable.rawValue,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return nil }
        return key
    }

    @discardableResult
    func destroyKey(for erasable: ErasableClass) -> Bool {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: erasable.rawValue,
        ] as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// An in-memory store for tests and for any context where the Keychain is not available.
final class InMemoryScopedKeyStore: ScopedKeyStore {
    private var keys: [ErasableClass: SymmetricKey] = [:]
    /// Set to refuse every key, standing in for a Keychain that cannot be reached.
    var refusesKeys = false

    init() {}

    func key(for erasable: ErasableClass) -> SymmetricKey? { keys[erasable] }

    func createKey(for erasable: ErasableClass) -> SymmetricKey? {
        guard !refusesKeys else { return nil }
        let key = SymmetricKey(size: .bits256)
        keys[erasable] = key
        return key
    }

    @discardableResult
    func destroyKey(for erasable: ErasableClass) -> Bool {
        keys.removeValue(forKey: erasable)
        return true
    }
}

enum ScopedKeyringError: Error, Equatable {
    /// The bytes are sealed and the key that opens them is gone. For a class that was erased this
    /// is the correct outcome, not a fault — it is what cryptographic erasure means.
    case keyUnavailable
    case malformed
}

/// W03.5 — per-class keys, and the erasure that destroys one.
final class ScopedKeyring {

    static let shared = ScopedKeyring()

    /// Sealed blobs start with this, so a file written before sealing existed is still readable
    /// and migrates on its next save rather than being lost.
    static let magic = Data("OGSK1".utf8)

    private let store: ScopedKeyStore

    init(store: ScopedKeyStore = KeychainScopedKeyStore()) {
        self.store = store
    }

    func hasKey(for erasable: ErasableClass) -> Bool { store.key(for: erasable) != nil }

    func isSealed(_ data: Data) -> Bool { data.starts(with: Self.magic) }

    /// Seal `data` under the class's key, minting one if there is none.
    ///
    /// Returns nil when no key could be obtained — a locked or unavailable Keychain. The caller
    /// then writes plaintext, which is what the store did before this existed: degrading to the
    /// previous behaviour is right, and losing the wearer's data because a keychain read failed
    /// would not be. What that costs is recorded in the coverage a later erasure reports.
    func seal(_ data: Data, for erasable: ErasableClass) -> Data? {
        guard let key = store.key(for: erasable) ?? store.createKey(for: erasable),
              let sealed = try? ChaChaPoly.seal(data, using: key) else { return nil }
        var output = Self.magic
        output.append(sealed.combined)
        return output
    }

    /// Open `data`. Unsealed bytes are returned unchanged, so a store adopting this reads what it
    /// wrote before adopting it.
    func open(_ data: Data, for erasable: ErasableClass) throws -> Data {
        guard isSealed(data) else { return data }
        guard let key = store.key(for: erasable) else { throw ScopedKeyringError.keyUnavailable }
        let body = data.dropFirst(Self.magic.count)
        guard let box = try? ChaChaPoly.SealedBox(combined: body),
              let plaintext = try? ChaChaPoly.open(box, using: key) else {
            throw ScopedKeyringError.malformed
        }
        return plaintext
    }

    /// Destroy the class's key, then remove its files.
    ///
    /// The order matters and is the point: the key goes first, so a crash between the two steps
    /// leaves unreadable files rather than readable ones. The receipt reports `.cryptographic`
    /// only when every file it removed was actually sealed — a class that was still writing
    /// plaintext (because the Keychain was unavailable when it saved) gets `.logicalOnly` and says
    /// so, rather than inheriting a guarantee from the key's existence.
    @discardableResult
    func eraseClass(_ erasable: ErasableClass, files: [URL],
                    fileManager: FileManager = .default) -> ClassErasureReceipt {
        let present = files.filter { fileManager.fileExists(atPath: $0.path) }
        let unsealed = present.filter { url in
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
            return !isSealed(data)
        }
        let keyDestroyed = store.destroyKey(for: erasable)

        var removed = 0
        var failures = 0
        for url in present {
            do {
                try fileManager.removeItem(at: url)
                removed += 1
            } catch {
                failures += 1
            }
        }

        let coverage: ErasureCoverage
        if present.isEmpty {
            coverage = keyDestroyed
                ? .cryptographic
                : .logicalOnly("the class's key could not be destroyed")
        } else if unsealed.isEmpty && keyDestroyed {
            coverage = .cryptographic
        } else if !keyDestroyed {
            coverage = .logicalOnly("the class's key could not be destroyed, so a copy elsewhere "
                                    + "stays readable")
        } else {
            coverage = .logicalOnly("some of this class was written in the clear, so a copy in a "
                                    + "snapshot or an existing backup is not reached")
        }

        PrivacyLog.store(.scopedKey, .cleared, slot: PrivacyToken(erasable.rawValue),
                         count: removed, total: present.count,
                         detail: PrivacyToken(coverage.isCryptographic ? "cryptographic" : "logical"))
        return ClassErasureReceipt(erasable: erasable, keyDestroyed: keyDestroyed,
                                   filesRemoved: removed, failures: failures, coverage: coverage)
    }
}

/// What one class erasure did.
struct ClassErasureReceipt: Equatable {
    let erasable: ErasableClass
    let keyDestroyed: Bool
    let filesRemoved: Int
    let failures: Int
    let coverage: ErasureCoverage
}
