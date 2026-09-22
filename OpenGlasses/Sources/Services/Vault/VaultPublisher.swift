import Foundation

/// Plan FS §2 — who may sign a vault archive, as the vendor's signed catalog states it.
///
/// A publisher is not a vendor product and the vendor hosts nothing for them: the catalog carries
/// only the *name and key* a phone needs to tell a signed archive from an anonymous one, so a
/// publisher can be listed — or revoked — without an app release. The archive itself comes from
/// the publisher's own site, which is the only place it ever lives.
struct VaultPublisher: Codable, Equatable, Identifiable {

    enum Status: String, Codable, Equatable {
        case active
        /// Listed once, and no longer trusted. A revoked publisher's links are refused outright,
        /// and its already-installed vaults are flagged — never deleted, because the technician
        /// may be standing in a plant room depending on one.
        case revoked
    }

    let id: String
    /// What a signed archive from this publisher is allowed to say it is.
    let name: String
    /// Curve25519 raw public key, base64 — the same key format the vendor's own signing key uses.
    let publicKey: String
    let status: Status

    init(id: String, name: String, publicKey: String, status: Status = .active) {
        self.id = id
        self.name = name
        self.publicKey = publicKey
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case id, name, status
        case publicKey = "public_key"
    }

    /// Hand-written so an entry without an explicit status reads as active, which is what a
    /// publisher row means when nobody has revoked it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        publicKey = try c.decode(String.self, forKey: .publicKey)
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .active
    }
}

/// What verifying an archive against the publisher list came to.
///
/// Three outcomes and no fourth: it is signed by a listed, active publisher; it is unverified and
/// may be installed at the reader's own risk with a second acknowledgement; or it is refused with
/// no override at all.
enum VaultArchiveVerification: Equatable {

    /// A validly signed archive from a listed publisher.
    case signed(publisherId: String, publisherName: String)
    /// Installable, loudly marked, and badged "Unverified source" ever after.
    case unverified(UnverifiedReason)
    /// No override exists for these.
    case refused(Refusal)

    enum UnverifiedReason: Equatable {
        /// No `vault-archive.sig` at all.
        case notSigned
        /// Signed by an id nobody has listed, so there is no key to check it with. The claimed id
        /// is kept for the log; the *name* the archive claims is never shown as a publisher.
        case unknownPublisher(claimedId: String)
    }

    enum Refusal: Equatable {
        /// Signed by a listed, active publisher — and the signature does not verify.
        case signatureInvalid
        /// A file's bytes are not what the header says they are.
        case contentsAltered(String)
        case revokedPublisher(String)
        /// The archive's header describes a different vault to the one inside it.
        case headerDoesNotMatchVault(String)
    }

    var isRefused: Bool {
        if case .refused = self { return true }
        return false
    }

    var isSigned: Bool {
        if case .signed = self { return true }
        return false
    }

    /// The publisher a received vault records. Nil unless the signature actually verified — an
    /// unverified archive's claimed name is never written anywhere as a publisher.
    var verifiedPublisher: (id: String, name: String)? {
        if case .signed(let id, let name) = self { return (id, name) }
        return nil
    }
}

/// Verify an extracted archive against the publisher list. Pure: the list is passed in, so every
/// outcome renders in a test without a catalog, a network or a key of our own.
enum VaultArchiveVerifier {

    /// Order: the publisher lookup decides *which* key (and whether the publisher is still
    /// trusted), the signature decides whether the header and files are the ones that were signed,
    /// and the header's own hashes decide whether the bytes on this phone are those files. A
    /// failure at any step after the publisher is a tamper, and a tamper is never overridable.
    static func verify(_ extracted: VaultArchiveReader.Extracted,
                       publishers: [VaultPublisher]) -> VaultArchiveVerification {
        let header = extracted.header

        // The header has to be about the vault it is wrapped around, whatever it is signed with.
        guard let manifestData = extracted.files["manifest.json"],
              let manifest = try? JSONDecoder().decode(VaultManifest.self, from: manifestData) else {
            return .refused(.headerDoesNotMatchVault("manifest.json is unreadable"))
        }
        guard manifest.id == header.vaultId else {
            return .refused(.headerDoesNotMatchVault("the header names a different vault to manifest.json"))
        }

        if let error = VaultArchiveReader.checkFiles(header: header, files: extracted.files) {
            switch error {
            case .checksumMismatch(let path), .sizeMismatch(let path), .fileListMismatch(let path):
                return .refused(.contentsAltered(path))
            default:
                return .refused(.contentsAltered(VaultArchiveReader.describe(error)))
            }
        }

        guard let signature = extracted.signature, !signature.isEmpty else {
            return .unverified(.notSigned)
        }
        guard let publisher = publishers.first(where: { $0.id == header.publisherId }),
              !header.publisherId.isEmpty else {
            return .unverified(.unknownPublisher(claimedId: header.publisherId))
        }
        guard publisher.status == .active else {
            return .refused(.revokedPublisher(publisher.name))
        }
        guard VaultArchiveSignature.verify(signatureBase64: signature, header: header,
                                           files: extracted.files,
                                           publicKeyBase64: publisher.publicKey) else {
            return .refused(.signatureInvalid)
        }
        return .signed(publisherId: publisher.id, publisherName: publisher.name)
    }

    /// The sentence a refusal shows. No install button follows any of them.
    static func describe(_ refusal: VaultArchiveVerification.Refusal) -> String {
        switch refusal {
        case .signatureInvalid:
            return "This archive is signed by a listed publisher, but the signature doesn't check out. It has been altered since it was signed — it can't be installed."
        case .contentsAltered(let detail):
            return "This archive's contents don't match what its header says they are (\(detail)). It has been altered — it can't be installed."
        case .revokedPublisher(let name):
            return "\(name) is no longer a listed publisher. Vaults signed with that key can't be installed."
        case .headerDoesNotMatchVault(let detail):
            return "This archive doesn't describe itself consistently (\(detail)). It can't be installed."
        }
    }
}
