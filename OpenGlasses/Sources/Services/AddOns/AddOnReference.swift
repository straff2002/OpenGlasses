import Foundation
import CryptoKit

/// How an organisation profile or an office assignment names an organisation add-on: **by
/// reference, never embedded** — the id and version it must be, the organisation that must have
/// signed it, and where to fetch the signed envelope (a pointer, not the payload).
///
/// ```json
/// { "id": "com.acme-heating.supplier-stock", "version": "1.2.0",
///   "organizationID": "acme-heating",
///   "url": "https://addons.acme-heating.example/supplier-stock-1.2.0.json",
///   "sha256": "<optional: hex SHA-256 of the exact add-on file bytes>" }
/// ```
///
/// Strict decode (any other key refuses), then `validationIssues`. After fetching, `check`
/// decides whether the verified envelope is the add-on referenced: organisation-signed by the
/// referenced organisation, the same id and version, and — when the reference pins one — the
/// same file digest. A mismatch is a named refusal, never a fallback to community.
struct AddOnReference: Equatable, Sendable {

    let id: String
    let version: String
    let organizationID: String
    let url: String
    /// Lowercase hex SHA-256 of the exact add-on file bytes (not the envelope). Optional: when
    /// present it binds the reference to one file, not just to an id and version.
    let sha256: String?

    static let maxURLLength = 2_048

    init(id: String, version: String, organizationID: String, url: String, sha256: String? = nil) {
        self.id = id
        self.version = version
        self.organizationID = organizationID
        self.url = url
        self.sha256 = sha256
    }

    // MARK: Decode

    enum DecodeError: Error, Equatable, Sendable {
        case notJSON
        case unknownKey(String)
        case missing(String)
        case wrongType(String)
    }

    /// Strict decode from JSON bytes.
    static func decode(_ data: Data) throws -> AddOnReference {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodeError.notJSON
        }
        return try decode(object)
    }

    /// Strict decode from an already-parsed JSON object (a profile or assignment carrying it).
    static func decode(_ object: [String: Any]) throws -> AddOnReference {
        let allowed: Set<String> = ["id", "version", "organizationID", "url", "sha256"]
        if let unknown = object.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw DecodeError.unknownKey(unknown)
        }
        func string(_ key: String) throws -> String {
            guard let value = object[key] else { throw DecodeError.missing(key) }
            guard let text = value as? String else { throw DecodeError.wrongType(key) }
            return text
        }
        var digest: String?
        if let value = object["sha256"] {
            guard let text = value as? String else { throw DecodeError.wrongType("sha256") }
            digest = text
        }
        return AddOnReference(id: try string("id"), version: try string("version"),
                              organizationID: try string("organizationID"), url: try string("url"),
                              sha256: digest)
    }

    // MARK: Validate

    enum Issue: Equatable, Sendable {
        case idInvalid
        case versionInvalid
        case organizationIDInvalid
        /// Not an https address with a host, or it carries a user, a fragment or a template.
        case urlInvalid
        case sha256Invalid
    }

    /// Every reason the reference is unusable; empty means it may be fetched.
    var validationIssues: [Issue] {
        var issues: [Issue] = []
        if !RecipeAddOnValidator.isValidID(id) { issues.append(.idInvalid) }
        if !RecipeAddOnValidator.isValidVersion(version) { issues.append(.versionInvalid) }
        if !AddOnSignature.isValidOrganizationID(organizationID) { issues.append(.organizationIDInvalid) }
        if fetchURL == nil { issues.append(.urlInvalid) }
        if let sha256, !(sha256.count == 64 && sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })) {
            issues.append(.sha256Invalid)
        }
        return issues
    }

    var isValid: Bool { validationIssues.isEmpty }

    /// The address to fetch the envelope from, when it is an acceptable one: https, a host, no
    /// user or password, no fragment, no template, no whitespace, within `maxURLLength`.
    var fetchURL: URL? {
        guard url.count <= Self.maxURLLength, !url.contains("{{"),
              !url.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              let c = URLComponents(string: url), c.scheme?.lowercased() == "https",
              let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.fragment == nil else { return nil }
        return c.url
    }

    // MARK: Match

    /// Why a fetched envelope is not the add-on this reference names.
    enum Mismatch: Error, Equatable, Sendable {
        /// The reference itself is not valid.
        case referenceInvalid([Issue])
        /// The envelope did not verify as signed by an organisation (named failure, if any).
        case notOrganisationSigned(AddOnTrustClass, AddOnSignature.Failure?)
        /// It verified, but for a different organisation than the reference names.
        case otherOrganisation(expected: String, signedBy: String)
        /// The file's bytes are not the digest the reference pins.
        case digestMismatch
        /// The verified bytes are not an add-on file.
        case notAnAddOn(RecipeAddOnDecodeError)
        case idMismatch(expected: String, found: String)
        case versionMismatch(expected: String, found: String)
    }

    /// Whether `resolution` (the verified result of fetching `url`) is the add-on referenced.
    /// Returns the decoded manifest when it is; validate it next under `resolution.trust`.
    func check(_ resolution: AddOnSignature.Resolution) -> Result<RecipeAddOnManifest, Mismatch> {
        let issues = validationIssues
        guard issues.isEmpty else { return .failure(.referenceInvalid(issues)) }
        guard case .organisationSigned(let signedBy) = resolution.trust else {
            return .failure(.notOrganisationSigned(resolution.trust, resolution.failure))
        }
        guard signedBy == organizationID else {
            return .failure(.otherOrganisation(expected: organizationID, signedBy: signedBy))
        }
        if let sha256 {
            let actual = SHA256.hash(data: resolution.fileBytes).map { String(format: "%02x", $0) }.joined()
            guard actual == sha256 else { return .failure(.digestMismatch) }
        }
        let manifest: RecipeAddOnManifest
        do {
            manifest = try RecipeAddOnManifest.decode(resolution.fileBytes)
        } catch let error as RecipeAddOnDecodeError {
            return .failure(.notAnAddOn(error))
        } catch {
            return .failure(.notAnAddOn(.malformed(path: "", reason: "not valid JSON")))
        }
        guard manifest.id == id else { return .failure(.idMismatch(expected: id, found: manifest.id)) }
        guard manifest.version == version else {
            return .failure(.versionMismatch(expected: version, found: manifest.version))
        }
        return .success(manifest)
    }
}
