import Foundation
import CryptoKit

/// Plan BX P1 — ed25519 signing for skill packs, on the exact pattern Field Assist licensing
/// already ships (`LicenseService`): the vendor's private key signs, an embedded public key
/// verifies, and the private half never ships in the app.
///
/// The signed message covers the manifest bytes AND a sorted digest of every payload file, so
/// neither the manifest nor any file can be swapped after signing. Unsigned packs install only in
/// developer mode, loudly labeled — that policy lives in `SkillPackStore`, not here.
enum SkillPackSignature {

    /// Production signing key (base64, Curve25519 raw representation), rotated 2026-09-03 via
    /// `Scripts/skillpack-sign.swift keygen <file>`. The private half is held only by the vendor,
    /// alongside the Field Assist licensing key — it never ships in the app or the repo.
    ///
    /// Rotated because the previous private key had been printed into terminal scrollback and chat
    /// transcripts. No vault packs were published and only the two first-party skill packs existed,
    /// so the blast radius was one app release: both catalogs and every pack were re-signed with
    /// this key in the same change. `keygen` now writes the private half to a 0600 file and prints
    /// only the public half — the printing was what lost the old key.
    static let productionPublicKeyBase64 = "6fiA4lmBU5VBSOHRWGh9U73XbmMJA4wZnqCt0YU+o5g="

    /// The canonical byte string the signature covers: the manifest bytes, then one line per
    /// payload file — `sha256(path)=<hex>` — sorted by path. Deterministic by construction; any
    /// added, removed, or altered file changes the message.
    static func signingMessage(manifestData: Data, payloadFiles: [String: Data]) -> Data {
        var message = Data()
        message.append(manifestData)
        for path in payloadFiles.keys.sorted() {
            let digest = SHA256.hash(data: payloadFiles[path] ?? Data())
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            message.append(Data("\nsha256(\(path))=\(hex)".utf8))
        }
        return message
    }

    /// Verify a pack signature against a public key. Pure — key injectable so tests sign with an
    /// ephemeral pair (the `LicenseService` test pattern).
    static func verify(
        signatureBase64: String,
        manifestData: Data,
        payloadFiles: [String: Data],
        publicKeyBase64: String = productionPublicKeyBase64
    ) -> Bool {
        guard let signature = Data(base64Encoded: signatureBase64),
              let keyData = Data(base64Encoded: publicKeyBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            return false
        }
        let message = signingMessage(manifestData: manifestData, payloadFiles: payloadFiles)
        return publicKey.isValidSignature(signature, for: message)
    }

    /// Produce a signature with a private key. Vendor/test side only — the app never holds a
    /// private key; this exists so tests and the future `Scripts/sign-skillpack` tool share the
    /// exact message construction with `verify`.
    static func sign(
        manifestData: Data,
        payloadFiles: [String: Data],
        privateKeyBase64: String
    ) throws -> String {
        guard let keyData = Data(base64Encoded: privateKeyBase64) else {
            throw SigningError.badKey
        }
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
        let message = signingMessage(manifestData: manifestData, payloadFiles: payloadFiles)
        return try privateKey.signature(for: message).base64EncodedString()
    }

    enum SigningError: Error { case badKey }
}
