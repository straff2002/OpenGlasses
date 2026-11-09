import Foundation
import CryptoKit

/// A company credential the organisation profile carries sealed: today the company's Workiz API key,
/// which its partner sets (and replaces) centrally.
///
/// The profile is public and prints `licenceCode` in clear, so the box is sealed with neither: it is
/// AES-GCM under HKDF-SHA256(company secret, info `"openglasses.org-credential.v1"`), authenticating
/// `"openglasses.org-credential.v1\n<profileId>\n<name>"`. The company secret reaches the phone only
/// inside the activation file (`ActivationKey.Contents.companySecret`).
///
/// Mirrors `ProfileContract.Credential` in Tools/LicenceIssuance byte for byte; pinned by
/// `OrgCredentialTests`.
enum OrgCredentialSeal {
    static let secretLength = 32
    /// **Signing domain, not a product name.** Never change it: every credential already sealed into
    /// a published profile would stop opening.
    static let sealingSigningDomain = "openglasses.org-credential.v1"
    static let workiz = "workiz"

    private static func key(_ secret: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret),
                               info: Data(sealingSigningDomain.utf8), outputByteCount: 32)
    }

    private static func authenticated(name: String, profileId: String) -> Data {
        Data((sealingSigningDomain + "\n" + profileId + "\n" + name).utf8)
    }

    /// The value, or nil when this secret did not seal this box for this profile and name.
    static func open(_ box: String, name: String, profileId: String, companySecret: Data) -> String? {
        guard companySecret.count == secretLength,
              let combined = Data(base64Encoded: box),
              let sealed = try? AES.GCM.SealedBox(combined: combined),
              let plain = try? AES.GCM.open(sealed, using: key(companySecret),
                                            authenticating: authenticated(name: name, profileId: profileId)),
              let value = String(data: plain, encoding: .utf8),
              (8...256).contains(value.count),
              value.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
            return nil
        }
        return value
    }

    /// As the licence service seals one. Tests and fixtures only on the phone.
    static func seal(_ value: String, name: String, profileId: String, companySecret: Data) throws -> String {
        guard let combined = try AES.GCM.seal(Data(value.utf8), using: key(companySecret),
                                              authenticating: authenticated(name: name, profileId: profileId)).combined else {
            throw CryptoKitError.incorrectParameterSize
        }
        return combined.base64EncodedString()
    }
}

/// The company secret, in the device-only Keychain. Written once an enrolment from a version 2
/// activation file is applied; erased when the phone leaves the firm. Registered with
/// DataStoreRegistry as `orgCompanySecret`.
struct CompanySecretStore {
    static let keychainAccount = "orgCompanySecret"
    var read: () -> Data? = { try? KeychainService.readData(for: keychainAccount) }
    var write: (Data) throws -> Void = {
        try KeychainService.upsertDataAtomically($0, for: keychainAccount, accessibility: .afterFirstUnlockThisDeviceOnly)
    }
    var erase: () -> Void = { try? KeychainService.deleteItem(keychainAccount) }

    static var device: CompanySecretStore { CompanySecretStore() }

    static func erase() { device.erase() }
}

/// Puts the profile's sealed Workiz key into `WorkizConnection`'s Keychain item, with no prompt, on
/// every enrolment, renewal and launch; and takes a key the profile supplied away again when the
/// profile stops carrying one. A key pasted on the phone is the phone's until the profile carries one.
@MainActor
final class OrgCredentialSync: ObservableObject {

    enum Outcome: Equatable {
        /// Nothing to do: the key in the Keychain is already the profile's, or neither has one.
        case unchanged
        /// A new or replaced key was written.
        case written
        /// The profile stopped carrying a key, and the one it had supplied was deleted.
        case removed
        /// The profile carries a key this phone cannot open: it has no company secret (it was set up
        /// before sealed credentials, or from a link rather than an activation key), or another
        /// company's. The key on the phone, if any, is left as it is.
        case needsActivationKey
        /// The key could not be written (the phone is locked, or the office connects to Workiz).
        case failed
    }

    struct Seams {
        var secrets: CompanySecretStore = .device
        var connection: @MainActor () -> WorkizConnection? = { AppStateProvider.shared?.workizConnection }
        /// A key arrived or changed: drop what the old key fetched and load the technician list,
        /// which starts "Which one are you?".
        var keyArrived: @MainActor () -> Void = {
            guard let workiz = AppStateProvider.shared?.workiz else { return }
            workiz.keyChanged()
            Task { await workiz.testConnection() }
        }
        var keyRemoved: @MainActor () -> Void = { AppStateProvider.shared?.workiz.keyChanged() }
    }

    static let shared = OrgCredentialSync()

    /// Whether the profile carries a Workiz key this phone cannot open. An administrator is told to
    /// enter the company's activation key again.
    @Published private(set) var workizNeedsActivationKey = false

    private let seams: Seams

    init(seams: Seams = Seams()) {
        self.seams = seams
    }

    /// Keep the secret that came with an applied enrolment. A version 1 file carries none, and the
    /// phone keeps whatever it had.
    func keep(_ secret: Data?) {
        guard let secret, secret.count == OrgCredentialSeal.secretLength else { return }
        try? seams.secrets.write(secret)
    }

    @discardableResult
    func apply(_ profile: ConfigProfile) -> Outcome {
        guard let connection = seams.connection() else { return .unchanged }
        guard let box = profile.credentials?.boxes[OrgCredentialSeal.workiz] else {
            workizNeedsActivationKey = false
            guard connection.isManagedKey else { return .unchanged }
            do {
                try connection.removeManagedKey()
                seams.keyRemoved()
                return .removed
            } catch {
                return .failed
            }
        }
        guard let secret = seams.secrets.read(),
              let key = OrgCredentialSeal.open(box, name: OrgCredentialSeal.workiz, profileId: profile.profileId,
                                               companySecret: secret) else {
            workizNeedsActivationKey = true
            return .needsActivationKey
        }
        workizNeedsActivationKey = false
        do {
            guard try connection.setManagedKey(key, organization: profile.organizationName) else { return .unchanged }
            seams.keyArrived()
            return .written
        } catch {
            return .failed
        }
    }

    /// The phone left the firm: its secret goes with it. (Its Workiz key goes through `WorkizController.remove`.)
    func forget() {
        seams.secrets.erase()
        workizNeedsActivationKey = false
    }
}
