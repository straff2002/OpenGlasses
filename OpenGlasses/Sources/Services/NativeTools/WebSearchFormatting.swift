import Foundation

/// How recent `web_search` results must be — the time a question is about ("last night",
/// "this week"), passed as a filter rather than written into the query as a date.
enum WebSearchRecency: String, CaseIterable, Equatable {
    case day, week, month, year

    /// A `recency` argument, leniently: case and whitespace ignored, anything else dropped.
    init?(argument: Any?) {
        guard let raw = argument as? String else { return nil }
        self.init(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// The backend's own filter for this recency, as the parameter's name and value — nil where the
    /// backend has none, and the recency is then dropped without a word (DuckDuckGo's instant
    /// answers have no date filter; putting a year into the query instead changes what it means).
    func filter(for backend: WebSearchBackend) -> (name: String, value: String)? {
        switch backend {
        case .perplexity: return ("search_recency_filter", rawValue)
        case .tavily: return ("time_range", rawValue)
        case .brave: return ("freshness", "p" + String(rawValue.prefix(1)))
        case .searxng: return ("time_range", rawValue)
        case .duckDuckGo: return nil
        }
    }
}

/// The search services `web_search` can answer from.
enum WebSearchBackend: CaseIterable, Equatable {
    case perplexity, tavily, brave, searxng, duckDuckGo
}

/// What `web_search` hands the model: the answer, the links for the phone under a line telling
/// the model not to read them out, and **one** source as a name it can say ("Source: Stuff
/// (stuff.co.nz)"). The reply is spoken, so "[1] https://…" is no use to the ear; the phone still
/// shows every link, read from the `Sources:` line by `ProviderSearchEvidence.ourToolSources`.
///
/// Pure.
enum WebSearchResultFormat {

    /// One result's address and what is known about whose it is.
    struct Link: Equatable {
        var url: String
        var title: String? = nil
        /// The site's own name when the service gives one (Brave's `profile.name`,
        /// DuckDuckGo's `AbstractSource`).
        var siteName: String? = nil
    }

    /// The line above the links. The tool's description tells the model the same.
    static let phoneLinksLine = "For the phone — don't read these out:"

    /// Links listed for the phone.
    static let linkLimit = 3

    /// `header: summary`, then the phone's links and the one source to name, when there are links.
    static func compose(header: String, summary: String, links: [Link]) -> String {
        var result = "\(header): \(summary)"
        let shown = links.filter { !$0.url.isEmpty }.prefix(linkLimit)
        guard let top = shown.first else { return result }
        let list = shown.enumerated().map { "[\($0.offset + 1)] \($0.element.url)" }.joined(separator: ", ")
        result += "\n\n\(phoneLinksLine)\nSources: \(list)"
        if let line = sourceLine(for: top) { result += "\n\n\(line)" }
        return result
    }

    /// "Source: Stuff (stuff.co.nz)" — or "Source: stuff.co.nz" when nothing names the site.
    static func sourceLine(for link: Link) -> String? {
        guard let domain = domain(of: link.url) else { return nil }
        let name = nonEmpty(link.siteName) ?? link.title.flatMap { siteName(fromTitle: $0, domain: domain) }
        guard let name, name.lowercased() != domain else { return "Source: \(domain)" }
        return "Source: \(name) (\(domain))"
    }

    /// The host without the prefixes that say nothing ("www.", "m.", "amp.", "mobile.").
    static func domain(of url: String) -> String? {
        guard var host = URL(string: url)?.host?.lowercased(), !host.isEmpty else { return nil }
        for prefix in ["www.", "m.", "amp.", "mobile."] where host.hasPrefix(prefix) {
            host.removeFirst(prefix.count)
            break
        }
        return host.isEmpty ? nil : host
    }

    /// The site's name from a page title's last segment ("All Blacks win | Stuff" → "Stuff"), kept
    /// only when it matches the address — so "How to fix it - Step by step" names nobody.
    static func siteName(fromTitle title: String, domain: String) -> String? {
        let separators = [" | ", " - ", " – ", " — "]
        var last: Substring?
        for separator in separators {
            if let range = title.range(of: separator, options: .backwards) {
                let candidate = title[range.upperBound...]
                if last.map({ candidate.count < $0.count }) ?? true { last = candidate }
            }
        }
        guard let segment = last?.trimmingCharacters(in: .whitespaces), !segment.isEmpty,
              segment.count <= 30, segment.split(separator: " ").count <= 4 else { return nil }
        let squashed = segment.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !squashed.isEmpty else { return nil }
        // The address's own labels, without the top-level domain and the generic second levels
        // ("stuff.co.nz" → stuff, "en.wikipedia.org" → en, wikipedia).
        let generic: Set<String> = ["co", "com", "org", "net", "gov", "ac", "edu"]
        let labels = domain.split(separator: ".").dropLast().map(String.init).filter { !generic.contains($0) }
        let matches = labels.contains { label in
            label == squashed || (label.count >= 3 && (squashed.contains(label) || label.contains(squashed)))
        }
        return matches ? segment : nil
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
