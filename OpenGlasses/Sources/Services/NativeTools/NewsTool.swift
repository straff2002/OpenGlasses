import Foundation

/// Fetches top news headlines from Google News RSS. No API key needed.
struct NewsTool: NativeTool {
    let name = "get_news"
    let description = "Get the latest news headlines. Optionally filter by topic."
    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "topic": [
                "type": "string",
                "description": "Optional topic to filter news, e.g. 'technology', 'sports', 'business'"
            ]
        ],
        "required": [] as [String]
    ]

    func execute(args: [String: Any]) async throws -> String {
        guard MedicalEgressGuard.allows(.newsHeadlines) else { return MedicalEgressRefusal.userMessage }
        let topic = args["topic"] as? String

        var urlString = "https://news.google.com/rss?hl=en&gl=US&ceid=US:en"
        if let topic, !topic.isEmpty {
            if let encoded = topic.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                urlString = "https://news.google.com/rss/search?q=\(encoded)&hl=en&gl=US&ceid=US:en"
            }
        }

        guard let url = URL(string: urlString) else {
            return "Couldn't build news URL."
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: config)

        let (data, response) = try await session.data(from: url)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return "News service is temporarily unavailable."
        }

        guard let xmlString = String(data: data, encoding: .utf8) else {
            return "Couldn't read news data."
        }

        let headlines = parseRSSHeadlines(xmlString, maxItems: 5)

        guard !headlines.isEmpty else {
            if let topic {
                return "No news found for \"\(topic)\"."
            }
            return "Couldn't find any news headlines right now."
        }

        let topicStr = topic.map { " about \($0)" } ?? ""
        var result = "Top headlines\(topicStr): "
        result += headlines.enumerated().map { (i, h) in
            "\(i + 1). \(h)"
        }.joined(separator: ". ")

        return result
    }

    /// Simple RSS title extraction without a full XML parser
    private func parseRSSHeadlines(_ xml: String, maxItems: Int) -> [String] {
        var headlines: [String] = []
        var searchRange = xml.startIndex..<xml.endIndex
        var isFirstItem = true

        while headlines.count < maxItems {
            guard let itemStart = xml.range(of: "<item>", range: searchRange) else { break }
            guard let itemEnd = xml.range(of: "</item>", range: itemStart.upperBound..<xml.endIndex) else { break }

            let itemContent = xml[itemStart.upperBound..<itemEnd.lowerBound]

            if let titleStart = itemContent.range(of: "<title>"),
               let titleEnd = itemContent.range(of: "</title>", range: titleStart.upperBound..<itemContent.endIndex) {
                var title = String(itemContent[titleStart.upperBound..<titleEnd.lowerBound])
                // Strip CDATA if present
                title = title.replacingOccurrences(of: "<![CDATA[", with: "")
                title = title.replacingOccurrences(of: "]]>", with: "")
                title = title.trimmingCharacters(in: .whitespacesAndNewlines)

                // Skip first item for topic searches as it's often the search header
                if isFirstItem && title.lowercased().contains("google news") {
                    isFirstItem = false
                    searchRange = itemEnd.upperBound..<xml.endIndex
                    continue
                }

                if !title.isEmpty {
                    headlines.append(title)
                }
            }

            isFirstItem = false
            searchRange = itemEnd.upperBound..<xml.endIndex
        }

        return headlines
    }
}
