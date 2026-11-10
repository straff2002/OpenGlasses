import Foundation

/// One web page a reply's search cited: shown under the reply as **Sources (n)**, opened in
/// Safari, never spoken.
struct WebSource: Codable, Equatable, Hashable, Sendable {
    let title: String
    let url: String
    /// The page's host without `www.`, which is how the list names the site.
    let site: String
    /// Who searched: an `LLMProvider` raw value, or `avenkin` for our own `web_search`.
    let provider: String

    static let ourToolProvider = "avenkin"
    static let titleLimit = 160

    init(title: String, url: String, provider: String) {
        let site = WebSource.site(of: url)
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // xAI's annotation title is the citation number; a bare number is no title.
        let usable = trimmed.isEmpty || trimmed.allSatisfy(\.isNumber) ? site : trimmed
        self.title = String(usable.prefix(Self.titleLimit))
        self.url = url
        self.site = site
        self.provider = provider
    }

    static func site(of url: String) -> String {
        guard let host = URL(string: url)?.host?.lowercased() else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Only web addresses are kept: a source is opened in Safari.
    static func isWebURL(_ url: String) -> Bool {
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased() else { return false }
        return (scheme == "https" || scheme == "http") && parsed.host != nil
    }
}

/// What a provider-run search came back with, read from the provider's own response (Plan KZ §3).
///
/// One pure parser per response shape: Anthropic content blocks, Responses output items and
/// annotations (OpenAI, xAI), Chat Completions message annotations (OpenRouter, Groq), and
/// Gemini's `groundingMetadata`. Bounded on the way in: at most 5 queries of 200 characters,
/// 10 sources de-duplicated by address in the order the reply first cites them.
struct ProviderSearchEvidence: Equatable {
    var queries: [String] = []
    var sources: [WebSource] = []
    /// Anthropic's `cited_text` snippets (at most 150 characters each, by the provider's rule).
    var citedSnippets: [String] = []
    var searchCount = 0
    /// How many result pages the model saw. Pages it read are untrusted content in its context.
    var resultCount = 0
    /// The provider's error codes, by name only (`unavailable`, `too_many_requests`, …).
    var errors: [String] = []
    /// Gemini only: Google's Search Suggestions, which are shown with the grounded answer.
    var searchSuggestions: SearchSuggestions?

    static let maxQueries = 5
    static let queryLimit = 200
    static let maxSources = 10
    static let maxSnippets = 10
    static let snippetLimit = 150

    /// A search ran, or was attempted, in this response.
    var ranSearch: Bool { searchCount > 0 || !queries.isEmpty || !sources.isEmpty || !errors.isEmpty }
    /// The model read web content in this response (§5): any result page or cited source.
    var readWeb: Bool { resultCount > 0 || !sources.isEmpty || searchCount > errors.count }

    mutating func merge(_ other: ProviderSearchEvidence) {
        for query in other.queries { addQuery(query) }
        for source in other.sources { addSource(source) }
        for snippet in other.citedSnippets { addSnippet(snippet) }
        searchCount += other.searchCount
        resultCount += other.resultCount
        errors += other.errors
        if let suggestions = other.searchSuggestions { searchSuggestions = suggestions }
    }

    mutating func addQuery(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, queries.count < Self.maxQueries else { return }
        let bounded = String(trimmed.prefix(Self.queryLimit))
        if !queries.contains(bounded) { queries.append(bounded) }
    }

    mutating func addSource(_ source: WebSource) {
        guard WebSource.isWebURL(source.url), sources.count < Self.maxSources,
              !sources.contains(where: { $0.url == source.url }) else { return }
        sources.append(source)
    }

    mutating func addSnippet(_ snippet: String) {
        let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, citedSnippets.count < Self.maxSnippets else { return }
        citedSnippets.append(String(trimmed.prefix(Self.snippetLimit)))
    }

    // MARK: - Anthropic Messages

    /// `server_tool_use` (name `web_search`, `input.query`), `web_search_tool_result` (a list of
    /// `web_search_result`, or one `web_search_tool_result_error` with `error_code`), and text
    /// blocks' `web_search_result_location` citations. `usage.server_tool_use.web_search_requests`
    /// is the billed count when present.
    static func anthropic(content: [[String: Any]], usage: [String: Any]? = nil) -> ProviderSearchEvidence {
        var evidence = ProviderSearchEvidence()
        let provider = LLMProvider.anthropic.rawValue
        var calls = 0
        for block in content {
            switch block["type"] as? String {
            case "server_tool_use":
                guard block["name"] as? String == "web_search" else { continue }
                calls += 1
                if let query = (block["input"] as? [String: Any])?["query"] as? String {
                    evidence.addQuery(query)
                }
            case "web_search_tool_result":
                if let results = block["content"] as? [[String: Any]] {
                    evidence.resultCount += results.filter { $0["type"] as? String == "web_search_result" }.count
                } else if let error = block["content"] as? [String: Any],
                          let code = error["error_code"] as? String {
                    evidence.errors.append(code)
                }
            case "text":
                for citation in block["citations"] as? [[String: Any]] ?? []
                where citation["type"] as? String == "web_search_result_location" {
                    guard let url = citation["url"] as? String else { continue }
                    evidence.addSource(WebSource(title: citation["title"] as? String ?? "", url: url,
                                                 provider: provider))
                    if let cited = citation["cited_text"] as? String { evidence.addSnippet(cited) }
                }
            default:
                continue
            }
        }
        let billed = ((usage?["server_tool_use"] as? [String: Any])?["web_search_requests"] as? Int)
        evidence.searchCount = billed ?? calls
        return evidence
    }

    // MARK: - Responses (OpenAI, xAI)

    /// `web_search_call` items (`action.query` or `action.queries`, optional `action.sources`),
    /// and `url_citation` annotations on the answer's `output_text`. xAI also returns a top-level
    /// `citations` list of every address it saw, used when the text cites none.
    static func responses(_ response: [String: Any], provider: LLMProvider) -> ProviderSearchEvidence {
        var evidence = ProviderSearchEvidence()
        var seen: [WebSource] = []
        for item in response["output"] as? [[String: Any]] ?? [] {
            switch item["type"] as? String {
            case "web_search_call":
                let action = item["action"] as? [String: Any] ?? [:]
                let type = action["type"] as? String ?? "search"
                if type == "search" { evidence.searchCount += 1 }
                if let query = action["query"] as? String { evidence.addQuery(query) }
                for query in action["queries"] as? [String] ?? [] { evidence.addQuery(query) }
                for source in action["sources"] as? [[String: Any]] ?? [] {
                    if let url = source["url"] as? String {
                        seen.append(WebSource(title: source["title"] as? String ?? "", url: url,
                                              provider: provider.rawValue))
                    }
                }
                if let status = item["status"] as? String, status == "failed" {
                    evidence.errors.append("failed")
                }
            case "message":
                guard !ResponsesTranslator.isCommentary(item) else { continue }
                for block in item["content"] as? [[String: Any]] ?? [] {
                    for annotation in block["annotations"] as? [[String: Any]] ?? []
                    where annotation["type"] as? String == "url_citation" {
                        guard let url = annotation["url"] as? String else { continue }
                        evidence.addSource(WebSource(title: annotation["title"] as? String ?? "", url: url,
                                                     provider: provider.rawValue))
                    }
                }
            default:
                continue
            }
        }
        if evidence.sources.isEmpty {
            for url in response["citations"] as? [String] ?? [] {
                seen.append(WebSource(title: "", url: url, provider: provider.rawValue))
            }
            for source in seen { evidence.addSource(source) }
        }
        evidence.resultCount = max(evidence.resultCount, seen.count)
        // xAI reports server-side tool use by tool in its usage block.
        if let usage = response["usage"] as? [String: Any],
           let byTool = usage["server_side_tool_usage"] as? [String: Any] {
            let searches = byTool.filter { $0.key.lowercased().contains("search") }
                .compactMap { $0.value as? Int }.reduce(0, +)
            if searches > 0 { evidence.searchCount = searches }
        }
        return evidence
    }

    // MARK: - Chat Completions (OpenRouter, Groq)

    /// OpenRouter: `message.annotations[]` of `{type: url_citation, url_citation: {url, title,
    /// content}}`, and `usage.server_tool_use_details.web_search_requests`. Groq: `executed_tools`
    /// on the message (read defensively; Groq does not document their fields).
    static func chatMessage(_ message: [String: Any], usage: [String: Any]? = nil,
                            provider: LLMProvider) -> ProviderSearchEvidence {
        var evidence = ProviderSearchEvidence()
        for annotation in message["annotations"] as? [[String: Any]] ?? []
        where annotation["type"] as? String == "url_citation" {
            let citation = annotation["url_citation"] as? [String: Any] ?? annotation
            guard let url = citation["url"] as? String else { continue }
            evidence.addSource(WebSource(title: citation["title"] as? String ?? "", url: url,
                                         provider: provider.rawValue))
        }
        for tool in message["executed_tools"] as? [[String: Any]] ?? [] {
            let type = (tool["type"] as? String ?? "").lowercased()
            guard type.contains("search") else { continue }
            evidence.searchCount += 1
            if let arguments = tool["arguments"] as? String,
               let parsed = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any],
               let query = parsed["query"] as? String {
                evidence.addQuery(query)
            }
            let results = (tool["search_results"] as? [String: Any])?["results"] as? [[String: Any]] ?? []
            evidence.resultCount += results.count
            for result in results {
                if let url = result["url"] as? String {
                    evidence.addSource(WebSource(title: result["title"] as? String ?? "", url: url,
                                                 provider: provider.rawValue))
                }
            }
        }
        if let requests = (usage?["server_tool_use_details"] as? [String: Any])?["web_search_requests"] as? Int,
           requests > 0 {
            evidence.searchCount = requests
        } else if evidence.searchCount == 0, !evidence.sources.isEmpty {
            evidence.searchCount = 1
        }
        return evidence
    }

    // MARK: - Gemini generateContent

    /// `candidates[0].groundingMetadata`: `webSearchQueries`, `groundingChunks[].web {uri,title}`
    /// (the uri is a Google redirect, kept as given), `groundingSupports[].groundingChunkIndices`
    /// for the order the answer cites them, and `searchEntryPoint.renderedContent`.
    static func gemini(candidate: [String: Any]) -> ProviderSearchEvidence {
        var evidence = ProviderSearchEvidence()
        guard let metadata = candidate["groundingMetadata"] as? [String: Any] else { return evidence }
        let queries = metadata["webSearchQueries"] as? [String] ?? []
        queries.forEach { evidence.addQuery($0) }
        evidence.searchCount = queries.count
        let chunks = (metadata["groundingChunks"] as? [[String: Any]] ?? []).map { $0["web"] as? [String: Any] ?? [:] }
        evidence.resultCount = chunks.count
        var order: [Int] = []
        for support in metadata["groundingSupports"] as? [[String: Any]] ?? [] {
            for index in support["groundingChunkIndices"] as? [Int] ?? [] where !order.contains(index) {
                order.append(index)
            }
        }
        if order.isEmpty { order = Array(chunks.indices) }
        for index in order where chunks.indices.contains(index) {
            if let uri = chunks[index]["uri"] as? String {
                evidence.addSource(WebSource(title: chunks[index]["title"] as? String ?? "", url: uri,
                                             provider: LLMProvider.gemini.rawValue))
            }
        }
        evidence.searchSuggestions = SearchSuggestions(groundingMetadata: metadata)
        return evidence
    }

    // MARK: - Our own tool

    /// The addresses our `web_search` listed on its `Sources:` line (`[1] https://…, [2] …`), so
    /// a reply from our tool shows the same list as one from the provider's.
    static func ourToolSources(fromResult result: String) -> [WebSource] {
        guard let line = result.components(separatedBy: "\n").last(where: { $0.hasPrefix("Sources:") }) else {
            return []
        }
        var evidence = ProviderSearchEvidence()
        for token in line.split(whereSeparator: { $0 == " " || $0 == "," }) {
            let candidate = String(token)
            if candidate.hasPrefix("http") {
                evidence.addSource(WebSource(title: "", url: candidate, provider: WebSource.ourToolProvider))
            }
        }
        return evidence.sources
    }

    // MARK: - The support trace

    /// The note's "returned text": cited pages and snippets, since a provider's results are not
    /// returned to the app (Anthropic's are encrypted). Bounded by the trace's own limits.
    var traceText: String {
        var lines: [String] = []
        lines.append("searches: \(searchCount)")
        if !errors.isEmpty { lines.append("errors: " + errors.joined(separator: ", ")) }
        if !sources.isEmpty {
            lines.append("cited pages:")
            lines += sources.map { "- \($0.title) — \($0.url)" }
        }
        if !citedSnippets.isEmpty {
            lines.append("cited text:")
            lines += citedSnippets.map { "- \($0)" }
        }
        return lines.joined(separator: "\n")
    }
}

/// Google's Search Suggestions for a grounded Gemini reply (Plan KZ, Decision 6): the HTML
/// snippet Google returns for rendering them (`searchEntryPoint.renderedContent`), kept exactly
/// as given and shown unaltered under the reply, with the searches it ran and the suggestion
/// links (`searchEntryPoint.sdkBlob`). Stored with the conversation message, so a reply that
/// landed while the phone was locked still shows them in the thread.
struct SearchSuggestions: Codable, Equatable, Hashable, Sendable {
    struct Link: Codable, Equatable, Hashable, Sendable {
        let query: String
        let url: String
    }

    /// Google's snippet, byte for byte. Never edited and never mixed with other content.
    let renderedContent: String
    /// `webSearchQueries`: what the model searched for.
    let queries: [String]
    /// The suggestion chips' searches and their Google addresses, from `sdkBlob`.
    let links: [Link]

    init(renderedContent: String, queries: [String] = [], links: [Link] = []) {
        self.renderedContent = renderedContent
        self.queries = queries
        self.links = links
    }

    /// From a candidate's `groundingMetadata`; nil when Google sent no snippet.
    init?(groundingMetadata metadata: [String: Any]) {
        guard let entry = metadata["searchEntryPoint"] as? [String: Any],
              let html = entry["renderedContent"] as? String,
              !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.init(renderedContent: html, queries: metadata["webSearchQueries"] as? [String] ?? [],
                  links: Self.links(fromSDKBlob: entry["sdkBlob"] as? String))
    }

    /// `sdkBlob` is base64 JSON of search-term and search-address pairs. Read leniently: pairs
    /// as two-element arrays or as objects; anything else gives no links.
    static func links(fromSDKBlob blob: String?) -> [Link] {
        guard let blob, let data = Data(base64Encoded: blob),
              let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let rows: [Any]
        if let array = json as? [Any] { rows = array }
        else if let object = json as? [String: Any], let array = object["items"] as? [Any] ?? object["searchSuggestions"] as? [Any] { rows = array }
        else { return [] }
        return rows.compactMap { row in
            if let pair = row as? [String], pair.count >= 2, WebSource.isWebURL(pair[1]) {
                return Link(query: pair[0], url: pair[1])
            }
            if let object = row as? [String: Any] {
                let query = object["query"] as? String ?? object["searchTerm"] as? String ?? object["term"] as? String
                let url = object["url"] as? String ?? object["searchUrl"] as? String ?? object["uri"] as? String
                if let query, let url, WebSource.isWebURL(url) { return Link(query: query, url: url) }
            }
            return nil
        }
    }
}

/// What a navigation inside the Search Suggestions view may do (Plan KZ, Decision 6). The
/// snippet's own first load is allowed; a tapped link opens in Safari, directly, at exactly the
/// address it names — no in-app browser, no interstitial, no tracking, nothing logged. Anything
/// else (a redirect, a form, a script navigating) is cancelled.
enum SearchSuggestionsLinkPolicy {
    enum Navigation: Equatable {
        case initialLoad
        case linkTapped
        case other
    }

    enum Action: Equatable {
        case allow
        case openInSafari(URL)
        case cancel
    }

    static func action(for navigation: Navigation, url: URL?) -> Action {
        switch navigation {
        case .initialLoad:
            return .allow
        case .linkTapped:
            guard let url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
                  url.host != nil else { return .cancel }
            return .openInSafari(url)
        case .other:
            return .cancel
        }
    }
}

/// What an assistant reply carries under it in the conversation thread: its web sources and,
/// for a grounded Gemini reply, Google's Search Suggestions. A user turn carries neither.
struct ReplyAttachments: Equatable {
    let sources: [WebSource]
    let suggestions: SearchSuggestions?

    init(message: ConversationMessage) {
        let isReply = message.role == "assistant"
        sources = isReply ? message.sources : []
        suggestions = isReply ? message.searchSuggestions : nil
    }

    var isEmpty: Bool { sources.isEmpty && suggestions == nil }

    /// Each reply's attachments by message id, for the thread view.
    static func byMessage(_ messages: [ConversationMessage]) -> [String: ReplyAttachments] {
        var out: [String: ReplyAttachments] = [:]
        for message in messages {
            let attachments = ReplyAttachments(message: message)
            if !attachments.isEmpty { out[message.id] = attachments }
        }
        return out
    }
}
