import Foundation

/// Parsing and refusing the text a user types when importing a model from a public repository
/// (docs/plans/DZ-local-gguf-and-durable-agent-runtime.md, "Import parsing").
///
/// The whole file is pure and structural: it decides what a string is allowed to *mean* before any
/// network call exists to be pointed somewhere. That ordering is the point — a host allowlist that
/// runs after the first request has already leaked the request.
///
/// **The parsed value is user content.** `owner` and `repository` are whatever someone typed, so
/// they may be shown back to that person and sent to the allowlisted host, and they may never be
/// written to a log line. Every diagnostic in the acquisition path logs a rejection's *case name*
/// via `PrivacyToken.caseName(of:)`, never its payload.

/// A public model repository, already proved to be well-formed and on an allowlisted host.
///
/// Deliberately carries no revision: a reference names a repository, and a *pinned* revision is
/// something only the resolver can produce. Nothing downstream can accidentally treat "the
/// repository the user typed" as "the exact bytes we agreed to fetch".
struct LocalModelRepositoryReference: Equatable, Hashable, Sendable {
    /// Canonical host — always `huggingface.co`, even when the user pasted the `hf.co` short form.
    let host: String
    let owner: String
    let repository: String

    /// `owner/repository`, the form the metadata API and the descriptor both use.
    var repositoryID: String { "\(owner)/\(repository)" }

    /// The repository's public page. Built from validated components rather than kept from the
    /// input, so nothing the user typed survives into a request unexamined.
    var webURL: URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/\(owner)/\(repository)"
        return components.url
    }

    /// The download URL for one file at one exact revision.
    ///
    /// `revision` must be an exact immutable revision; a branch name here would produce a URL that
    /// resolves to different bytes tomorrow, which is the thing decision 9 forbids. The planner is
    /// what guarantees that, and `LocalModelDownloadPlan` refuses to be built without it.
    func fileURL(revision: String, relativePath: String) -> URL? {
        guard case .contained(let normalized) = LocalModelPath.normalize(relativePath),
              LocalModelRepositoryReference.isValidRevision(revision) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        // Percent-encoded per component: a path segment is data, and letting `?` or `#` from a
        // filename become URL syntax is exactly how a path turns into a query.
        let segments = ["", owner, repository, "resolve", revision]
            + normalized.split(separator: "/").map(String.init)
        components.percentEncodedPath = segments
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
            .joined(separator: "/")
        return components.url
    }

    /// An exact revision is a full 40-character hex commit. Short hashes and branch names are both
    /// refused: a short hash is ambiguous and a branch moves.
    static func isValidRevision(_ revision: String) -> Bool {
        revision.count == 40 && revision.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }
}

/// Why an import string was refused. One case per rule, so the UI can say which rule and the log
/// can record the case name with none of the text that triggered it.
enum LocalModelImportRejection: Error, Equatable, Sendable {
    /// Nothing but whitespace.
    case empty
    /// Not parseable as a URL at all.
    case notAURL
    /// A host-looking string with no scheme (`huggingface.co/owner/repo`). Refused rather than
    /// upgraded to HTTPS: silently choosing the scheme for someone is how a downgrade goes unseen.
    case missingScheme
    /// Any scheme other than HTTPS, `http` included.
    case disallowedScheme(String)
    /// `https://user:password@host/…`.
    case embeddedCredentials
    /// A query string. Repository URLs need none, and a query is where token material travels.
    case queryNotAllowed
    /// A fragment. Same reasoning, plus it is a second place to hide a path.
    case fragmentNotAllowed
    /// A host that is not on the allowlist.
    case disallowedHost(String)
    /// A private, loopback, link-local or otherwise reserved host.
    case privateOrReservedHost(String)
    /// The path is not exactly `/owner/repository` — a file, branch, or app route.
    case pathOutsideRepositoryForm
    /// The owner segment is not a legal repository-owner name.
    case malformedOwner
    /// The repository segment is not a legal repository name.
    case malformedRepository

    /// User-facing copy. Deliberately says which rule failed and what to do instead; it never
    /// echoes the input, because a rejection message is also the most convenient place to leak it.
    var localizedMessage: String {
        switch self {
        case .empty:
            return "Enter a model repository, for example owner/repository."
        case .notAURL:
            return "That isn't a repository name or a web address."
        case .missingScheme:
            return "Paste the full address, starting with https://."
        case .disallowedScheme:
            return "Only https:// addresses can be imported."
        case .embeddedCredentials:
            return "Addresses with a username or password can't be imported."
        case .queryNotAllowed:
            return "Remove everything after the ? — a repository address needs no query."
        case .fragmentNotAllowed:
            return "Remove everything after the # — a repository address needs no fragment."
        case .disallowedHost:
            return "Models can only be imported from a supported public model host."
        case .privateOrReservedHost:
            return "That address points at a private or reserved network."
        case .pathOutsideRepositoryForm:
            return "Use the repository address itself, without a file or branch path."
        case .malformedOwner:
            return "That owner name isn't valid."
        case .malformedRepository:
            return "That repository name isn't valid."
        }
    }
}

extension LocalModelRepositoryReference {

    // MARK: - Host policy

    /// Hosts a repository may be named by. One entry today; the set exists so adding a second host
    /// is a data change with a test, not an `if` somewhere in the parser.
    ///
    /// `hf.co` is the same service's short form and canonicalizes to `huggingface.co`, so a
    /// reference has one spelling regardless of what was pasted.
    static let allowedRepositoryHosts: [String: String] = [
        "huggingface.co": "huggingface.co",
        "www.huggingface.co": "huggingface.co",
        "hf.co": "huggingface.co",
        "www.hf.co": "huggingface.co",
    ]

    /// Registrable domains a *download* response may finally land on.
    ///
    /// This is intentionally broader than the repository host: weights are served by CDN hosts
    /// under the same domains (`us.aws.cdn.hf.co`, `cdn-lfs.huggingface.co`,
    /// `transfer.xethub.hf.co`), so pinning the download to the exact repository host would refuse
    /// every real download. The rule is "same domain family, HTTPS, no credentials" and it is
    /// re-checked on every response, not only on the request we built.
    static let allowedDownloadDomains: [String] = ["huggingface.co", "hf.co"]

    /// Whether a response's final host may serve model bytes.
    static func isAllowedDownloadHost(_ rawHost: String?) -> Bool {
        guard let rawHost, !rawHost.isEmpty else { return false }
        let host = rawHost.lowercased()
        guard !URLFetchGuard.isBlockedHost(host) else { return false }
        return allowedDownloadDomains.contains { domain in
            host == domain || host.hasSuffix("." + domain)
        }
    }

    /// Whether a redirect target is acceptable: HTTPS, no credentials, allowlisted domain family.
    static func isAllowedDownloadURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        guard (url.scheme ?? "").lowercased() == "https" else { return false }
        guard url.user == nil, url.password == nil else { return false }
        return isAllowedDownloadHost(url.host)
    }

    // MARK: - Parsing

    /// Parse `owner/repository` or a full HTTPS repository URL.
    ///
    /// Refuses in the order the rules are cheapest to check, so the reason a user sees is the
    /// first thing actually wrong rather than whichever check happened to run last.
    static func parse(_ raw: String) -> Result<LocalModelRepositoryReference, LocalModelImportRejection> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        // A control character or whitespace inside the string is never part of a legal reference,
        // and is the cheapest way to smuggle a second line into a request.
        guard !trimmed.contains(where: { $0.isWhitespace || $0.unicodeScalars.contains(where: { $0.value < 0x20 }) })
        else { return .failure(.notAURL) }

        if trimmed.contains("://") || trimmed.hasPrefix("//") {
            return parseURLForm(trimmed)
        }
        return parseShorthand(trimmed)
    }

    /// `owner/repository`, with no scheme and no host.
    private static func parseShorthand(
        _ input: String) -> Result<LocalModelRepositoryReference, LocalModelImportRejection> {
        let components = input.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // A leading host with no scheme is a specific, common mistake: name it rather than letting
        // it fail as a malformed owner, and never repair it by inventing `https://`.
        if let first = components.first?.lowercased(), allowedRepositoryHosts[first] != nil {
            return .failure(.missingScheme)
        }
        guard components.count == 2 else {
            return components.count > 2 ? .failure(.pathOutsideRepositoryForm) : .failure(.notAURL)
        }
        return assemble(host: "huggingface.co", owner: components[0], repository: components[1])
    }

    private static func parseURLForm(
        _ input: String) -> Result<LocalModelRepositoryReference, LocalModelImportRejection> {
        guard let components = URLComponents(string: input) else { return .failure(.notAURL) }

        let scheme = (components.scheme ?? "").lowercased()
        guard !scheme.isEmpty else { return .failure(.missingScheme) }
        guard scheme == "https" else { return .failure(.disallowedScheme(scheme)) }

        guard components.user == nil, components.password == nil else {
            return .failure(.embeddedCredentials)
        }
        guard components.query == nil, components.percentEncodedQuery == nil else {
            return .failure(.queryNotAllowed)
        }
        guard components.fragment == nil, components.percentEncodedFragment == nil else {
            return .failure(.fragmentNotAllowed)
        }

        guard let rawHost = components.host, !rawHost.isEmpty else { return .failure(.notAURL) }
        let host = rawHost.lowercased()
        // Checked before the allowlist so a private address is reported as what it is. No
        // allowlisted host can be private today; the ordering is what keeps that true if one day a
        // host resolves differently.
        guard !URLFetchGuard.isBlockedHost(host) else { return .failure(.privateOrReservedHost(host)) }
        guard let canonical = allowedRepositoryHosts[host] else { return .failure(.disallowedHost(host)) }

        // Decoded path segments: `%2e%2e` must be a traversal here, not a literal name.
        let decodedPath = components.path.removingPercentEncoding ?? components.path
        let segments = decodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard segments.count == 2 else { return .failure(.pathOutsideRepositoryForm) }
        return assemble(host: canonical, owner: segments[0], repository: segments[1])
    }

    private static func assemble(
        host: String, owner: String,
        repository: String) -> Result<LocalModelRepositoryReference, LocalModelImportRejection> {
        guard isValidName(owner) else { return .failure(.malformedOwner) }
        // `git clone` copy/paste is the one repair worth making: it changes no host, no path, and
        // no meaning.
        let repositoryName = repository.hasSuffix(".git") ? String(repository.dropLast(4)) : repository
        guard isValidName(repositoryName) else { return .failure(.malformedRepository) }
        return .success(LocalModelRepositoryReference(host: host, owner: owner, repository: repositoryName))
    }

    /// A legal owner or repository segment.
    ///
    /// Starts alphanumeric, then alphanumerics plus `.`, `_`, `-`; never contains `..`; bounded in
    /// length. The charset is what keeps a segment from being a path, a traversal, or URL syntax
    /// once it is pasted back into a request.
    static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 96 else { return false }
        guard !name.contains("..") else { return false }
        guard let first = name.first, first.isASCII, first.isLetter || first.isNumber else { return false }
        return name.allSatisfy { character in
            guard character.isASCII else { return false }
            return character.isLetter || character.isNumber
                || character == "." || character == "_" || character == "-"
        }
    }
}
