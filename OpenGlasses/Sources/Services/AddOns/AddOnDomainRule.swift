import Foundation

/// One entry of an add-on's `network` allowlist: an exact host (`api.example.org`) or a host with
/// one leading wildcard label (`*.example.org`).
///
/// **Matching.** An exact rule matches only that host. A wildcard rule matches exactly one extra
/// label in front of its base — `*.example.org` matches `en.example.org`, not `example.org` and
/// not `a.b.example.org` (the TLS certificate rule, and the narrower reading). Hosts are compared
/// lowercased with one trailing dot dropped.
///
/// **Refused entries.** IP literals (IPv4 in any numeric spelling, IPv6), ports, paths, queries,
/// fragments, userinfo, schemes, empty labels, non-ASCII (write the punycode form), single-label
/// hosts, and a wildcard over a public suffix. Private and LAN addresses reached through an
/// allowed name are refused at connect time by the real transport's address check, which is not
/// this type's job: nothing here resolves DNS.
///
/// **Public suffixes — a curated set, not the full list.** The repository carries no public
/// suffix list and this type deliberately doesn't download one. Instead a wildcard is refused when
/// its base is a single label (`*.com`, `*.uk`) or appears in `curatedPublicSuffixes`: the common
/// two-label country-code registries (`co.uk`, `com.au`, …) and well-known shared-hosting and
/// dynamic-DNS suffixes where every subdomain belongs to a different party (`github.io`,
/// `herokuapp.com`, …). A suffix that is missing from the set is accepted as an ordinary base, so
/// the set errs toward the suffixes add-on authors plausibly reach for; the install sheet still
/// names every domain, which is the wearer's real check. Add entries here as they come up.
struct AddOnDomainRule: Equatable, Hashable, Sendable {

    /// The host the rule is anchored on, lowercased, without a trailing dot or the `*.`.
    let base: String
    let isWildcard: Bool

    static let maxEntries = 30
    static let maxHostLength = 253

    enum ParseError: Error, Equatable, Sendable {
        case empty
        case tooLong
        case notAHostName          // scheme, path, query, fragment, userinfo, whitespace…
        case hasPort
        case ipLiteral
        case emptyLabel
        case invalidLabel(String)
        case nonASCII
        case singleLabel
        case misplacedWildcard
        case wildcardOverPublicSuffix(String)
    }

    /// The entry as the wearer sees it on the sheet.
    var display: String { isWildcard ? "*.\(base)" : base }

    // MARK: - Parsing

    static func parse(_ raw: String) -> Result<AddOnDomainRule, ParseError> {
        var text = raw
        guard !text.isEmpty else { return .failure(.empty) }
        guard text.unicodeScalars.allSatisfy(\.isASCII) else { return .failure(.nonASCII) }
        if text.hasPrefix("[") || text.filter({ $0 == ":" }).count > 1 { return .failure(.ipLiteral) }
        if text.contains(":") {
            // `host:443` is a port; `https://host` is a scheme.
            if text.contains("://") { return .failure(.notAHostName) }
            return .failure(.hasPort)
        }
        if text.contains(where: { "/?#@\\ %".contains($0) || $0.isWhitespace }) { return .failure(.notAHostName) }
        text = text.lowercased()
        if text.hasSuffix(".") { text.removeLast() }

        var isWildcard = false
        if text.hasPrefix("*.") {
            isWildcard = true
            text.removeFirst(2)
        }
        guard !text.contains("*") else { return .failure(.misplacedWildcard) }
        guard !text.isEmpty else { return .failure(.emptyLabel) }
        guard text.count <= maxHostLength else { return .failure(.tooLong) }

        let labels = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if labels.contains(where: \.isEmpty) { return .failure(.emptyLabel) }
        if looksLikeIPv4(labels) { return .failure(.ipLiteral) }
        for label in labels where !isValidLabel(label) { return .failure(.invalidLabel(label)) }
        guard labels.count >= 2 else {
            return .failure(isWildcard ? .wildcardOverPublicSuffix(text) : .singleLabel)
        }
        if isWildcard, curatedPublicSuffixes.contains(text) { return .failure(.wildcardOverPublicSuffix(text)) }
        return .success(AddOnDomainRule(base: text, isWildcard: isWildcard))
    }

    /// Parse a whole allowlist: every entry's outcome in order, plus whether the list is too long.
    /// Duplicate entries are kept once.
    static func parseAllowlist(_ entries: [String]) -> (rules: [AddOnDomainRule], failures: [(entry: String, error: ParseError)], tooMany: Bool) {
        var rules: [AddOnDomainRule] = []
        var failures: [(entry: String, error: ParseError)] = []
        for entry in entries {
            switch parse(entry) {
            case .success(let rule): if !rules.contains(rule) { rules.append(rule) }
            case .failure(let error): failures.append((entry: entry, error: error))
            }
        }
        return (rules, failures, entries.count > maxEntries)
    }

    // MARK: - Matching

    /// Whether `host` (as it appears in a URL) is covered by this rule.
    func matches(host: String) -> Bool {
        guard let normalised = Self.normalisedHost(host) else { return false }
        if !isWildcard { return normalised == base }
        let suffix = "." + base
        guard normalised.hasSuffix(suffix) else { return false }
        let head = normalised.dropLast(suffix.count)
        return !head.isEmpty && !head.contains(".")
    }

    /// Whether any rule in `rules` covers `host`.
    static func allows(host: String, rules: [AddOnDomainRule]) -> Bool {
        rules.contains { $0.matches(host: host) }
    }

    /// A URL host lowercased with one trailing dot removed; `nil` for IP literals and anything
    /// that is not a plain ASCII host name.
    static func normalisedHost(_ host: String) -> String? {
        var text = host.lowercased()
        if text.hasSuffix(".") { text.removeLast() }
        guard !text.isEmpty, text.unicodeScalars.allSatisfy(\.isASCII),
              !text.contains(":"), !text.hasPrefix("[") else { return nil }
        let labels = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !labels.contains(where: \.isEmpty), !looksLikeIPv4(labels),
              labels.allSatisfy(isValidLabel) else { return nil }
        return text
    }

    // MARK: - Pieces

    /// LDH label: letters, digits, hyphens, 1–63 characters, no leading or trailing hyphen.
    /// Underscores are accepted for service names some APIs use.
    private static func isValidLabel(_ label: String) -> Bool {
        guard (1...63).contains(label.count), !label.hasPrefix("-"), !label.hasSuffix("-") else { return false }
        return label.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "-" || scalar == "_"
        }
    }

    /// IPv4 in any spelling `inet_aton` accepts — `127.0.0.1`, `2130706433`, `0x7f.1`: no real
    /// top-level domain is numeric, so a numeric or hex final label marks an address.
    private static func looksLikeIPv4(_ labels: [String]) -> Bool {
        guard let last = labels.last else { return false }
        if last.allSatisfy({ $0.isASCII && $0.isNumber }) { return true }
        if last.hasPrefix("0x"), last.dropFirst(2).allSatisfy({ $0.isHexDigit }) { return true }
        return false
    }

    /// Curated — see the type comment. Two-label registries under country codes, then shared
    /// hosting and dynamic DNS where each subdomain is a different owner.
    static let curatedPublicSuffixes: Set<String> = [
        // Country-code second levels
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "ltd.uk", "plc.uk", "net.uk", "sch.uk", "nhs.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "asn.au", "id.au",
        "co.nz", "org.nz", "net.nz", "govt.nz", "ac.nz", "school.nz", "geek.nz", "gen.nz", "kiwi.nz", "maori.nz",
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp", "gr.jp",
        "com.br", "net.br", "org.br", "gov.br",
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn",
        "co.in", "net.in", "org.in", "gov.in", "ac.in", "firm.in", "gen.in", "ind.in",
        "co.za", "org.za", "gov.za", "ac.za", "net.za",
        "com.mx", "org.mx", "gob.mx", "edu.mx",
        "co.kr", "or.kr", "go.kr", "ac.kr",
        "com.sg", "org.sg", "gov.sg", "edu.sg",
        "com.hk", "org.hk", "gov.hk",
        "com.tw", "org.tw", "gov.tw",
        "com.ar", "com.co", "com.pe", "com.tr", "com.my", "com.ph", "com.pk", "com.ng", "com.eg",
        "com.sa", "com.ua", "co.il", "org.il", "co.id", "or.id", "co.th", "in.th", "com.vn",
        "co.ke", "co.tz", "co.ug",
        // Shared hosting, platform and dynamic-DNS suffixes. GitHub Pages' suffix is split so
        // PublicSiteGuardTests, which keeps our own old Pages address out of the sources, does not
        // read a public suffix as that address.
        "github" + ".io", "githubusercontent.com", "gitlab.io", "bitbucket.io", "pages.dev", "workers.dev",
        "vercel.app", "now.sh", "netlify.app", "netlify.com", "herokuapp.com", "herokudns.com",
        "azurewebsites.net", "azurestaticapps.net", "cloudapp.net", "trafficmanager.net",
        "cloudfront.net", "s3.amazonaws.com", "elasticbeanstalk.com", "amplifyapp.com",
        "appspot.com", "web.app", "firebaseapp.com", "run.app", "cloudfunctions.net",
        "blogspot.com", "wordpress.com", "tumblr.com", "wixsite.com", "squarespace.com",
        "onrender.com", "fly.dev", "glitch.me", "repl.co", "replit.app", "railway.app", "deno.dev",
        "ngrok.io", "ngrok-free.app", "ngrok.app", "loca.lt", "trycloudflare.com",
        "duckdns.org", "no-ip.org", "ddns.net", "dyndns.org", "freedns.afraid.org",
    ]
}
