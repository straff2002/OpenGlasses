import CryptoKit
import Foundation

/// Application identity for office commissioning. The private key is generated on this phone,
/// stored in a device-only Keychain item, and never sent in an invitation or transport config.
/// The transport's separate identity must be bound to this public key by the administrator.
actor OfficePhoneIdentity {
    enum Refusal: Error, Equatable {
        case corruptIdentity
        case invalidChallenge
    }

    static let shared = OfficePhoneIdentity()
    static let possessionDomain = Data("Avenkin.PhonePossession.v1\0".utf8)
    private let account: String

    init(account: String = "office.phone.application.signing.v1") {
        self.account = account
    }

    func publicKey() throws -> Data { try key().publicKey.rawRepresentation }

    /// An invitation response proves possession of the application key. Callers supply a fresh
    /// 32-byte challenge from the reviewed office invitation; a stored signature is not reusable
    /// for a different invitation or message type.
    func signChallenge(_ challenge: Data) throws -> Data {
        guard challenge.count == 32 else { throw Refusal.invalidChallenge }
        return try key().signature(for: Self.possessionDomain + challenge)
    }

    private func key() throws -> Curve25519.Signing.PrivateKey {
        if let existing = try KeychainService.readData(for: account) {
            guard existing.count == 32,
                  let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: existing) else {
                throw Refusal.corruptIdentity
            }
            return privateKey
        }
        let created = Curve25519.Signing.PrivateKey()
        try KeychainService.upsertDataAtomically(created.rawRepresentation, for: account,
                                                  accessibility: .afterFirstUnlockThisDeviceOnly)
        return created
    }
}
