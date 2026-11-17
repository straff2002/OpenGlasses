import Foundation

/// The fields of an add-on the assistant builds that the app fills in itself, never the model:
/// the id, the version and the author. Pure.
///
/// - `id` is `local.assistant.<slug>`, the slug made from the add-on's name, with `-2`, `-3`… when
///   that id is already taken (installed, or held by another draft). An update keeps its id.
/// - `version` is `1.0.0` for a new add-on; an update is the installed version's minor plus one.
/// - `author.name` is fixed; `author.web` is the documentation page the assistant actually read
///   (or the service's own address when it read none), so the sheet's domain line says where the
///   data comes from.
///
/// Where it came from is store metadata (`AddOnOrigin.selfBuilt`), not a field: the file stays a
/// plain add-on file wherever it travels.
enum SelfBuiltIdentity {

    static let idPrefix = "local.assistant."
    /// The author line every self-built add-on carries.
    static let authorName = "Built on this phone"
    static let firstVersion = "1.0.0"
    static let fallbackSlug = "addon"
    /// Room for the prefix and a collision suffix inside the validator's id limit.
    static let maxSlugLength = RecipeAddOnValidator.maxIDLength - idPrefix.count - 4

    /// Lowercase ASCII letters and digits, words joined by single hyphens.
    static func slug(from name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var out = ""
        var pendingHyphen = false
        for scalar in folded.unicodeScalars {
            let isWordCharacter = scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)
            if isWordCharacter {
                if pendingHyphen && !out.isEmpty { out.append("-") }
                pendingHyphen = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingHyphen = true
            }
        }
        if out.count > maxSlugLength {
            out = String(out.prefix(maxSlugLength))
            while out.hasSuffix("-") { out.removeLast() }
        }
        return out.isEmpty ? fallbackSlug : out
    }

    /// A new add-on's id, unique against `taken`.
    static func id(forName name: String, taken: Set<String>) -> String {
        let base = idPrefix + slug(from: name)
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    /// Whether an id has the shape the assistant gives the add-ons it builds. Anyone can write
    /// such an id, so this is a note on a sheet, never a trust decision.
    static func isSelfBuiltID(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    /// The version an improvement gets: the installed version's minor plus one, patch zero.
    static func nextVersion(after installed: String) -> String {
        let core = installed.split(separator: "+", maxSplits: 1).first.map(String.init) ?? installed
        let release = core.split(separator: "-", maxSplits: 1).first.map(String.init) ?? core
        let numbers = release.split(separator: ".").compactMap { Int($0) }
        guard numbers.count == 3, RecipeAddOnValidator.isValidVersion(installed) else { return "1.1.0" }
        return "\(numbers[0]).\(numbers[1] + 1).0"
    }

    /// `author.web`: the first documentation page the session fetched that the draft names, else
    /// the first page it fetched, else the service's own address. Only HTTPS, never a page nobody
    /// read: the sheet shows its domain as where the add-on comes from.
    static func authorWeb(claimed: String?, fetched: [URL], serviceHosts: [String]) -> String? {
        let pages = fetched.filter { $0.scheme?.lowercased() == "https" && $0.host != nil }
        if let claimed, let match = pages.first(where: { $0.absoluteString == claimed }) {
            return shown(match)
        }
        if let first = pages.first { return shown(first) }
        if let host = serviceHosts.first { return "https://\(host)" }
        return nil
    }

    /// The page as the file records it: no user, query or fragment, and short enough for the
    /// validator's limit (the host alone when the path is too long).
    static func shown(_ page: URL) -> String? {
        guard var parts = URLComponents(url: page, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty else { return nil }
        parts.user = nil
        parts.password = nil
        parts.query = nil
        parts.fragment = nil
        parts.port = nil
        let full = parts.string ?? "https://\(host)"
        return full.count <= 200 && !full.contains("{{") ? full : "https://\(host)"
    }
}
