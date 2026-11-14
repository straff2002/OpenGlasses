import Foundation

/// Searches the web. Prefers Perplexity AI, then Tavily, then Brave Search, when an
/// API key is configured (grounded/cited answers first, then an independent web
/// index). Then SearXNG when an instance URL is configured (open-source meta-search).
/// With nothing configured, Tavily's keyless tier runs next (free, rate-limited, no signup),
/// then DuckDuckGo Instant Answer as a last resort.
struct WebSearchTool: NativeTool {
    let name = "web_search"
    /// Plan LT §2: the query is model-written and goes to a third-party search service.
    var egressProfile: NativeEgressProfile? { .webSearch }
    let description = "Search the web for current information: news, sport, weather, prices, opening hours, anything local and anything that changes. Don't search for common knowledge, small talk, maths or translation. Put the time a question is about in recency, never a date in the query, and read \"this week\" or \"last night\" against today's date. Returns a brief summary, then links for the phone that are never read out, then one source: name it in words (\"according to Stuff\"), never as a link. For current events, verify the exact event, date and local time against the sources. If results conflict or do not verify the requested fact, say you could not verify it. When the user corrects an answer, re-check the evidence rather than repeating it as confirmed."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": [
                "type": "string",
                "description": "The search query, without a date"
            ],
            "recency": [
                "type": "string",
                "enum": WebSearchRecency.allCases.map(\.rawValue),
                "description": "How recent the results must be, when the question is about a time: day for today or last night, week for this week, month, year"
            ]
        ],
        "required": ["query"]
    ]

    /// The refusal a wearer sees rather than a silently empty search.
    static let localOnlyMessage =
        "Cloud search is unavailable in medical local-only mode. "
        + MedicalEgressRefusal.userMessage

    func execute(args: [String: Any]) async throws -> String {
        guard let query = args["query"] as? String, !query.isEmpty else {
            return "No search query provided."
        }

        // The tool is already absent from the tool list in HIPAA mode; this covers the paths that
        // reach it another way (a cascade retry, an agent harness, a stale schema).
        guard MedicalEgressGuard.allows(.webSearch) else { return Self.localOnlyMessage }

        // A recency the backend cannot filter on is dropped, never folded into the query.
        let recency = WebSearchRecency(argument: args["recency"])

        // Try Perplexity first if configured
        if Config.isPerplexityConfigured {
            if let result = await searchPerplexity(query: query, recency: recency) {
                return result
            }
            // Fall through on failure
        }

        // Then Tavily if configured
        if Config.isTavilyConfigured {
            if let result = await searchTavily(query: query, recency: recency) {
                return result
            }
            // Fall through on failure
        }

        // Then Brave Search if configured
        if Config.isBraveConfigured {
            if let result = await searchBrave(query: query, recency: recency) {
                return result
            }
            // Fall through on failure
        }

        // Then SearXNG if configured (open-source meta-search, no API key)
        if Config.isSearXNGConfigured {
            if let result = await searchSearXNG(query: query, recency: recency) {
                return result
            }
            // Fall through on failure
        }

        // Zero-setup fallback: Tavily's keyless tier needs no account or API key.
        if !Config.isTavilyConfigured {
            if let result = await searchTavily(query: query, keyless: true, recency: recency) {
                return result
            }
        }

        return await searchDuckDuckGo(query: query)
    }

    // MARK: - Perplexity Search

    private func searchPerplexity(query: String, recency: WebSearchRecency?) async -> String? {
        guard let url = URL(string: "https://api.perplexity.ai/chat/completions") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(Config.perplexityAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        var body: [String: Any] = [
            "model": "sonar",
            "messages": [
                ["role": "user", "content": query]
            ],
            "max_tokens": 400,
            "return_citations": true
        ]
        if let filter = recency?.filter(for: .perplexity) { body[filter.name] = filter.value }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config)

        do {
            let (data, response) = try await session.consentedData(for: request, scope: .webSearch)

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                PrivacyLog.webSearch(.perplexity, succeeded: false,
                                     status: (response as? HTTPURLResponse)?.statusCode ?? 0)
                return nil // Fall back to DuckDuckGo
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let message = firstChoice["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                return nil
            }

            return WebSearchResultFormat.compose(header: "Search result for \"\(query)\" (via Perplexity)",
                                                 summary: content, links: Self.perplexityLinks(json))

        } catch let refusal as CloudProcessingRefusal {
            return refusal.localizedDescription
        } catch {
            PrivacyLog.webSearch(.perplexity, succeeded: false, error: SafeErrorSummary(error))
            return nil
        }
    }

    // MARK: - Tavily Search

    private func searchTavily(query: String, keyless: Bool = false, recency: WebSearchRecency?) async -> String? {
        guard let url = URL(string: "https://api.tavily.com/search") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if keyless {
            request.setValue("keyless", forHTTPHeaderField: "X-Tavily-Access-Mode")
        } else {
            request.setValue("Bearer \(Config.tavilyAPIKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        var body: [String: Any] = [
            "query": query,
            "search_depth": "basic",
            "include_answer": true,
            "max_results": 5
        ]
        if let filter = recency?.filter(for: .tavily) { body[filter.name] = filter.value }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config)

        do {
            let (data, response) = try await session.consentedData(for: request, scope: .webSearch)

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                PrivacyLog.webSearch(.tavily, succeeded: false,
                                     status: (response as? HTTPURLResponse)?.statusCode ?? 0)
                return nil // Fall back to DuckDuckGo
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            let results = json["results"] as? [[String: Any]] ?? []

            // Prefer Tavily's synthesized answer; otherwise stitch the top result snippets.
            var summary = (json["answer"] as? String) ?? ""
            if summary.isEmpty {
                let snippets = results.prefix(3).compactMap { $0["content"] as? String }
                summary = snippets.joined(separator: " ")
            }
            guard !summary.isEmpty else { return nil }

            let label = keyless ? "Tavily free" : "Tavily"
            return WebSearchResultFormat.compose(header: "Search result for \"\(query)\" (via \(label))",
                                                 summary: summary, links: Self.titledLinks(results))

        } catch let refusal as CloudProcessingRefusal {
            return refusal.localizedDescription
        } catch {
            PrivacyLog.webSearch(.tavily, succeeded: false, error: SafeErrorSummary(error))
            return nil
        }
    }

    // MARK: - Brave Search

    /// Brave Search web API: an independent index with plain result snippets —
    /// no LLM synthesis, so the summary is stitched from the top descriptions.
    private func searchBrave(query: String, recency: WebSearchRecency?) async -> String? {
        guard let url = Self.braveSearchURL(query: query, recency: recency) else { return nil }

        var request = URLRequest(url: url)
        request.setValue(Config.braveAPIKey, forHTTPHeaderField: "X-Subscription-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config)

        do {
            let (data, response) = try await session.consentedData(for: request, scope: .webSearch)

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                PrivacyLog.webSearch(.brave, succeeded: false,
                                     status: (response as? HTTPURLResponse)?.statusCode ?? 0)
                return nil
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let web = json["web"] as? [String: Any],
                  let results = web["results"] as? [[String: Any]], !results.isEmpty else {
                return nil
            }

            // Strip Brave's <strong> highlight tags from the snippets.
            func clean(_ text: String) -> String {
                text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            }

            let snippets = results.prefix(3).compactMap { item -> String? in
                guard let description = item["description"] as? String, !description.isEmpty else { return nil }
                let title = (item["title"] as? String).map { "\(clean($0)): " } ?? ""
                return "\(title)\(clean(description))"
            }
            guard !snippets.isEmpty else { return nil }

            return WebSearchResultFormat.compose(header: "Search result for \"\(query)\" (via Brave)",
                                                 summary: snippets.joined(separator: " · "),
                                                 links: Self.braveLinks(results))

        } catch let refusal as CloudProcessingRefusal {
            return refusal.localizedDescription
        } catch {
            PrivacyLog.webSearch(.brave, succeeded: false, error: SafeErrorSummary(error))
            return nil
        }
    }

    // MARK: - SearXNG Search

    /// SearXNG JSON API: open-source meta-search aggregating multiple engines.
    /// The wearer points at their own instance or a trusted public one — no API key.
    private func searchSearXNG(query: String, recency: WebSearchRecency?) async -> String? {
        guard let url = Self.searxngSearchURL(baseURL: Config.searxngBaseURL, query: query,
                                              timeRange: recency?.filter(for: .searxng)?.value) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config)

        do {
            let (data, response) = try await session.consentedData(for: request, scope: .webSearch)

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                PrivacyLog.webSearch(.searxng, succeeded: false,
                                     status: (response as? HTTPURLResponse)?.statusCode ?? 0)
                return nil
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]], !results.isEmpty else {
                PrivacyLog.webSearch(.searxng, succeeded: false, results: 0)
                return nil
            }

            func clean(_ text: String) -> String {
                text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            }

            let snippets = results.prefix(5).compactMap { item -> String? in
                let content = (item["content"] as? String).map(clean) ?? ""
                let title = (item["title"] as? String).map(clean) ?? ""
                if !content.isEmpty {
                    return title.isEmpty ? content : "\(title): \(content)"
                }
                return title.isEmpty ? nil : title
            }
            guard !snippets.isEmpty else {
                PrivacyLog.webSearch(.searxng, succeeded: false, results: results.count)
                return nil
            }

            PrivacyLog.webSearch(.searxng, succeeded: true, results: results.count)
            return WebSearchResultFormat.compose(header: "Search result for \"\(query)\" (via SearXNG)",
                                                 summary: snippets.joined(separator: " · "),
                                                 links: Self.titledLinks(results))

        } catch let refusal as CloudProcessingRefusal {
            return refusal.localizedDescription
        } catch {
            PrivacyLog.webSearch(.searxng, succeeded: false, error: SafeErrorSummary(error))
            return nil
        }
    }

    /// Build `{base}/search?q=…&format=json`, keeping any path on the instance URL
    /// (`https://host/searx/` → `https://host/searx/search?…`). Query items encode `&`, `=` and
    /// `#`; `+` is escaped by hand because URLComponents leaves it literal and servers read it as a space.
    nonisolated static func searxngSearchURL(baseURL: String, query: String, timeRange: String? = nil) -> URL? {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty,
              var components = URLComponents(string: base),
              components.scheme != nil, components.host?.isEmpty == false else {
            return nil
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/search"
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
        ] + (timeRange.map { [URLQueryItem(name: "time_range", value: $0)] } ?? [])
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    // MARK: - DuckDuckGo Fallback

    private func searchDuckDuckGo(query: String) async -> String {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.duckduckgo.com/?q=\(encoded)&format=json&no_html=1&skip_disambig=1") else {
            return "Couldn't build search URL."
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: config)

        do {
            let (data, response) = try await session.consentedData(for: URLRequest(url: url), scope: .webSearch)

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return "Search service is temporarily unavailable."
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return "Couldn't parse search results."
            }

            // Try direct answer first
            if let answer = json["Answer"] as? String, !answer.isEmpty {
                return "Search result for \"\(query)\": \(answer)"
            }

            // Try abstract
            if let abstract = json["AbstractText"] as? String, !abstract.isEmpty {
                return Self.duckDuckGoAbstract(query: query, json: json)
            }

            // Try related topics
            if let topics = json["RelatedTopics"] as? [[String: Any]], !topics.isEmpty {
                let summaries = topics.prefix(3).compactMap { topic -> String? in
                    topic["Text"] as? String
                }
                if !summaries.isEmpty {
                    return "Search results for \"\(query)\": \(summaries.joined(separator: ". "))"
                }
            }

            return Self.noClearAnswer(query: query)

        } catch let refusal as CloudProcessingRefusal {
            return refusal.localizedDescription
        } catch {
            return "Search failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Result shapes (pure)

    /// Perplexity's sources: `search_results` (title and address) when sent, else `citations`.
    nonisolated static func perplexityLinks(_ json: [String: Any]) -> [WebSearchResultFormat.Link] {
        if let results = json["search_results"] as? [[String: Any]] {
            let links = titledLinks(results)
            if !links.isEmpty { return links }
        }
        return (json["citations"] as? [String] ?? []).map { WebSearchResultFormat.Link(url: $0) }
    }

    /// Results carrying `url` and `title` (Tavily, SearXNG, Perplexity's `search_results`).
    nonisolated static func titledLinks(_ results: [[String: Any]]) -> [WebSearchResultFormat.Link] {
        results.compactMap { item in
            guard let url = item["url"] as? String, !url.isEmpty else { return nil }
            return WebSearchResultFormat.Link(url: url, title: item["title"] as? String)
        }
    }

    /// Brave's results, with the site's own name from `profile.name`.
    nonisolated static func braveLinks(_ results: [[String: Any]]) -> [WebSearchResultFormat.Link] {
        results.compactMap { item in
            guard let url = item["url"] as? String, !url.isEmpty else { return nil }
            let profile = item["profile"] as? [String: Any]
            return WebSearchResultFormat.Link(url: url, title: item["title"] as? String,
                                              siteName: profile?["name"] as? String)
        }
    }

    /// DuckDuckGo's abstract, named by its `AbstractSource` at its `AbstractURL`.
    nonisolated static func duckDuckGoAbstract(query: String, json: [String: Any]) -> String {
        let abstract = json["AbstractText"] as? String ?? ""
        let links = (json["AbstractURL"] as? String).map {
            [WebSearchResultFormat.Link(url: $0, siteName: json["AbstractSource"] as? String)]
        } ?? []
        return WebSearchResultFormat.compose(header: "Search result for \"\(query)\"", summary: abstract, links: links)
    }

    /// Brave's search address, with its `freshness` filter when a recency was asked for.
    nonisolated static func braveSearchURL(query: String, recency: WebSearchRecency?) -> URL? {
        guard var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search") else { return nil }
        var items = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "count", value: "5")]
        if let filter = recency?.filter(for: .brave) { items.append(URLQueryItem(name: filter.name, value: filter.value)) }
        components.queryItems = items
        // URLComponents leaves `+` literal, and servers read it as a space.
        let encoded = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components.percentEncodedQuery = encoded
        return components.url
    }

    nonisolated static func noClearAnswer(query: String) -> String {
        "No verified search answer was found for \"\(query)\". "
            + "This result does not confirm the requested fact. For current events, schedules, "
            + "scores or other time-sensitive information, do not substitute an answer from memory. "
            + "Say you could not verify it, or ask for clarification if the event is ambiguous."
    }
}
