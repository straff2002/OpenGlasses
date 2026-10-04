import CryptoKit
import Foundation

/// Application identity for office commissioning. The private key is generated on this phone,
/// stored in a device-only Keychain item, and never sent in an invitation or transport config.
/// The transport's separate identity must be bound to this public key by the administrator.
actor OfficePhoneIdentity {
    enum Refusal: Error, Equatable {
        case corruptIdentity
        case invalidChallenge
        case invalidRedemption
        case invalidReceipt
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

    static let commissionRedemptionDomain = Data("Avenkin.CommissionRedemption.v1\0".utf8)
    /// The redemption envelope's cap, so its payload is necessarily smaller.
    static let maximumRedemptionPayload = 4_096

    /// Sign the redemption a phone sends when it joins an office by scanning its code
    /// (Contracts/commissioning.md §2.2). `signingInput` is the exact signed bytes: the
    /// redemption domain, one zero byte, then the payload. Only a redemption is signed here: the
    /// input must start with that domain, stay within the redemption's size, and its payload must
    /// be a redemption presenting this phone's own application key, so this method cannot be used
    /// to make the key sign anything else.
    func signCommissionRedemption(_ signingInput: Data) throws -> Data {
        let domain = Self.commissionRedemptionDomain
        guard signingInput.count > domain.count,
              signingInput.count <= domain.count + Self.maximumRedemptionPayload,
              signingInput.starts(with: domain) else { throw Refusal.invalidRedemption }
        let privateKey = try key()
        let payload = Data(signingInput.dropFirst(domain.count))
        guard let fields = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              fields["kind"] as? String == "avenkin.commission-redemption",
              fields["phoneApplicationKey"] as? String
                == privateKey.publicKey.rawRepresentation.base64EncodedString() else {
            throw Refusal.invalidRedemption
        }
        return try privateKey.signature(for: signingInput)
    }

    /// Sign the receipt for a managed job this phone has verified and committed
    /// (Contracts/README.md, "Managed job receipt"). `payload` is the exact bytes the transport
    /// offers; the signature is over the receipt domain followed by them. Only a receipt is signed
    /// here: anything that is not a closed receipt payload within the contract's field rules is
    /// refused, so this method cannot be used to make the key sign anything else.
    func signManagedJobReceipt(_ payload: Data) throws -> Data {
        guard OfficeManagedJobReceipt.payload(payload) != nil else { throw Refusal.invalidReceipt }
        return try key().signature(for: OfficeManagedJobReceipt.domain + payload)
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
