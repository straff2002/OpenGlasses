import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto // swift-crypto: the same API on Linux (the service's containers)
#endif

extension ProfileContract {
    /// A company credential the profile carries **sealed**: today the company's Workiz API key.
    ///
    /// Plan CT's rule is that a key never travels readable in the licence, the profile or any request to the
    /// profile's address. The profile is public and prints `licenceCode` in clear, so the box is sealed with
    /// neither: it is AES-GCM under HKDF-SHA256(company secret, info `openglasses.org-credential.v1`), and the
    /// company secret (32 random bytes made at sign-up) reaches a phone only inside the activation file
    /// (`ActivationKeyMint.seal(_:companySecret:canonical:)`). The authenticated data names the profile and
    /// the credential, so a box cannot be moved to another company's profile or another credential's slot.
    ///
    /// Mirrored by `OrgCredentialSeal` in the app (OpenGlasses/Sources/Services/OrgProfile); the two must
    /// stay byte-for-byte compatible.
    public enum Credential {
        /// The credentials a profile may carry, by name. The app ignores any other.
        public static let names: Set<String> = ["workiz"]
        public static let secretLength = 32
        /// **Signing domain.** Never change it: every sealed credential already published would stop opening.
        public static let sealingDomain = "openglasses.org-credential.v1"
        public static let secretIdDomain = "openglasses.company-secret-id.v1\n"
        /// The bounds of the credential itself: a Workiz API key is a few dozen printable characters.
        public static let valueLength = 8...256
        static let boxOverhead = 12 + 16 // AES-GCM's nonce and tag

        public enum Problem: Error, Equatable {
            case unknownName, invalidValue, invalidSecret, unreadable
        }

        /// A new company secret. Shown to nothing: it goes into the activation file and the service's protected state.
        public static func newSecret() -> Data {
            Data(SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) })
        }

        /// Recorded on the customer in the journal so a secret can be checked without the journal holding it.
        public static func secretId(_ secret: Data) -> String {
            IssuanceWire.digest(Data(secretIdDomain.utf8) + secret)
        }

        /// Printable ASCII, no spaces, within `valueLength`.
        public static func isAcceptableValue(_ value: String) -> Bool {
            valueLength.contains(value.count) && value.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) }
        }

        static func key(_ secret: Data) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), info: Data(sealingDomain.utf8), outputByteCount: 32)
        }

        static func authenticated(name: String, profileId: String) -> Data {
            Data((sealingDomain + "\n" + profileId + "\n" + name).utf8)
        }

        /// base64 of AES-GCM's combined nonce, ciphertext and tag.
        public static func seal(_ value: String, name: String, profileId: String, companySecret: Data) throws -> String {
            guard names.contains(name) else { throw Problem.unknownName }
            guard isAcceptableValue(value) else { throw Problem.invalidValue }
            guard companySecret.count == secretLength, isSafeIdentifier(profileId) else { throw Problem.invalidSecret }
            guard let combined = try AES.GCM.seal(Data(value.utf8), using: key(companySecret),
                                                  authenticating: authenticated(name: name, profileId: profileId)).combined else {
                throw Problem.unreadable
            }
            return combined.base64EncodedString()
        }

        public static func open(_ box: String, name: String, profileId: String, companySecret: Data) throws -> String {
            guard companySecret.count == secretLength else { throw Problem.invalidSecret }
            guard let combined = Data(base64Encoded: box), let sealed = try? AES.GCM.SealedBox(combined: combined),
                  let plain = try? AES.GCM.open(sealed, using: key(companySecret),
                                                authenticating: authenticated(name: name, profileId: profileId)),
                  let value = String(data: plain, encoding: .utf8), isAcceptableValue(value) else { throw Problem.unreadable }
            return value
        }

        /// The shape `check` holds a profile's `credentials` to. It cannot tell whether a box opens: only a phone can.
        static func checkBoxes(_ boxes: [String: String]) throws {
            if boxes.isEmpty { throw Invalid(message: "credentials is empty (leave it out)") }
            for (name, box) in boxes {
                guard names.contains(name) else {
                    throw Invalid(message: "credentials names \(name), which is not one of \(names.sorted().joined(separator: ", "))")
                }
                guard let data = Data(base64Encoded: box), data.base64EncodedString() == box,
                      (boxOverhead + valueLength.lowerBound...boxOverhead + valueLength.upperBound).contains(data.count) else {
                    throw Invalid(message: "credentials.\(name) is not a sealed credential")
                }
            }
        }
    }
}
