import Foundation

/// Plan FS §3 — what a vault link may be, and what the app is allowed to say about it.
///
/// Two shapes reach here and nothing else does: an `https://` URL the reader pasted, and
/// `openglasses://vault?src=<https url>` from a QR code, which exists only so that scanning a
/// publisher's code with the phone's own Camera app opens this app instead of a browser. The
/// scheme route carries **one** parameter; anything else is refused rather than ignored, because a
/// link that quietly drops a parameter is a link whose meaning the reader cannot check.
///
/// ## Why only the host is ever shown
///
/// A post-purchase link is very often a capability: `…/d/9f3c…/vault.zip`, or a query carrying the
/// buyer's order token. Rendering it puts a credential on a screen, into a screenshot, into a
/// support ticket and into whatever the reader pastes next. So the whole app shows the **host**
/// and never the path or the query — including in errors, logs, diagnostics, exports and session
/// records. `displayHost` is the only rendering of a vault link that exists.
enum VaultLinkPolicy {

    enum Refusal: Error, Equatable {
        case notAVaultLink
        case missingSource
        /// Anything that is not `https`. A vault comes over TLS or it does not come.
        case insecureScheme(String)
        /// `https://user:password@host/…`. A credential in a URL is a credential in a log.
        case credentialsInURL
        case noHost
        /// The `openglasses://vault` route takes `src` and nothing else.
        case unexpectedParameters([String])

        /// What the reader is told. Never quotes the link back.
        var message: String {
            switch self {
            case .notAVaultLink:
                return "That isn't a vault link."
            case .missingSource:
                return "That vault code doesn't carry a link to a vault."
            case .insecureScheme(let scheme):
                return scheme.isEmpty
                    ? "A vault link has to be an https:// address."
                    : "A vault link has to be an https:// address; this one is \(scheme)."
            case .credentialsInURL:
                return "That link carries a user name and password in the address. Ask the publisher for a plain https:// link."
            case .noHost:
                return "That link has no site in it."
            case .unexpectedParameters(let names):
                return "That vault code carries extra parameters (\(names.joined(separator: ", "))). Only the vault's address is allowed."
            }
        }
    }

    /// The one query parameter the scheme route accepts.
    static let sourceParameterName = "src"
    static let scheme = "openglasses"
    static let host = "vault"

    /// Resolve whatever was pasted or scanned to the https URL the archive will be fetched from.
    static func resolve(_ raw: String) -> Result<URL, Refusal> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return .failure(.notAVaultLink) }
        return resolve(url)
    }

    static func resolve(_ url: URL) -> Result<URL, Refusal> {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == Self.scheme {
            guard url.host?.lowercased() == Self.host else { return .failure(.notAVaultLink) }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let extras = items.map(\.name).filter { $0 != sourceParameterName }
            guard extras.isEmpty else { return .failure(.unexpectedParameters(extras.sorted())) }
            guard let raw = items.first(where: { $0.name == sourceParameterName })?.value,
                  !raw.isEmpty, let source = URL(string: raw) else {
                return .failure(.missingSource)
            }
            return validate(source)
        }
        return validate(url)
    }

    /// The rules an archive URL keeps, wherever it came from.
    static func validate(_ url: URL) -> Result<URL, Refusal> {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "https" else { return .failure(.insecureScheme(scheme)) }
        guard url.user == nil, url.password == nil else { return .failure(.credentialsInURL) }
        guard let host = url.host, !host.isEmpty else { return .failure(.noHost) }
        return .success(url)
    }

    /// The only rendering of a vault link the app performs: host, and a port when the URL named
    /// one. No scheme decoration, no path, no query, no fragment.
    static func displayHost(_ url: URL) -> String {
        let host = url.host?.lowercased() ?? "unknown site"
        guard let port = url.port else { return host }
        return "\(host):\(port)"
    }

    /// Whether a redirect stayed on the site the reader agreed to. A redirect that did not means
    /// the review is shown again for the new host — the reader agreed to a publisher, not to
    /// wherever that publisher forwards to.
    static func isSameHost(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let a = lhs.host?.lowercased(), let b = rhs.host?.lowercased() else { return false }
        return a == b && lhs.port == rhs.port
    }
}

/// Whether an unsigned archive may be installed on this phone at all.
///
/// Two things can take the choice away from the reader, and both are deliberate. Medical/HIPAA
/// mode always refuses: a vault's reference files steer clinical answers, and "I know the person
/// who sent it" is not a control anyone can audit. An organisation profile may refuse for the same
/// reason on its own terms — Plan CT is unbuilt, so what exists here is the flag the profile will
/// set and the behaviour that reads it, checked by a test rather than promised by copy.
struct VaultLinkInstallPolicy: Equatable {

    enum UnsignedRule: Equatable {
        case allowedWithAcknowledgement
        case forbiddenByMedicalMode
        case forbiddenByOrganizationProfile
    }

    let unsigned: UnsignedRule

    var allowsUnsigned: Bool { unsigned == .allowedWithAcknowledgement }

    /// Why an unsigned archive stops here, or nil when it may proceed.
    var refusalMessage: String? {
        switch unsigned {
        case .allowedWithAcknowledgement:
            return nil
        case .forbiddenByMedicalMode:
            return "Medical mode only installs vaults signed by a listed publisher. This one isn't signed, so it can't be installed on this phone."
        case .forbiddenByOrganizationProfile:
            return "Your organisation's configuration only allows vaults signed by a listed publisher. This one isn't signed, so it can't be installed on this phone."
        }
    }

    /// Resolve from the two switches that can forbid it. Pure, so both refusals are testable
    /// without a profile or a medical build.
    static func resolve(medicalMode: Bool, organizationAllowsUnsigned: Bool) -> VaultLinkInstallPolicy {
        if medicalMode { return VaultLinkInstallPolicy(unsigned: .forbiddenByMedicalMode) }
        if !organizationAllowsUnsigned {
            return VaultLinkInstallPolicy(unsigned: .forbiddenByOrganizationProfile)
        }
        return VaultLinkInstallPolicy(unsigned: .allowedWithAcknowledgement)
    }

    /// What the app's own switches say right now.
    static func current() -> VaultLinkInstallPolicy {
        resolve(medicalMode: Config.hipaaMode,
                organizationAllowsUnsigned: Config.organizationAllowsUnsignedVaults)
    }
}
